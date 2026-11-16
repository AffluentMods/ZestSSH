//! A Mosh session's thread: UDP sockets, timers and events for the app around a [Connection].
//!
//! Roaming: the server takes a datagram from a new address as the client's new address once it
//! opens and is newer than any before, so the client only has to keep sending. When the server
//! has not been heard for [HOP_AFTER_MS] the client also sends from a new socket (a new local
//! port), which gets a new mapping through a NAT that dropped the old one; the old socket is
//! still read for a while for datagrams already on their way.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;
use tokio::sync::mpsc::UnboundedReceiver;

use super::connection::{Connection, Incoming, IncomingError};
use super::crypto::Key;
use super::sync::Received;
use super::wire::HostEvent;
use super::{Command, Notifier, OpenRequest, event};

/// How long to wait for the server's first answer when the request does not say (ms).
const FIRST_ANSWER_MS: u64 = 15_000;
/// How long a close waits for the server to acknowledge it (ms).
const SHUTDOWN_WAIT_MS: u64 = 2_000;
/// Silence after which the client sends from a new local port (ms), and no more often.
const HOP_AFTER_MS: u64 = 10_000;
/// How long a socket left behind by a hop is still read (ms).
const OLD_SOCKET_MS: u64 = 60_000;
/// The status event's period (ms).
const STATUS_EVERY_MS: u64 = 1_000;
/// The largest datagram read (UDP's own limit).
const RECV_BUFFER: usize = 65_536;

/// How a session ended, for CLOSED.
struct Closed {
    reason: &'static str,
    message: String,
}

impl Closed {
    fn new(reason: &'static str, message: impl Into<String>) -> Self {
        Self { reason, message: message.into() }
    }

    fn json(&self) -> serde_json::Value {
        serde_json::json!({ "reason": self.reason, "message": self.message })
    }
}

/// Runs one session to its end, always with CLOSED last, whatever happens in it (a panic
/// included: it closes this session with "internal", never the app).
pub fn run(request: OpenRequest, commands: UnboundedReceiver<Command>, notifier: Notifier) {
    let closed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_io().enable_time().build();
        match runtime {
            Ok(rt) => rt.block_on(session(request, commands, notifier)),
            Err(e) => Closed::new("internal", format!("runtime: {e}")),
        }
    }))
    .unwrap_or_else(|_| Closed::new("internal", "the Mosh engine stopped unexpectedly"));
    notifier.json(event::CLOSED, closed.json());
}

/// Random padding for an instruction (0 to 16 bytes), so its length says less about what was
/// typed.
fn chaff() -> Vec<u8> {
    use ring::rand::SecureRandom as _;
    let rng = ring::rand::SystemRandom::new();
    let mut len = [0u8; 1];
    if rng.fill(&mut len).is_err() {
        return Vec::new();
    }
    let mut out = vec![0u8; usize::from(len[0] % 17)];
    let _ = rng.fill(&mut out);
    out
}

async fn bind(v6: bool) -> std::io::Result<UdpSocket> {
    let any = if v6 { IpAddr::V6(Ipv6Addr::UNSPECIFIED) } else { IpAddr::V4(Ipv4Addr::UNSPECIFIED) };
    UdpSocket::bind(SocketAddr::new(any, 0)).await
}

/// A socket's next datagram, or never when there is no socket.
async fn recv_on(socket: Option<&UdpSocket>, buf: &mut [u8]) -> std::io::Result<(usize, SocketAddr)> {
    match socket {
        Some(s) => s.recv_from(buf).await,
        None => std::future::pending().await,
    }
}

struct Sockets {
    v4: Option<UdpSocket>,
    v6: Option<UdpSocket>,
    /// The socket a hop left behind, read until the time given.
    old: Option<(UdpSocket, u64)>,
}

/// The server's address that [from] is, if it is one: one of [targets] (the addresses the app
/// gave, by address and port), and once the server has answered ([target]), that one alone. The
/// client never follows the server to another address (the server follows the client when the
/// client roams, never the other way): a datagram from anywhere else is dropped before it is
/// opened, so nobody who can send to this device's port can draw its datagrams elsewhere.
///
/// An IPv4 address and the same address mapped into IPv6 (::ffff:192.0.2.1, what a dual-stack
/// socket reports for an IPv4 peer) are the same server: both sides are compared canonically, so
/// a datagram from 192.0.2.1 reported as ::ffff:192.0.2.1 still matches the 192.0.2.1 given, and
/// the other way round. What is returned is the address as given, which the datagrams go to.
fn from_the_server(from: &SocketAddr, targets: &[SocketAddr], target: Option<SocketAddr>) -> Option<SocketAddr> {
    let from_ip = from.ip().to_canonical();
    let same = |a: &SocketAddr| a.ip().to_canonical() == from_ip && a.port() == from.port();
    match target {
        Some(t) => same(&t).then_some(t),
        None => targets.iter().find(|a| same(a)).copied(),
    }
}

impl Sockets {
    fn for_addr(&self, a: &SocketAddr) -> Option<&UdpSocket> {
        if a.is_ipv6() { self.v6.as_ref() } else { self.v4.as_ref() }
    }
}

async fn session(request: OpenRequest, mut commands: UnboundedReceiver<Command>, n: Notifier) -> Closed {
    let OpenRequest { addresses, port, key: key_text, cols, rows, first_answer_ms } = request;
    let parsed = Key::parse(&key_text);
    // The key's text is wiped now (Secret); the parsed key once the cipher holds it.
    drop(key_text);
    let key = match parsed {
        Ok(k) => k,
        Err(e) => return Closed::new("key", e.to_string()),
    };
    // The key lives only as long as this session, in the cipher. Never add "resume with a saved
    // key" (a session picked up again after the app restarts) without persisting the datagram
    // counter with it: the same key with a counter that starts again at 0 reuses OCB nonces.
    let mut conn = Connection::new(&key);
    drop(key);

    let targets: Vec<SocketAddr> = addresses
        .iter()
        .filter_map(|a| a.trim().trim_start_matches('[').trim_end_matches(']').parse::<IpAddr>().ok())
        .map(|ip| SocketAddr::new(ip, port))
        .collect();
    if targets.is_empty() || port == 0 {
        return Closed::new("internal", "no server address to send to");
    }
    let mut sockets = Sockets { v4: None, v6: None, old: None };
    let mut bind_error = None;
    for v6 in [false, true] {
        if targets.iter().any(|t| t.is_ipv6() == v6) {
            match bind(v6).await {
                Ok(s) if v6 => sockets.v6 = Some(s),
                Ok(s) => sockets.v4 = Some(s),
                Err(e) => bind_error = Some(e),
            }
        }
    }
    if sockets.v4.is_none() && sockets.v6.is_none() {
        let why = bind_error.map(|e| format!(": {e}")).unwrap_or_default();
        return Closed::new("network", format!("could not open a UDP socket{why}"));
    }

    let start = Instant::now();
    let now = || u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
    let first_answer = first_answer_ms.unwrap_or(FIRST_ANSWER_MS);
    conn.resize(cols, rows, 0);

    let mut target: Option<SocketAddr> = None;
    let mut last_hop = 0u64;
    let mut next_status = STATUS_EVERY_MS;
    let mut shutdown_since: Option<u64> = None;
    let mut send_failures = 0u64;
    let mut reported_drops = 0u64;
    // Datagrams from an address that is not the server's, dropped unopened.
    let mut foreign = 0u64;
    let mut reported_foreign = 0u64;
    // The app's end of the commands: gone once it closed the session.
    let mut commands_open = true;
    let (mut b4, mut b6, mut bold) = (vec![0u8; RECV_BUFFER], vec![0u8; RECV_BUFFER], vec![0u8; RECV_BUFFER]);

    loop {
        let t = now();

        // Send what is due: to the server's address once it answered, to each address the app
        // gave until then. Never anywhere else.
        let out = conn.outgoing(t, chaff());
        if !out.is_empty() {
            let dests: Vec<SocketAddr> = match target {
                Some(a) => vec![a],
                None => targets.clone(),
            };
            for d in &out {
                for a in &dests {
                    if let Some(s) = sockets.for_addr(a)
                        && s.send_to(d, a).await.is_err()
                    {
                        // A network that is going or coming (roaming): the next send tries again.
                        send_failures += 1;
                    }
                }
            }
            // The server's shutdown, acknowledged: the session is over.
            if conn.receiver.shutdown() {
                return Closed::new("server_closed", "the session ended on the host");
            }
        }

        if let Some(since) = shutdown_since
            && (conn.sender.shutdown_acknowledged() || t.saturating_sub(since) >= SHUTDOWN_WAIT_MS)
        {
            return Closed::new("local", "closed");
        }
        if conn.last_heard.is_none() && t >= first_answer && shutdown_since.is_none() {
            return Closed::new(
                "no_answer",
                format!(
                    "no answer from mosh-server on UDP port {port} within {} s ({} datagrams could not be sent)",
                    first_answer / 1000,
                    send_failures
                ),
            );
        }

        // Status, and a hop to a new port after a long silence.
        if t >= next_status {
            next_status = t + STATUS_EVERY_MS;
            let heard = conn.last_heard.map(|h| t.saturating_sub(h));
            n.json(
                event::STATUS,
                serde_json::json!({ "last_heard_ms": heard, "srtt_ms": conn.rtt.srtt().round() as u64 }),
            );
            if conn.dropped > reported_drops || foreign > reported_foreign {
                reported_drops = conn.dropped;
                reported_foreign = foreign;
                n.json(event::INFO, serde_json::json!({ "dropped": conn.dropped, "foreign": foreign }));
            }
            if let (Some(h), Some(a)) = (heard, target)
                && h >= HOP_AFTER_MS
                && t.saturating_sub(last_hop) >= HOP_AFTER_MS
                && let Ok(fresh) = bind(a.is_ipv6()).await
            {
                last_hop = t;
                let slot = if a.is_ipv6() { &mut sockets.v6 } else { &mut sockets.v4 };
                if let Some(previous) = slot.replace(fresh) {
                    sockets.old = Some((previous, t + OLD_SOCKET_MS));
                }
                n.json(event::INFO, serde_json::json!({ "new_local_port": true }));
            }
            if sockets.old.as_ref().is_some_and(|(_, until)| t >= *until) {
                sockets.old = None;
            }
        }

        // Wait for the next thing to do.
        let due = conn.next_due().min(next_status).max(t);
        let wake = tokio::time::Instant::from_std(start + Duration::from_millis(due));
        let got = tokio::select! {
            biased;
            cmd = commands.recv(), if commands_open => {
                if cmd.is_none() {
                    // The app let go of the session: as a close, and nothing more to read.
                    commands_open = false;
                }
                match cmd {
                    Some(Command::Keys(k)) => {
                        if shutdown_since.is_none() {
                            conn.keys(&k, now());
                        }
                    }
                    Some(Command::Resize { cols, rows }) => {
                        if shutdown_since.is_none() {
                            conn.resize(cols, rows, now());
                        }
                    }
                    Some(Command::Close) | None => {
                        if shutdown_since.is_none() {
                            // Never heard from: nobody to tell.
                            if conn.last_heard.is_none() {
                                return Closed::new("local", "closed");
                            }
                            let t = now();
                            shutdown_since = Some(t);
                            conn.sender.start_shutdown(t);
                        }
                    }
                }
                None
            }
            r = recv_on(sockets.v4.as_ref(), &mut b4) => r.ok().map(|(len, from)| (b4[..len].to_vec(), from)),
            r = recv_on(sockets.v6.as_ref(), &mut b6) => r.ok().map(|(len, from)| (b6[..len].to_vec(), from)),
            r = recv_on(sockets.old.as_ref().map(|(s, _)| s), &mut bold) => r.ok().map(|(len, from)| (bold[..len].to_vec(), from)),
            () = tokio::time::sleep_until(wake) => None,
        };
        let Some((bytes, from)) = got else { continue };
        // Only the server's address, and once it answered only the address it answered from: a
        // datagram from anywhere else is not even opened.
        let Some(server) = from_the_server(&from, &targets, target) else {
            foreign += 1;
            continue;
        };

        let t = now();
        let heard_before = conn.last_heard;
        let result = conn.incoming(&bytes, t);
        if target.is_none() && conn.last_heard != heard_before {
            // The first datagram that opened: the server is at this one of the addresses, from now
            // on the only one sent to.
            n.json(event::CONNECTED, serde_json::json!({ "address": server.to_string() }));
            target = Some(server);
        }
        match result {
            Ok(Incoming::Instruction(Received::Applied { events, .. })) => {
                for e in events {
                    match e {
                        HostEvent::Bytes(b) if !b.is_empty() => n.bytes(event::HOST_BYTES, 0, b),
                        HostEvent::Resize { width, height } => {
                            n.json(event::INFO, serde_json::json!({ "server_size": [width, height] }));
                        }
                        _ => {}
                    }
                }
            }
            Ok(_) => {}
            Err(IncomingError::Version(v)) => {
                return Closed::new(
                    "protocol",
                    format!("the server speaks Mosh protocol version {v}, which this client does not"),
                );
            }
            // Damaged, foreign or malformed: dropped (counted in the status).
            Err(_) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mosh::connection::fake_server::FakeServer;
    use std::sync::mpsc;

    static EVENTS: Mutex<Vec<(u64, u32, Vec<u8>)>> = Mutex::new(Vec::new());
    use std::sync::Mutex;

    extern "C" fn record(handle: u64, kind: u32, _a: i64, data: *mut u8, len: usize) {
        let bytes = if data.is_null() {
            Vec::new()
        } else {
            // SAFETY: the callback's bytes, freed right after the copy.
            let v = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
            unsafe { crate::mosh::free_bytes(data, len) };
            v
        };
        EVENTS.lock().unwrap().push((handle, kind, bytes));
    }

    fn events_of(handle: u64) -> Vec<(u32, Vec<u8>)> {
        EVENTS.lock().unwrap().iter().filter(|e| e.0 == handle).map(|e| (e.1, e.2.clone())).collect()
    }

    fn wait_for(handle: u64, kind: u32, secs: u64) -> Option<Vec<u8>> {
        let until = Instant::now() + Duration::from_secs(secs);
        while Instant::now() < until {
            if let Some((_, b)) = events_of(handle).into_iter().find(|e| e.0 == kind) {
                return Some(b);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        None
    }

    /// A fake server on a real UDP socket on this machine: the whole client, over the network
    /// stack, with its first answer, keys, screen, a close and its acknowledgement.
    #[test]
    fn a_session_against_a_fake_server_on_udp() {
        let server = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        server.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let port = server.local_addr().unwrap().port();
        let key = Key::from_bytes([5; 16]);
        let req = serde_json::json!({
            "addresses": ["127.0.0.1"], "port": port, "key": key.printed(), "cols": 100, "rows": 30,
        });
        let h = crate::mosh::open(&req.to_string(), record).unwrap();
        let mut fake = FakeServer::new(&key);
        let (tx, rx) = mpsc::channel();
        let srv = std::thread::spawn(move || {
            let mut buf = [0u8; 65536];
            let mut client = None;
            let mut sent_screen = false;
            let deadline = Instant::now() + Duration::from_secs(10);
            while Instant::now() < deadline {
                let Ok((len, from)) = server.recv_from(&mut buf) else { break };
                client = Some(from);
                let Some(inst) = fake.take(&buf[..len]) else { continue };
                if !sent_screen {
                    sent_screen = true;
                    for d in fake.screen(0, 1, b"hello from the fake", true) {
                        server.send_to(&d, from).unwrap();
                    }
                }
                if inst.new_num == crate::mosh::sync::SHUTDOWN_NUM {
                    // Acknowledge the client's shutdown.
                    let ack = crate::mosh::wire::Instruction {
                        protocol_version: Some(2),
                        old_num: 1,
                        new_num: 1,
                        ack_num: crate::mosh::sync::SHUTDOWN_NUM,
                        ..Default::default()
                    };
                    for d in fake.send(&ack, true) {
                        server.send_to(&d, from).unwrap();
                    }
                    break;
                }
            }
            tx.send((fake.events.clone(), client)).unwrap();
        });
        assert!(wait_for(h, event::CONNECTED, 5).is_some(), "connected");
        assert_eq!(wait_for(h, event::HOST_BYTES, 5).unwrap(), b"hello from the fake");
        crate::mosh::keys(h, b"ls\r");
        std::thread::sleep(Duration::from_millis(400));
        crate::mosh::close(h);
        let closed = wait_for(h, event::CLOSED, 5).expect("closed");
        let v: serde_json::Value = serde_json::from_slice(&closed).unwrap();
        assert_eq!(v["reason"], "local");
        let (events, _) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        srv.join().unwrap();
        assert_eq!(events.first(), Some(&crate::mosh::wire::UserEvent::Resize { width: 100, height: 30 }));
        assert!(events.contains(&crate::mosh::wire::UserEvent::Keys(b"ls\r".to_vec())), "{events:?}");
        assert_eq!(events_of(h).last().map(|e| e.0), Some(event::CLOSED), "CLOSED is the last event");
    }

    /// The client never follows the server to another address: a valid, newer datagram of the
    /// server's (the right key, the next counter) that comes from a foreign address is dropped
    /// unopened. Nothing of it is shown, CONNECTED named the server's own address, and what is
    /// typed next still goes to the server's address, never the foreign one.
    #[test]
    fn a_server_datagram_from_a_foreign_address_moves_nothing() {
        let server = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let foreign = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        server.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        foreign.set_read_timeout(Some(Duration::from_millis(300))).unwrap();
        let port = server.local_addr().unwrap().port();
        let key = Key::from_bytes([6; 16]);
        let req = serde_json::json!({
            "addresses": ["127.0.0.1"], "port": port, "key": key.printed(), "cols": 80, "rows": 24,
        });
        let h = crate::mosh::open(&req.to_string(), record).unwrap();
        let mut fake = FakeServer::new(&key);
        let mut buf = [0u8; 65536];
        // The client's first datagram, then the server's answer from its own address.
        let (len, client) = server.recv_from(&mut buf).unwrap();
        fake.take(&buf[..len]);
        for d in fake.screen(0, 1, b"from the server", true) {
            server.send_to(&d, client).unwrap();
        }
        assert_eq!(wait_for(h, event::HOST_BYTES, 5).unwrap(), b"from the server");
        let connected: serde_json::Value = serde_json::from_slice(&wait_for(h, event::CONNECTED, 5).unwrap()).unwrap();
        assert_eq!(connected["address"], format!("127.0.0.1:{port}"));
        // A newer datagram of the server's, sent from elsewhere.
        for d in fake.screen(1, 2, b"from elsewhere", true) {
            foreign.send_to(&d, client).unwrap();
        }
        std::thread::sleep(Duration::from_millis(300));
        let shown: Vec<u8> = events_of(h).into_iter().filter(|e| e.0 == event::HOST_BYTES).flat_map(|e| e.1).collect();
        assert_eq!(shown, b"from the server", "nothing from the foreign address is shown");
        // What is typed next goes to the server's address alone.
        crate::mosh::keys(h, b"x");
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut typed = false;
        while !typed && Instant::now() < deadline {
            let Ok((len, _)) = server.recv_from(&mut buf) else { break };
            fake.take(&buf[..len]);
            typed = fake.events.contains(&crate::mosh::wire::UserEvent::Keys(b"x".to_vec()));
        }
        assert!(typed, "the keys reached the server's address");
        assert!(foreign.recv_from(&mut buf).is_err(), "nothing was sent to the foreign address");
        assert_eq!(events_of(h).iter().filter(|e| e.0 == event::CONNECTED).count(), 1);
        crate::mosh::close(h);
        wait_for(h, event::CLOSED, 5);
    }

    #[test]
    fn only_the_given_addresses_and_then_the_one_that_answered() {
        let a: SocketAddr = "192.0.2.1:60001".parse().unwrap();
        let b: SocketAddr = "[2001:db8::1]:60001".parse().unwrap();
        let targets = [a, b];
        assert_eq!(from_the_server(&a, &targets, None), Some(a));
        assert_eq!(from_the_server(&b, &targets, None), Some(b));
        assert_eq!(from_the_server(&"192.0.2.1:60002".parse().unwrap(), &targets, None), None, "another port");
        assert_eq!(from_the_server(&"192.0.2.9:60001".parse().unwrap(), &targets, None), None, "another address");
        assert_eq!(from_the_server(&b, &targets, Some(a)), None, "once one answered, the other is foreign too");
        assert_eq!(from_the_server(&a, &targets, Some(a)), Some(a));
    }

    /// A dual-stack socket reports an IPv4 server as ::ffff:a.b.c.d: still the server, and the
    /// address given is the one returned (and sent to). Mapped the other way round matches too;
    /// another address, another port, or an IPv4-compatible (::a.b.c.d) form does not.
    #[test]
    fn an_ipv4_mapped_address_is_the_ipv4_server() {
        let a: SocketAddr = "192.0.2.1:60001".parse().unwrap();
        let mapped: SocketAddr = "[::ffff:192.0.2.1]:60001".parse().unwrap();
        let b: SocketAddr = "[2001:db8::1]:60001".parse().unwrap();
        let targets = [a, b];
        assert_eq!(from_the_server(&mapped, &targets, None), Some(a));
        assert_eq!(from_the_server(&mapped, &targets, Some(a)), Some(a));
        assert_eq!(from_the_server(&mapped, &targets, Some(b)), None, "once the IPv6 one answered");
        assert_eq!(from_the_server(&"[::ffff:192.0.2.1]:60002".parse().unwrap(), &targets, None), None, "another port");
        assert_eq!(from_the_server(&"[::ffff:192.0.2.9]:60001".parse().unwrap(), &targets, None), None, "another address");
        assert_eq!(from_the_server(&"[::192.0.2.1]:60001".parse().unwrap(), &targets, None), None, "IPv4-compatible is not mapped");

        // The app gave the mapped form: a datagram from the plain IPv4 address is still the server.
        let given = [mapped];
        assert_eq!(from_the_server(&a, &given, None), Some(mapped));
        assert_eq!(from_the_server(&a, &given, Some(mapped)), Some(mapped));
    }

    /// Nothing answers: the session ends with no_answer, saying the port.
    #[test]
    fn no_answer_is_said_with_the_port() {
        // A bound socket that never answers.
        let silent = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        let port = silent.local_addr().unwrap().port();
        let req = serde_json::json!({
            "addresses": ["127.0.0.1"], "port": port, "key": Key::from_bytes([1; 16]).printed(),
            "cols": 80, "rows": 24, "first_answer_ms": 600,
        });
        let h = crate::mosh::open(&req.to_string(), record).unwrap();
        let closed = wait_for(h, event::CLOSED, 5).expect("closed");
        let v: serde_json::Value = serde_json::from_slice(&closed).unwrap();
        assert_eq!(v["reason"], "no_answer");
        assert!(v["message"].as_str().unwrap().contains(&format!("UDP port {port}")));
    }

    #[test]
    fn a_bad_key_closes_with_key_and_never_says_it() {
        let req = serde_json::json!({
            "addresses": ["127.0.0.1"], "port": 60001, "key": "secret-not-a-key!!!!!!", "cols": 80, "rows": 24,
        });
        let h = crate::mosh::open(&req.to_string(), record).unwrap();
        let closed = wait_for(h, event::CLOSED, 5).expect("closed");
        let text = String::from_utf8(closed).unwrap();
        assert!(text.contains("\"key\""), "{text}");
        assert!(!text.contains("secret-not-a-key"), "{text}");
    }

    #[test]
    fn a_request_that_does_not_parse_is_refused_without_repeating_it() {
        let e = crate::mosh::open(r#"{"key": "abcdefghijklmnopqrstuv", "port": "#, record).unwrap_err();
        assert!(!e.contains("abcdef"), "{e}");
    }
}

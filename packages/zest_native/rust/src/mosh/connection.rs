//! One Mosh session's protocol, without sockets or clocks: datagrams in and out, time given as
//! milliseconds since the session began. client.rs runs it over UDP; the tests and the fuzz
//! target run it directly.
//!
//! Layers, from the wire up: datagram.rs (sealing, direction, timestamps), fragment.rs (pieces
//! and zlib), wire.rs (the instruction and the two diffs), sync.rs (the two objects).

use super::crypto::{Cipher, Key};
use super::datagram::{self, Datagram, DatagramError, NO_REPLY, OVERHEAD, stamp_diff};
use super::fragment::{self, Assembler, Fragment, FragmentError, Fragmenter, HEADER_LEN};
use super::sync::{ReceiveError, Received, Receiver, Rtt, Sender};
use super::wire::{Instruction, UserEvent, WireError};

/// The largest datagram this client sends (bytes of UDP payload): small enough for any path,
/// as Mosh keeps its own (a keystroke is far smaller; a paste goes in several).
pub const SEND_MTU: usize = 500;
/// A round trip measured above this (ms) is not believed (a stale echo).
const MAX_RTT_SAMPLE: u16 = 5000;
/// A timestamp held longer than this (ms) is not echoed.
const MAX_STAMP_HOLD: u64 = 1000;

/// Why a datagram from the network was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncomingError {
    Datagram(DatagramError),
    Fragment(FragmentError),
    Wire(WireError),
    /// The server speaks another protocol version: the session cannot go on.
    Version(u32),
}

impl std::fmt::Display for IncomingError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Datagram(e) => write!(f, "datagram: {e:?}"),
            Self::Fragment(e) => write!(f, "fragment: {e:?}"),
            Self::Wire(e) => write!(f, "message: {e}"),
            Self::Version(v) => write!(f, "the server speaks Mosh protocol version {v}, this client 2"),
        }
    }
}

/// What a datagram from the network did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    /// A piece of an instruction still being put together.
    Partial,
    /// A whole instruction.
    Instruction(Received),
}

pub struct Connection {
    cipher: Cipher,
    next_seq: u64,
    fragmenter: Fragmenter,
    assembler: Assembler,
    pub sender: Sender,
    pub receiver: Receiver,
    pub rtt: Rtt,
    /// The server's last timestamp and when it came, to echo.
    saved_stamp: Option<(u16, u64)>,
    highest_seq: Option<u64>,
    /// When the server was last heard from (a newer datagram that opened).
    pub last_heard: Option<u64>,
    /// Datagrams dropped, by what was wrong (for the log).
    pub dropped: u64,
}

fn stamp(now: u64) -> u16 {
    (now % 65536) as u16
}

impl Connection {
    pub fn new(key: &Key) -> Self {
        Self {
            cipher: Cipher::new(key),
            next_seq: 0,
            fragmenter: Fragmenter::default(),
            assembler: Assembler::default(),
            sender: Sender::default(),
            receiver: Receiver::default(),
            rtt: Rtt::default(),
            saved_stamp: None,
            highest_seq: None,
            last_heard: None,
            dropped: 0,
        }
    }

    pub fn keys(&mut self, bytes: &[u8], now: u64) {
        if !bytes.is_empty() {
            self.sender.push(UserEvent::Keys(bytes.to_vec()), now);
        }
    }

    pub fn resize(&mut self, width: u16, height: u16, now: u64) {
        self.sender.push(UserEvent::Resize { width: i32::from(width), height: i32::from(height) }, now);
    }

    /// When [outgoing] next has something to send.
    pub fn next_due(&self) -> u64 {
        self.sender.next_due(&self.rtt)
    }

    /// The datagrams to send now ([chaff] is random padding for the instruction, if one goes).
    pub fn outgoing(&mut self, now: u64, chaff: Vec<u8>) -> Vec<Vec<u8>> {
        let Some(inst) = self.sender.tick(now, &self.rtt, chaff) else { return Vec::new() };
        self.seal_instruction(&inst, now)
    }

    fn seal_instruction(&mut self, inst: &Instruction, now: u64) -> Vec<Vec<u8>> {
        let room = SEND_MTU - OVERHEAD - HEADER_LEN;
        let frags = self.fragmenter.split(&inst.encode(), room);
        let reply = match self.saved_stamp.take() {
            Some((ts, at)) if now.saturating_sub(at) < MAX_STAMP_HOLD => ts.wrapping_add((now - at) as u16),
            _ => NO_REPLY,
        };
        frags
            .into_iter()
            .map(|f| {
                let seq = self.next_seq;
                self.next_seq += 1;
                datagram::seal(&self.cipher, seq, false, stamp(now), reply, &f.encode())
            })
            .collect()
    }

    /// One datagram from the network.
    pub fn incoming(&mut self, bytes: &[u8], now: u64) -> Result<Incoming, IncomingError> {
        let d = match datagram::open(&self.cipher, bytes, true) {
            Ok(d) => d,
            Err(e) => {
                self.dropped += 1;
                return Err(IncomingError::Datagram(e));
            }
        };
        self.heard(&d, now);
        let f = Fragment::decode(&d.payload).map_err(IncomingError::Fragment)?;
        let Some(whole) = self.assembler.add(f).map_err(IncomingError::Fragment)? else { return Ok(Incoming::Partial) };
        let bytes = fragment::decompress(&whole).map_err(IncomingError::Fragment)?;
        let inst = Instruction::decode(&bytes).map_err(IncomingError::Wire)?;
        self.sender.acknowledged(inst.ack_num);
        let got = self.receiver.receive(&inst).map_err(|e| match e {
            ReceiveError::Version(v) => IncomingError::Version(v.0),
            ReceiveError::Wire(w) => IncomingError::Wire(w),
        })?;
        match &got {
            Received::Applied { shutdown, .. } => {
                self.sender.ack_num = self.receiver.current();
                self.sender.ack_soon(now, *shutdown);
            }
            Received::Duplicate | Received::NoBase => self.sender.ack_soon(now, false),
        }
        Ok(Incoming::Instruction(got))
    }

    /// Timing from a datagram that opened: only a newer one counts (a replayed old one neither
    /// measures the round trip nor says the server is there).
    fn heard(&mut self, d: &Datagram, now: u64) {
        if self.highest_seq.is_some_and(|h| d.seq <= h) {
            return;
        }
        self.highest_seq = Some(d.seq);
        self.last_heard = Some(now);
        self.saved_stamp = Some((d.timestamp, now));
        if d.timestamp_reply != NO_REPLY {
            let r = stamp_diff(stamp(now), d.timestamp_reply);
            if r < MAX_RTT_SAMPLE {
                self.rtt.sample(f64::from(r));
            }
        }
    }
}

/// The server's side, as much as the tests and the fuzz target need: it opens the client's
/// datagrams, keeps the client's events, and sends screen diffs. Not a Mosh server.
#[cfg(any(test, fuzzing))]
pub mod fake_server {
    use super::*;
    use crate::mosh::wire::{HostEvent, decode_user_message, encode_host_message};

    pub struct FakeServer {
        cipher: Cipher,
        seq: u64,
        fragmenter: Fragmenter,
        assembler: Assembler,
        /// Client states seen: number and events count.
        pub client_states: Vec<(u64, usize)>,
        pub events: Vec<UserEvent>,
        pub last_client_stamp: Option<u16>,
        pub screen_num: u64,
        pub acked_by_client: u64,
    }

    impl FakeServer {
        pub fn new(key: &Key) -> Self {
            Self {
                cipher: Cipher::new(key),
                seq: 0,
                fragmenter: Fragmenter::default(),
                assembler: Assembler::default(),
                client_states: vec![(0, 0)],
                events: Vec::new(),
                last_client_stamp: None,
                screen_num: 0,
                acked_by_client: 0,
            }
        }

        /// Takes a client datagram; returns the client's instruction once whole.
        pub fn take(&mut self, bytes: &[u8]) -> Option<Instruction> {
            let d = datagram::open(&self.cipher, bytes, false).ok()?;
            self.last_client_stamp = Some(d.timestamp);
            let whole = self.assembler.add(Fragment::decode(&d.payload).ok()?).ok()??;
            let inst = Instruction::decode(&fragment::decompress(&whole).ok()?).ok()?;
            self.acked_by_client = self.acked_by_client.max(inst.ack_num);
            let known = self.client_states.iter().any(|s| s.0 == inst.new_num);
            if !known && let Some(&(_, count)) = self.client_states.iter().find(|s| s.0 == inst.old_num) {
                let new = decode_user_message(&inst.diff).ok()?;
                self.events.truncate(count);
                self.events.extend(new);
                self.client_states.push((inst.new_num, self.events.len()));
            }
            Some(inst)
        }

        pub fn client_acked_num(&self) -> u64 {
            self.client_states.iter().map(|s| s.0).max().unwrap_or(0)
        }

        /// A datagram (or several) with a diff from [old] to [new] of [text].
        pub fn screen(&mut self, old: u64, new: u64, text: &[u8], echo_stamp: bool) -> Vec<Vec<u8>> {
            let inst = Instruction {
                protocol_version: Some(2),
                old_num: old,
                new_num: new,
                ack_num: self.client_acked_num(),
                throwaway_num: old,
                diff: if text.is_empty() { Vec::new() } else { encode_host_message(&[HostEvent::Bytes(text.to_vec())]) },
                chaff: Vec::new(),
            };
            self.screen_num = new;
            self.send(&inst, echo_stamp)
        }

        pub fn send(&mut self, inst: &Instruction, echo_stamp: bool) -> Vec<Vec<u8>> {
            let reply = if echo_stamp { self.last_client_stamp.unwrap_or(NO_REPLY) } else { NO_REPLY };
            self.fragmenter
                .split(&inst.encode(), 300)
                .into_iter()
                .map(|f| {
                    self.seq += 1;
                    datagram::seal(&self.cipher, self.seq, true, 0, reply, &f.encode())
                })
                .collect()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake_server::FakeServer;
    use super::*;
    use crate::mosh::sync::SHUTDOWN_NUM;
    use crate::mosh::wire::HostEvent;

    fn pair() -> (Connection, FakeServer) {
        let key = [3u8; 16];
        (Connection::new(&Key::from_bytes(key)), FakeServer::new(&Key::from_bytes(key)))
    }

    fn deliver(c: &mut Connection, s: &mut FakeServer, now: u64) -> Vec<Instruction> {
        c.outgoing(now, vec![9; 4]).iter().filter_map(|d| s.take(d)).collect()
    }

    fn shown(c: &mut Connection, datagrams: &[Vec<u8>], now: u64) -> Vec<u8> {
        let mut out = Vec::new();
        for d in datagrams {
            if let Ok(Incoming::Instruction(Received::Applied { events, .. })) = c.incoming(d, now) {
                for e in events {
                    if let HostEvent::Bytes(b) = e {
                        out.extend(b);
                    }
                }
            }
        }
        out
    }

    #[test]
    fn keys_reach_the_server_and_the_screen_comes_back() {
        let (mut c, mut s) = pair();
        c.resize(80, 24, 0);
        let got = deliver(&mut c, &mut s, 0);
        assert_eq!(got.len(), 1);
        assert_eq!(s.events, vec![UserEvent::Resize { width: 80, height: 24 }]);
        // The next frame waits for the frame interval (250 ms before any round trip is known).
        c.keys(b"ls\r", 300);
        deliver(&mut c, &mut s, 301);
        assert_eq!(s.events.last(), Some(&UserEvent::Keys(b"ls\r".to_vec())));
        let screen = s.screen(0, 1, b"file1  file2\r\n$ ", true);
        assert_eq!(shown(&mut c, &screen, 350), b"file1  file2\r\n$ ");
        assert!(c.last_heard.is_some());
        assert!(c.rtt.sampled(), "the echoed stamp measured the round trip");
        // The client acknowledges the server's state 1 within the delay, and the server's
        // acknowledgement of state 2 let the client's log go.
        assert_eq!(c.sender.ack_num, 1);
        let acks = deliver(&mut c, &mut s, 350 + 100);
        assert_eq!(acks.last().map(|i| i.ack_num), Some(1));
    }

    #[test]
    fn a_large_paste_goes_in_fragments_and_arrives_whole() {
        let (mut c, mut s) = pair();
        let mut x = 0x2545_f491u32;
        let paste: Vec<u8> = (0..30000).map(|_| { x ^= x << 13; x ^= x >> 17; x ^= x << 5; b'a' + (x % 26) as u8 }).collect();
        c.keys(&paste, 0);
        let ds = c.outgoing(1, vec![]);
        assert!(ds.len() > 1);
        assert!(ds.iter().all(|d| d.len() <= SEND_MTU));
        for d in &ds {
            s.take(d);
        }
        assert_eq!(s.events, vec![UserEvent::Keys(paste)]);
    }

    #[test]
    fn a_lost_datagram_is_made_good_by_a_retransmission() {
        let (mut c, mut s) = pair();
        c.keys(b"a", 0);
        let lost = c.outgoing(1, vec![]);
        assert_eq!(lost.len(), 1);
        // Nothing reached the server; after the timeout (1 s with no sample yet) it goes again.
        assert!(c.outgoing(500, vec![]).is_empty());
        let again = c.outgoing(1001, vec![]);
        assert_eq!(again.len(), 1);
        let i = s.take(&again[0]).unwrap();
        assert_eq!((i.old_num, i.new_num), (0, 1));
        assert_eq!(s.events, vec![UserEvent::Keys(b"a".to_vec())]);
    }

    #[test]
    fn a_damaged_or_foreign_datagram_is_dropped_and_counted() {
        let (mut c, mut s) = pair();
        let mut d = s.screen(0, 1, b"x", false).remove(0);
        d[20] ^= 1;
        assert_eq!(c.incoming(&d, 0), Err(IncomingError::Datagram(DatagramError::Auth)));
        assert_eq!(c.dropped, 1);
        assert!(c.last_heard.is_none());
        let mut other = FakeServer::new(&Key::from_bytes([4; 16]));
        let f = other.screen(0, 1, b"x", false).remove(0);
        assert!(c.incoming(&f, 0).is_err());
    }

    #[test]
    fn a_replayed_datagram_neither_measures_nor_counts_as_contact() {
        let (mut c, mut s) = pair();
        c.keys(b"a", 0);
        deliver(&mut c, &mut s, 1);
        let d = s.screen(0, 1, b"x", true).remove(0);
        c.incoming(&d, 10).unwrap();
        let heard = c.last_heard;
        let srtt = c.rtt.srtt();
        // Its fragment is a late copy of an instruction already whole: nothing.
        assert_eq!(c.incoming(&d, 4000).unwrap(), Incoming::Partial);
        assert_eq!(c.last_heard, heard);
        assert_eq!(c.rtt.srtt(), srtt);
    }

    /// Every earlier datagram of the server's, replayed (by anyone on the path) in any order and
    /// any number of times, changes nothing: the screen stays at the newest state, the client's
    /// sent states and its log are as they were, nothing is shown again, and the client answers
    /// with at most one acknowledgement per ACK_DELAY.
    #[test]
    fn replayed_server_datagrams_change_nothing_and_are_acknowledged_at_most_once_per_delay() {
        use crate::mosh::sync::ACK_DELAY;
        let (mut c, mut s) = pair();
        c.keys(b"a", 0);
        deliver(&mut c, &mut s, 1);
        let mut all = Vec::new();
        for (i, t) in [(1u64, 50u64), (2, 400), (3, 800)] {
            let d = s.screen(i - 1, i, format!("screen {i}").as_bytes(), true);
            assert!(!shown(&mut c, &d, t).is_empty());
            all.extend(d);
            deliver(&mut c, &mut s, t + ACK_DELAY);
        }
        // And an empty acknowledgement of the server's, and a heartbeat.
        all.extend(s.screen(3, 3, b"", true));
        let before = (c.sender.snapshot(), c.receiver.current(), c.sender.ack_num);
        assert_eq!(before.1, 3);
        // Replayed in three orders, one datagram every 7 ms.
        let n = all.len();
        let orders: Vec<Vec<usize>> = vec![
            (0..n).rev().collect(),
            (0..n).map(|i| (i * 3) % n).collect(),
            (0..n).flat_map(|i| [i, n - 1 - i]).collect(),
        ];
        let mut now = 1000;
        let start = now;
        let mut acks = Vec::new();
        for order in orders {
            for i in order {
                let r = c.incoming(&all[i], now).unwrap();
                assert!(!matches!(r, Incoming::Instruction(Received::Applied { .. })), "nothing is applied again");
                if !c.outgoing(now, vec![]).is_empty() {
                    acks.push(now);
                }
                now += 7;
            }
        }
        // Anything still due by the end, as the loop would send it.
        if !c.outgoing(now + ACK_DELAY, vec![]).is_empty() {
            acks.push(now + ACK_DELAY);
        }
        let after = c.sender.snapshot();
        assert_eq!((after.1, after.2), (before.0.1, before.0.2), "the log as it was");
        // The same states (only when the newest was last sent may move: an acknowledgement repeats it).
        assert_eq!(
            after.0.iter().map(|s| (s.0, s.1)).collect::<Vec<_>>(),
            before.0.0.iter().map(|s| (s.0, s.1)).collect::<Vec<_>>(),
            "the same states"
        );
        assert_eq!(c.receiver.current(), 3);
        assert_eq!(c.sender.ack_num, before.2);
        let window = now + ACK_DELAY - start;
        assert!(!acks.is_empty(), "a replay is acknowledged (the server may have lost the first)");
        assert!(acks.len() as u64 <= window / ACK_DELAY + 1, "{} acknowledgements in {window} ms", acks.len());
        for w in acks.windows(2) {
            assert!(w[1] - w[0] >= ACK_DELAY, "two acknowledgements {} ms apart", w[1] - w[0]);
        }
    }

    #[test]
    fn the_servers_shutdown_is_acknowledged_at_once() {
        let (mut c, mut s) = pair();
        deliver(&mut c, &mut s, 0);
        let d = s.screen(0, SHUTDOWN_NUM, b"", false);
        assert_eq!(
            c.incoming(&d[0], 50).unwrap(),
            Incoming::Instruction(Received::Applied { events: vec![], shutdown: true })
        );
        let ack = deliver(&mut c, &mut s, 50);
        assert_eq!(ack.last().map(|i| i.ack_num), Some(SHUTDOWN_NUM));
    }

    #[test]
    fn another_protocol_version_stops_the_session() {
        let (mut c, mut s) = pair();
        let inst = Instruction { protocol_version: Some(1), new_num: 1, ..Default::default() };
        let d = s.send(&inst, false);
        assert_eq!(c.incoming(&d[0], 0), Err(IncomingError::Version(1)));
    }

    #[test]
    fn the_echo_is_moved_on_by_the_time_held() {
        let (mut c, mut s) = pair();
        // The server stamps 0 (fake), the client holds it 40 ms before it replies.
        c.incoming(&s.screen(0, 1, b"x", false)[0], 1000).unwrap();
        c.keys(b"k", 1040);
        let d = c.outgoing(1040, vec![]);
        let o = datagram::open(&Cipher::new(&Key::from_bytes([3; 16])), &d[0], false).unwrap();
        assert_eq!(o.timestamp_reply, 40);
        assert_eq!(o.timestamp, 1040);
        // Used once.
        c.keys(b"j", 2000);
        let d = c.outgoing(2200, vec![]);
        let o = datagram::open(&Cipher::new(&Key::from_bytes([3; 16])), &d[0], false).unwrap();
        assert_eq!(o.timestamp_reply, NO_REPLY);
    }
}

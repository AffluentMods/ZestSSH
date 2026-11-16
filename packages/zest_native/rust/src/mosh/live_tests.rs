//! The client against a real mosh-server (interoperability), where one can be started: on Windows
//! in WSL (`wsl -d Ubuntu`), elsewhere on this machine. Each test says so and passes when there is
//! none (install it with `sudo apt install mosh` in WSL, or the system's package manager).
//!
//! Run alone with `cargo test --lib --features mosh mosh::live_tests -- --nocapture`.

use std::process::Command;
use std::time::{Duration, Instant};

use super::event;

fn wsl() -> bool {
    cfg!(windows)
}

/// A command run where mosh-server is: in WSL on Windows, here elsewhere.
fn there(args: &[&str]) -> Option<std::process::Output> {
    let mut c = if wsl() {
        let mut c = Command::new("wsl.exe");
        c.args(["-d", "Ubuntu", "--"]);
        c.args(args);
        c
    } else {
        let mut c = Command::new(args[0]);
        c.args(&args[1..]);
        c
    };
    c.output().ok()
}

/// The address mosh-server is reached on from here, or None when there is no mosh-server.
fn server_address() -> Option<String> {
    let found = there(&["sh", "-c", "command -v mosh-server"])?;
    if !found.status.success() {
        eprintln!("SKIPPED: no mosh-server{}", if wsl() { " in WSL" } else { "" });
        return None;
    }
    if !wsl() {
        return Some("127.0.0.1".into());
    }
    let ip = there(&["hostname", "-I"])?;
    String::from_utf8_lossy(&ip.stdout).split_whitespace().next().map(str::to_owned)
}

/// Starts a mosh-server running [command]; returns its port and key.
fn start_server(ip: &str, command: &[&str]) -> (u16, String) {
    let mut args = vec!["env", "-i", "PATH=/usr/bin:/bin", "mosh-server", "new", "-i", ip, "-p", "60100:60999", "-c", "256", "-l", "LANG=C.UTF-8", "--"];
    args.extend_from_slice(command);
    let out = there(&args).expect("mosh-server ran");
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    let line = text.lines().find(|l| l.starts_with("MOSH CONNECT")).unwrap_or_else(|| {
        panic!("no MOSH CONNECT line; stderr: {}", String::from_utf8_lossy(&out.stderr))
    });
    let mut parts = line.split_whitespace().skip(2);
    let port = parts.next().unwrap().parse().unwrap();
    let key = parts.next().unwrap().to_owned();
    (port, key)
}

static EVENTS: std::sync::Mutex<Vec<(u64, u32, Vec<u8>)>> = std::sync::Mutex::new(Vec::new());

extern "C" fn record(handle: u64, kind: u32, _a: i64, data: *mut u8, len: usize) {
    let bytes = if data.is_null() {
        Vec::new()
    } else {
        // SAFETY: the callback's bytes, freed right after the copy.
        let v = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
        unsafe { super::free_bytes(data, len) };
        v
    };
    EVENTS.lock().unwrap().push((handle, kind, bytes));
}

fn output_of(h: u64) -> String {
    let all: Vec<u8> =
        EVENTS.lock().unwrap().iter().filter(|e| e.0 == h && e.1 == event::HOST_BYTES).flat_map(|e| e.2.clone()).collect();
    String::from_utf8_lossy(&all).into_owned()
}

fn event_of(h: u64, kind: u32) -> Option<Vec<u8>> {
    EVENTS.lock().unwrap().iter().find(|e| e.0 == h && e.1 == kind).map(|e| e.2.clone())
}

fn wait(secs: u64, mut done: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < until {
        if done() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn open(ip: &str, port: u16, key: &str, cols: u16, rows: u16) -> u64 {
    let req = serde_json::json!({ "addresses": [ip], "port": port, "key": key, "cols": cols, "rows": rows });
    super::open(&req.to_string(), record).expect("opened")
}

/// Typing reaches the shell on the host and its output comes back; the terminal's size is the
/// one sent; the shell's exit ends the session as the server's shutdown.
#[test]
fn live_a_shell_through_a_real_mosh_server() {
    let Some(ip) = server_address() else { return };
    let (port, key) = start_server(&ip, &["/bin/sh"]);
    let h = open(&ip, port, &key, 91, 27);
    assert!(wait(10, || event_of(h, event::CONNECTED).is_some()), "the server answered");
    super::keys(h, b"echo zest-$((6*7))\r");
    assert!(wait(10, || output_of(h).contains("zest-42")), "output came back: {:?}", output_of(h));
    super::keys(h, b"stty size\r");
    assert!(wait(10, || output_of(h).contains("27 91")), "the size reached the host: {:?}", output_of(h));
    super::resize(h, 100, 30);
    std::thread::sleep(Duration::from_millis(300));
    super::keys(h, b"stty size\r");
    assert!(wait(10, || output_of(h).contains("30 100")), "the new size reached the host: {:?}", output_of(h));
    // What the server's diffs look like (for whoever reads the run).
    eprintln!("host bytes: {:?}", output_of(h).chars().take(600).collect::<String>());
    super::keys(h, b"exit\r");
    assert!(wait(15, || event_of(h, event::CLOSED).is_some()), "the session ended with the shell");
    let closed: serde_json::Value = serde_json::from_slice(&event_of(h, event::CLOSED).unwrap()).unwrap();
    assert_eq!(closed["reason"], "server_closed", "{closed}");
    super::close(h);
}

/// The app closing the session tells the server, which ends: its port is free again.
#[test]
fn live_closing_ends_the_server() {
    let Some(ip) = server_address() else { return };
    let (port, key) = start_server(&ip, &["/bin/sh"]);
    let h = open(&ip, port, &key, 80, 24);
    assert!(wait(10, || event_of(h, event::CONNECTED).is_some()), "the server answered");
    super::keys(h, b"echo ready\r");
    assert!(wait(10, || output_of(h).contains("ready")));
    let started = Instant::now();
    super::close(h);
    assert!(wait(5, || event_of(h, event::CLOSED).is_some()));
    let closed: serde_json::Value = serde_json::from_slice(&event_of(h, event::CLOSED).unwrap()).unwrap();
    assert_eq!(closed["reason"], "local");
    assert!(started.elapsed() < Duration::from_millis(1900), "the server acknowledged the close: {:?}", started.elapsed());
    // mosh-server let its port go.
    let gone = wait(10, || {
        there(&["sh", "-c", &format!("ss -uln | grep -q ':{port} ' && echo up || echo gone")])
            .is_some_and(|o| String::from_utf8_lossy(&o.stdout).contains("gone"))
    });
    assert!(gone, "mosh-server still listens on {port}");
}

/// A key that is not the server's: nothing it sends opens, nothing it hears opens either, and
/// the session ends with no answer.
#[test]
fn live_the_wrong_key_gets_no_answer() {
    let Some(ip) = server_address() else { return };
    let (port, _key) = start_server(&ip, &["/bin/true"]);
    let req = serde_json::json!({
        "addresses": [ip], "port": port, "key": "AAAAAAAAAAAAAAAAAAAAAA", "cols": 80, "rows": 24, "first_answer_ms": 2500,
    });
    let h = super::open(&req.to_string(), record).unwrap();
    assert!(wait(10, || event_of(h, event::CLOSED).is_some()));
    let closed: serde_json::Value = serde_json::from_slice(&event_of(h, event::CLOSED).unwrap()).unwrap();
    assert_eq!(closed["reason"], "no_answer");
    assert!(event_of(h, event::CONNECTED).is_none());
}

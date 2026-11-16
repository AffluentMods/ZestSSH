//! Mosh, built in (4.0, feature "mosh"): a client of the Mobile Shell protocol, so a Mosh host
//! opens on every platform without a mosh program on the device.
//!
//! The app starts `mosh-server` over its own SSH connection and reads the port and key it prints
//! (Dart, lib/services/mosh/); this module takes it from there: UDP to the server, the datagram
//! layer, state synchronisation, roaming, and the server's screen diffs handed to the app's
//! terminal emulator as output.
//!
//! A clean implementation from the protocol's published description (the USENIX ATC 2012 paper
//! "Mosh: An Interactive Remote Shell for Mobile Clients", the protocol's .proto message
//! definitions, RFC 7253) and from watching a real mosh-server (1.4.0) answer; no code of mosh's
//! is in it.
//!
//! The files, from the wire up, each reviewable alone:
//! - crypto.rs: the key and AES-128-OCB3;
//! - datagram.rs: the sealed datagram, its direction bit and timestamps;
//! - fragment.rs: fragments and zlib, with the bounds on what a peer can make this side hold;
//! - wire.rs: the protocol buffers messages (the parser of what the server sends);
//! - sync.rs: state synchronisation (the client's events out, the server's screen in);
//! - connection.rs: the above together, without sockets or clocks;
//! - client.rs: the session's thread: UDP sockets, timers, roaming, events for the app;
//! - this file: the handles the C functions of lib.rs (zest_mosh_*) use.

mod client;
pub mod connection;
pub mod crypto;
pub mod datagram;
pub mod fragment;
pub mod sync;
pub mod wire;

#[cfg(test)]
mod live_tests;

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// What Rust tells Dart, through the callback's `kind`.
pub mod event {
    /// Terminal output for the session's terminal: `data` (free with `zest_mosh_free_bytes`).
    pub const HOST_BYTES: u32 = 1;
    /// The server answered for the first time: `data` is JSON, `{"address": "ip:port"}`. The
    /// screen's first diff follows; the terminal is cleared before it.
    pub const CONNECTED: u32 = 2;
    /// Once a second: `data` is JSON, `{"last_heard_ms": n or null, "srtt_ms": n}`; the app shows
    /// "last contact" from it when the server has not been heard for a while.
    pub const STATUS: u32 = 3;
    /// The session ended: `data` is JSON, `{"reason": "...", "message": "..."}`, reason one of
    /// `local` (the app closed it), `server_closed` (the shell on the host ended, or the server
    /// shut down), `no_answer` (nothing came back on UDP before the time limit), `key` (the key
    /// is not one), `protocol` (the server speaks another version), `network` (no socket could
    /// be opened), `internal`. Nothing follows.
    pub const CLOSED: u32 = 4;
    /// For the app's log: `data` is JSON (`{"server_size": [w, h]}`, `{"new_local_port": true}`,
    /// `{"dropped": n, "foreign": n}`: datagrams that did not open, and datagrams from an address
    /// that is not the server's, dropped unopened).
    pub const INFO: u32 = 5;
}

/// The callback into Dart: (session, kind, a, data, len). `data` (when not null) is the
/// library's, freed by Dart with `zest_mosh_free_bytes(data, len)` once read.
pub type Callback = extern "C" fn(u64, u32, i64, *mut u8, usize);

#[derive(Clone, Copy)]
pub struct Notifier {
    pub handle: u64,
    pub callback: Callback,
}

impl Notifier {
    pub fn bytes(&self, kind: u32, a: i64, bytes: Vec<u8>) {
        let len = bytes.len();
        let ptr = Box::into_raw(bytes.into_boxed_slice()).cast::<u8>();
        (self.callback)(self.handle, kind, a, ptr, len);
    }

    pub fn json(&self, kind: u32, value: serde_json::Value) {
        self.bytes(kind, 0, value.to_string().into_bytes());
    }
}

/// Frees bytes handed to Dart by [Notifier::bytes].
///
/// # Safety
/// [ptr] and [len] must be one pair the callback gave, freed once.
pub unsafe fn free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: made by Box::into_raw of a boxed slice of this length.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}

/// Input from Dart, in the order it came.
#[derive(Debug)]
pub enum Command {
    Keys(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    /// End the session: the server is told, and its acknowledgement waited for a moment.
    Close,
}

/// The session's settings (JSON from Dart).
#[derive(Debug, serde::Deserialize)]
pub struct OpenRequest {
    /// The server's addresses (IPv4 or IPv6, no port): the one the SSH connection reached, or
    /// through a jump host what the host's name resolves to here. Datagrams go to all of them
    /// until one answers, then to that one alone; datagrams are taken from these addresses only,
    /// and once one answered from it only (the client never follows the server elsewhere).
    pub addresses: Vec<String>,
    /// The UDP port mosh-server printed.
    pub port: u16,
    /// The key mosh-server printed (22 characters). Wiped once read; never logged.
    pub key: crate::secret::Secret,
    pub cols: u16,
    pub rows: u16,
    /// How long to wait for the server's first answer before giving up (ms; 15 s when not
    /// given).
    #[serde(default)]
    pub first_answer_ms: Option<u64>,
}

struct Handle {
    tx: tokio::sync::mpsc::UnboundedSender<Command>,
}

fn sessions() -> &'static Mutex<HashMap<u64, Arc<Handle>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<Handle>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

fn held<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn handle(h: u64) -> Option<Arc<Handle>> {
    held(sessions()).get(&h).cloned()
}

/// Starts a session on a thread of its own. Returns its handle (never 0), or why the request
/// cannot start. Everything later comes through the callback, CLOSED last.
pub fn open(request_json: &str, callback: Callback) -> Result<u64, String> {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    // The parse error never repeats the text (it holds the key).
    let request: OpenRequest = serde_json::from_str(request_json).map_err(|e| format!("request: line {} column {}", e.line(), e.column()))?;
    let handle = NEXT.fetch_add(1, Ordering::Relaxed);
    let notifier = Notifier { handle, callback };
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    std::thread::Builder::new()
        .name(format!("zest-mosh-{handle}"))
        .spawn(move || client::run(request, rx, notifier))
        .map_err(|e| format!("thread: {e}"))?;
    held(sessions()).insert(handle, Arc::new(Handle { tx }));
    Ok(handle)
}

pub fn keys(h: u64, bytes: &[u8]) {
    if let Some(s) = handle(h) {
        let _ = s.tx.send(Command::Keys(bytes.to_vec()));
    }
}

pub fn resize(h: u64, cols: u16, rows: u16) {
    if let Some(s) = handle(h) {
        let _ = s.tx.send(Command::Resize { cols, rows });
    }
}

/// Ends a session: returns at once; its thread tells the server and closes within about two
/// seconds, CLOSED last (keep the callback until then).
pub fn close(h: u64) {
    if let Some(s) = held(sessions()).remove(&h) {
        let _ = s.tx.send(Command::Close);
    }
}

//! The bridge as Dart drives it: `zest_screen_open` with a request, the channel's bytes through
//! `zest_screen_feed`, input through the other calls, the end of the channel, the frame taken,
//! then `zest_screen_close`.

use std::collections::HashSet;
use std::ffi::CString;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use zest_native::screen::event;

use super::Pieces;

/// Sessions that said CLOSED.
fn closed() -> &'static (Mutex<HashSet<u64>>, Condvar) {
    static CLOSED: OnceLock<(Mutex<HashSet<u64>>, Condvar)> = OnceLock::new();
    CLOSED.get_or_init(Default::default)
}

/// Sessions that said CONNECTED.
fn connected() -> &'static Mutex<HashSet<u64>> {
    static CONNECTED: OnceLock<Mutex<HashSet<u64>>> = OnceLock::new();
    CONNECTED.get_or_init(Default::default)
}

/// The last CLOSED event's JSON (why a session ended), for the seed writer to print.
pub fn last_closed() -> String {
    LAST_CLOSED.lock().unwrap().clone()
}

static LAST_CLOSED: Mutex<String> = Mutex::new(String::new());

/// Dart's side of the callback: frees what it is handed, notes CLOSED.
extern "C" fn callback(handle: u64, kind: u32, _a: i64, data: *mut u8, len: usize) {
    if kind == event::CLOSED && !data.is_null() {
        // SAFETY: len readable bytes, until they are freed below.
        let text = String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(data, len) }).into_owned();
        *LAST_CLOSED.lock().unwrap() = text;
    }
    if !data.is_null() {
        // SAFETY: the library's bytes, freed once, as Dart does.
        unsafe { zest_native::zest_screen_free_bytes(data, len) };
    }
    if kind == event::CONNECTED {
        connected().lock().unwrap().insert(handle);
    }
    if kind == event::CLOSED {
        let (m, c) = closed();
        m.lock().unwrap().insert(handle);
        c.notify_all();
    }
}

/// How long a session may take to close once its channel ended (it has nothing left to wait
/// for: a longer wait is a hang).
const CLOSE_WITHIN: Duration = Duration::from_secs(20);

/// Opens a session with [request] (NUL ends it, as a C string would); when it opens, feeds
/// [server] in pieces with input between them as [input] says, ends the channel, waits for
/// CLOSED, takes the frame and closes. Returns whether the session connected (its handshake or
/// sign-in finished).
pub fn session(request: &[u8], server: &[u8], input: u8) -> bool {
    let end = request.iter().position(|b| *b == 0).unwrap_or(request.len());
    let request = CString::new(&request[..end]).unwrap();
    // SAFETY: a valid C string; the callback lives as long as the process.
    let handle = unsafe { zest_native::zest_screen_open(request.as_ptr(), callback) };
    if handle == 0 {
        return false;
    }
    let mut pieces = Pieces::new(server.len() as u64 ^ u64::from(input));
    let mut at = 0;
    let mut step = 0u32;
    while at < server.len() {
        let n = pieces.next().min(server.len() - at);
        // SAFETY: n readable bytes.
        unsafe { zest_native::zest_screen_feed(handle, server[at..].as_ptr(), n) };
        at += n;
        if input != 0 {
            step += 1;
            match (step + u32::from(input)) % 9 {
                0 if input & 1 != 0 => zest_native::zest_screen_pointer(handle, step * 7, step * 3, step & 7),
                1 if input & 2 != 0 => zest_native::zest_screen_key(handle, 0x61 + step % 26, step % 3, step & 1),
                2 if input & 4 != 0 => {
                    let text = "clipboard \u{e9}";
                    // SAFETY: the text's bytes.
                    unsafe { zest_native::zest_screen_clipboard(handle, text.as_ptr(), text.len()) };
                }
                3 if input & 8 != 0 => zest_native::zest_screen_pause(handle),
                4 if input & 8 != 0 => zest_native::zest_screen_resume(handle),
                5 if input & 16 != 0 => zest_native::zest_screen_full_refresh(handle),
                6 if input & 32 != 0 => zest_native::zest_screen_resize(handle, 640 + step, 480),
                7 if input & 64 != 0 => zest_native::zest_screen_clipboard_share(handle, (step & 1) as i32),
                _ => {}
            }
        }
    }
    zest_native::zest_screen_feed_end(handle);
    let (m, c) = closed();
    let deadline = Instant::now() + CLOSE_WITHIN;
    let mut g = m.lock().unwrap();
    while !g.contains(&handle) {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "session {handle} did not close after its channel ended");
        g = c.wait_timeout(g, left).unwrap().0;
    }
    g.remove(&handle);
    drop(g);
    let frame = zest_native::zest_screen_take_frame(handle);
    // SAFETY: a packet taken from the session (or null), freed once.
    unsafe { zest_native::zest_screen_free_frame(frame) };
    zest_native::zest_screen_close(handle);
    connected().lock().unwrap().remove(&handle)
}

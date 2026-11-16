//! ZestSSH's native library (3.4): Rust code the app loads through Dart's build hooks
//! (packages/zest_native/hook/build.dart). Its version, and FTPS (suppaftp with rustls, the
//! `ftps` module) behind a small C interface of JSON in and JSON out.

use std::ffi::{CStr, CString, c_char};

pub mod ftps;
#[cfg(feature = "mosh")]
pub mod mosh;
#[cfg(feature = "rdp")]
pub mod rdp;
#[cfg(any(feature = "vnc", feature = "rdp"))]
pub mod screen;
#[cfg(any(feature = "vnc", feature = "rdp", feature = "mosh"))]
pub mod secret;
#[cfg(feature = "vnc")]
pub mod vnc;

/// The library's name and version, NUL-terminated.
const VERSION: &str = concat!("zest_native ", env!("CARGO_PKG_VERSION"), "\0");

/// The library's name and version ("zest_native 0.1.0"): a NUL-terminated string the library
/// owns for the life of the process. The caller reads it and never frees it.
#[unsafe(no_mangle)]
pub extern "C" fn zest_native_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

/// A new FTPS handle, not connected yet: a number other than 0.
#[unsafe(no_mangle)]
pub extern "C" fn zest_ftps_open() -> u64 {
    ftps::open()
}

/// Runs one FTPS request (JSON, NUL-terminated) on [handle] and returns the answer (JSON), which
/// the caller frees with [zest_string_free]. Blocks until the request is done: call it off the UI
/// thread. Requests on one handle wait for each other.
///
/// # Safety
/// [request] must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_ftps_call(handle: u64, request: *const c_char) -> *mut c_char {
    let answer = if request.is_null() {
        r#"{"error":{"kind":"request","message":"no request"}}"#.to_string()
    } else {
        // SAFETY: the caller hands a valid NUL-terminated string.
        let request = unsafe { CStr::from_ptr(request) }.to_string_lossy();
        ftps::call(handle, &request)
    };
    // serde_json escapes a NUL inside a string, so the answer holds none.
    CString::new(answer).unwrap_or_default().into_raw()
}

/// Asks the transfer running on [handle] to stop. Returns at once.
#[unsafe(no_mangle)]
pub extern "C" fn zest_ftps_cancel(handle: u64) {
    ftps::cancel(handle)
}

/// Bytes the transfer running on [handle] has moved so far. Returns at once.
#[unsafe(no_mangle)]
pub extern "C" fn zest_ftps_progress(handle: u64) -> u64 {
    ftps::progress(handle)
}

/// Ends [handle]: QUIT and TLS close_notify on its connection (which can wait for the server up
/// to the connection's time limit: call it off the UI thread).
#[unsafe(no_mangle)]
pub extern "C" fn zest_ftps_close(handle: u64) {
    ftps::close(handle)
}

/// RDP probe (developer builds only: features "rdp" and "probes", never the app's): a JSON
/// request in (rdp::ProbeRequest), JSON out, which the caller frees with [zest_string_free].
/// Blocks until the first screen update or the request's time limit.
///
/// # Safety
/// [request] must be a valid NUL-terminated string.
#[cfg(all(feature = "rdp", feature = "probes"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_rdp_probe(request: *const c_char) -> *mut c_char {
    let answer = if request.is_null() {
        r#"{"error":"no request"}"#.to_string()
    } else {
        // SAFETY: the caller hands a valid NUL-terminated string.
        rdp::probe_json(&unsafe { CStr::from_ptr(request) }.to_string_lossy())
    };
    CString::new(answer).unwrap_or_default().into_raw()
}

/// VNC probe (developer builds only: features "vnc" and "probes", never the app's): a JSON
/// request in (vnc::ProbeRequest), JSON out, which the caller frees with [zest_string_free].
/// Blocks until the first framebuffer update or the request's time limit.
///
/// # Safety
/// [request] must be a valid NUL-terminated string.
#[cfg(all(feature = "vnc", feature = "probes"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_vnc_probe(request: *const c_char) -> *mut c_char {
    let answer = if request.is_null() {
        r#"{"error":"no request"}"#.to_string()
    } else {
        // SAFETY: the caller hands a valid NUL-terminated string.
        vnc::probe_json(&unsafe { CStr::from_ptr(request) }.to_string_lossy())
    };
    CString::new(answer).unwrap_or_default().into_raw()
}

/// Remote screens (4.0, feature "vnc" or "rdp"): starts a session from a JSON request
/// (screen::OpenRequest) whose engine reads what [zest_screen_feed] gets and writes through
/// [callback] (kind SEND). Returns its handle, or 0 when the request is wrong. Every session ends
/// with a CLOSED callback, its last; [zest_screen_close] must be called, and CLOSED have come,
/// before [callback] goes. The request holds the password: the caller wipes its copy once this
/// returns.
///
/// # Safety
/// [request] must be a valid NUL-terminated string; [callback] must stay callable from any thread
/// until the session's CLOSED callback came.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_open(request: *const c_char, callback: screen::Callback) -> u64 {
    if request.is_null() {
        return 0;
    }
    // SAFETY: the caller hands a valid NUL-terminated string.
    let request = unsafe { CStr::from_ptr(request) }.to_string_lossy();
    screen::open(&request, callback).unwrap_or(0)
}

/// Bytes the session's channel received, for its engine. Returns how many bytes wait unread
/// (pause the channel above 4 MiB; a DRAINED callback says when to resume). Returns at once.
///
/// # Safety
/// [data] must point at [len] readable bytes (or be null with 0).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_feed(handle: u64, data: *const u8, len: usize) -> u64 {
    let Some(s) = screen::session(handle) else { return 0 };
    let bytes = if data.is_null() || len == 0 {
        &[][..]
    } else {
        // SAFETY: the caller hands len readable bytes.
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    s.pipe.feed(bytes) as u64
}

/// The session's channel ended.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_feed_end(handle: u64) {
    if let Some(s) = screen::session(handle) {
        s.pipe.end();
    }
}

/// The pointer at (x, y) in remote pixels, with these buttons down (bit 0 left, 1 middle, 2
/// right, 3 wheel up, 4 wheel down). Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_pointer(handle: u64, x: u32, y: u32, buttons: u32) {
    if let Some(s) = screen::session(handle) {
        let c = |v: u32| v.min(u32::from(u16::MAX)) as u16;
        s.commands.push(screen::Command::Pointer { x: c(x), y: c(y), buttons: buttons as u8 });
    }
}

/// The mouse moved by (`dx`, `dy`) with `buttons` down (as [zest_screen_pointer]'s): relative
/// mouse (4.0), for a session that asked for it and whose server takes it (CONNECTED's
/// `relative_mouse`). Nothing otherwise, and nothing for VNC. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_pointer_relative(handle: u64, dx: i32, dy: i32, buttons: u32) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::PointerRelative { dx, dy, buttons: buttons as u8 });
    }
}

/// A key: its X keysym, its XT scancode (0 when not known), down or up. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_key(handle: u64, keysym: u32, scancode: u32, down: u32) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::Key { keysym, scancode, down: down != 0 });
    }
}

/// The view's size in remote pixels: RDP asks the server to resize the desktop to it (display
/// control channel) when the server allows; VNC ignores it for now. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_resize(handle: u64, width: u32, height: u32) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::Resize { width, height });
    }
}

/// What the session's own reader takes from now on (4.0): the rectangle `x`, `y`,
/// `width`, `height` of the picture, one of the remote's displays, or all of it (a `width` or
/// `height` of 0). [zest_screen_take_frame] then gives that part only, its tiles' places from
/// the part's corner and the packet's size the part's, starting with all of it; the app takes
/// a frame after this call without waiting to be told. Pointer places are still the whole
/// picture's.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_show(handle: u64, x: u32, y: u32, width: u32, height: u32) {
    use screen::LockAnyway as _;
    if let Some(s) = screen::session(handle) {
        s.frame.held().show(x, y, width, height);
    }
}

/// Opens a view on a part of a session's picture (4.0): the rectangle `x`, `y`, `width`,
/// `height` in the picture's pixels, read with [zest_screen_view_take_frame], its own picture
/// `divide` times smaller a side (1: as it is; up to 16: a small picture). For a window that
/// shows one of the remote's displays, in whatever engine of this process: a view is never
/// called back, its reader asks when it draws. The rectangle may reach past the picture; the
/// view shows what of it is inside, from the start again whenever the picture's size changes.
/// Returns the view's number (from 1), or 0: no such session, sixteen views open already, an
/// empty rectangle, or a `divide` that is not 1 to 16.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_view_open(handle: u64, x: u32, y: u32, width: u32, height: u32, divide: u32) -> u32 {
    use screen::LockAnyway as _;
    screen::session(handle).and_then(|s| s.frame.held().view_open(x, y, width, height, divide)).unwrap_or(0)
}

/// A view's changed tiles, as [zest_screen_take_frame] gives the picture's: their places from
/// the view's own corner, the packet's size the view's (free it with `zest_screen_free_frame`).
/// Null when nothing in it changed, or when the session or the view is gone
/// ([zest_screen_view_alive] tells which).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_view_take_frame(handle: u64, view: u32) -> *mut screen::FramePacket {
    use screen::LockAnyway as _;
    screen::session(handle)
        .and_then(|s| s.frame.held().view_take(view, screen::now_us()))
        .unwrap_or(std::ptr::null_mut())
}

/// 1 while the session is there and the view is open, else 0: a window reading a view stops
/// when its session has ended.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_view_alive(handle: u64, view: u32) -> i32 {
    use screen::LockAnyway as _;
    i32::from(screen::session(handle).is_some_and(|s| s.frame.held().view_is_open(view)))
}

/// Closes a view. Nothing where the session or the view is gone already (a session that ends
/// takes its views with it).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_view_close(handle: u64, view: u32) {
    use screen::LockAnyway as _;
    if let Some(s) = screen::session(handle) {
        s.frame.held().view_close(view);
    }
}

/// The displays the remote should have from now on (4.0): JSON (UTF-8, `len` bytes), a
/// list of `{"x", "y", "width", "height", "scale", "primary"}` as the open request's `displays`.
/// RDP asks the server for them on the display control channel where it has one; a layout a
/// server does not take is not asked for, and the app is told why (INFO, `layout_refused`).
/// VNC ignores it. Returns 0, or -1 where the JSON is not such a list (nothing is asked then).
///
/// # Safety
/// [json] must be null or point at [len] readable bytes for the duration of the call.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_displays(handle: u64, json: *const u8, len: usize) -> i32 {
    if json.is_null() || len == 0 {
        return -1;
    }
    // SAFETY: as the caller promises.
    let bytes = unsafe { std::slice::from_raw_parts(json, len) };
    let Ok(displays) = serde_json::from_slice::<Vec<screen::DisplaySpec>>(bytes) else { return -1 };
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::Layout(displays));
    }
    0
}

/// The channel failed (`reason` 1: the SSH connection or channel, 2: the network under it), with
/// a message (UTF-8, `len` bytes): the engine reads an error after what was fed, and the session
/// closes with that reason. `zest_screen_feed_end` is the clean end (the server closed it).
///
/// # Safety
/// [message] must be null or point at [len] readable bytes for the duration of the call.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_feed_fail(handle: u64, reason: u32, message: *const u8, len: usize) {
    let Some(s) = screen::session(handle) else { return };
    let text = if message.is_null() || len == 0 {
        String::from("the connection failed")
    } else {
        // SAFETY: as the caller promises.
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(message, len) }).into_owned()
    };
    let reason = if reason == 2 { screen::CloseReason::Network } else { screen::CloseReason::Ssh };
    s.pipe.end_with(screen::TransportEnd::Failed { reason, message: text });
}

/// Text for the remote clipboard (UTF-8, `len` bytes; anything not UTF-8 is replaced, and text
/// over 1 MiB is cut there). VNC sends it as the extended clipboard's UTF-8 when the server has
/// it, else as Latin-1 (RFC 6143). Returns at once.
///
/// # Safety
/// [text] must be null or point at [len] readable bytes for the duration of the call.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_clipboard(handle: u64, text: *const u8, len: usize) {
    let Some(s) = screen::session(handle) else { return };
    let text = if text.is_null() || len == 0 {
        String::new()
    } else {
        // SAFETY: as the caller promises.
        String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(text, len) }).into_owned()
    };
    s.commands.push(screen::Command::Clipboard(text));
}

/// Whether the clipboard is shared with the remote from now on (`on` not 0) or no longer (0).
/// For an RDP session that has the clipboard's channel (the open request's `rdp_clipboard`):
/// off wipes the text given by [zest_screen_clipboard], tells the server there is none and takes
/// none of the server's; on asks for the server's text where it has some. Nothing for VNC, and
/// nothing for a session without the channel. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_clipboard_share(handle: u64, on: i32) {
    let Some(s) = screen::session(handle) else { return };
    s.commands.push(screen::Command::ClipboardShare(on != 0));
}

/// Whether the remote's sound is played from now on (`on` not 0) or not (0): for an RDP session
/// whose open request asked for sound (`rdp_sound`) on a device with an output. Off empties what
/// waits to be played. Nothing otherwise. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_sound(handle: u64, on: i32) {
    let Some(s) = screen::session(handle) else { return };
    s.commands.push(screen::Command::Sound(on != 0));
}

/// The app is hidden: the server stops sending (VNC: no update requests, continuous updates off;
/// RDP: Suppress Output). Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_pause(handle: u64) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::Pause);
    }
}

/// Back from [zest_screen_pause]: updates again, the whole screen first. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_resume(handle: u64) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::Resume);
    }
}

/// Asks the server for the whole screen again. Returns at once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_full_refresh(handle: u64) {
    if let Some(s) = screen::session(handle) {
        s.commands.push(screen::Command::FullRefresh);
    }
}

/// The tiles that changed since the last call, packed (free with [zest_screen_free_frame]), or
/// null when none did. Returns at once (a copy of the changed pixels under the picture's lock).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_take_frame(handle: u64) -> *mut screen::FramePacket {
    let Some(s) = screen::session(handle) else { return std::ptr::null_mut() };
    let now = screen::now_us();
    screen::LockAnyway::held(&*s.frame).take(now).unwrap_or(std::ptr::null_mut())
}

/// Frees a packet of [zest_screen_take_frame].
///
/// # Safety
/// [packet] must be null or a packet [zest_screen_take_frame] returned, freed once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_free_frame(packet: *mut screen::FramePacket) {
    // SAFETY: as the caller promises.
    unsafe { screen::free_packet(packet) }
}

/// Frees bytes a callback handed over.
///
/// # Safety
/// [data] and [len] must be a pair a callback gave, freed once.
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_screen_free_bytes(data: *mut u8, len: usize) {
    // SAFETY: as the caller promises.
    unsafe { screen::free_bytes(data, len) }
}

/// Microseconds on the clock frames are stamped with (for latency figures).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_now_us() -> i64 {
    screen::now_us()
}

/// Ends the session. Returns within a few milliseconds whatever the session is busy with; its
/// last callback, CLOSED, may come after this returns (keep the callback until then).
#[cfg(any(feature = "vnc", feature = "rdp"))]
#[unsafe(no_mangle)]
pub extern "C" fn zest_screen_close(handle: u64) {
    screen::close(handle)
}

/// Mosh (4.0, feature "mosh"): starts a session from a JSON request (mosh::OpenRequest: the
/// server's addresses, the port and key mosh-server printed, the terminal's size) on a thread of
/// its own. Returns its handle, or 0 when the request is wrong. Everything later comes through
/// [callback] (mosh::event), CLOSED last; [zest_mosh_close] must be called, and CLOSED have come,
/// before [callback] goes. The request holds the session key: the caller wipes its copy once
/// this returns.
///
/// # Safety
/// [request] must be a valid NUL-terminated string; [callback] must stay callable from any thread
/// until the session's CLOSED callback came.
#[cfg(feature = "mosh")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_mosh_open(request: *const c_char, callback: mosh::Callback) -> u64 {
    if request.is_null() {
        return 0;
    }
    // SAFETY: the caller hands a valid NUL-terminated string.
    // Read in place: a request that is not UTF-8 is refused, never mended (to_string_lossy would
    // make a copy of the text, the session key in it, that nothing wipes).
    let Ok(request) = unsafe { CStr::from_ptr(request) }.to_str() else { return 0 };
    mosh::open(request, callback).unwrap_or(0)
}

/// What was typed (bytes as the terminal sends them), for the server. Returns at once.
///
/// # Safety
/// [data] must point at [len] readable bytes (or be null with 0).
#[cfg(feature = "mosh")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_mosh_keys(handle: u64, data: *const u8, len: usize) {
    if data.is_null() || len == 0 {
        return;
    }
    // SAFETY: the caller hands len readable bytes.
    mosh::keys(handle, unsafe { std::slice::from_raw_parts(data, len) });
}

/// The terminal's size in characters. Returns at once.
#[cfg(feature = "mosh")]
#[unsafe(no_mangle)]
pub extern "C" fn zest_mosh_resize(handle: u64, cols: u32, rows: u32) {
    let c = |v: u32| v.clamp(1, u32::from(u16::MAX)) as u16;
    mosh::resize(handle, c(cols), c(rows));
}

/// Ends the session: the server is told (the shell on the host ends) and its acknowledgement
/// waited for up to two seconds on the session's thread. Returns at once; CLOSED comes last.
#[cfg(feature = "mosh")]
#[unsafe(no_mangle)]
pub extern "C" fn zest_mosh_close(handle: u64) {
    mosh::close(handle)
}

/// Frees bytes a Mosh callback handed over.
///
/// # Safety
/// [data] and [len] must be a pair a callback gave, freed once.
#[cfg(feature = "mosh")]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_mosh_free_bytes(data: *mut u8, len: usize) {
    // SAFETY: as the caller promises.
    unsafe { mosh::free_bytes(data, len) }
}

/// Frees a string this library returned.
///
/// # Safety
/// [s] must be null or a string [zest_ftps_call] returned, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zest_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: made by CString::into_raw above, and freed once.
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_a_c_string() {
        let s = unsafe { CStr::from_ptr(zest_native_version()) };
        assert_eq!(s.to_str().unwrap(), concat!("zest_native ", env!("CARGO_PKG_VERSION")));
    }

    #[test]
    fn a_call_round_trips_through_c_strings() {
        let id = zest_ftps_open();
        let req = CString::new(r#"{"op":"pwd"}"#).unwrap();
        let out = unsafe { zest_ftps_call(id, req.as_ptr()) };
        let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_string();
        unsafe { zest_string_free(out) };
        zest_ftps_close(id);
        assert!(text.contains("\"closed\""), "{text}");
    }
}

//! Runs the library's own RDP session against a real server, as Dart drives it: the bridge's C
//! functions, the server's bytes from a TCP socket fed in, what the engine sends written back.
//! For meeting a test server (tool/remote_screens_test_servers.sh: xrdp in WSL) with the session
//! and its guards, which the fuzz targets only ever meet with made-up bytes. Never in the app,
//! and no fuzz target: built without the fuzz flags,
//!
//!   cd packages/zest_native/rust/fuzz
//!   CARGO_TARGET_DIR=target/live cargo build --release --locked --bin rdp_live
//!   ZS_RDP_HOST=127.0.0.1 ZS_RDP_PORT=13389 ZS_USER=alex target/live/release/rdp_live
//!
//! Settings (environment): ZS_RDP_HOST, ZS_RDP_PORT (13389), ZS_USER, ZS_PASSWORD (given to the
//! engine only with NLA), ZS_RDP_DOMAIN (the Windows domain or the PC's name, with NLA; none when
//! not given, which a local account takes), ZS_RDP_NLA ("without": TLS alone, no password sent; anything else:
//! NLA and nothing less), ZS_RDP_GRAPHICS (gfx, remotefx, bitmap), ZS_RDP_PIN (the certificate's
//! SHA-256; without it the first try shows the certificate and a second try pins it, as the app
//! does after its question), ZS_RDP_RUN_MS (8000: how long to stay connected), ZS_RDP_TYPE (text
//! typed into the picture two seconds after connecting, then Enter: a test server's own sign-in
//! box; never printed), ZS_RDP_RESIZE ("1024x700", or several with commas between: the first
//! asked for after five seconds, the next every two seconds), ZS_RDP_CLIPBOARD (on, off or
//! none: the clipboard's channel), ZS_RDP_OFFER (text given as this device's clipboard six
//! seconds after connecting), ZS_RDP_SHARE_AT_MS (with ZS_RDP_CLIPBOARD=off: sharing is turned
//! on this long after connecting), ZS_RDP_MOVE (the pointer is moved across the screen from
//! seven seconds on, so the server changes its shape), ZS_RDP_H264 (off, avc420 or avc444; off
//! when not given), ZS_RDP_DISPLAYS (the displays asked for when connecting, each as
//! "1920x1080+0+0" or with a place below zero "1280x1024-1280+200", commas between; a scale in
//! percent may follow as "@150"; the first is the primary one), ZS_RDP_LAYOUT (such lists with
//! semicolons between: the first asked for on the display control channel five seconds after
//! connecting, the next every three seconds), ZS_RDP_SCALE (one screen's scale factor in
//! percent). The server's clipboard text that comes is printed (test servers only).
//!
//! It prints the session's facts (CONNECTED), how many frames were taken, the last graphics
//! report (INFO), and how it ended (CLOSED). The exit code is 0 when the session connected and ended by
//! this tool's own close.

use std::ffi::CString;
use std::io::{Read as _, Write as _};
use std::net::TcpStream;
use std::sync::Mutex;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use zest_native::screen::event;

type Event = (u64, u32, i64, Vec<u8>);

static EVENTS: Mutex<Option<Sender<Event>>> = Mutex::new(None);

extern "C" fn callback(handle: u64, kind: u32, a: i64, data: *mut u8, len: usize) {
    let bytes = if data.is_null() {
        Vec::new()
    } else {
        // SAFETY: the library's bytes, copied and freed once, as Dart does.
        let copy = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
        unsafe { zest_native::zest_screen_free_bytes(data, len) };
        copy
    };
    if let Some(tx) = EVENTS.lock().unwrap().as_ref() {
        let _ = tx.send((handle, kind, a, bytes));
    }
}

/// "1920x1080+0+0,1280x1024-1280+200@150" as the engine's list of displays.
fn displays(list: &str) -> Result<serde_json::Value, String> {
    let mut out = Vec::new();
    for (i, item) in list.split(',').map(str::trim).filter(|s| !s.is_empty()).enumerate() {
        let bad = || format!("{item:?} is not a display (1920x1080+0+0)");
        let (item, scale) = match item.split_once('@') {
            Some((d, s)) => (d, s.parse::<u32>().map_err(|_| bad())?),
            None => (item, 0),
        };
        let (w, rest) = item.split_once('x').ok_or_else(bad)?;
        // The size ends at the first sign; the place is two signed numbers.
        let at = rest.find(['+', '-']).unwrap_or(rest.len());
        let (h, place) = rest.split_at(at);
        let (x, y) = if place.is_empty() {
            (0, 0)
        } else {
            let second = place[1..].find(['+', '-']).ok_or_else(bad)? + 1;
            let number = |t: &str| t.trim_start_matches('+').parse::<i32>().map_err(|_| bad());
            (number(&place[..second])?, number(&place[second..])?)
        };
        out.push(serde_json::json!({
            "x": x,
            "y": y,
            "width": w.parse::<u32>().map_err(|_| bad())?,
            "height": h.parse::<u32>().map_err(|_| bad())?,
            "scale": scale,
            "primary": i == 0,
        }));
    }
    Ok(serde_json::Value::Array(out))
}

fn setting(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

struct Outcome {
    connected: bool,
    closed: serde_json::Value,
}

fn run(pin: Option<&str>, events: &Receiver<Event>) -> Result<Outcome, String> {
    let host = setting("ZS_RDP_HOST").ok_or("set ZS_RDP_HOST")?;
    let port: u16 = setting("ZS_RDP_PORT").and_then(|p| p.parse().ok()).unwrap_or(13389);
    let nla = setting("ZS_RDP_NLA").as_deref() != Some("without");
    let run_for = Duration::from_millis(setting("ZS_RDP_RUN_MS").and_then(|t| t.parse().ok()).unwrap_or(8000));
    let mut request = serde_json::json!({
        "kind": "rdp",
        "username": setting("ZS_USER"),
        "server_name": host,
        "width": 1280,
        "height": 800,
        "rdp_graphics": setting("ZS_RDP_GRAPHICS").unwrap_or_else(|| "gfx".to_owned()),
        "rdp_h264": setting("ZS_RDP_H264").unwrap_or_else(|| "off".to_owned()),
        "rdp_nla": nla,
        "rdp_clipboard": setting("ZS_RDP_CLIPBOARD"),
        "tls_pin": pin,
    });
    if let Some(list) = setting("ZS_RDP_DISPLAYS") {
        request["displays"] = displays(&list)?;
    }
    if let Some(scale) = setting("ZS_RDP_SCALE").and_then(|s| s.parse::<u32>().ok()) {
        request["scale"] = scale.into();
    }
    let layouts: Vec<String> = match setting("ZS_RDP_LAYOUT") {
        Some(lists) => lists.split(';').map(|l| displays(l).map(|d| d.to_string())).collect::<Result<_, _>>()?,
        None => Vec::new(),
    };
    let mut laid_out = 0usize;
    if nla {
        request["password"] = setting("ZS_PASSWORD").into();
        request["domain"] = setting("ZS_RDP_DOMAIN").into();
    }
    let mut socket = TcpStream::connect((host.as_str(), port)).map_err(|e| format!("TCP: {e}"))?;
    socket.set_nodelay(true).ok();
    let request = CString::new(request.to_string()).unwrap();
    // SAFETY: a valid C string; the callback lives as long as the process.
    let handle = unsafe { zest_native::zest_screen_open(request.as_ptr(), callback) };
    if handle == 0 {
        return Err("the engine refused the request".to_owned());
    }
    let mut from_server = socket.try_clone().map_err(|e| format!("socket: {e}"))?;
    let reader = std::thread::spawn(move || {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match from_server.read(&mut buf) {
                Ok(0) | Err(_) => break,
                // SAFETY: n readable bytes.
                Ok(n) => unsafe {
                    zest_native::zest_screen_feed(handle, buf.as_ptr(), n);
                },
            }
        }
        zest_native::zest_screen_feed_end(handle);
    });

    let mut connected_at: Option<Instant> = None;
    let (mut typed, mut closing) = (false, false);
    let (mut offered, mut shared) = (false, false);
    let (moving, mut moved) = (setting("ZS_RDP_MOVE").is_some(), 0u32);
    let share_at = setting("ZS_RDP_SHARE_AT_MS").and_then(|t| t.parse().ok()).map(Duration::from_millis);
    let sizes: Vec<(u32, u32)> = setting("ZS_RDP_RESIZE")
        .map(|list| {
            list.split(',')
                .filter_map(|s| {
                    let (w, h) = s.split_once('x')?;
                    Some((w.trim().parse().ok()?, h.trim().parse().ok()?))
                })
                .collect()
        })
        .unwrap_or_default();
    let mut resized = 0usize;
    let (mut frames, mut sent, mut reports) = (0u64, 0u64, 0u32);
    let mut cursors = 0u32;
    let mut last_report = String::new();
    let closed = loop {
        let wait = Duration::from_millis(100);
        match events.recv_timeout(wait) {
            Ok((h, _, _, _)) if h != handle => {}
            Ok((_, kind, a, bytes)) => match kind {
                event::SEND => {
                    sent += bytes.len() as u64;
                    if socket.write_all(&bytes).is_err() {
                        zest_native::zest_screen_feed_end(handle);
                    }
                }
                event::CONNECTED => {
                    connected_at = Some(Instant::now());
                    println!("CONNECTED {}", String::from_utf8_lossy(&bytes));
                }
                event::FRAME => {
                    frames += 1;
                    let packet = zest_native::zest_screen_take_frame(handle);
                    // SAFETY: a packet taken from the session (or null), freed once.
                    unsafe { zest_native::zest_screen_free_frame(packet) };
                }
                event::RESIZE => println!("RESIZE {} x {}", a >> 32, a & 0xffff_ffff),
                event::DISPLAYS => println!("DISPLAYS {}", String::from_utf8_lossy(&bytes)),
                event::CLIPBOARD => println!("CLIPBOARD {:?}", String::from_utf8_lossy(&bytes)),
                event::CURSOR => {
                    cursors += 1;
                    let u = |at: usize| bytes.get(at..at + 2).map_or(0, |b| u16::from_le_bytes([b[0], b[1]]));
                    let what = match (a, u(0), u(2)) {
                        (1, ..) => "the system's own".to_owned(),
                        (_, 0, _) | (_, _, 0) => "hidden".to_owned(),
                        (_, w, h) => format!("{w} x {h}, hot spot {} {}, {} bytes", u(4), u(6), bytes.len() - 8),
                    };
                    if cursors <= 12 {
                        println!("CURSOR {what}");
                    }
                }
                event::INFO => {
                    // The last report says the most: it is printed at the end.
                    reports += 1;
                    last_report = String::from_utf8_lossy(&bytes).into_owned();
                    // What became of a size or a layout asked for is said when it comes.
                    if last_report.contains("layout_refused") || last_report.contains("resize_unavailable") {
                        println!("INFO {last_report}");
                    }
                }
                event::CLOSED => break serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or_default(),
                _ => {}
            },
            Err(_) => {}
        }
        if let Some(at) = connected_at {
            let since = at.elapsed();
            if !typed && since > Duration::from_secs(2) {
                typed = true;
                if let Some(text) = setting("ZS_RDP_TYPE") {
                    // As a person types into the picture: each character down and up (no
                    // scancode: sent as Unicode), then Enter by its scancode.
                    for c in text.chars() {
                        zest_native::zest_screen_key(handle, c as u32, 0, 1);
                        zest_native::zest_screen_key(handle, c as u32, 0, 0);
                    }
                    zest_native::zest_screen_key(handle, 0xff0d, 0x1c, 1);
                    zest_native::zest_screen_key(handle, 0xff0d, 0x1c, 0);
                    println!("typed {} characters and Enter", text.chars().count());
                }
            }
            if resized < sizes.len() && since > Duration::from_secs(5 + 2 * resized as u64) {
                let (w, h) = sizes[resized];
                resized += 1;
                zest_native::zest_screen_resize(handle, w, h);
                println!("asked for {w} x {h}");
            }
            if laid_out < layouts.len() && since > Duration::from_secs(5 + 3 * laid_out as u64) {
                let json = &layouts[laid_out];
                laid_out += 1;
                // SAFETY: the text's own bytes, for the call.
                let taken = unsafe { zest_native::zest_screen_displays(handle, json.as_ptr(), json.len()) };
                println!("asked for the displays {json} ({taken})");
            }
            if moving && since > Duration::from_secs(7) && moved < 400 {
                // Across the desktop, a few pixels each turn of this loop.
                moved += 1;
                zest_native::zest_screen_pointer(handle, 40 + moved * 3, 60 + moved * 2, 0);
            }
            if !offered && since > Duration::from_secs(6) {
                offered = true;
                if let Some(text) = setting("ZS_RDP_OFFER") {
                    // SAFETY: the text's own bytes, for the call.
                    unsafe { zest_native::zest_screen_clipboard(handle, text.as_ptr(), text.len()) };
                    println!("offered {} bytes as this device's clipboard", text.len());
                }
            }
            if !shared && share_at.is_some_and(|at| since > at) {
                shared = true;
                zest_native::zest_screen_clipboard_share(handle, 1);
                println!("sharing turned on");
            }
            if !closing && since > run_for {
                closing = true;
                zest_native::zest_screen_close(handle);
            }
        }
    };
    let _ = socket.shutdown(std::net::Shutdown::Both);
    let _ = reader.join();
    if !closing {
        zest_native::zest_screen_close(handle);
    }
    println!("frames taken: {frames}; bytes sent to the server: {sent}; graphics reports: {reports}; pointer shapes: {cursors}");
    if !last_report.is_empty() {
        println!("LAST INFO {last_report}");
    }
    Ok(Outcome { connected: connected_at.is_some(), closed })
}

fn main() -> std::process::ExitCode {
    let (tx, rx) = channel();
    *EVENTS.lock().unwrap() = Some(tx);
    let mut pin = setting("ZS_RDP_PIN");
    for attempt in 0..2 {
        let outcome = match run(pin.as_deref(), &rx) {
            Ok(o) => o,
            Err(e) => {
                eprintln!("{e}");
                return std::process::ExitCode::from(2);
            }
        };
        let c = &outcome.closed;
        // The certificate itself (base64) is long: say the rest.
        println!(
            "CLOSED reason {} detail {} message {:?} sha256 {} subject {}",
            c["reason"], c["detail"], c["message"].as_str().unwrap_or(""), c["sha256"], c["subject"]
        );
        if attempt == 0 && pin.is_none() && c["reason"] == "certificate" {
            pin = c["sha256"].as_str().map(str::to_owned);
            println!("the certificate is pinned for a second try, as after the app's question");
            continue;
        }
        return if outcome.connected && c["reason"] == "local" {
            std::process::ExitCode::SUCCESS
        } else {
            std::process::ExitCode::from(1)
        };
    }
    std::process::ExitCode::from(1)
}

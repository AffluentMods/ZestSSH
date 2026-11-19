//! The session through its C-facing pieces, against a synthetic RFB server fed as Dart would.

use std::collections::HashMap;
use std::sync::{Condvar, Mutex, OnceLock};
use std::time::Duration;

use super::*;
use crate::vnc::engine::PixelFormat;

/// What the callback got, by session.
#[derive(Default)]
struct Seen {
    events: HashMap<u64, Vec<(u32, i64, Vec<u8>)>>,
}

fn seen() -> &'static (Mutex<Seen>, Condvar) {
    static SEEN: OnceLock<(Mutex<Seen>, Condvar)> = OnceLock::new();
    SEEN.get_or_init(Default::default)
}

extern "C" fn callback(handle: u64, kind: u32, a: i64, data: *mut u8, len: usize) {
    let bytes = if data.is_null() {
        Vec::new()
    } else {
        // SAFETY: the session hands len bytes, ours to free.
        let v = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
        unsafe { free_bytes(data, len) };
        v
    };
    let (m, c) = seen();
    m.lock().unwrap().events.entry(handle).or_default().push((kind, a, bytes));
    c.notify_all();
}

/// Waits for an event of [kind] (after [from] events), returning its index.
fn wait_for(handle: u64, kind: u32, from: usize) -> (usize, i64, Vec<u8>) {
    let (m, c) = seen();
    let mut g = m.lock().unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(list) = g.events.get(&handle) {
            if let Some((i, e)) = list.iter().enumerate().skip(from).find(|(_, e)| e.0 == kind) {
                return (i, e.1, e.2.clone());
            }
        }
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        assert!(!left.is_zero(), "no event {kind} for session {handle}");
        g = c.wait_timeout(g, left).unwrap().0;
    }
}

/// Everything the engine sent so far, in order.
fn sent(handle: u64) -> Vec<u8> {
    let g = seen().0.lock().unwrap();
    g.events
        .get(&handle)
        .map(|l| l.iter().filter(|e| e.0 == event::SEND).flat_map(|e| e.2.clone()).collect())
        .unwrap_or_default()
}

fn server_handshake(width: u16, height: u16) -> Vec<u8> {
    let mut b = b"RFB 003.008\n".to_vec();
    b.extend([1u8, 1]); // one security type: None
    b.extend(0u32.to_be_bytes()); // SecurityResult OK
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend(Vec::<u8>::from(PixelFormat::rgba()));
    b.extend(4u32.to_be_bytes());
    b.extend(b"demo");
    b
}

fn raw_update(x: u16, y: u16, w: u16, h: u16, pixel: [u8; 4]) -> Vec<u8> {
    let mut b = vec![0u8, 0];
    b.extend(1u16.to_be_bytes());
    for v in [x, y, w, h] {
        b.extend(v.to_be_bytes());
    }
    b.extend(0i32.to_be_bytes());
    for _ in 0..(w as usize * h as usize) {
        b.extend(pixel);
    }
    b
}

#[test]
fn a_session_runs_over_the_pipe_and_hands_over_dirty_tiles() {
    let handle = open(r#"{"kind":"vnc","tile_size":4}"#, callback).unwrap();
    let s = session(handle).unwrap();
    // The server's side, fed in pieces as an SSH channel would hand it over.
    let hello = server_handshake(10, 6);
    for chunk in hello.chunks(5) {
        s.pipe.feed(chunk);
    }
    let (_, _, info) = wait_for(handle, event::CONNECTED, 0);
    let info: serde_json::Value = serde_json::from_slice(&info).unwrap();
    assert_eq!(info["name"], "demo");
    assert_eq!(info["width"], 10);
    // The client's version, its security choice and ClientInit went out through the callback.
    assert!(sent(handle).starts_with(b"RFB 003.008\n\x01"), "{:?}", sent(handle));

    // The first frame: the whole (black) screen, then a 2 x 2 rectangle in tile (1, 1).
    s.pipe.feed(&raw_update(5, 4, 2, 2, [10, 20, 30, 0]));
    let (_, seq, _) = wait_for(handle, event::FRAME, 0);
    assert!(seq >= 1);
    let packet = s.frame.lock().unwrap().take(now_us()).unwrap();
    // SAFETY: a packet just taken, freed below.
    let p = unsafe { &*packet };
    assert_eq!((p.width, p.height), (10, 6));
    // 10 x 6 in tiles of 4: all 6 dirty after the resize, so the whole screen as one tile.
    assert_eq!(p.tile_count, 1);
    let tiles = unsafe { std::slice::from_raw_parts(p.tiles, p.tile_count as usize) };
    let pixels = unsafe { std::slice::from_raw_parts(p.pixels, p.pixels_len as usize) };
    assert_eq!(tiles[0], FrameTile { x: 0, y: 0, width: 10, height: 6, offset: 0 });
    assert_eq!(pixels.len(), 10 * 6 * 4);
    // Pixel (5, 4), made opaque.
    let at = (4 * 10 + 5) * 4;
    assert_eq!(&pixels[at..at + 4], &[10, 20, 30, 255]);
    assert!(p.first_change_us > 0 && p.last_done_us >= p.first_change_us);
    unsafe { free_packet(packet) };

    // Next update: only the tiles it touches.
    let before = seen().0.lock().unwrap().events[&handle].len();
    s.pipe.feed(&raw_update(3, 1, 2, 1, [1, 2, 3, 0]));
    wait_for(handle, event::FRAME, before);
    let packet = s.frame.lock().unwrap().take(now_us()).unwrap();
    let p = unsafe { &*packet };
    let tiles = unsafe { std::slice::from_raw_parts(p.tiles, p.tile_count as usize) };
    let pixels = unsafe { std::slice::from_raw_parts(p.pixels, p.pixels_len as usize) };
    assert_eq!(tiles.iter().map(|t| (t.x, t.y, t.width, t.height)).collect::<Vec<_>>(), vec![(0, 0, 4, 4), (4, 0, 4, 4)]);
    assert_eq!(pixels.len(), 2 * 4 * 4 * 4);
    // Pixel (4, 1) is the second tile's (0, 1): its second row starts 4 pixels in.
    let at = tiles[1].offset as usize + 4 * 4;
    assert_eq!(&pixels[at..at + 4], &[1, 2, 3, 255]);
    unsafe { free_packet(packet) };
    assert!(s.frame.lock().unwrap().take(now_us()).is_none(), "nothing new");

    // Input goes out as RFB messages, in order: PointerEvent then KeyEvent.
    let before = sent(handle).len();
    s.commands.push(Command::Pointer { x: 7, y: 3, buttons: 1 });
    s.commands.push(Command::Key { keysym: 0x61, scancode: 0, down: true });
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let out = sent(handle)[before..].to_vec();
        let pointer = [5u8, 1, 0, 7, 0, 3];
        let key = [4u8, 1, 0, 0, 0, 0, 0, 0x61];
        let p = out.windows(6).position(|w| w == pointer);
        let k = out.windows(8).position(|w| w == key);
        if let (Some(p), Some(k)) = (p, k) {
            assert!(p < k);
            break;
        }
        assert!(std::time::Instant::now() < deadline, "input not sent: {out:?}");
        std::thread::sleep(Duration::from_millis(10));
    }

    // Close: CLOSED comes (an idle session's before close returns), with the reason "local"
    // and no error.
    close(handle);
    let (_, _, closed) = wait_for(handle, event::CLOSED, 0);
    let closed: serde_json::Value = serde_json::from_slice(&closed).unwrap();
    assert_eq!(closed["reason"], "local");
    assert!(closed.get("error").is_none());
    assert!(session(handle).is_none());
}

#[test]
fn the_end_of_the_channel_closes_the_session_with_a_reason() {
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(b"RFB 003.008\n");
    s.pipe.end();
    let (_, _, closed) = wait_for(handle, event::CLOSED, 0);
    let closed: serde_json::Value = serde_json::from_slice(&closed).unwrap();
    // The channel's clean end during the handshake: the server closed it (not "end of file").
    assert_eq!(closed["reason"], "server_closed", "{closed}");
    assert_eq!(closed["error"], "the server closed the connection");
    close(handle);
}

// The engines read a server's bytes with code that is not all ours, and a
// panic in it used to end the app (the library was built to abort). Fuzzing the RDP sign-in
// found one in its first minutes: sspi split a CredSSP proof shorter than a signature.
#[test]
fn a_panic_in_a_sessions_engine_closes_that_session_and_nothing_else() {
    let handle = 9_000_001;
    let notifier = Notifier { handle, callback };
    let frame = std::sync::Arc::new(Mutex::new(Framebuffer::new(64)));
    let held = frame.clone();
    let thread = std::thread::spawn(move || {
        run_session(notifier, || async move {
            let _picture = held.held();
            let short: &[u8] = &[1, 2, 3];
            let _ = short.split_at(std::hint::black_box(16));
            Ok(())
        })
    });
    thread.join().expect("the panic left the session's thread");
    let (_, _, bytes) = wait_for(handle, event::CLOSED, 0);
    let closed: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(closed["reason"], "internal", "{closed}");
    let message = closed["message"].as_str().unwrap();
    assert!(message.starts_with("the session's engine stopped at src/screen/tests.rs:"), "{message}");
    assert!(message.ends_with(": mid > len"), "{message}");
    // The lock the engine held is taken as before: Dart still asks for the frame, feeds, closes.
    assert!(frame.is_poisoned());
    drop(frame.held());
    // And the thread is as good as new for the next session on it.
    run_session(notifier, || async { Ok(()) });
    let (_, _, bytes) = wait_for(handle, event::CLOSED, 1);
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&bytes).unwrap()["reason"], "local");
}

#[test]
fn a_panics_place_is_told_from_its_crate_on() {
    for (file, short) in [
        (r"C:\Users\someone\.cargo\registry\src\index.crates.io-1949cf8c6b5b557f\sspi-0.23.0\src\credssp\mod.rs", "sspi-0.23.0/src/credssp/mod.rs"),
        ("/home/someone/.cargo/registry/src/index.crates.io-1/ironrdp-pdu-0.11.0/src/rdp/headers.rs", "ironrdp-pdu-0.11.0/src/rdp/headers.rs"),
        (r"src\screen\rdp_session.rs", "src/screen/rdp_session.rs"),
        ("/rustc/58cf8f9c/library/core/src/slice/mod.rs", "core/src/slice/mod.rs"),
        ("build.rs", "build.rs"),
    ] {
        assert_eq!(from_its_crate(file), short);
    }
}

#[test]
fn a_wrong_request_or_engine_is_refused() {
    assert!(open("{", callback).is_err());
    assert!(open(r#"{"kind":"spice"}"#, callback).unwrap_err().contains("spice"));
}

#[test]
fn feeding_past_the_high_mark_asks_to_pause_and_reading_says_drained() {
    let n = Notifier { handle: 999_001, callback };
    let pipe = Arc::new(Pipe::new(n));
    let chunk = vec![7u8; 1 << 20];
    let mut queued = 0;
    for _ in 0..5 {
        queued = pipe.feed(&chunk);
    }
    assert!(queued > FEED_HIGH_MARK);
    let mut stream = DartStream::new(pipe.clone(), n);
    let rt = tokio::runtime::Builder::new_current_thread().build().unwrap();
    rt.block_on(async {
        use tokio::io::AsyncReadExt;
        let mut buf = vec![0u8; 1 << 20];
        for _ in 0..4 {
            stream.read_exact(&mut buf).await.unwrap();
        }
        stream.read_exact(&mut buf[..1 << 19]).await.unwrap();
    });
    let (_, left, _) = wait_for(999_001, event::DRAINED, 0);
    assert!(left < FEED_LOW_MARK as i64);
}

#[test]
fn copy_rect_handles_overlap() {
    let mut f = Framebuffer::new(0);
    f.resize(4, 1);
    f.put(0, 0, 4, 1, &[1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0], 1);
    f.copy(1, 0, 0, 0, 3, 1, 2);
    let reds: Vec<u8> = f.rgba().chunks_exact(4).map(|p| p[0]).collect();
    assert_eq!(reds, vec![1, 1, 2, 3]);
    // Out of the screen: clipped, never a panic.
    f.put(3, 0, 5, 5, &[9; 100], 3);
    f.copy(10, 10, 0, 0, 2, 2, 4);
}

/// One FramebufferUpdate made of [rects] (each: header then body).
fn update(rects: &[(u16, u16, u16, u16, i32, Vec<u8>)]) -> Vec<u8> {
    let mut b = vec![0u8, 0];
    b.extend((rects.len() as u16).to_be_bytes());
    for (x, y, w, h, enc, body) in rects {
        for v in [*x, *y, *w, *h] {
            b.extend(v.to_be_bytes());
        }
        b.extend(enc.to_be_bytes());
        b.extend(body);
    }
    b
}

/// The whole screen as Tight solid fills, in bands of [band] rows (as TigerVNC sends a solid
/// colour: a few bytes a rectangle).
fn tight_fill_screen(w: u16, h: u16, band: u16, rgb: [u8; 3]) -> Vec<u8> {
    let mut rects = Vec::new();
    let mut y = 0;
    while y < h {
        let bh = band.min(h - y);
        let mut body = vec![0x80u8];
        body.extend(rgb);
        rects.push((0, y, w, bh, 7, body));
        y += bh;
    }
    update(&rects)
}

/// The whole screen as one ZRLE rectangle of solid 64 x 64 tiles (one zlib stream for the
/// session, as the protocol has it).
fn zrle_solid_screen(z: &mut flate2::Compress, w: u16, h: u16, rgb: [u8; 3]) -> Vec<u8> {
    let tiles = w.div_ceil(64) as usize * h.div_ceil(64) as usize;
    let mut raw = Vec::with_capacity(tiles * 4);
    for _ in 0..tiles {
        raw.push(1u8);
        raw.extend(rgb);
    }
    let mut out = Vec::with_capacity(raw.len() + 1024);
    z.compress_vec(&raw, &mut out, flate2::FlushCompress::Sync).unwrap();
    let mut body = (out.len() as u32).to_be_bytes().to_vec();
    body.extend(out);
    update(&[(0, 0, w, h, 16, body)])
}

/// The whole screen as one Raw rectangle.
fn raw_screen(w: u16, h: u16, rgb: [u8; 3]) -> Vec<u8> {
    let mut body = Vec::with_capacity(w as usize * h as usize * 4);
    for _ in 0..w as usize * h as usize {
        body.extend([rgb[0], rgb[1], rgb[2], 0]);
    }
    update(&[(0, 0, w, h, 0, body)])
}

/// Updates the session finished: it asks for the next one (an incremental request for the whole
/// screen) after each, so they are counted in what it sent. Returns false when [n] did not come
/// within the time limit.
fn wait_requests(handle: u64, w: u16, h: u16, from: usize, n: usize) -> bool {
    let mut pattern = vec![3u8, 1, 0, 0, 0, 0];
    pattern.extend(w.to_be_bytes());
    pattern.extend(h.to_be_bytes());
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    loop {
        let out = sent(handle);
        let got = out[from.min(out.len())..].windows(10).filter(|x| *x == pattern.as_slice()).count();
        if got >= n {
            return true;
        }
        if std::time::Instant::now() > deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// The whole-screen worst case through the engine and into the framebuffer (day 2: a solid
/// colour flipping over the whole screen): milliseconds per update for Tight fills, ZRLE solid
/// tiles and Raw, at 1920 x 1080. A measurement, not a check: run with
/// `cargo test --release --features vnc -- --ignored --nocapture whole_screen`.
#[test]
#[ignore]
fn whole_screen_updates_per_second() {
    let (w, h) = (1920u16, 1080u16);
    let mut z = flate2::Compress::new(flate2::Compression::fast(), true);
    let kinds: Vec<(&str, usize, Box<dyn FnMut(usize) -> Vec<u8>>)> = vec![
        ("tight_fill_bands_68", 120, Box::new(move |i| tight_fill_screen(w, h, 68, if i % 2 == 0 { [255, 0, 0] } else { [0, 0, 255] }))),
        ("zrle_solid_tiles", 120, Box::new(move |i| zrle_solid_screen(&mut z, w, h, if i % 2 == 0 { [255, 0, 0] } else { [0, 0, 255] }))),
        ("raw", 30, Box::new(move |i| raw_screen(w, h, if i % 2 == 0 { [255, 0, 0] } else { [0, 0, 255] }))),
    ];
    for (name, n, mut make) in kinds {
        let encodings = if name == "zrle_solid_tiles" { r#","encodings":["ZRLE"]"# } else { "" };
        let handle = open(&format!(r#"{{"kind":"vnc","tile_size":256{encodings}}}"#), callback).unwrap();
        let s = session(handle).unwrap();
        s.pipe.feed(&server_handshake(w, h));
        wait_for(handle, event::CONNECTED, 0);
        let updates: Vec<Vec<u8>> = (0..n + 5).map(&mut make).collect();
        // Warm up (first update, allocations).
        let from = sent(handle).len();
        for u in &updates[..5] {
            s.pipe.feed(u);
        }
        assert!(wait_requests(handle, w, h, from, 5), "{name}: warm-up");
        let from = sent(handle).len();
        let t = std::time::Instant::now();
        for u in &updates[5..] {
            s.pipe.feed(u);
        }
        assert!(wait_requests(handle, w, h, from, n), "{name}: updates");
        let per = t.elapsed().as_secs_f64() * 1000.0 / n as f64;
        // The last update drawn: the whole screen in its colour (n + 5 updates, the last odd or
        // even), opaque.
        let want = if (n + 4) % 2 == 0 { [255u8, 0, 0, 255] } else { [0, 0, 255, 255] };
        {
            let f = s.frame.lock().unwrap();
            let px = f.rgba();
            for at in [0usize, (w as usize * h as usize / 2) * 4, (w as usize * h as usize - 1) * 4] {
                assert_eq!(&px[at..at + 4], &want, "{name}: pixel {}", at / 4);
            }
        }
        println!("BENCH {name}: {n} updates of {w}x{h}, {per:.2} ms an update, {:.0} updates/s", 1000.0 / per);
        close(handle);
    }
}

/// Counts `pattern` in what the session sent after `from` bytes.
fn count_sent(handle: u64, from: usize, pattern: &[u8]) -> usize {
    let out = sent(handle);
    out[from.min(out.len())..].windows(pattern.len()).filter(|x| *x == pattern).count()
}

fn wait_sent(handle: u64, from: usize, pattern: &[u8], n: usize) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while count_sent(handle, from, pattern) < n {
        assert!(std::time::Instant::now() < deadline, "not sent: {pattern:?}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

fn closed_json(handle: u64) -> serde_json::Value {
    let (_, _, closed) = wait_for(handle, event::CLOSED, 0);
    serde_json::from_slice(&closed).unwrap()
}

#[test]
fn the_channel_failing_closes_with_its_reason() {
    // Mid-session, the SSH connection drops: the reason Dart gave, not "end of file" or "the
    // VNC client isn't started" (day 4).
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    s.pipe.end_with(TransportEnd::Failed {
        reason: CloseReason::Network,
        message: "SSH connection lost: Software caused connection abort".into(),
    });
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "network", "{closed}");
    assert_eq!(closed["error"], "SSH connection lost: Software caused connection abort");
    close(handle);

    // The channel closes cleanly mid-session (the server ended it): server_closed.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    s.pipe.end();
    assert_eq!(closed_json(handle)["reason"], "server_closed");
    close(handle);
}

#[test]
fn a_refused_password_closes_as_auth_with_the_servers_reason() {
    let handle = open(r#"{"kind":"vnc","password":"wrong"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    let mut b = b"RFB 003.008\n".to_vec();
    b.extend([1u8, 2]); // VNC authentication only
    b.extend([7u8; 16]); // the challenge
    b.extend(1u32.to_be_bytes()); // SecurityResult: failed
    b.extend(14u32.to_be_bytes());
    b.extend(b"wrong password");
    s.pipe.feed(&b);
    s.pipe.end();
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "auth", "{closed}");
    assert!(closed["error"].as_str().unwrap().contains("wrong password"), "{closed}");
    close(handle);
}

#[test]
fn pause_stops_the_requests_and_resume_asks_for_the_whole_screen() {
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    let incremental = [3u8, 1, 0, 0, 0, 0, 0, 8, 0, 8];
    let full = [3u8, 0, 0, 0, 0, 0, 0, 8, 0, 8];
    let from = sent(handle).len();
    s.pipe.feed(&raw_update(0, 0, 1, 1, [1, 2, 3, 0]));
    wait_sent(handle, from, &incremental, 1);

    s.commands.push(Command::Pause);
    let (i, _, info) = wait_for(handle, event::INFO, 0);
    let info: serde_json::Value = serde_json::from_slice(&info).unwrap();
    assert_eq!(info["paused"], true);
    assert_eq!(info["how"], "no_requests");
    // An update already asked for still comes, and is drawn; no request follows it.
    let from = sent(handle).len();
    s.pipe.feed(&raw_update(1, 1, 1, 1, [4, 5, 6, 0]));
    let before = seen().0.lock().unwrap().events[&handle].len();
    s.pipe.feed(&raw_update(2, 2, 1, 1, [4, 5, 6, 0]));
    // A third update (any) to know the second was read: Bell.
    s.pipe.feed(&[2]);
    wait_for(handle, event::BELL, before);
    assert_eq!(count_sent(handle, from, &incremental), 0);

    s.commands.push(Command::Resume);
    wait_for(handle, event::INFO, i + 1);
    wait_sent(handle, from, &full, 1);
    // Then updates are asked for again.
    let from = sent(handle).len();
    s.pipe.feed(&raw_update(0, 0, 1, 1, [1, 2, 3, 0]));
    wait_sent(handle, from, &incremental, 1);
    close(handle);
}

#[test]
fn continuous_updates_through_the_session_need_no_requests() {
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    // The engine offered both (defaults).
    assert!(sent(handle).windows(4).any(|w| w == (-313i32).to_be_bytes()));
    assert!(sent(handle).windows(4).any(|w| w == (-312i32).to_be_bytes()));
    let from = sent(handle).len();
    let mut fence = vec![248u8, 0, 0, 0];
    fence.extend((1u32 << 31).to_be_bytes());
    fence.push(0);
    s.pipe.feed(&fence);
    s.pipe.feed(&[150]);
    let (_, _, info) = wait_for(handle, event::INFO, 0);
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&info).unwrap()["continuous_updates"], true);
    // The fence answered, continuous updates on for the screen.
    wait_sent(handle, from, &[248, 0, 0, 0, 0, 0, 0, 0, 0], 1);
    wait_sent(handle, from, &[150, 1, 0, 0, 0, 0, 0, 8, 0, 8], 1);
    // Updates come without requests now.
    let incremental = [3u8, 1, 0, 0, 0, 0, 0, 8, 0, 8];
    let from = sent(handle).len();
    for i in 0..3u16 {
        let before = seen().0.lock().unwrap().events[&handle].len();
        s.pipe.feed(&raw_update(i, i, 1, 1, [9, 9, 9, 0]));
        wait_for(handle, event::FRAME, before);
        s.frame.lock().unwrap().take(now_us()).map(|p| unsafe { free_packet(p) });
    }
    assert_eq!(count_sent(handle, from, &incremental), 0);
    // Pause turns them off (the INFO says how).
    s.commands.push(Command::Pause);
    wait_sent(handle, from, &[150, 0, 0, 0, 0, 0, 0, 8, 0, 8], 1);
    close(handle);
}

#[test]
fn fills_and_zrle_go_straight_into_the_picture() {
    let handle = open(r#"{"kind":"vnc","tile_size":4,"encodings":["Tight","ZRLE"]}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(70, 8));
    wait_for(handle, event::CONNECTED, 0);
    // A Tight fill over (1, 1, 3, 2), then a ZRLE rectangle of two tiles (64 + 6 wide).
    let mut fill = vec![0x80u8];
    fill.extend([10, 20, 30]);
    let mut z = flate2::Compress::new(flate2::Compression::fast(), true);
    let mut raw = vec![1u8, 40, 50, 60]; // tile 1: solid
    raw.push(0); // tile 2: raw pixels, 6 x 8
    for i in 0..48u8 {
        raw.extend([i, i, i]);
    }
    let mut out = Vec::with_capacity(4096);
    z.compress_vec(&raw, &mut out, flate2::FlushCompress::Sync).unwrap();
    let mut zrle = (out.len() as u32).to_be_bytes().to_vec();
    zrle.extend(out);
    let before = seen().0.lock().unwrap().events[&handle].len();
    s.pipe.feed(&update(&[(1, 1, 3, 2, 7, fill), (0, 0, 70, 8, 16, zrle)]));
    wait_for(handle, event::FRAME, before);
    let f = s.frame.lock().unwrap();
    let px = |x: usize, y: usize| f.rgba()[(y * 70 + x) * 4..(y * 70 + x) * 4 + 4].to_vec();
    // ZRLE came after the fill and covers it.
    assert_eq!(px(1, 1), [40, 50, 60, 255]);
    assert_eq!(px(63, 7), [40, 50, 60, 255]);
    assert_eq!(px(64, 0), [0, 0, 0, 255]);
    assert_eq!(px(69, 7), [47, 47, 47, 255]);
    drop(f);
    close(handle);
}

/// The test certificate of the VeNCrypt tests, as DER.
fn test_certificate_der() -> Vec<u8> {
    use base64::Engine as _;
    let pem = include_str!("../vnc/engine/client/vencrypt_test_identity.pem");
    let body: String = pem
        .split("-----BEGIN CERTIFICATE-----")
        .nth(1)
        .and_then(|rest| rest.split("-----END CERTIFICATE-----").next())
        .unwrap()
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD.decode(body).unwrap()
}

#[test]
fn a_certificate_not_trusted_closes_with_the_certificate_its_subject_and_validity() {
    use base64::Engine as _;
    use sha2::{Digest as _, Sha256};
    let der = test_certificate_der();
    let json = Closed::certificate(&der).json();
    let sha = hex(&Sha256::digest(&der));
    assert_eq!(json["reason"], "certificate");
    assert_eq!(json["sha256"], sha.as_str());
    assert_eq!(json["error"], format!("certificate not trusted: SHA-256 {sha}"));
    assert_eq!(base64::engine::general_purpose::STANDARD.decode(json["der"].as_str().unwrap()).unwrap(), der);
    assert_eq!(json["subject"], "CN=zestscreens-vnc-test.example.test", "{json}");
    let (from, until) = (json["not_before"].as_i64().unwrap(), json["not_after"].as_i64().unwrap());
    // Made on 7 November 2026, for a hundred years.
    assert!((1_794_000_000..1_795_000_000).contains(&from), "{from}");
    assert!(until > from + 99 * 365 * 86_400, "{until}");

    // Bytes that are no certificate still give their fingerprint (the question can be asked).
    let json = Closed::certificate(b"not a certificate").json();
    assert_eq!(json["sha256"], hex(&Sha256::digest(b"not a certificate")).as_str());
    assert_eq!(json["subject"], "");
    assert!(json["not_before"].is_null() && json["not_after"].is_null());

    // Other reasons carry none of it.
    let json = Closed::new(CloseReason::Auth, "no").json();
    assert!(json.get("der").is_none() && json.get("sha256").is_none());
}

#[test]
fn clipboard_text_goes_to_the_server() {
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    let from = sent(handle).len();
    // No extended clipboard from this server: ClientCutText in Latin-1 (RFC 6143 7.5.6).
    let text = "caf\u{e9}";
    // SAFETY: the bytes are live for the call.
    unsafe { crate::zest_screen_clipboard(handle, text.as_ptr(), text.len()) };
    let mut want = vec![6u8, 0, 0, 0];
    want.extend(4u32.to_be_bytes());
    want.extend(b"caf\xe9");
    wait_sent(handle, from, &want, 1);
    close(handle);
}

#[test]
fn the_remote_cursor_shape_goes_to_dart() {
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    // A 2 x 1 cursor with its hot spot at (1, 0): two pixels, then a mask with the first set.
    let mut b = vec![0u8, 0];
    b.extend(1u16.to_be_bytes());
    for v in [1u16, 0, 2, 1] {
        b.extend(v.to_be_bytes());
    }
    b.extend((-239i32).to_be_bytes());
    b.extend([10, 20, 30, 0, 40, 50, 60, 0]);
    b.push(0b1000_0000);
    s.pipe.feed(&b);
    let (_, _, data) = wait_for(handle, event::CURSOR, 0);
    assert_eq!(&data[..8], &[2, 0, 1, 0, 1, 0, 0, 0]);
    assert_eq!(&data[8..], &[10, 20, 30, 255, 40, 50, 60, 0]);
    close(handle);
}

#[test]
fn the_password_is_never_printed() {
    let request: OpenRequest = serde_json::from_str(r#"{"kind":"vnc","password":"hunter2","username":"u"}"#).unwrap();
    let text = format!("{request:?}");
    assert!(!text.contains("hunter2") && text.contains("<redacted>"), "{text}");
    let options = crate::vnc::engine::ConnectOptions { password: request.password.clone(), ..Default::default() };
    let text = format!("{options:?}");
    assert!(!text.contains("hunter2") && text.contains("<redacted>"), "{text}");
}

#[test]
fn shared_is_asked_for_unless_the_request_says_not() {
    for (request, flag) in [(r#"{"kind":"vnc"}"#, 1u8), (r#"{"kind":"vnc","shared":false}"#, 0u8)] {
        let handle = open(request, callback).unwrap();
        let s = session(handle).unwrap();
        s.pipe.feed(&server_handshake(8, 8));
        wait_for(handle, event::CONNECTED, 0);
        // "RFB 003.008\n", the security type chosen (None), then ClientInit's shared flag.
        let out = sent(handle);
        assert_eq!(&out[..14], &[b"RFB 003.008\n".as_slice(), &[1, flag]].concat()[..], "{request}");
        close(handle);
    }
}

// From a security review: a few KB from a server must neither keep the session busy for minutes nor
// make closing it wait.

/// How many events of [kind] the session has had once there are [want] (waited for up to 2 s)
/// and 300 ms more have passed: for an event that is paced, to count what came and then make
/// sure no more do.
fn count_settled(handle: u64, kind: u32, want: usize) -> usize {
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while count_kind(handle, kind) < want && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    std::thread::sleep(Duration::from_millis(300));
    count_kind(handle, kind)
}

fn count_kind(handle: u64, kind: u32) -> usize {
    let g = seen().0.lock().unwrap();
    g.events.get(&handle).map_or(0, |l| l.iter().filter(|e| e.0 == kind).count())
}

/// A FramebufferUpdate of one RRE rectangle over the whole [w] x [h] screen whose [n]
/// subrectangles each cover it all again (12 bytes each).
fn rre_cover_update(w: u16, h: u16, n: u32) -> Vec<u8> {
    let mut b = vec![0u8, 0];
    b.extend(1u16.to_be_bytes());
    for v in [0u16, 0, w, h] {
        b.extend(v.to_be_bytes());
    }
    b.extend(2i32.to_be_bytes()); // RRE
    b.extend(n.to_be_bytes());
    b.extend([1, 2, 3, 0]); // the background
    for i in 0..n {
        b.extend([(i % 255) as u8, 7, 7, 0]);
        for v in [0u16, 0, w, h] {
            b.extend(v.to_be_bytes());
        }
    }
    b
}

#[test]
fn closing_during_the_reviews_rre_flood_returns_at_once() {
    // The review's probe: 36 KB of RRE (3000 subrectangles each over the whole 8192 x 1012
    // rectangle), then the app closes the tab: zest_screen_close blocked its caller for 48 s.
    let handle = open(r#"{"kind":"vnc","tile_size":256}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8192, 1012));
    wait_for(handle, event::CONNECTED, 0);
    s.pipe.feed(&rre_cover_update(8192, 1012, 3000));
    std::thread::sleep(Duration::from_millis(300));
    let t = std::time::Instant::now();
    close(handle);
    let took = t.elapsed();
    assert!(took < Duration::from_millis(100), "close blocked its caller for {took:?}");
    // Closed by the app or by the limit on subrectangles, whichever came first: soon either way.
    let closed = closed_json(handle);
    assert!(closed["reason"] == "local" || closed["reason"] == "protocol", "{closed}");
}

#[test]
fn closing_during_a_flood_returns_at_once_and_the_session_stops_soon_after() {
    let handle = open(r#"{"kind":"vnc","tile_size":256}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8192, 1012));
    wait_for(handle, event::CONNECTED, 0);
    // Updates within every limit (a full-screen RRE rectangle with three subrectangles over it
    // all), 200 of them: 11 KB, and seconds of drawing even in a release build.
    s.pipe.feed(&rre_cover_update(8192, 1012, 3).repeat(200));
    std::thread::sleep(Duration::from_millis(300));
    let t = std::time::Instant::now();
    close(handle);
    let took = t.elapsed();
    assert!(took < Duration::from_millis(100), "close blocked its caller for {took:?}");
    // The engine stopped within a subrectangle: CLOSED soon, as the app closed it.
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "local", "{closed}");
}

#[test]
fn subrectangles_covering_their_rectangle_again_and_again_close_the_session() {
    // The review's probe: 3000 subrectangles each over the whole 8192 x 1012 rectangle (36 KB;
    // 48 s of drawing before). Refused at the fifth.
    let handle = open(r#"{"kind":"vnc","tile_size":256}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8192, 1012));
    wait_for(handle, event::CONNECTED, 0);
    let flood = rre_cover_update(8192, 1012, 3000);
    assert_eq!(flood.len(), 36024);
    s.pipe.feed(&flood);
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "protocol", "{closed}");
    assert!(closed["message"].as_str().unwrap().contains("subrectangles cover their rectangle more than 4 times"), "{closed}");
    close(handle);
}

#[test]
fn an_update_may_draw_four_times_the_screen_and_change_its_size_once() {
    // Five full-screen rectangles in one update: refused.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    let one = raw_update(0, 0, 8, 8, [1, 2, 3, 0]);
    let mut b = vec![0u8, 0];
    b.extend(5u16.to_be_bytes());
    for _ in 0..5 {
        b.extend_from_slice(&one[4..]);
    }
    s.pipe.feed(&b);
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "protocol", "{closed}");
    assert!(closed["message"].as_str().unwrap().contains("draws more than 4 times the screen"), "{closed}");
    close(handle);

    // The review's probe: 300 DesktopSize rectangles in one update (3.6 KB; 300 pictures of
    // 33 MB before). Refused at the second.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    // ServerInit's size is the first.
    wait_for(handle, event::RESIZE, 0);
    let resizes = count_kind(handle, event::RESIZE);
    let n: u16 = 300;
    let mut b = vec![0u8, 0];
    b.extend(n.to_be_bytes());
    for i in 0..n {
        let h: u16 = if i % 2 == 0 { 1012 } else { 1011 };
        for v in [0u16, 0, 8192, h] {
            b.extend(v.to_be_bytes());
        }
        b.extend((-223i32).to_be_bytes());
    }
    s.pipe.feed(&b);
    let closed = closed_json(handle);
    assert_eq!(closed["reason"], "protocol", "{closed}");
    assert!(closed["message"].as_str().unwrap().contains("size twice in one update"), "{closed}");
    // At most the one size the update may change to: a size is sent at most every 100 ms and
    // the latest held meanwhile (paced), and one held when the session closes is never sent, so
    // a release build, fast enough to close first, sees none. What this test is
    // about is that 300 are not.
    let n = count_kind(handle, event::RESIZE);
    assert!(n <= resizes + 1, "{} resizes after the first", n - resizes);
    close(handle);
}

#[test]
fn many_layouts_in_one_update_resize_the_picture_once() {
    // ExtendedDesktopSize: TigerVNC may queue several layouts in one update, so they are not
    // refused, but the picture is made once, at the size the update ends with.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    // ServerInit's size is the first.
    wait_for(handle, event::RESIZE, 0);
    let resizes = count_kind(handle, event::RESIZE);
    let n: u16 = 301;
    let mut b = vec![0u8, 0];
    b.extend(n.to_be_bytes());
    for i in 0..n {
        let (w, h): (u16, u16) = if i % 2 == 0 { (8192, 1012) } else { (8192, 1011) };
        for v in [0u16, 0, w, h] {
            b.extend(v.to_be_bytes());
        }
        b.extend((-308i32).to_be_bytes());
        b.extend([1u8, 0, 0, 0]); // one screen
        b.extend(1u32.to_be_bytes());
        for v in [0u16, 0, w, h] {
            b.extend(v.to_be_bytes());
        }
        b.extend(0u32.to_be_bytes());
    }
    b.push(2); // Bell: the update is done once it comes
    s.pipe.feed(&b);
    wait_for(handle, event::BELL, 0);
    // The bell goes at once; the size, paced (at most every 100 ms, the latest held), may
    // come up to 100 ms after it. Counted once it came and a while after: one (counted
    // at the bell, a release build saw none).
    assert_eq!(count_settled(handle, event::RESIZE, resizes + 1), resizes + 1);
    let last = seen().0.lock().unwrap().events[&handle].iter().filter(|e| e.0 == event::RESIZE).last().unwrap().1;
    assert_eq!(last, (8192 << 32) | 1012);
    let size = {
        let f = s.frame.lock().unwrap();
        (f.width, f.height)
    };
    assert_eq!(size, (8192, 1012));
    close(handle);
}

#[test]
fn a_servers_layout_before_its_pixels_resizes_the_picture_first() {
    // wayvnc sends its own new layout (ExtendedDesktopSize, reason server) and pixels in that
    // size in one update: the picture takes the new size before the pixels are drawn (the session
    // ended with invalid image data).
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    wait_for(handle, event::RESIZE, 0);
    let (w, h): (u16, u16) = (16, 10);
    let mut b = vec![0u8, 0];
    b.extend(2u16.to_be_bytes());
    for v in [0u16, 0, w, h] {
        b.extend(v.to_be_bytes());
    }
    b.extend((-308i32).to_be_bytes());
    b.extend([1u8, 0, 0, 0]); // one screen
    b.extend(1u32.to_be_bytes());
    for v in [0u16, 0, w, h] {
        b.extend(v.to_be_bytes());
    }
    b.extend(0u32.to_be_bytes());
    // One raw pixel at the new picture's far corner.
    for v in [w - 1, h - 1, 1, 1] {
        b.extend(v.to_be_bytes());
    }
    b.extend(0i32.to_be_bytes());
    b.extend([10u8, 20, 30, 0]);
    b.push(2); // Bell: the update is done once it comes
    s.pipe.feed(&b);
    wait_for(handle, event::BELL, 0);
    let size = {
        let f = s.frame.lock().unwrap();
        (f.width, f.height)
    };
    assert_eq!(size, (16, 10));
    close(handle);
}

/// The last event of [kind] the session's callback got, once it is [want] (within 5 s).
fn wait_last(handle: u64, kind: u32, want: impl Fn(i64, &[u8]) -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        {
            let g = seen().0.lock().unwrap();
            if let Some(e) = g.events.get(&handle).and_then(|l| l.iter().filter(|e| e.0 == kind).last()) {
                if want(e.1, &e.2) {
                    return;
                }
            }
        }
        assert!(std::time::Instant::now() < deadline, "the last event {kind} never came");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn floods_of_bells_clipboards_cursors_and_sizes_reach_dart_paced_with_the_latest_kept() {
    // From a security review: one BELL callback per byte of Bell (200000 in the probe), and a message
    // per cursor, clipboard and size, each queued on Dart's UI isolate.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    wait_for(handle, event::RESIZE, 0);
    let t = std::time::Instant::now();
    let mut b = vec![2u8; 200_000];
    for i in 0..1000 {
        let text = format!("text {i}");
        b.extend([3u8, 0, 0, 0]);
        b.extend((text.len() as u32).to_be_bytes());
        b.extend(text.as_bytes());
    }
    for i in 0..1000u32 {
        b.extend([0u8, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 1]);
        b.extend((-239i32).to_be_bytes());
        b.extend([(i % 256) as u8, 0, 0, 0, 0x80]);
    }
    for i in 0..200u16 {
        b.extend([0u8, 0, 0, 1, 0, 0, 0, 0]);
        b.extend((10 + i % 2).to_be_bytes());
        b.extend(10u16.to_be_bytes());
        b.extend((-223i32).to_be_bytes());
    }
    for chunk in b.chunks(65536) {
        s.pipe.feed(chunk);
    }
    // The latest of each comes.
    wait_last(handle, event::CLIPBOARD, |_, d| d == b"text 999");
    wait_last(handle, event::CURSOR, |_, d| d.len() == 12 && d[8..] == [231, 0, 0, 255]);
    wait_last(handle, event::RESIZE, |a, _| a == (11 << 32) | 10);
    let ms = t.elapsed().as_millis() as usize;
    // At most one each interval (and the first at once).
    let (bells, clips, cursors, sizes) = (
        count_kind(handle, event::BELL),
        count_kind(handle, event::CLIPBOARD),
        count_kind(handle, event::CURSOR),
        count_kind(handle, event::RESIZE),
    );
    assert!(bells >= 1 && bells <= 2 + ms / 250, "{bells} bells in {ms} ms");
    assert!(clips <= 2 + ms / 100, "{clips} clipboards in {ms} ms");
    assert!(cursors <= 2 + ms / 50, "{cursors} cursors in {ms} ms");
    // ServerInit's size was one.
    assert!(sizes <= 3 + ms / 100, "{sizes} sizes in {ms} ms");
    close(handle);
}

#[test]
fn a_cursor_over_256_pixels_on_a_side_is_hidden_and_its_bytes_skipped() {
    // From a security review: a cursor up to 8192 x 1012 (33 MB) was copied for Dart, then into an
    // image there.
    let handle = open(r#"{"kind":"vnc"}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(8, 8));
    wait_for(handle, event::CONNECTED, 0);
    for (w, h) in [(257u16, 1u16), (1, 257), (4096, 1012)] {
        let before = seen().0.lock().unwrap().events[&handle].len();
        let mut b = vec![0u8, 0];
        b.extend(1u16.to_be_bytes());
        for v in [3u16, 4, w, h] {
            b.extend(v.to_be_bytes());
        }
        b.extend((-239i32).to_be_bytes());
        b.extend(vec![9u8; usize::from(w) * usize::from(h) * 4]);
        b.extend(vec![0xffu8; usize::from(w).div_ceil(8) * usize::from(h)]);
        b.push(2); // Bell: read in step after the shape
        for chunk in b.chunks(65536) {
            s.pipe.feed(chunk);
        }
        let (i, _, data) = wait_for(handle, event::CURSOR, before);
        // Hidden: a size of 0, the hot spot kept, no pixels.
        assert_eq!((&data[..8], data.len()), (&[0u8, 0, 0, 0, 3, 0, 4, 0][..], 8), "{w} x {h}");
        let (bell, _, _) = wait_for(handle, event::BELL, before);
        assert!(bell > i);
        // A bell after a bell waits its turn (the pacing).
        std::thread::sleep(Duration::from_millis(300));
    }
    // 256 x 256 is drawn.
    let before = seen().0.lock().unwrap().events[&handle].len();
    let mut b = vec![0u8, 0];
    b.extend(1u16.to_be_bytes());
    for v in [0u16, 0, 256, 256] {
        b.extend(v.to_be_bytes());
    }
    b.extend((-239i32).to_be_bytes());
    b.extend(vec![9u8; 256 * 256 * 4]);
    b.extend(vec![0xffu8; 32 * 256]);
    for chunk in b.chunks(65536) {
        s.pipe.feed(chunk);
    }
    let (_, _, data) = wait_for(handle, event::CURSOR, before);
    assert_eq!(&data[..4], &[0, 1, 0, 1]);
    assert_eq!(data.len(), 8 + 256 * 256 * 4);
    close(handle);
}

/// A packet's tiles and pixels, copied, and the packet freed.
fn unpack(packet: *mut FramePacket) -> ((u32, u32), Vec<FrameTile>, Vec<u8>) {
    // SAFETY: a packet just taken, read and freed once.
    let p = unsafe { &*packet };
    let tiles = unsafe { std::slice::from_raw_parts(p.tiles, p.tile_count as usize) }.to_vec();
    let pixels = unsafe { std::slice::from_raw_parts(p.pixels, p.pixels_len as usize) }.to_vec();
    let size = (p.width, p.height);
    unsafe { free_packet(packet) };
    (size, tiles, pixels)
}

/// A picture of [w] by [h] in tiles of 4 whose pixel at (x, y) is (x, y, 0).
fn numbered(w: u32, h: u32) -> Framebuffer {
    let mut f = Framebuffer::new(4);
    f.resize(w, h);
    let mut pixels = Vec::new();
    for y in 0..h {
        for x in 0..w {
            pixels.extend_from_slice(&[x as u8, y as u8, 0, 0]);
        }
    }
    f.put(0, 0, w, h, &pixels, 1);
    f
}

#[test]
fn a_view_gives_its_rectangle_of_the_picture_counted_from_its_own_corner() {
    // Two displays side by side, 8 by 4 each; the view is the second.
    let mut f = numbered(16, 4);
    let view = f.view_open(8, 0, 8, 4, 1).unwrap();
    assert_eq!(view, 1);
    let ((w, h), tiles, pixels) = unpack(f.view_take(view, 2).unwrap());
    assert_eq!((w, h), (8, 4), "the packet has the size of the view");
    // All of it at first, as one tile from the corner of the view.
    assert_eq!(tiles, vec![FrameTile { x: 0, y: 0, width: 8, height: 4, offset: 0 }]);
    assert_eq!(&pixels[..4], &[8, 0, 0, 255], "the first pixel of the view is (8, 0) of the picture");
    assert_eq!(&pixels[(3 * 8 + 7) * 4..][..4], &[15, 3, 0, 255]);
    // Taken: nothing more until something in it changes.
    assert!(f.view_take(view, 3).is_none());

    // A change in the first display is not the view's.
    f.fill(1, 1, 2, 2, [200, 0, 0, 0], 4);
    assert!(f.view_take(view, 5).is_none());
    // One across the line between them: only the tile of the view it touches, and only the
    // part of the change that is in the view.
    f.fill(6, 0, 4, 1, [99, 99, 99, 0], 6);
    let (_, tiles, pixels) = unpack(f.view_take(view, 7).unwrap());
    assert_eq!(tiles, vec![FrameTile { x: 0, y: 0, width: 4, height: 4, offset: 0 }]);
    assert_eq!(&pixels[..4], &[99, 99, 99, 255]);
    assert_eq!(&pixels[4..8], &[99, 99, 99, 255]);
    assert_eq!(&pixels[8..12], &[10, 0, 0, 255], "(10, 0) of the picture, untouched");
}

#[test]
fn the_reader_of_the_picture_and_each_view_take_their_changes_apart() {
    let mut f = numbered(16, 4);
    let left = f.view_open(0, 0, 8, 4, 1).unwrap();
    let right = f.view_open(8, 0, 8, 4, 1).unwrap();
    assert_eq!((left, right), (1, 2));
    // Each starts with all of its own.
    unpack(f.take(2).unwrap());
    unpack(f.view_take(left, 2).unwrap());
    unpack(f.view_take(right, 2).unwrap());
    f.fill(13, 2, 1, 1, [7, 7, 7, 0], 3);
    // The reader of the picture taking it leaves it there for the view, and the other way round.
    let (_, tiles, _) = unpack(f.take(4).unwrap());
    assert_eq!(tiles, vec![FrameTile { x: 12, y: 0, width: 4, height: 4, offset: 0 }]);
    assert!(f.view_take(left, 4).is_none());
    let (_, tiles, pixels) = unpack(f.view_take(right, 4).unwrap());
    assert_eq!(tiles, vec![FrameTile { x: 4, y: 0, width: 4, height: 4, offset: 0 }]);
    assert_eq!(&pixels[(2 * 4 + 1) * 4..][..4], &[7, 7, 7, 255]);
    assert!(f.take(5).is_none() && f.view_take(right, 5).is_none());
    // A copy inside the picture marks the views it lands in.
    f.copy(0, 0, 8, 0, 4, 4, 6);
    assert!(f.view_take(left, 7).is_some());
    assert!(f.view_take(right, 7).is_none());
}

#[test]
fn a_view_past_the_edge_of_the_picture_shows_what_is_inside_and_starts_again_when_the_size_changes() {
    let mut f = numbered(10, 4);
    // Asked for 8 wide from 6: 4 of it is picture.
    let view = f.view_open(6, 0, 8, 4, 1).unwrap();
    let ((w, h), _, pixels) = unpack(f.view_take(view, 2).unwrap());
    assert_eq!((w, h), (4, 4));
    assert_eq!(pixels.len(), 4 * 4 * 4);
    // A view that lies outside the picture altogether has nothing, and is still a view.
    let outside = f.view_open(40, 40, 8, 4, 1).unwrap();
    assert!(f.view_take(outside, 2).is_none());
    assert!(f.view_is_open(outside));

    // The picture grows (the server made the second display): all of the view now, from the
    // start, black until something is drawn.
    f.resize(16, 4);
    let ((w, h), tiles, pixels) = unpack(f.view_take(view, 3).unwrap());
    assert_eq!((w, h), (8, 4));
    assert_eq!(tiles.len(), 1);
    assert!(pixels.chunks_exact(4).all(|p| p == [0, 0, 0, 255]));
    // It shrinks to nothing of the view: nothing to take, no panic, and a draw is fine.
    f.resize(4, 4);
    assert!(f.view_take(view, 4).is_none());
    f.fill(0, 0, 4, 4, [1, 1, 1, 0], 5);
    assert!(f.view_take(view, 6).is_none());
}

#[test]
fn a_small_picture_of_a_view_is_the_mean_of_what_it_stands_for() {
    let mut f = Framebuffer::new(4);
    f.resize(8, 5);
    // The left half 100, the right half 200; the last row 50.
    f.fill(0, 0, 4, 4, [100, 0, 0, 0], 1);
    f.fill(4, 0, 4, 4, [200, 0, 0, 0], 1);
    f.fill(0, 4, 8, 1, [50, 0, 0, 0], 1);
    let view = f.view_open(0, 0, 8, 5, 4).unwrap();
    let ((w, h), tiles, pixels) = unpack(f.view_take(view, 2).unwrap());
    // 8 by 5 four times smaller: 2 by 1 (the row left over is not a pixel of its own).
    assert_eq!((w, h), (2, 1));
    assert_eq!(tiles, vec![FrameTile { x: 0, y: 0, width: 2, height: 1, offset: 0 }]);
    assert_eq!(pixels, vec![100, 0, 0, 255, 200, 0, 0, 255]);
    // A change anywhere in it gives the whole small picture again; none gives nothing.
    assert!(f.view_take(view, 3).is_none());
    f.fill(0, 0, 2, 2, [0, 0, 0, 0], 4);
    let (_, _, pixels) = unpack(f.view_take(view, 5).unwrap());
    // A quarter of the first block is black now: three quarters of 100.
    assert_eq!(&pixels[..4], &[75, 0, 0, 255]);
    // A view smaller than one block is one pixel.
    let tiny = f.view_open(0, 0, 3, 3, 16).unwrap();
    let ((w, h), _, pixels) = unpack(f.view_take(tiny, 6).unwrap());
    assert_eq!((w, h), (1, 1));
    assert_eq!(pixels.len(), 4);
}

#[test]
fn sixteen_views_at_most_and_the_place_of_a_closed_one_is_free_again() {
    let mut f = numbered(8, 4);
    let views: Vec<u32> = (0..MAX_VIEWS).map(|_| f.view_open(0, 0, 4, 4, 1).unwrap()).collect();
    assert_eq!(views, (1..=MAX_VIEWS as u32).collect::<Vec<_>>());
    assert_eq!(f.views_open(), MAX_VIEWS);
    assert!(f.view_open(0, 0, 4, 4, 1).is_none(), "a seventeenth");
    f.view_close(3);
    assert!(!f.view_is_open(3));
    assert!(f.view_take(3, 2).is_none());
    assert_eq!(f.view_open(4, 0, 4, 4, 1), Some(3), "the place that was let go");
    // Not views: nothing of that number, no size, no such divisor.
    f.view_close(0);
    f.view_close(99);
    assert!(f.view_take(0, 2).is_none() && f.view_take(99, 2).is_none());
    assert!(!f.view_is_open(0) && !f.view_is_open(99));
    f.view_close(1);
    assert!(f.view_open(0, 0, 0, 4, 1).is_none());
    assert!(f.view_open(0, 0, 4, 0, 1).is_none());
    assert!(f.view_open(0, 0, 4, 4, 0).is_none());
    assert!(f.view_open(0, 0, 4, 4, MAX_VIEW_DIVIDE + 1).is_none());
    assert_eq!(f.view_open(0, 0, 4, 4, MAX_VIEW_DIVIDE), Some(1));
    // Numbers no picture has: taken as a view that shows nothing, never a panic.
    f.view_close(2);
    assert_eq!(f.view_open(u32::MAX, u32::MAX, u32::MAX, u32::MAX, 1), Some(2));
    assert!(f.view_take(2, 3).is_none());
}

#[test]
fn a_view_is_read_through_the_calls_and_ends_with_its_session() {
    let handle = open(r#"{"kind":"vnc","tile_size":4}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(10, 6));
    wait_for(handle, event::CONNECTED, 0);
    s.pipe.feed(&raw_update(5, 4, 2, 2, [10, 20, 30, 0]));
    wait_for(handle, event::FRAME, 0);

    // The right half, as another window would open it.
    let view = crate::zest_screen_view_open(handle, 5, 0, 5, 6, 1);
    assert_eq!(view, 1);
    assert_eq!(crate::zest_screen_view_alive(handle, view), 1);
    let ((w, h), _, pixels) = unpack(crate::zest_screen_view_take_frame(handle, view));
    assert_eq!((w, h), (5, 6));
    // (5, 4) of the picture is (0, 4) of the view.
    assert_eq!(&pixels[4 * 5 * 4..][..4], &[10, 20, 30, 255]);
    assert!(crate::zest_screen_view_take_frame(handle, view).is_null());
    // The reader of the session still has its frame: a view takes nothing from it.
    let whole = crate::zest_screen_take_frame(handle);
    assert!(!whole.is_null());
    unsafe { free_packet(whole) };

    // Not views, not sessions.
    assert_eq!(crate::zest_screen_view_open(handle, 0, 0, 0, 0, 1), 0);
    assert_eq!(crate::zest_screen_view_open(handle + 12_345, 0, 0, 4, 4, 1), 0);
    assert_eq!(crate::zest_screen_view_alive(handle, 9), 0);
    assert!(crate::zest_screen_view_take_frame(handle, 9).is_null());
    crate::zest_screen_view_close(handle, 9);

    // The session ends: its views are gone with it, and the calls say so.
    drop(s);
    close(handle);
    assert_eq!(crate::zest_screen_view_alive(handle, view), 0);
    assert!(crate::zest_screen_view_take_frame(handle, view).is_null());
    crate::zest_screen_view_close(handle, view);
    assert_eq!(crate::zest_screen_view_open(handle, 0, 0, 4, 4, 1), 0);
}

#[test]
fn the_reader_of_the_picture_can_be_shown_one_part_of_it_and_all_of_it_again() {
    // Two displays side by side, 8 by 4 each, in tiles of 4.
    let mut f = numbered(16, 4);
    unpack(f.take(2).unwrap());

    // The second display: all of it first, counted from its own corner, the size its own.
    f.show(8, 0, 8, 4);
    let ((w, h), tiles, pixels) = unpack(f.take(3).unwrap());
    assert_eq!((w, h), (8, 4));
    assert_eq!(tiles, vec![FrameTile { x: 0, y: 0, width: 8, height: 4, offset: 0 }]);
    assert_eq!(&pixels[..4], &[8, 0, 0, 255]);
    assert!(f.take(4).is_none());

    // A change in it: its tile, from the corner of the part.
    f.fill(13, 1, 1, 1, [7, 7, 7, 0], 5);
    assert!(f.update_done(6), "its reader is told");
    let (_, tiles, pixels) = unpack(f.take(7).unwrap());
    assert_eq!(tiles, vec![FrameTile { x: 4, y: 0, width: 4, height: 4, offset: 0 }]);
    assert_eq!(&pixels[(4 + 1) * 4..][..4], &[7, 7, 7, 255]);

    // A change in the first display, which is not shown: nothing to take now. It waits.
    f.fill(1, 1, 1, 1, [9, 9, 9, 0], 8);
    f.update_done(9);
    assert!(f.take(10).is_none());
    // And a reader that found nothing is told again of the next change in its part.
    f.fill(9, 0, 1, 1, [3, 3, 3, 0], 11);
    assert!(f.update_done(12));
    assert!(f.take(13).is_some());

    // All of it again: everything, with what changed while it was not shown.
    f.show(0, 0, 0, 0);
    let ((w, h), tiles, pixels) = unpack(f.take(14).unwrap());
    assert_eq!((w, h), (16, 4));
    assert_eq!(tiles.len(), 1);
    assert_eq!(&pixels[(16 + 1) * 4..][..4], &[9, 9, 9, 255]);
    assert_eq!(&pixels[(16 + 13) * 4..][..4], &[7, 7, 7, 255]);
}

#[test]
fn a_shown_part_that_is_not_on_tile_lines_or_not_in_the_picture() {
    let mut f = numbered(16, 8);
    // From (2, 1), 9 by 5: it cuts tiles on every side.
    f.show(2, 1, 9, 5);
    let ((w, h), tiles, pixels) = unpack(f.take(2).unwrap());
    assert_eq!((w, h), (9, 5));
    assert_eq!(tiles, vec![FrameTile { x: 0, y: 0, width: 9, height: 5, offset: 0 }]);
    assert_eq!(pixels.len(), 9 * 5 * 4);
    assert_eq!(&pixels[..4], &[2, 1, 0, 255]);
    assert_eq!(&pixels[(4 * 9 + 8) * 4..][..4], &[10, 5, 0, 255]);
    // One pixel changed at the part's edge: the piece of its tile that is inside the part.
    f.fill(10, 5, 1, 1, [1, 1, 1, 0], 3);
    let (_, tiles, pixels) = unpack(f.take(4).unwrap());
    assert_eq!(tiles, vec![FrameTile { x: 6, y: 3, width: 3, height: 2, offset: 0 }]);
    assert_eq!(pixels.len(), 3 * 2 * 4);
    assert_eq!(&pixels[(3 + 2) * 4..][..4], &[1, 1, 1, 255]);

    // A part past the edge shows what is inside; one outside the picture is all of it.
    f.show(12, 4, 100, 100);
    let ((w, h), _, _) = unpack(f.take(5).unwrap());
    assert_eq!((w, h), (4, 4));
    f.show(40, 40, 8, 8);
    let ((w, h), _, _) = unpack(f.take(6).unwrap());
    assert_eq!((w, h), (16, 8));
    // The picture shrinks under a shown part: what is left of it, or all, never a panic.
    f.show(8, 0, 8, 8);
    f.resize(12, 8);
    let ((w, h), _, _) = unpack(f.take(7).unwrap());
    assert_eq!((w, h), (4, 8));
    f.resize(6, 8);
    let ((w, h), _, _) = unpack(f.take(8).unwrap());
    assert_eq!((w, h), (6, 8));
}

#[test]
fn showing_a_part_is_a_call_and_views_are_not_changed_by_it() {
    let handle = open(r#"{"kind":"vnc","tile_size":4}"#, callback).unwrap();
    let s = session(handle).unwrap();
    s.pipe.feed(&server_handshake(10, 6));
    wait_for(handle, event::CONNECTED, 0);
    s.pipe.feed(&raw_update(5, 4, 2, 2, [10, 20, 30, 0]));
    wait_for(handle, event::FRAME, 0);
    let view = crate::zest_screen_view_open(handle, 0, 0, 10, 6, 1);

    crate::zest_screen_show(handle, 5, 0, 5, 6);
    let ((w, h), _, pixels) = unpack(crate::zest_screen_take_frame(handle));
    assert_eq!((w, h), (5, 6));
    assert_eq!(&pixels[4 * 5 * 4..][..4], &[10, 20, 30, 255]);
    // The view still has the whole picture.
    let ((w, h), _, _) = unpack(crate::zest_screen_view_take_frame(handle, view));
    assert_eq!((w, h), (10, 6));
    crate::zest_screen_show(handle, 0, 0, 0, 0);
    let ((w, h), _, _) = unpack(crate::zest_screen_take_frame(handle));
    assert_eq!((w, h), (10, 6));
    // A session that is not there: nothing.
    crate::zest_screen_show(handle + 54_321, 0, 0, 4, 4);
    drop(s);
    close(handle);
}

//! What every fuzz target shares (each target includes this file as `mod harness`).
//!
//! - A crash is reported as libFuzzer expects on every platform: the panic is printed, then the C
//!   runtime's `abort` raises SIGABRT, which libFuzzer catches and saves the input for. (Rust's own
//!   abort on Windows is `__fastfail`, which no handler sees.)
//! - An allocation over [ALLOC_CAP] is a crash too: the engine's own caps (src/vnc/engine/limits.rs)
//!   keep every buffer a server can size well under it.
//! - The VNC engine runs over [ServerBytes], the fuzz input handed over in uneven pieces (as an
//!   SSH channel would), on a current-thread runtime whose clock is paused, so a timeout in the
//!   engine never makes a run wait.
//! - Pixels go into the app's own [Framebuffer] through a [DrawTarget] that checks what the engine
//!   hands it: every rectangle inside the screen and every picture exactly `w * h * 4` bytes.

#![allow(dead_code)]

pub mod ffi;
pub mod rdp;

use std::alloc::{GlobalAlloc, Layout, System};
use std::io::Write as _;
use std::pin::Pin;
use std::sync::{Arc, Mutex, Once};
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use zest_native::screen::{Framebuffer, free_packet};
use zest_native::vnc::engine::{
    ClientKeyEvent, ClientMouseEvent, ConnectOptions, Draw, DrawTarget, PixelFormat, Rect, VncEncoding, VncEvent,
    X11Event, connect, default_encodings,
};

/// The largest single allocation a run may make. The engine's largest legitimate buffers are a
/// picture of MAX_PIXELS (33.2 MB) and a compressed rectangle (MAX_COMPRESSED, 33.7 MB); a vector
/// grown to that size may have asked for up to twice as much on the way.
pub const ALLOC_CAP: usize = 80 << 20;

/// The cap in force: [ALLOC_CAP] unless a target sets its own ([set_alloc_cap]).
static CAP: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(ALLOC_CAP);

/// A target whose code has a documented larger budget (none today: IronRDP's ZGFX had 256 MiB a
/// message until the app's fork of it took the ceilings down).
pub fn set_alloc_cap(bytes: usize) {
    CAP.store(bytes, std::sync::atomic::Ordering::Relaxed);
}

unsafe extern "C" {
    /// The C runtime's abort (SIGABRT first, which libFuzzer handles).
    #[link_name = "abort"]
    fn c_abort() -> !;
}

fn die(message: &[u8]) -> ! {
    let mut e = std::io::stderr();
    let _ = e.write_all(message);
    let _ = e.flush();
    // SAFETY: ends the process.
    unsafe { c_abort() }
}

pub struct CappedAlloc;

#[inline]
fn check(size: usize) {
    if size > CAP.load(std::sync::atomic::Ordering::Relaxed) {
        oversized(size);
    }
}

#[cold]
fn oversized(size: usize) -> ! {
    // The allocator is re-entered for the message and the stack (both far under the cap).
    let trace = std::backtrace::Backtrace::force_capture();
    let cap = CAP.load(std::sync::atomic::Ordering::Relaxed);
    let _ = writeln!(std::io::stderr(), "\n==fuzz== oversized allocation: {size} bytes (cap {cap})\n{trace}");
    die(b"==fuzz== aborting\n");
}

// SAFETY: forwards to the system allocator, refusing only sizes over the cap.
unsafe impl GlobalAlloc for CappedAlloc {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        check(l.size());
        unsafe { System.alloc(l) }
    }
    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        check(l.size());
        unsafe { System.alloc_zeroed(l) }
    }
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) }
    }
    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        check(new);
        unsafe { System.realloc(p, l, new) }
    }
}

#[global_allocator]
static ALLOC: CappedAlloc = CappedAlloc;

/// Call first in every target: a panic anywhere (any thread) ends the run as a crash libFuzzer
/// records. (The app's library catches a panic in a session's thread since 4.0's RDP; a fuzz build
/// is built to abort, so nothing is caught here and every panic is found.)
pub fn init() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            let trace = std::backtrace::Backtrace::force_capture();
            let _ = writeln!(std::io::stderr(), "\n==fuzz== panic: {info}\n{trace}");
            die(b"==fuzz== aborting\n");
        }));
    });
}

/// A small generator for the sizes of the pieces (deterministic for one input).
pub struct Pieces(u64);

impl Pieces {
    pub fn new(seed: u64) -> Self {
        Self(seed | 1)
    }
    pub fn next(&mut self) -> usize {
        // xorshift64
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        match self.0 % 8 {
            0 => 1,
            1 => 2,
            2 => 3,
            3 => 7,
            4 => 64,
            5 => 1000,
            _ => usize::MAX,
        }
    }
}

/// The server's side: [data] in uneven pieces, then the end of the stream. What the engine
/// writes is counted and dropped.
pub struct ServerBytes {
    data: Vec<u8>,
    at: usize,
    pieces: Pieces,
    pub written: usize,
}

impl ServerBytes {
    pub fn new(data: Vec<u8>) -> Self {
        let seed = data.iter().fold(data.len() as u64, |h, b| h.wrapping_mul(31).wrapping_add(u64::from(*b)));
        Self { data, at: 0, pieces: Pieces::new(seed), written: 0 }
    }
}

impl AsyncRead for ServerBytes {
    fn poll_read(mut self: Pin<&mut Self>, _: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let left = self.data.len() - self.at;
        if left == 0 {
            return Poll::Ready(Ok(()));
        }
        let n = self.pieces.next().min(left).min(buf.remaining());
        let at = self.at;
        buf.put_slice(&self.data[at..at + n]);
        self.at += n;
        Poll::Ready(Ok(()))
    }
}

impl AsyncWrite for ServerBytes {
    fn poll_write(mut self: Pin<&mut Self>, _: &mut Context<'_>, b: &[u8]) -> Poll<std::io::Result<usize>> {
        self.written = self.written.saturating_add(b.len());
        Poll::Ready(Ok(b.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// The app's framebuffer behind the engine's draw interface, checking what it is handed.
pub struct CheckedDraw {
    frame: Mutex<Framebuffer>,
    screen: Mutex<(u16, u16)>,
}

impl CheckedDraw {
    pub fn new(tile: u32) -> Arc<Self> {
        Arc::new(Self { frame: Mutex::new(Framebuffer::new(tile)), screen: Mutex::new((0, 0)) })
    }

    fn inside(&self, what: &str, r: &Rect) {
        let (w, h) = *self.screen.lock().unwrap();
        let right = u32::from(r.x) + u32::from(r.width);
        let bottom = u32::from(r.y) + u32::from(r.height);
        assert!(
            right <= u32::from(w) && bottom <= u32::from(h),
            "{what} {r:?} outside the {w} x {h} screen"
        );
    }

    /// The end of an update: the frame is packed as the app takes it.
    pub fn update_done(&self) {
        let mut f = self.frame.lock().unwrap();
        if f.update_done(1) {
            if let Some(p) = f.take(2) {
                // SAFETY: a packet just taken, freed once.
                unsafe { free_packet(p) };
            }
        }
    }
}

impl DrawTarget for CheckedDraw {
    fn resize(&self, width: u16, height: u16) {
        *self.screen.lock().unwrap() = (width, height);
        self.frame.lock().unwrap().resize(width.into(), height.into());
    }
    fn fill(&self, r: &Rect, pixel: [u8; 4]) {
        self.inside("fill", r);
        self.frame.lock().unwrap().fill(r.x.into(), r.y.into(), r.width.into(), r.height.into(), pixel, 1);
    }
    fn put(&self, r: &Rect, pixels: &[u8]) {
        self.inside("put", r);
        assert_eq!(
            pixels.len(),
            usize::from(r.width) * usize::from(r.height) * 4,
            "put {r:?} with {} bytes",
            pixels.len()
        );
        self.frame.lock().unwrap().put(r.x.into(), r.y.into(), r.width.into(), r.height.into(), pixels, 1);
    }
    fn copy(&self, dst: &Rect, src: &Rect) {
        self.inside("copy to", dst);
        self.inside("copy from", src);
        assert_eq!((dst.width, dst.height), (src.width, src.height), "copy of unequal rectangles");
        self.frame.lock().unwrap().copy(
            dst.x.into(),
            dst.y.into(),
            src.x.into(),
            src.y.into(),
            dst.width.into(),
            dst.height.into(),
            1,
        );
    }
}

/// The options the app's session builds (src/screen/vnc_session.rs), from bits of [flags].
pub fn options(flags: u8, draw: &Arc<CheckedDraw>) -> ConnectOptions {
    ConnectOptions {
        password: (flags & 1 != 0).then(|| "secret".into()),
        username: (flags & 2 != 0).then(|| "alex".to_string()),
        require_tls: flags & 4 != 0,
        tls_pin: (flags & 8 != 0).then_some([7u8; 32]),
        continuous_updates: flags & 16 == 0,
        shared: flags & 32 == 0,
        encodings: every_encoding(),
        draw: Some(Draw(draw.clone())),
        ..Default::default()
    }
}

/// The app's defaults, with TRLE (which a person may ask for) added.
pub fn every_encoding() -> Vec<VncEncoding> {
    let mut e = default_encodings();
    e.push(VncEncoding::Trle);
    e.push(VncEncoding::Raw);
    e
}

/// Input the app may send meanwhile, chosen by [flags] (none for 0).
pub fn inputs(flags: u8) -> Vec<X11Event> {
    let mut v = Vec::new();
    if flags & 1 != 0 {
        v.push(X11Event::PointerEvent(ClientMouseEvent { position_x: 9, position_y: 7, bottons: 1 }));
    }
    if flags & 2 != 0 {
        v.push(X11Event::KeyEvent(ClientKeyEvent { keycode: 0x61, down: true }));
        v.push(X11Event::ScancodeKey { keysym: 0x61, scancode: 0x1e, down: false });
    }
    if flags & 4 != 0 {
        v.push(X11Event::CopyText("copied \u{e9}".into()));
    }
    if flags & 8 != 0 {
        v.push(X11Event::Pause);
    }
    if flags & 16 != 0 {
        v.push(X11Event::Resume);
    }
    if flags & 32 != 0 {
        v.push(X11Event::FullRefresh);
    }
    v
}

/// Events read before a run counts as a hang (each is at least one byte of input).
const MAX_EVENTS: usize = 1 << 22;

/// Connects over [server] and reads every event until the engine stops, sending [input] once
/// connected. Returns whether the handshake finished.
pub fn run_vnc(server: Vec<u8>, options: ConnectOptions, draw: &Arc<CheckedDraw>, input: Vec<X11Event>) -> bool {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .start_paused(true)
        .build()
        .unwrap();
    runtime.block_on(async {
        let Ok((client, info)) = connect(ServerBytes::new(server), options).await else { return false };
        assert!(info.width > 0 && info.height > 0, "connected with an empty screen");
        let mut input = input.into_iter();
        let mut events = 0usize;
        loop {
            if let Some(e) = input.next() {
                if client.input(e).await.is_err() {
                    break;
                }
            }
            match client.recv_event().await {
                Ok(VncEvent::UpdateDone) => draw.update_done(),
                Ok(_) => {}
                Err(_) => break,
            }
            events += 1;
            assert!(events < MAX_EVENTS, "the engine never stopped");
        }
        let _ = client.close().await;
        true
    })
}

/// A complete handshake up to the server's messages: RFB 3.8, security None, ServerInit with
/// [width] x [height] and the client's own pixel format.
pub fn handshake(width: u16, height: u16) -> Vec<u8> {
    let mut b = b"RFB 003.008\n".to_vec();
    b.extend([1u8, 1]);
    b.extend(0u32.to_be_bytes());
    b.extend(width.to_be_bytes());
    b.extend(height.to_be_bytes());
    b.extend(Vec::<u8>::from(PixelFormat::rgba()));
    b.extend(4u32.to_be_bytes());
    b.extend(b"fuzz");
    b
}

/// A FramebufferUpdate's header with one rectangle's header.
pub fn one_rect(x: u16, y: u16, w: u16, h: u16, encoding: i32) -> Vec<u8> {
    let mut b = vec![0u8, 0];
    b.extend(1u16.to_be_bytes());
    for v in [x, y, w, h] {
        b.extend(v.to_be_bytes());
    }
    b.extend(encoding.to_be_bytes());
    b
}

/// One rectangle of [encoding] on a 256 x 256 screen, its place and size from the first four
/// bytes, then the rest of the input as its payload (and whatever messages follow it).
pub fn rect_target(encoding: VncEncoding, data: &[u8]) {
    init();
    if data.len() < 5 {
        return;
    }
    let x = u16::from(data[0] % 64);
    let y = u16::from(data[1] % 64);
    let w = 1 + u16::from(data[2] % 192);
    let h = 1 + u16::from(data[3] % 192);
    let flags = data[4];
    let mut server = handshake(256, 256);
    server.extend(one_rect(x, y, w, h, encoding.wire()));
    server.extend_from_slice(&data[5..]);
    let draw = CheckedDraw::new(if flags & 64 != 0 { 0 } else { 64 });
    let options = options(flags & 0b0011_0000, &draw);
    run_vnc(server, options, &draw, inputs(flags & 0x0f));
}

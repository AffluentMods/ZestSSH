//! Remote screens (4.0, with feature "vnc" or "rdp"): one session per remote screen, each on a
//! thread of its own with a small tokio runtime, fed by Dart through a byte pipe.
//!
//! The protocol engines (our RFB engine today, IronRDP next) run over any
//! `AsyncRead + AsyncWrite` stream. Here that stream is [DartStream]: Dart pushes the bytes it
//! reads from its SSH channel in with `zest_screen_feed`, and the bytes the engine writes go out
//! to Dart through one C callback (a `NativeCallable.listener` on the Dart side), which writes
//! them to the channel. No local port is opened, so no other program on the device can reach the
//! remote screen through us.
//!
//! The picture lives here ([Framebuffer], RGBA, opaque): the engine's rectangles are drawn into
//! it, the tiles they touch are marked dirty, and at the end of each server update Dart is told
//! once (FRAME) until it takes the dirty tiles with `zest_screen_take_frame` (one packed buffer,
//! so each tile's pixels are one contiguous run Dart can hand to `ui.ImageDescriptor.raw`).
//! Updates that come while Dart is busy are merged, so a slow UI drops frames, never data.
//!
//! What is generic (the pipe, the callback, the framebuffer, the C interface) serves both
//! protocols: [vnc_session] (our RFB engine) and [rdp_session] (IronRDP) are the only parts that
//! know one.

mod framebuffer;
#[cfg(all(feature = "rdp", windows))]
mod h264_mf;
mod pipe;
#[cfg(feature = "rdp")]
mod rdp_channels;
#[cfg(feature = "rdp")]
mod rdp_clipboard;
#[cfg(feature = "rdp")]
mod rdp_gateway;
#[cfg(feature = "rdp")]
mod rdp_graphics;
#[cfg(feature = "rdp")]
mod rdp_layout;
#[cfg(feature = "rdp")]
mod rdp_session;
#[cfg(feature = "sound")]
mod rdp_sound;
#[cfg(feature = "vnc")]
mod vnc_session;

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub use framebuffer::{FramePacket, FrameTile, Framebuffer, MAX_VIEWS, MAX_VIEW_DIVIDE, free_packet};
pub use pipe::{DartStream, Mailbox, Pipe, TransportEnd};
#[cfg(feature = "rdp")]
pub use rdp_layout::DisplaySpec;

/// One display as the app asks for it. Without RDP built in nothing reads it: a VNC server
/// has the displays it has.
#[cfg(not(feature = "rdp"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Deserialize)]
pub struct DisplaySpec {
    #[serde(default)]
    pub x: i32,
    #[serde(default)]
    pub y: i32,
    pub width: u32,
    pub height: u32,
    #[serde(default)]
    pub scale: u32,
    #[serde(default)]
    pub primary: bool,
}

/// For the fuzz targets only (packages/zest_native/rust/fuzz builds with `--cfg fuzzing`; the
/// app's builds never set it): the RDP parsers of ours they reach directly.
#[cfg(all(fuzzing, feature = "rdp"))]
pub mod fuzzing {
    pub use super::rdp_clipboard::Clipboard;
    pub use super::rdp_gateway::{
        Frame as GatewayFrame, challenge_of as gateway_challenge, packet as gateway_packet, parse_frame as gateway_frame,
        parse_head as gateway_head, pick_scheme as gateway_scheme, through as gateway_through,
    };
    pub use super::rdp_gateway::{
        read_channel_response, read_data, read_handshake_response, read_tunnel_auth_response, read_tunnel_response,
    };
    pub use super::rdp_graphics::{Gfx, H264Mode, Stats, count_fastpath};
    #[cfg(feature = "sound")]
    pub use super::rdp_sound::{Shared as SoundShared, Sink as SoundSink, SoundQueue};
}

/// What Rust tells Dart, through the callback's `kind`.
pub mod event {
    /// Bytes for the remote side: `data`/`len` (free with `zest_screen_free_bytes`).
    pub const SEND: u32 = 1;
    /// Connected: `data` is JSON (the session's facts).
    pub const CONNECTED: u32 = 2;
    /// New pixels: take them with `zest_screen_take_frame`. `a` is the frame number.
    pub const FRAME: u32 = 3;
    /// The session ended: `data` is JSON, `{"reason": "<CloseReason>", "message": "..."}` (with
    /// `"error"`, the same text, unless the app closed it; for a certificate not trusted also
    /// `"sha256"` (hex), `"der"` (base64), `"subject"` and `"not_before"`/`"not_after"` (seconds
    /// since 1970, or null)). Nothing follows.
    pub const CLOSED: u32 = 4;
    /// The bytes fed but not read yet fell under the low mark: `a` is how many. Dart resumes
    /// reading its channel (it paused when `zest_screen_feed` returned more than the high mark).
    pub const DRAINED: u32 = 5;
    /// The remote clipboard: `data` is the text, UTF-8.
    pub const CLIPBOARD: u32 = 6;
    /// The remote bell.
    pub const BELL: u32 = 7;
    /// The remote screen's size changed: `a` is width << 32 | height.
    pub const RESIZE: u32 = 8;
    /// Something about the session changed, for the app's log: `data` is JSON (for example
    /// `{"continuous_updates": true}`, `{"paused": true, "how": "suppress_output"}`; RDP:
    /// `{"clipboard_too_long": 1}`, and `{"resize_unavailable": true}` once where the server has
    /// no channel to ask for another screen size on).
    pub const INFO: u32 = 9;
    /// The remote cursor's shape (VNC's Cursor pseudo-encoding, RDP's pointer updates: the server
    /// leaves the cursor out of the picture and the app draws it): `data` is 8 bytes, the width,
    /// height, hot spot x and hot spot y as little-endian u16, then `width * height * 4` bytes of
    /// RGBA (VNC: alpha 0 or 255; RDP: any alpha, the colours already multiplied by it). A width
    /// or height of 0 hides the cursor; with `a` 1 (RDP only) it means the system's own pointer
    /// instead: the server has no shape of its own just now.
    pub const CURSOR: u32 = 10;
    /// The remote's displays, when they are first known and whenever they change (RDP; 4.0):
    /// `data` is JSON, `{"displays": [[x, y, width, height], ...]}`, each a rectangle of
    /// the picture in its pixels, in the order they were asked for. One rectangle, the whole
    /// picture, where the server gave another desktop than the one asked for. It follows the
    /// RESIZE of the same change.
    pub const DISPLAYS: u32 = 11;
}

/// Why a session ended, in [event::CLOSED]'s `reason`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CloseReason {
    /// The app closed it.
    Local,
    /// The remote screen's server ended it, or closed the connection (the SSH channel's end
    /// came with no error): a log off, the server stopping, another viewer taking over.
    ServerClosed,
    /// The SSH connection or channel failed or closed (its reason in the message).
    Ssh,
    /// The network failed under the SSH connection (a socket error, a time out).
    Network,
    /// The server refused the credentials.
    Auth,
    /// The server's TLS certificate is not the trusted one (its SHA-256 in `sha256`).
    Certificate,
    /// TLS failed otherwise.
    Tls,
    /// The server said something the engine cannot take, or offers nothing it can use.
    Protocol,
    /// Ours: a bug, or something the device refused.
    Internal,
}

/// How a session ended: the reason, a sentence for people, and for [CloseReason::Certificate]
/// the certificate shown.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Closed {
    pub reason: CloseReason,
    pub message: String,
    pub certificate: Option<CertificateFacts>,
    /// What exactly, where the app says something of its own for it (`"detail"` in the JSON):
    /// for RDP, `nla_missing` (the server has no Network Level Authentication and the host asks
    /// for it) and `nla_required` (the server insists on it and the host says without); why a
    /// sign-in was refused where the server said (`account_locked`, `account_disabled`,
    /// `password_expired`, `account_restricted`); and why the server ended a session (`idle`,
    /// `replaced`, `signed_out` and the rest of rdp_session.rs's SERVER_ENDINGS).
    pub detail: Option<&'static str>,
}

/// A server's TLS certificate the session refused (not the pinned one, or nothing was pinned),
/// with what the app's question shows: its fingerprint, subject and validity. The certificate
/// itself goes along, so the app keeps exactly what the person accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CertificateFacts {
    /// SHA-256 of [der], lower-case hex.
    pub sha256: String,
    pub der: Vec<u8>,
    /// The subject as RFC 4514 writes it ("CN=host,O=Example"); empty when the certificate does
    /// not parse (the fingerprint still identifies it).
    pub subject: String,
    /// Valid from and until, seconds since 1970 (UTC); None when the certificate does not parse.
    pub not_before: Option<i64>,
    pub not_after: Option<i64>,
}

impl CertificateFacts {
    /// Reads what the question needs from [der]; a certificate that does not parse still gives
    /// its fingerprint (the TLS library took it, so the person may still be asked).
    ///
    /// Only a certificate already refused is parsed here (none was pinned, or another one): the
    /// pinned one is matched by its SHA-256 alone and never reaches x509-cert, and nothing is
    /// sent before this. A panic in x509-cert would still end the app (panic = "abort", so
    /// catch_unwind cannot help); the fuzz target `certificate` runs this function (from a
    /// security review).
    pub fn of(der: &[u8]) -> Self {
        use sha2::{Digest as _, Sha256};
        use x509_cert::der::Decode as _;
        let sha256 = hex(&Sha256::digest(der));
        let parsed = x509_cert::Certificate::from_der(der).ok();
        let seconds = |t: x509_cert::time::Time| i64::try_from(t.to_unix_duration().as_secs()).ok();
        let (subject, not_before, not_after) = match &parsed {
            Some(c) => {
                let tbs = c.tbs_certificate();
                let v = tbs.validity();
                (tbs.subject().to_string(), seconds(v.not_before), seconds(v.not_after))
            }
            None => (String::new(), None, None),
        };
        Self { sha256, der: der.to_vec(), subject, not_before, not_after }
    }
}

impl Closed {
    pub fn new(reason: CloseReason, message: impl Into<String>) -> Self {
        Self { reason, message: message.into(), certificate: None, detail: None }
    }

    /// [self] with what exactly it was ([Closed::detail]).
    pub fn with_detail(mut self, detail: &'static str) -> Self {
        self.detail = Some(detail);
        self
    }

    pub fn local() -> Self {
        Self::new(CloseReason::Local, "closed")
    }

    /// The certificate [der] is not the trusted one: "certificate not trusted: SHA-256 <hex>",
    /// with the certificate's facts for the app's question.
    pub fn certificate(der: &[u8]) -> Self {
        let facts = CertificateFacts::of(der);
        Self {
            reason: CloseReason::Certificate,
            message: format!("certificate not trusted: SHA-256 {}", facts.sha256),
            certificate: Some(facts),
            detail: None,
        }
    }

    /// When the stream under the session had ended, that is the reason (an engine error then
    /// is only what the end looked like from inside, such as "end of file"); otherwise [self].
    pub fn or_transport(self, pipe: &Pipe) -> Self {
        match pipe.transport_end() {
            Some(TransportEnd::Eof) => Self::new(CloseReason::ServerClosed, "the server closed the connection"),
            Some(TransportEnd::Failed { reason, message }) => Self::new(reason, message),
            None => self,
        }
    }

    pub fn json(&self) -> serde_json::Value {
        let mut v = serde_json::json!({ "reason": self.reason, "message": self.message });
        if self.reason != CloseReason::Local {
            v["error"] = serde_json::Value::String(self.message.clone());
        }
        if let Some(detail) = self.detail {
            v["detail"] = detail.into();
        }
        if let Some(c) = &self.certificate {
            use base64::Engine as _;
            v["sha256"] = c.sha256.clone().into();
            v["der"] = base64::engine::general_purpose::STANDARD.encode(&c.der).into();
            v["subject"] = c.subject.clone().into();
            v["not_before"] = c.not_before.into();
            v["not_after"] = c.not_after.into();
        }
        v
    }
}

/// Bytes fed and not read yet above which Dart should pause its channel (the SSH window then
/// holds the server back), and under which it may resume.
pub const FEED_HIGH_MARK: usize = 4 << 20;
pub const FEED_LOW_MARK: usize = 1 << 20;

/// The callback into Dart: (session, kind, a, data, len). `data` (when not null) is the
/// library's, freed by Dart with `zest_screen_free_bytes(data, len)` once read.
pub type Callback = extern "C" fn(u64, u32, i64, *mut u8, usize);

/// Calls Dart from any thread of the session.
#[derive(Clone, Copy)]
pub struct Notifier {
    pub handle: u64,
    pub callback: Callback,
}

impl Notifier {
    pub fn signal(&self, kind: u32, a: i64) {
        (self.callback)(self.handle, kind, a, std::ptr::null_mut(), 0);
    }

    /// Hands [bytes] to Dart, which frees them.
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
#[derive(Debug, Clone)]
pub enum Command {
    /// The pointer at (x, y) in remote pixels with these buttons down (bit 0 left, 1 middle, 2
    /// right, 3 and 4 the wheel up and down).
    Pointer { x: u16, y: u16, buttons: u8 },
    /// The mouse moved by (dx, dy), with these buttons down (as [Command::Pointer]'s): for a
    /// remote that is told movement, not places (RDP's relative pointer event, where the
    /// session asked for it and the server takes it; 4.0). Nothing otherwise.
    PointerRelative { dx: i32, dy: i32, buttons: u8 },
    /// A key: its X keysym, and its XT scancode when known (0 when not).
    Key { keysym: u32, scancode: u32, down: bool },
    /// Text for the remote clipboard.
    Clipboard(String),
    /// The clipboard is shared with the remote from now on, or no longer (RDP, where the session
    /// has the clipboard's channel: off wipes this device's text and takes nothing of the
    /// server's; VNC has nothing to do, the app drops what comes).
    ClipboardShare(bool),
    /// The remote's sound is played from now on, or not (RDP, where the session has the sound
    /// channel: muted, the app locked, recording mode, a phone's app in the background; off
    /// empties what waits). Nothing otherwise.
    Sound(bool),
    /// Ask for the whole screen again.
    FullRefresh,
    /// The view's size in remote pixels: the server is asked to resize the desktop to it where
    /// it allows (RDP's display control channel; VNC ignores it for now).
    Resize { width: u32, height: u32 },
    /// The displays the remote should have from now on (RDP's display control channel; VNC
    /// ignores it: its server has the displays it has).
    Layout(Vec<DisplaySpec>),
    /// The app is hidden: the server stops sending (VNC: no requests, continuous updates off;
    /// RDP: Suppress Output). Input still goes.
    Pause,
    /// Back: updates again, starting with the whole screen.
    Resume,
    /// End the session.
    Close,
}

/// One remote screen.
pub struct Session {
    pub pipe: Arc<Pipe>,
    pub frame: Arc<Mutex<Framebuffer>>,
    pub commands: Arc<Mailbox<Command>>,
    /// Set by [close] from the caller's thread: the engine stops at its next piece of work (the
    /// VNC decoder looks at it before each message, rectangle, RRE subrectangle and Hextile
    /// tile), whatever its thread is busy with.
    pub stop: Arc<AtomicBool>,
    thread: Mutex<Option<JoinHandle<()>>>,
    /// Disconnected once the session's thread has run to its end (CLOSED sent).
    done: Mutex<Option<Receiver<()>>>,
}

impl Session {
    /// The app closed the session.
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }
}

/// How long [close] waits for the session's thread before it lets it finish on its own. The
/// caller is Dart's UI isolate: a frame or two at most, never the server's pace (an idle
/// session ends in well under a millisecond; one in the middle of a hostile flood within one
/// rectangle or subrectangle).
pub const CLOSE_WAIT: Duration = Duration::from_millis(20);

fn sessions() -> &'static Mutex<HashMap<u64, Arc<Session>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, Arc<Session>>>> = OnceLock::new();
    SESSIONS.get_or_init(Default::default)
}

pub fn session(handle: u64) -> Option<Arc<Session>> {
    sessions().held().get(&handle).cloned()
}

/// Microseconds on one clock for the whole process (from the first call), for measurements
/// both sides compare: Rust stamps frames with it, Dart reads it when it paints.
pub fn now_us() -> i64 {
    static EPOCH: OnceLock<Instant> = OnceLock::new();
    let epoch = *EPOCH.get_or_init(Instant::now);
    i64::try_from(epoch.elapsed().as_micros()).unwrap_or(i64::MAX)
}

/// The session's settings (JSON from Dart).
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct OpenRequest {
    /// "vnc" or "rdp".
    pub kind: String,
    #[serde(default)]
    pub username: Option<String>,
    /// Wiped from memory when it goes (the VNC engine lets it go after the handshake); printed
    /// as `<redacted>`.
    #[serde(default)]
    pub password: Option<crate::secret::Secret>,
    /// The TLS certificate's SHA-256 (hex) the person accepted (VeNCrypt, RDP).
    #[serde(default)]
    pub tls_pin: Option<String>,
    #[serde(default)]
    pub require_tls: bool,
    /// VNC: leave other viewers connected (true when not given); false asks the server to
    /// disconnect them.
    #[serde(default)]
    pub shared: Option<bool>,
    /// Encodings by name, in order (the engine's defaults when not given).
    #[serde(default)]
    pub encodings: Option<Vec<String>>,
    /// Tiles' side in pixels (0: the whole screen as one image).
    #[serde(default = "default_tile")]
    pub tile_size: u32,
    /// RDP: the desktop size asked for at connect (the view's size).
    #[serde(default)]
    pub width: Option<u16>,
    #[serde(default)]
    pub height: Option<u16>,
    /// RDP: the remote's displays (4.0), each with its place among the others. Not
    /// given, or one: a single screen (of [width] by [height] when not given). At most four,
    /// none over another, each touching another, sizes as a server takes them (200 to 8192 a
    /// side, the width even); anything else ends the session before it starts.
    #[serde(default)]
    pub displays: Option<Vec<DisplaySpec>>,
    /// RDP: the desktop scale factor in percent for a single screen (100 to 500; 0 or not
    /// given: none said, the server's own). Several displays carry their own.
    #[serde(default)]
    pub scale: Option<u32>,
    /// RDP: ask the server for relative mouse movement (4.0: a host whose person turned
    /// "Relative mouse" on). The connection then says the client version from which servers
    /// honour it; CONNECTED's `relative_mouse` says whether this server takes it. Not given, or
    /// false: the connection is the one it was, and [Command::PointerRelative] sends nothing.
    #[serde(default)]
    pub rdp_relative_mouse: Option<bool>,
    /// RDP: the Windows domain (NLA).
    #[serde(default)]
    pub domain: Option<String>,
    /// RDP: the name TLS (SNI) and CredSSP use: the host the SSH channel goes to.
    #[serde(default)]
    pub server_name: Option<String>,
    /// VNC: use continuous updates when the server has them (true when not given); false asks
    /// for each update (the fallback, for measurements).
    #[serde(default)]
    pub continuous_updates: Option<bool>,
    /// RDP: what the client offers for the picture: "gfx" (the default: the graphics pipeline,
    /// and RemoteFX surface commands for a server without it), "remotefx" (surface commands
    /// only) or "bitmap" (no codec; bitmap updates).
    #[serde(default)]
    pub rdp_graphics: Option<String>,
    /// RDP, graphics pipeline: H.264 through the platform's decoder (Windows: Media Foundation).
    /// "avc444" (the default: AVC420 and AVC444, the pipeline converting the decoder's YUV
    /// planes), "avc420" (AVC420 only, converted by us) or "off" (RemoteFX Progressive and the
    /// rest). Without a decoder (another platform, or Windows without Media Foundation) AVC is
    /// not offered, whatever this says.
    #[serde(default)]
    pub rdp_h264: Option<String>,
    /// RDP: false is the host's "Sign in without NLA" (TLS alone is asked for and no password
    /// is sent); true, or not given, asks for Network Level Authentication and nothing less.
    #[serde(default)]
    pub rdp_nla: Option<bool>,
    /// RDP: the clipboard's channel. "on": the session has it and the clipboard is shared from
    /// the start; "off": it has it, shared once the app says so (`zest_screen_clipboard_share`);
    /// "none", or not given: the session has no clipboard channel at all, so the server has
    /// nothing to send on or ask through (a host whose clipboard is locked off).
    #[serde(default)]
    pub rdp_clipboard: Option<String>,
    /// RDP: the remote's sound (4.0). "on": the server is told this device plays sound
    /// and the session has the sound channel, playing from the start; "off": the same, silent
    /// until the app says so (`zest_screen_sound`); "none", or not given: the server is told
    /// there is no sound here, so it sends none. A build without the `sound` feature, or a
    /// device without an output, connects without it; the connected message's `sound` says
    /// which (`{"rate", "channels"}` or `{"unavailable": why}`).
    #[serde(default)]
    pub rdp_sound: Option<String>,
    /// RDP: reached through an RD Gateway (4.0): the pipe is then the TCP connection to
    /// the gateway, and the session's own connection (its TLS to the PC, [tls_pin], NLA) runs
    /// inside the gateway's channel to [GatewayRequest::target]. Not given: the pipe goes to the
    /// PC itself.
    #[serde(default)]
    pub rdp_gateway: Option<GatewayRequest>,
    /// For the fuzz targets only (`--cfg fuzzing`; no build of the app has this field): RDP
    /// takes the channel as if TLS had come up on it, so a target's bytes reach the sign-in and
    /// the session.
    #[cfg(fuzzing)]
    #[serde(default)]
    pub fuzz_as_if_tls: bool,
}

/// The RD Gateway a session goes through (4.0; src/screen/rdp_gateway.rs).
#[derive(Debug, Clone, Default, serde::Deserialize)]
pub struct GatewayRequest {
    /// The gateway's name, as TLS checks its certificate and the HTTP request says it.
    pub host: String,
    /// The gateway's port, for the HTTP request's Host (443 when not given; the app connects).
    #[serde(default)]
    pub port: Option<u16>,
    /// The gateway's certificate's SHA-256 (hex) the person accepted, apart from the PC's.
    #[serde(default)]
    pub tls_pin: Option<String>,
    /// The gateway's sign-in (NTLM): the PC's own, or an account of its own, as the host says.
    #[serde(default)]
    pub username: Option<String>,
    /// Wiped from memory when it goes; printed as `<redacted>`.
    #[serde(default)]
    pub password: Option<crate::secret::Secret>,
    #[serde(default)]
    pub domain: Option<String>,
    /// The PC as the gateway is asked for it (the host's address).
    pub target: String,
    /// The PC's RDP port (3389 when not given).
    #[serde(default)]
    pub target_port: Option<u16>,
}

fn default_tile() -> u32 {
    256
}

/// A lock taken whatever happened to its last holder.
///
/// A panic in a session's engine ends that session and nothing else ([run_session]). The calls
/// Dart still makes for it afterwards (the frame, feed, close) come on other threads and take
/// the same locks: a lock whose holder panicked says so to the next taker, and a taker that
/// treated that as a bug of its own would panic inside a function Dart called, which ends the
/// app. What such a lock guards is only that one session's (a picture half drawn, a queue).
pub trait LockAnyway<T> {
    fn held(&self) -> std::sync::MutexGuard<'_, T>;
}

impl<T> LockAnyway<T> for Mutex<T> {
    fn held(&self) -> std::sync::MutexGuard<'_, T> {
        self.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

thread_local! {
    /// Where this thread last panicked (the hook of [note_panics] writes it).
    static PANICKED_AT: std::cell::RefCell<Option<String>> = const { std::cell::RefCell::new(None) };
}

/// A source file as a panic names it, from its crate's folder on: `sspi-0.23.0/src/credssp/mod.rs`
/// (not the whole path, which is the build machine's).
pub(crate) fn from_its_crate(file: &str) -> String {
    let file = file.replace('\\', "/");
    let after = |i: Option<usize>| i.map_or(0, |i| i + 1);
    let from = match file.rfind("/src/") {
        Some(src) => after(file[..src].rfind('/')),
        // This crate's own files are named from its folder already.
        None if file.starts_with("src/") => 0,
        None => after(file.rfind('/')),
    };
    file[from..].to_owned()
}

/// Keeps where a panic happened for the session's closing words. Whatever hook was there before
/// still runs.
fn note_panics() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let before = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            if let Some(l) = info.location() {
                let at = format!("{}:{}", from_its_crate(l.file()), l.line());
                PANICKED_AT.with(|p| *p.borrow_mut() = Some(at));
            }
            before(info);
        }));
    });
}

/// What a caught panic says.
fn panic_words(payload: &(dyn std::any::Any + Send)) -> String {
    let said = payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_owned())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "no message".to_owned());
    let at = PANICKED_AT.with(|p| p.borrow_mut().take()).unwrap_or_else(|| "an unknown place".to_owned());
    // One line, and not a server's megabyte.
    let said: String = said.chars().filter(|c| !c.is_control()).take(200).collect();
    format!("the session's engine stopped at {at}: {said}")
}

/// Runs one session's protocol on a current-thread runtime of its own and always ends with
/// CLOSED (see [Closed::json]).
///
/// A panic in the engine is caught here and closes this session with "internal": the engines
/// read what a server sends with code that is not all ours (IronRDP, sspi and the ASN.1 readers
/// under them for RDP), fuzzing finds inputs that make such code panic (two of them
/// in its first minutes), and until the library was built to unwind (Cargo.toml, the release
/// profile) each of them ended the whole app, with every other session and unsaved thing in it.
pub fn run_session<F, Fut>(notifier: Notifier, body: F)
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<(), Closed>>,
{
    note_panics();
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_io().enable_time().build() {
        Ok(r) => r,
        Err(e) => {
            notifier.json(event::CLOSED, Closed::new(CloseReason::Internal, format!("runtime: {e}")).json());
            return;
        }
    };
    // Unwind safe: what the engine shares with the rest (the session's picture, its queues) is
    // behind locks taken with [LockAnyway], and nothing else of it is looked at again.
    let ran = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| runtime.block_on(body())));
    let closed = match ran {
        Ok(Ok(())) => Closed::local(),
        Ok(Err(c)) => c,
        Err(payload) => Closed::new(CloseReason::Internal, panic_words(payload.as_ref())),
    };
    // The engine's tasks end with the runtime (a task that panics while it is dropped is caught
    // too: CLOSED must be said).
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(move || drop(runtime)));
    notifier.json(event::CLOSED, closed.json());
}

/// A SHA-256 in hex (colons allowed), as the person accepted it.
pub fn parse_sha256(hex: &str) -> Result<[u8; 32], String> {
    let clean: Vec<u8> = hex.bytes().filter(|c| *c != b':').collect();
    if clean.len() != 64 {
        return Err(format!("a SHA-256 has 64 hex digits, not {}", clean.len()));
    }
    if !clean.iter().all(u8::is_ascii_hexdigit) {
        return Err(format!("not hex: {hex}"));
    }
    let digit = |c: u8| (c as char).to_digit(16).unwrap_or(0) as u8;
    let mut out = [0u8; 32];
    for (i, b) in out.iter_mut().enumerate() {
        *b = digit(clean[2 * i]) << 4 | digit(clean[2 * i + 1]);
    }
    Ok(out)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Starts a session: its thread runs the engine over the pipe. Returns the handle (never 0) or
/// an error for a request that cannot start; anything later comes through the callback.
pub fn open(request_json: &str, callback: Callback) -> Result<u64, String> {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let request: OpenRequest = serde_json::from_str(request_json).map_err(|e| format!("request: {e}"))?;
    let handle = NEXT.fetch_add(1, Ordering::Relaxed);
    let notifier = Notifier { handle, callback };
    let session = Arc::new(Session {
        pipe: Arc::new(Pipe::new(notifier)),
        frame: Arc::new(Mutex::new(Framebuffer::new(request.tile_size))),
        commands: Arc::new(Mailbox::default()),
        stop: Arc::new(AtomicBool::new(false)),
        thread: Mutex::new(None),
        done: Mutex::new(None),
    });
    let run: Box<dyn FnOnce() + Send> = match request.kind.as_str() {
        #[cfg(feature = "vnc")]
        "vnc" => {
            let s = session.clone();
            Box::new(move || vnc_session::run(s, request, notifier))
        }
        #[cfg(feature = "rdp")]
        "rdp" => {
            let s = session.clone();
            Box::new(move || rdp_session::run(s, request, notifier))
        }
        other => return Err(format!("no screen engine {other:?} in this build")),
    };
    let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
    let thread = std::thread::Builder::new()
        .name(format!("zest-screen-{handle}"))
        .spawn(move || {
            run();
            // The receiver hears the end (CLOSED was the session's last callback).
            drop(done_tx);
        })
        .map_err(|e| format!("thread: {e}"))?;
    *session.thread.held() = Some(thread);
    *session.done.held() = Some(done_rx);
    sessions().held().insert(handle, session);
    Ok(handle)
}

/// Ends a session: the engine stops at its next piece of work, and its thread is joined when it
/// ends within [CLOSE_WAIT] (it nearly always does), else left to end by itself. Either way its
/// last callback is CLOSED, which may come after this returns: the caller keeps the callback
/// until CLOSED (Dart releases its `NativeCallable` then). Never blocks for longer than
/// [CLOSE_WAIT] (found in a security review: a server's flood once kept this waiting for minutes on
/// Dart's UI isolate).
pub fn close(handle: u64) {
    let Some(session) = sessions().held().remove(&handle) else { return };
    session.stop.store(true, Ordering::Release);
    session.commands.push(Command::Close);
    session.pipe.end();
    let thread = session.thread.held().take();
    let done = session.done.held().take();
    if let (Some(thread), Some(done)) = (thread, done) {
        match done.recv_timeout(CLOSE_WAIT) {
            // Still busy: it ends by itself (dropping the handle detaches it).
            Err(RecvTimeoutError::Timeout) => {}
            Ok(()) | Err(RecvTimeoutError::Disconnected) => {
                let _ = thread.join();
            }
        }
    }
}

#[cfg(all(test, feature = "vnc"))]
mod tests;

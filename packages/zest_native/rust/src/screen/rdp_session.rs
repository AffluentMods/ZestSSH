//! An RDP session on IronRDP, over the Dart pipe (the bytes of an SSH `direct-tcpip` channel to
//! the server's RDP port).
//!
//! TLS runs inside Rust on top of the pipe, through tokio-rustls with our own certificate check
//! ([crate::rdp::tls_upgrade], not ironrdp-tls, whose rustls config writes TLS secrets to the file
//! `SSLKEYLOGFILE` names):
//! the certificate is trusted only by the SHA-256 the person accepted; any other ends the session
//! with "certificate not trusted: SHA-256 <hex>", so the app can show it and connect again pinned
//! (trust on first use, as for VeNCrypt and FTPS). Then IronRDP's connector (NLA when the server
//! asks for it), and the active stage: each PDU is decoded into IronRDP's own picture, and the
//! regions it reports changed are copied into the session's [Framebuffer] (one update per PDU, so
//! Dart hears FRAME once until it takes the tiles). Input becomes fast-path events: the pointer
//! (moves, button changes, the wheel), keys by scancode (Unicode events for a character without
//! one). The desktop follows the view's size through the display control channel when the server
//! opens it; the server then resizes with a Deactivation-Reactivation Sequence. Pause sends the
//! Suppress Output PDU (the server stops drawing for us); resume allows updates again and asks
//! for the whole screen (Refresh Rect).
//!
//! The picture's codecs ([crate::rdp::Graphics], `rdp_graphics` in the request): by default the
//! graphics pipeline on the dynamic channel (RemoteFX Progressive, RemoteFX, planar, ClearCodec,
//! and H.264 on Windows through Media Foundation, `rdp_h264` in the request; [super::rdp_graphics],
//! [super::h264_mf]), drained per completed frame straight into the framebuffer, and RemoteFX
//! in fast-path surface commands for a server without the pipeline (decoded by IronRDP's session
//! into its picture, like bitmap updates). What the server sent is counted and reported as INFO
//! (`{"graphics": ...}`) when a new kind arrives, about once a second while it changes, and at the
//! end.

use crate::screen::LockAnyway as _;
use std::sync::Arc;

use ironrdp_connector::connection_activation::ConnectionActivationState;
use ironrdp_connector::{ClientConnector, ConnectorErrorKind};
use ironrdp_displaycontrol::client::DisplayControlClient;
use ironrdp_displaycontrol::pdu::MonitorLayoutEntry;
use ironrdp_dvc::DrdynvcClient;
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_pdu::WriteBuf;
use ironrdp_pdu::geometry::InclusiveRectangle;
use ironrdp_pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags, SynchronizeFlags};
use ironrdp_pdu::input::mouse::PointerFlags;
use ironrdp_pdu::input::mouse_rel::PointerRelFlags;
use ironrdp_pdu::input::{MousePdu, MouseRelPdu};
use ironrdp_pdu::rdp::headers::ShareDataPdu;
use ironrdp_pdu::rdp::refresh_rectangle::RefreshRectanglePdu;
use ironrdp_pdu::rdp::server_error_info::{ErrorInfo, ProtocolIndependentCode as Ending, ProtocolIndependentLicensingCode as Licensing};
use ironrdp_pdu::rdp::suppress_output::SuppressOutputPdu;
use ironrdp_session::image::DecodedImage;
use ironrdp_session::{ActiveStage, ActiveStageBuilder, ActiveStageOutput, GracefulDisconnectReason};
use ironrdp_tokio::{FramedWrite as _, ShouldUpgrade, TokioFramed, single_sequence_step_read};
use tokio::io::{AsyncRead, AsyncWrite};

use crate::rdp::{Secured, SignedIn, TlsFailure, tls_upgrade};

use super::rdp_channels::{ChannelGuard, Look};
use super::rdp_clipboard::Clipboard;
#[cfg(feature = "sound")]
use super::rdp_sound::{Sink as SoundSink, Speaker};
use super::rdp_graphics::{Gfx, GfxSlots, H264Mode, SharedStats, Stats, count_fastpath};
use super::rdp_layout::{Layout, Limits};
use super::{
    CloseReason, Closed, Command, DartStream, Notifier, OpenRequest, Pipe, Session, event, hex, now_us, parse_sha256,
    run_session,
};

/// The session's thread: a runtime of its own, the connection, then PDUs and input until the
/// end. Always ends with CLOSED.
pub fn run(session: Arc<Session>, request: OpenRequest, notifier: Notifier) {
    run_session(notifier, || session_loop(&session, request, notifier));
}

/// A failure while reading or writing: the transport's reason when the channel ended, else the
/// network's.
/// The largest picture the app holds for a screen, the same as VNC's (vnc::engine::limits): a 4K
/// screen, and no side past 8192. An RDP server names its screen's size three ways (as the
/// session starts, when it reactivates, and in the graphics pipeline's reset), each a pair of
/// numbers up to 65,535 or 32,766, and each was allocated as sent, twice (IronRDP's picture and
/// ours): 65,535 by 65,535 is 17 GB. The vendored ZGFX ceiling
/// (vendor/ironrdp-graphics/NOTICE-ZESTSSH) is this many pixels of 4 bytes.
pub(crate) const MAX_PIXELS: usize = 8_294_400;
pub(crate) const MAX_DIMENSION: u16 = 8192;

/// Ours: a server may change its screen's size this many times a second. Each change makes
/// two new pictures (up to 33 MiB each) and tells the app; a person dragging a window's edge
/// asks for about four a second, the view's own pace.
pub(crate) const MAX_RESIZES_A_SECOND: u32 = 8;

/// One more change of the screen's size in this second: too many?
pub(crate) fn resized(count: &mut u32) -> Result<(), Closed> {
    *count += 1;
    if *count > MAX_RESIZES_A_SECOND {
        return Err(Closed::new(
            CloseReason::Protocol,
            format!("the server changed its screen's size more than {MAX_RESIZES_A_SECOND} times in a second"),
        ));
    }
    Ok(())
}

/// A screen size the server names: itself, or the session's end before anything of that size is
/// allocated. [limits] is what this session may hold: one display's ceilings, or the rectangle
/// around the displays it asked for.
pub(crate) fn server_size(limits: &Limits, width: u16, height: u16) -> Result<(u16, u16), Closed> {
    if !limits.takes(width.into(), height.into()) {
        return Err(Closed::new(
            CloseReason::Protocol,
            format!(
                "the server's screen of {width} by {height} is not one this app shows (at most {} a side and {} pixels)",
                limits.side(),
                limits.pixels()
            ),
        ));
    }
    Ok((width, height))
}

/// The displays to tell the app of for a picture of [w] by [h]: the ones asked for where the
/// server made the desktop asked for, else the whole picture as one.
pub(crate) fn displays_of(layout: &Layout, w: u16, h: u16) -> serde_json::Value {
    let rects = if layout.size() == (u32::from(w), u32::from(h)) { layout.rects() } else { vec![[0, 0, w.into(), h.into()]] };
    serde_json::json!(rects)
}

/// The size to ask the server for: as the display control channel takes it (200 to 8192 a side,
/// the width even), and scaled down, keeping its shape, where it would be more than MAX_PIXELS.
pub(crate) fn asked_size(width: u32, height: u32) -> (u32, u32) {
    let (mut w, mut h) = MonitorLayoutEntry::adjust_display_size(width, height);
    if (w as usize) * (h as usize) > MAX_PIXELS {
        let scale = (MAX_PIXELS as f64 / (f64::from(w) * f64::from(h))).sqrt();
        (w, h) = MonitorLayoutEntry::adjust_display_size((f64::from(w) * scale) as u32, (f64::from(h) * scale) as u32);
        while (w as usize) * (h as usize) > MAX_PIXELS {
            h -= 1;
        }
    }
    (w, h)
}

fn io_closed(what: &str, e: impl std::fmt::Display, pipe: &Pipe) -> Closed {
    Closed::new(CloseReason::Network, format!("{what}: {e}")).or_transport(pipe)
}

/// The largest pointer shape handed to the app, a side (as the VNC engine's MAX_CURSOR, from a security
/// review): real ones are 32 to 64 pixels, 128 or 256 on a large display. A larger one (the
/// protocol allows 384) is shown as the system's own pointer.
pub(crate) const MAX_CURSOR: u16 = 256;

/// How often a second the app is told of a new pointer shape, however often the server changes
/// it (the last one of a burst is the one told): each is a picture the app has to make.
pub(crate) const MAX_CURSORS_A_SECOND: u32 = 20;

/// [event::CURSOR]'s `a` and bytes for a pointer shape of the server's: the size and hot spot,
/// then RGBA with the colours multiplied by their alpha (IronRDP gives them unmultiplied; the
/// app's pictures are premultiplied). A shape with no size hides the pointer; one too large, or
/// whose pixels do not match its size, is the system's own pointer (`a` 1).
fn cursor_shape(pointer: &ironrdp_graphics::pointer::DecodedPointer) -> (i64, Vec<u8>) {
    let (w, h) = (pointer.width, pointer.height);
    if w == 0 || h == 0 {
        return cursor_hidden();
    }
    if w > MAX_CURSOR || h > MAX_CURSOR || pointer.bitmap_data.len() != usize::from(w) * usize::from(h) * 4 {
        return cursor_default();
    }
    let mut out = Vec::with_capacity(8 + pointer.bitmap_data.len());
    for v in [w, h, pointer.hotspot_x.min(w - 1), pointer.hotspot_y.min(h - 1)] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for px in pointer.bitmap_data.chunks_exact(4) {
        let a = u16::from(px[3]);
        let multiplied = |c: u8| ((u16::from(c) * a + 127) / 255) as u8;
        out.extend_from_slice(&[multiplied(px[0]), multiplied(px[1]), multiplied(px[2]), px[3]]);
    }
    (0, out)
}

/// No pointer at all (the server hides it).
fn cursor_hidden() -> (i64, Vec<u8>) {
    (0, vec![0; 8])
}

/// The system's own pointer.
fn cursor_default() -> (i64, Vec<u8>) {
    (1, vec![0; 8])
}

/// How long a size the view asked for waits for the server's display control channel before
/// the app is told the server takes none: the channel opens within a second of the first
/// picture where a server has it (Windows, xrdp 0.10), and an older xrdp never opens it.
pub(crate) const RESIZE_WAIT_SECONDS: u32 = 5;

/// A size the view asked for that the server has not been told yet, in seconds; and whether the
/// app was told that this server does not resize (once a session).
#[derive(Default)]
struct ResizeWait {
    waited: u32,
    told: bool,
}

impl ResizeWait {
    /// A second went by with a size still waiting ([pending]) or not: whether to tell the app
    /// now that the server takes no resize.
    fn tick(&mut self, pending: bool) -> bool {
        if !pending {
            self.waited = 0;
            return false;
        }
        self.waited += 1;
        if self.waited >= RESIZE_WAIT_SECONDS && !self.told {
            self.told = true;
            return true;
        }
        false
    }
}

/// The pointer shapes on their way to the app: the last one waits here, and goes when the second
/// has room for it ([MAX_CURSORS_A_SECOND]).
#[derive(Default)]
struct Cursors {
    waiting: Option<(i64, Vec<u8>)>,
    told: u32,
}

impl Cursors {
    fn set(&mut self, cursor: (i64, Vec<u8>)) {
        self.waiting = Some(cursor);
    }

    /// The shape to tell the app now, if there is one and the second has room.
    fn due(&mut self) -> Option<(i64, Vec<u8>)> {
        if self.told >= MAX_CURSORS_A_SECOND {
            return None;
        }
        let cursor = self.waiting.take()?;
        self.told += 1;
        Some(cursor)
    }

    /// A second went by.
    fn tick(&mut self) {
        self.told = 0;
    }
}

/// Why a server ended a session, where the app says it in its own words: the server's reason
/// (its Set Error Info PDU, [MS-RDPBCGR] 2.2.5.1.1) against the name the app knows it by
/// ([Closed::detail]). A closed list; any other reason is said as the server's own sentence.
const SERVER_ENDINGS: &[(ErrorInfo, &str)] = &[
    // Nobody touched the session for as long as the server allows.
    (ErrorInfo::ProtocolIndependentCode(Ending::IdleTimeout), "idle"),
    // Nobody signed in at the server's own sign-in screen in the time it allows.
    (ErrorInfo::ProtocolIndependentCode(Ending::LogonTimeout), "logon_timeout"),
    // The same account connected from somewhere else and took the session.
    (ErrorInfo::ProtocolIndependentCode(Ending::DisconnectedByOtherconnection), "replaced"),
    (ErrorInfo::ProtocolIndependentCode(Ending::ServerDeniedConnection), "denied"),
    // The account may not sign in over Remote Desktop.
    (ErrorInfo::ProtocolIndependentCode(Ending::ServerInsufficientPrivileges), "not_allowed"),
    // The server takes no saved credentials: it wants them typed each time.
    (ErrorInfo::ProtocolIndependentCode(Ending::ServerFreshCredentialsRequired), "fresh_credentials"),
    // Someone with an administrator's tools disconnected the session, or signed it out.
    (ErrorInfo::ProtocolIndependentCode(Ending::RpcInitiatedDisconnect), "admin_disconnected"),
    (ErrorInfo::ProtocolIndependentCode(Ending::RpcInitiatedLogoff), "admin_signed_out"),
    // The person themselves, inside the remote session: Disconnect, or Sign out.
    (ErrorInfo::ProtocolIndependentCode(Ending::RpcInitiatedDisconnectByuser), "disconnected"),
    (ErrorInfo::ProtocolIndependentCode(Ending::LogoffByUser), "signed_out"),
    (ErrorInfo::ProtocolIndependentCode(Ending::ServerShutdown), "shutdown"),
    (ErrorInfo::ProtocolIndependentCode(Ending::ServerReboot), "restart"),
    // Every licensing reason is one thing to a person: the server's licences, its owner's to fix.
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::Internal), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::NoLicenseServer), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::NoLicense), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::BadClientMsg), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::HwidDoesntMatchLicense), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::BadClientLicense), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::CantFinishProtocol), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::ClientEndedProtocol), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::BadClientEncryption), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::CantUpgradeLicense), "licence"),
    (ErrorInfo::ProtocolIndependentLicensingCode(Licensing::NoRemoteConnections), "licence"),
];

/// A session the server (or the person) ended in RDP's own orderly way, as how it closed.
///
/// IronRDP's session hands the server's reason on as its sentence only
/// (`GracefulDisconnectReason::Other(info.description())`, vendor/ironrdp-session), not as the
/// code. The sentence is `ErrorInfo::description()` of the same pinned ironrdp-pdu, so the name is
/// found by making that sentence again for each reason of [SERVER_ENDINGS] and comparing: exact,
/// and without a second change to the fork.
fn ended_by_server(reason: GracefulDisconnectReason) -> Result<(), Closed> {
    let said = match reason {
        GracefulDisconnectReason::UserInitiated => return Ok(()),
        other => other.description(),
    };
    let closed = Closed::new(CloseReason::ServerClosed, format!("the server ended the session: {said}"));
    Err(match SERVER_ENDINGS.iter().find(|(info, _)| info.description() == said) {
        Some((_, name)) => closed.with_detail(name),
        None => closed,
    })
}

/// Why a server refused a sign-in with Network Level Authentication, where it said (the status
/// in its CredSSP answer, [MS-CSSP] 2.2.1 `errorCode`, from version 3 of the protocol): the name
/// the app knows it by ([Closed::detail]). A wrong password or user name has no name: it is what
/// "the sign-in was refused" means, and a server may say only that for the others too.
fn refused_sign_in(e: &ironrdp_connector::sspi::Error) -> Option<&'static str> {
    use ironrdp_connector::sspi::credssp::NStatusCode as Status;
    match e.nstatus? {
        Status::ACCOUNT_LOCKED_OUT => Some("account_locked"),
        Status::ACCOUNT_DISABLED => Some("account_disabled"),
        Status::PASSWORD_EXPIRED | Status::PASSWORD_MUST_CHANGE => Some("password_expired"),
        // The account exists and the password was right, and it may not sign in this way: an
        // empty password, outside its hours, not from this computer, not over Remote Desktop.
        Status::ACCOUNT_RESTRICTION
        | Status::INVALID_LOGON_HOURS
        | Status::INVALID_WORKSTATION
        | Status::LOGON_NOT_GRANTED
        | Status::LOGON_TYPE_NOT_GRANTED => Some("account_restricted"),
        _ => None,
    }
}

/// What the clipboard's channel has to send after [what] was done to it, framed for the wire;
/// nothing where the session has no such channel ([joined]: the app asked and the server took it).
fn clipboard_frames(
    stage: &mut ActiveStage,
    joined: bool,
    what: impl FnOnce(&mut Clipboard) -> Vec<ironrdp_svc::SvcMessage>,
) -> ironrdp_session::SessionResult<Vec<ActiveStageOutput>> {
    if !joined {
        return Ok(Vec::new());
    }
    let Some(clip) = stage.get_svc_processor_mut::<Clipboard>() else {
        return Ok(Vec::new());
    };
    let messages = what(clip);
    if messages.is_empty() {
        return Ok(Vec::new());
    }
    let frame = stage.process_svc_processor_messages(ironrdp_svc::SvcProcessorMessages::<Clipboard>::new(messages))?;
    Ok(vec![ActiveStageOutput::ResponseFrame(frame)])
}

/// A connector error (the connection request or the log in) as a close reason.
fn connector_closed(what: &str, e: &ironrdp_connector::ConnectorError, pipe: &Pipe) -> Closed {
    let text = format!("{what}: {e}");
    match e.kind() {
        ConnectorErrorKind::Credssp(refused) => {
            let closed = Closed::new(CloseReason::Auth, format!("the server refused the sign-in ({text})"));
            match refused_sign_in(refused) {
                Some(name) => closed.with_detail(name),
                None => closed,
            }
        }
        ConnectorErrorKind::AccessDenied | ConnectorErrorKind::EntraAuth(_) => {
            Closed::new(CloseReason::Auth, format!("the server refused the sign-in ({text})"))
        }
        // The server's own refusal of what was asked for. Two of them are a host's setting
        // not fitting its server, which the app says in its own words.
        ConnectorErrorKind::Negotiation(failure) => {
            use ironrdp_pdu::nego::FailureCode;
            let closed = Closed::new(CloseReason::Protocol, text);
            match failure.code() {
                // "If only CredSSP was requested then the server only supports TLS."
                FailureCode::SSL_REQUIRED_BY_SERVER => closed.with_detail("nla_missing"),
                FailureCode::HYBRID_REQUIRED_BY_SERVER | FailureCode::SSL_WITH_USER_AUTH_REQUIRED_BY_SERVER => {
                    closed.with_detail("nla_required")
                }
                _ => closed,
            }
        }
        _ => {
            // An I/O error inside the connector is the channel ending; anything else the server's.
            let io = std::error::Error::source(e).is_some_and(|s| s.is::<std::io::Error>())
                || text.contains("I/O")
                || text.to_ascii_lowercase().contains("eof");
            if io || pipe.transport_end().is_some() {
                Closed::new(CloseReason::Network, text).or_transport(pipe)
            } else {
                Closed::new(CloseReason::Protocol, text)
            }
        }
    }
}

/// The stream under the connection request's framing, for TLS. Bytes the server sent after its
/// Connection Confirm, before the client's TLS hello, are refused: a server sends nothing there.
/// (IronRDP's `into_inner_no_leftover` asserts on them in a debug build and drops them in a
/// release one, where TLS then failed on whatever followed; found by fuzzing.)
fn stream_before_tls<S>(framed: TokioFramed<S>) -> Result<S, Closed>
where
    S: AsyncRead + AsyncWrite + Send + Sync + Unpin,
{
    let (stream, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(Closed::new(
            CloseReason::Protocol,
            format!("the server sent {} bytes before TLS started", leftover.len()),
        ));
    }
    Ok(stream)
}

/// The whole desktop as a rectangle (inclusive).
fn whole(w: u16, h: u16) -> InclusiveRectangle {
    InclusiveRectangle { left: 0, top: 0, right: w.saturating_sub(1), bottom: h.saturating_sub(1) }
}

/// Pause: Suppress Output with no rectangle (the server stops sending pictures). Resume: Suppress
/// Output with the whole desktop, then Refresh Rect for it (the picture is redrawn at once). Each
/// only when the server said it takes the PDU (its General Capability Set); otherwise nothing:
/// the server keeps sending, the picture keeps being merged.
fn pause_frames(stage: &ActiveStage, pause: bool, w: u16, h: u16, refresh_rect: bool, suppress_output: bool) -> ironrdp_session::SessionResult<Vec<Vec<u8>>> {
    let mut frames = Vec::new();
    if suppress_output {
        let mut buf = WriteBuf::new();
        let desktop_rect = if pause { None } else { Some(whole(w, h)) };
        stage.encode_static(&mut buf, ShareDataPdu::SuppressOutput(SuppressOutputPdu { desktop_rect }))?;
        frames.push(buf.into_inner());
    }
    if !pause && refresh_rect {
        let mut buf = WriteBuf::new();
        stage.encode_static(
            &mut buf,
            ShareDataPdu::RefreshRectangle(RefreshRectanglePdu { areas_to_refresh: vec![whole(w, h)] }),
        )?;
        frames.push(buf.into_inner());
    }
    Ok(frames)
}

/// Our buttons (bit 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down) to fast-path mouse
/// events: a move, then one event per button that changed, then a wheel notch per wheel bit that
/// came on (the wheel bits come and go like VNC's buttons 4 and 5).
pub(crate) fn mouse_events(x: u16, y: u16, before: u8, now: u8) -> Vec<FastPathInputEvent> {
    let ev = |flags: PointerFlags, units: i16| {
        FastPathInputEvent::MouseEvent(MousePdu { flags, number_of_wheel_rotation_units: units, x_position: x, y_position: y })
    };
    let mut out = vec![ev(PointerFlags::MOVE, 0)];
    for (bit, flag) in [
        (1u8, PointerFlags::LEFT_BUTTON),
        (2, PointerFlags::MIDDLE_BUTTON_OR_WHEEL),
        (4, PointerFlags::RIGHT_BUTTON),
    ] {
        if (before ^ now) & bit != 0 {
            out.push(ev(if now & bit != 0 { flag | PointerFlags::DOWN } else { flag }, 0));
        }
    }
    let rising = now & !before;
    if rising & 8 != 0 {
        out.push(ev(PointerFlags::VERTICAL_WHEEL, 120));
    }
    if rising & 16 != 0 {
        out.push(ev(PointerFlags::VERTICAL_WHEEL, -120));
    }
    out
}

/// Ours: one call's movement is sent as this many events at most. An event carries up to
/// 32,767 pixels a way; a movement larger than eight of them is not a hand's.
pub(crate) const MAX_RELATIVE_EVENTS: usize = 8;

/// The input capability a server says it takes relative mouse movement with
/// (INPUT_FLAG_MOUSE_RELATIVE).
pub(crate) const INPUT_FLAG_MOUSE_RELATIVE: u16 = 0x0080;

/// A movement of (dx, dy) with our buttons (as [mouse_events]) to relative pointer events: the
/// movement, in as many events as it takes ([MAX_RELATIVE_EVENTS] at most, the rest dropped),
/// then one event per button that changed. A wheel notch is not a movement: it goes as the
/// wheel event it always was, at the place the pointer last had ([at]).
pub(crate) fn relative_mouse_events(dx: i32, dy: i32, before: u8, now: u8, at: (u16, u16)) -> Vec<FastPathInputEvent> {
    let rel = |flags: PointerRelFlags, x: i16, y: i16| {
        FastPathInputEvent::MouseEventRel(MouseRelPdu { flags, x_delta: x, y_delta: y })
    };
    let mut out = Vec::new();
    let (mut left_x, mut left_y) = (dx, dy);
    while (left_x != 0 || left_y != 0) && out.len() < MAX_RELATIVE_EVENTS {
        let x = left_x.clamp(-i32::from(i16::MAX), i32::from(i16::MAX));
        let y = left_y.clamp(-i32::from(i16::MAX), i32::from(i16::MAX));
        out.push(rel(PointerRelFlags::MOVE, x as i16, y as i16));
        left_x -= x;
        left_y -= y;
    }
    for (bit, flag) in [(1u8, PointerRelFlags::BUTTON1), (2, PointerRelFlags::BUTTON3), (4, PointerRelFlags::BUTTON2)] {
        if (before ^ now) & bit != 0 {
            out.push(rel(if now & bit != 0 { flag | PointerRelFlags::DOWN } else { flag }, 0, 0));
        }
    }
    let wheel = |units: i16| {
        FastPathInputEvent::MouseEvent(MousePdu {
            flags: PointerFlags::VERTICAL_WHEEL,
            number_of_wheel_rotation_units: units,
            x_position: at.0,
            y_position: at.1,
        })
    };
    let rising = now & !before;
    if rising & 8 != 0 {
        out.push(wheel(120));
    }
    if rising & 16 != 0 {
        out.push(wheel(-120));
    }
    out
}

/// A key: by its scancode when known (QEMU's numbering, which [Command::Key] carries: XT set 1,
/// with 0x80 added for the keys sent after an 0xE0 prefix), else as Unicode when its keysym is a
/// character, else nothing.
pub(crate) fn key_events(keysym: u32, scancode: u32, down: bool) -> Vec<FastPathInputEvent> {
    let release = if down { KeyboardFlags::empty() } else { KeyboardFlags::RELEASE };
    if scancode != 0 && scancode < 0x100 {
        let extended = if scancode & 0x80 != 0 { KeyboardFlags::EXTENDED } else { KeyboardFlags::empty() };
        return vec![FastPathInputEvent::KeyboardEvent(release | extended, (scancode & 0x7f) as u8)];
    }
    let code = match keysym {
        0x20..=0x7e | 0xa0..=0xff => Some(keysym),
        k if k & 0xff00_0000 == 0x0100_0000 => Some(k & 0x00ff_ffff),
        _ => None,
    };
    let Some(ch) = code.and_then(char::from_u32) else { return Vec::new() };
    let mut units = [0u16; 2];
    ch.encode_utf16(&mut units)
        .iter()
        .map(|u| FastPathInputEvent::UnicodeKeyboardEvent(release, *u))
        .collect()
}

enum Step<P> {
    Command(Command),
    Pdu(std::io::Result<(ironrdp_pdu::Action, P)>),
    /// A second went by: time to tell what the server sent, if it changed.
    Tick,
}

async fn session_loop(session: &Session, request: OpenRequest, notifier: Notifier) -> Result<(), Closed> {
    let pipe = &session.pipe;
    let pin = request.tls_pin.as_deref().map(parse_sha256).transpose().map_err(|e| Closed::new(CloseReason::Internal, e))?;
    let server_name = request.server_name.clone().unwrap_or_else(|| "localhost".to_owned());
    // One screen as the display control channel would take it (200 to 8192, the width even,
    // and no more pixels than the app holds), or the displays asked for, as they are.
    let layout = match request.displays.as_deref() {
        Some(displays) if !displays.is_empty() => {
            Layout::of(displays).map_err(|e| Closed::new(CloseReason::Internal, format!("displays: {e}")))?
        }
        _ => Layout::single(
            u32::from(request.width.unwrap_or(1280)),
            u32::from(request.height.unwrap_or(800)),
            request.scale.unwrap_or(0),
        ),
    };
    // What the server may make the app hold follows from what it was asked for.
    let limits = Arc::new(Limits::for_layout(&layout));
    let (width, height) = (layout.size().0 as u16, layout.size().1 as u16);
    let started = now_us();

    let graphics = crate::rdp::Graphics::parse(request.rdp_graphics.as_deref()).map_err(|e| Closed::new(CloseReason::Internal, e))?;
    // NLA or nothing, unless the host says without (then TLS alone, and no password sent).
    let nla = if request.rdp_nla == Some(false) { crate::rdp::Nla::Without } else { crate::rdp::Nla::Required };
    let mut config = crate::rdp::connector_config(
        width,
        height,
        request.username.clone().unwrap_or_default(),
        request.password.as_deref().map(str::to_owned).unwrap_or_default(),
        request.domain.clone(),
        graphics,
        nla,
    );
    // Several displays: the desktop is the rectangle around them, and each is named. A scale
    // goes with the first.
    config.monitor_layout = layout.monitor_data();
    config.monitor_extended_layout = layout.monitor_extended();
    if layout.scale() != 0 {
        config.desktop_scale_factor = layout.scale();
    }
    // Relative mouse only for a host that asks for it: it changes the client version the
    // connection says, so a session that does not ask connects exactly as before.
    let relative_asked = request.rdp_relative_mouse == Some(true);
    config.relative_mouse_input = relative_asked;
    // The remote's sound, where the app asked for it and this device has an output: the server
    // is told this device plays sound (else it sends none), and the channel is added below.
    let (sound, sound_said) = open_sound(request.rdp_sound.as_deref())?;
    config.enable_audio_playback = sound.is_some();
    // The name and the password stay out of the connector until TLS is up (its connection
    // request would carry the name in the clear).
    let credentials = crate::rdp::hold_credentials(&mut config);
    let h264 = h264_for_displays(
        layout.count(),
        H264Mode::parse(request.rdp_h264.as_deref()).map_err(|e| Closed::new(CloseReason::Internal, e))?,
    );
    let stats: SharedStats = Arc::new(std::sync::Mutex::new(Stats::new(graphics.name())));
    // The display control channel (resize to the view) and the graphics pipeline ride the dynamic
    // channels. Both from factories: after a resize xrdp resets the core (a Deactivation-
    // Reactivation Sequence) and opens them again, and a channel registered as one instance is
    // only there for the first opening (the second got NO_LISTENER, and the pipeline went quiet).
    let mut drdynvc = DrdynvcClient::new().with_dynamic_channel_factory(ironrdp_displaycontrol::CHANNEL_NAME, || {
        DisplayControlClient::new(|_| Ok(Vec::new()))
    });
    if graphics == crate::rdp::Graphics::Gfx {
        let stats = stats.clone();
        // As many at once as [GfxSlots] has places for, however many the server asks for.
        let slots = GfxSlots::default();
        let limits = limits.clone();
        drdynvc = drdynvc.with_dynamic_channel_factory(ironrdp_egfx::CHANNEL_NAME, move || {
            Gfx::in_slot(&slots, stats.clone(), h264, limits.clone())
        });
    }
    // The client's address in the Client Info PDU: the channel has none of its own.
    let client_addr = std::net::SocketAddr::from(([127, 0, 0, 1], 0));
    let mut connector = ClientConnector::new(config, client_addr).with_static_channel(drdynvc);
    // The clipboard's channel only where the app asked for it: without it the server has
    // nothing to send a clipboard on or ask for one through.
    match request.rdp_clipboard.as_deref() {
        None | Some("none") => {}
        Some("on") => connector = connector.with_static_channel(Clipboard::new(true)),
        Some("off") => connector = connector.with_static_channel(Clipboard::new(false)),
        Some(other) => return Err(Closed::new(CloseReason::Internal, format!("rdp_clipboard: {other:?} is none of on, off, none"))),
    }
    #[cfg(feature = "sound")]
    if let Some((_, shared)) = &sound {
        connector = connector.with_static_channel(ironrdp_rdpsnd::client::Rdpsnd::new(Box::new(SoundSink::new(shared.clone()))));
    }

    let start = Start { server_name, credentials, layout, limits, started, graphics, h264, stats, relative_asked, sound, sound_said };
    let stream = DartStream::new(session.pipe.clone(), notifier);
    let Some(gateway) = &request.rdp_gateway else {
        #[cfg(fuzzing)]
        if request.fuzz_as_if_tls {
            return connect_on(session, stream, connector, start, pin, true, notifier).await;
        }
        return connect_on(session, stream, connector, start, pin, false, notifier).await;
    };
    // Through an RD Gateway: the pipe goes to the gateway, and the connection to the PC runs
    // inside its channel, its own TLS and the PC's pin as on any other way there.
    let (tunnel, gateway_end) = super::rdp_gateway::open(stream, gateway).await.map_err(|e| match e.reason {
        CloseReason::Network | CloseReason::ServerClosed if pipe.transport_end().is_some() => io_closed("the gateway", &e.message, pipe),
        _ => e,
    })?;
    let ran = connect_on(session, tunnel, connector, start, pin, false, notifier).await;
    // Where the gateway ended the channel, its reason, not the session's view of it.
    let said = gateway_end.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    match (ran, said) {
        (Err(ours), Some(gateway_said)) => Err(end_through_gateway(ours, gateway_said)),
        (ran, _) => ran,
    }
}

/// Which end a session through a gateway is said to have had, where both the session and the
/// gateway gave one. The gateway's where the session only saw its stream end (the gateway knows
/// why: its policy, the PC out of reach). The session's own where it says more: a sign-in the PC
/// refused, the PC's certificate, a server's own reason. (A PC that refuses a password then
/// closes, the gateway closes the channel for that, and "the gateway closed the channel" took
/// the place of the refusal: the password was not asked for again.)
fn end_through_gateway(ours: Closed, gateway: Closed) -> Closed {
    let only_ended = matches!(ours.reason, CloseReason::Network | CloseReason::ServerClosed)
        && ours.detail.is_none()
        && ours.certificate.is_none();
    if only_ended { gateway } else { ours }
}

/// The connection request, TLS to the PC and the rest, over `stream`: the pipe itself, or the
/// channel an RD Gateway opened to the PC.
async fn connect_on<S>(
    session: &Session,
    stream: S,
    mut connector: ClientConnector,
    start: Start,
    pin: Option<[u8; 32]>,
    as_if_tls: bool,
    notifier: Notifier,
) -> Result<(), Closed>
where
    S: AsyncRead + AsyncWrite + Send + Sync + Unpin,
{
    let pipe = &session.pipe;
    // The connection request and the server's answer are all that crosses the channel before
    // TLS: which security the client takes (TLS, and NLA inside it), no name and no password.
    let mut framed = TokioFramed::new(stream);
    let should_upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
        .await
        .map_err(|e| connector_closed("connection request", &e, pipe))?;
    // The fuzz targets' way past the handshake (never in a build of the app: OpenRequest has
    // the field only with `--cfg fuzzing`).
    #[cfg(fuzzing)]
    if as_if_tls {
        let (stream, ahead) = framed.into_inner();
        let secured = Secured::for_fuzzing(TokioFramed::new_with_leftover(stream, ahead));
        return after_tls(session, secured, should_upgrade, connector, start, notifier).await;
    }
    let _ = as_if_tls;
    let secured = tls_upgrade(stream_before_tls(framed)?, &start.server_name, pin, false).await.map_err(|e| match e {
        TlsFailure::Untrusted { der, .. } => Closed::certificate(&der),
        TlsFailure::Failed(t) if pipe.transport_end().is_some() => io_closed("TLS", t, pipe),
        TlsFailure::Failed(t) => Closed::new(CloseReason::Tls, format!("TLS: {t}")),
    })?;
    after_tls(session, secured, should_upgrade, connector, start, notifier).await
}

/// H.264 for a session of `count` displays: none where there are several. A Windows server sends
/// each display's picture as an H.264 stream of its own, and the pipeline's one decoder took them
/// all, so a session of two or more displays broke off within a second (IronRDP issue #2033; its
/// fix, a decoder for each surface, is in a release after the one built here). Such a session is
/// drawn with the other codecs the pipeline offers instead.
fn h264_for_displays(count: usize, asked: H264Mode) -> H264Mode {
    if count > 1 { H264Mode::Off } else { asked }
}

/// What the session keeps from before TLS.
struct Start {
    server_name: String,
    credentials: crate::rdp::HeldCredentials,
    /// The displays asked for.
    layout: Layout,
    /// What the server may make the app hold.
    limits: Arc<Limits>,
    /// The host asked for relative mouse movement.
    relative_asked: bool,
    started: i64,
    graphics: crate::rdp::Graphics,
    h264: H264Mode,
    stats: SharedStats,
    /// The speaker and what feeds it, where the session plays the remote's sound.
    sound: SoundParts,
    /// What the connected message says of the sound: its format, or why there is none.
    sound_said: serde_json::Value,
}

/// The sign-in and the session itself. It takes a [Secured] stream and nothing else, so no part
/// of it (the user name, the password, the picture, the keys) can run on the plain channel:
/// there is no other way to the stream it reads and writes.
async fn after_tls<T>(
    session: &Session,
    secured: Secured<T>,
    should_upgrade: ShouldUpgrade,
    connector: ClientConnector,
    start: Start,
    notifier: Notifier,
) -> Result<(), Closed>
where
    T: AsyncRead + AsyncWrite + Send + Sync + Unpin,
{
    let pipe = &session.pipe;
    let Start { server_name, credentials, layout, limits, started, graphics, h264, stats, relative_asked, sound, sound_said } = start;
    // (Kept to the session's end: the speaker stops when it goes. Nothing in a build without it.)
    #[cfg(not(feature = "sound"))]
    let _ = sound;
    let (width, height) = layout.size();
    let tls_us = now_us() - started;
    let SignedIn { connection, mut framed, facts, nla, .. } = secured
        .sign_in(should_upgrade, connector, credentials, &server_name)
        .await
        .map_err(|e| connector_closed("log in", &e, pipe))?;

    let (mut w, mut h) = server_size(&limits, connection.desktop_size.width, connection.desktop_size.height)?;
    let connection_input_flags = connection.input_flags.bits();
    // The displays the server has now, and the ones last asked for and not answered yet.
    let mut layout = layout;
    let mut asked_layout: Option<Layout> = None;
    let mut image = DecodedImage::new(PixelFormat::RgbA32, w, h);
    session.frame.held().resize(w.into(), h.into());
    let activation_factory = connection.activation_factory.clone();
    let (refresh_rect, suppress_output) = (connection.refresh_rect_support, connection.suppress_output_support);
    notifier.json(
        event::CONNECTED,
        serde_json::json!({
            "protocol": "rdp",
            "nla": nla,
            "tls": {
                "protocol": facts.protocol,
                "cipher_suite": facts.cipher_suite,
                "cert_sha256": hex(&facts.cert_sha256),
            },
            "width": w,
            "height": h,
            "asked": [width, height],
            "displays": displays_of(&layout, w, h),
            "graphics_offered": graphics.name(),
            "h264_asked": h264.name(),
            "fastpath_input": connection.input_flags.bits(),
            "relative_mouse": relative_asked && connection.input_flags.bits() & INPUT_FLAG_MOUSE_RELATIVE != 0,
            "sound": sound_said,
            "suppress_output": suppress_output,
            "refresh_rect": refresh_rect,
            "tls_us": tls_us,
            "handshake_us": now_us() - started,
        }),
    );
    // What one channel message may make the app hold: looked at before IronRDP has the frame.
    // The clipboard's channel is there when the app asked for it and the server joined it.
    let clipboard_channel = connection.static_channels.get_channel_id_by_type::<Clipboard>();
    #[cfg(feature = "sound")]
    let sound_channel = connection.static_channels.get_channel_id_by_type::<ironrdp_rdpsnd::client::Rdpsnd>();
    #[cfg(not(feature = "sound"))]
    let sound_channel: Option<u16> = None;
    let mut guard =
        ChannelGuard::new(connection.static_channels.get_channel_id_by_type::<DrdynvcClient>(), clipboard_channel)
            .with_sound(sound_channel);
    let mut stage: ActiveStage = ActiveStageBuilder {
        static_channels: connection.static_channels,
        user_channel_id: connection.user_channel_id,
        io_channel_id: connection.io_channel_id,
        message_channel_id: connection.message_channel_id,
        share_id: connection.share_id,
        compression_type: connection.compression_type,
        enable_server_pointer: connection.enable_server_pointer,
        pointer_software_rendering: connection.pointer_software_rendering,
    }
    .build();

    // The lock keys start off (as a client does when it gets the focus).
    for out in stage
        .process_fastpath_input(&mut image, &[FastPathInputEvent::SyncEvent(SynchronizeFlags::empty())])
        .map_err(|e| Closed::new(CloseReason::Internal, format!("input: {e}")))?
    {
        if let ActiveStageOutput::ResponseFrame(frame) = out {
            framed.write_all(&frame).await.map_err(|e| io_closed("write", e, pipe))?;
        }
    }

    // Movement goes only where it was asked for and the server said it takes it.
    let relative = relative_asked && connection_input_flags & INPUT_FLAG_MOUSE_RELATIVE != 0;
    let mut relative_refused_told = false;
    // Where the pointer last was, for a wheel notch while movement is sent.
    let mut pointer_at: (u16, u16) = (0, 0);
    let mut buttons: u8 = 0;
    let mut paused = false;
    // Displays the view asked for before the display control channel was ready.
    let mut want_layout: Option<Layout> = None;
    // The picture's size changed: tell the app its displays after this step.
    let mut tell_displays = false;
    let mut resize_wait = ResizeWait::default();
    // The graphics report: kinds seen and bytes at the last one, and when it went.
    let (mut told_kinds, mut told_bytes, mut told_at) = (0usize, 0u64, 0i64);
    let report = |stats: &SharedStats| {
        let s = stats.held().clone();
        notifier.json(event::INFO, serde_json::json!({ "graphics": s, "at_us": now_us() }));
    };
    let mut ticks = tokio::time::interval(std::time::Duration::from_secs(1));
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // Changes of the screen's size since the last tick.
    let mut resizes = 0u32;
    let mut cursors = Cursors::default();
    let result = loop {
        // Closed by the app: looked at before every piece of the server's, so a flood from
        // the server cannot keep the session going (close() itself never waits for this).
        if session.stopped() {
            break Ok(());
        }
        // Input goes out from this same loop (read_pdu is cancel safe). In this order, not
        // whichever is ready first: the app's own commands, Close among them, are never behind
        // a server that always has more to read, and neither is the second's tick.
        let step = tokio::select! {
            biased;
            c = session.commands.recv() => Step::Command(c),
            _ = ticks.tick() => Step::Tick,
            r = framed.read_pdu() => Step::Pdu(r),
        };
        let mut pdu_at = 0i64;
        let outputs = match step {
            Step::Pdu(Err(e)) => break Err(io_closed("read", e, pipe)),
            Step::Pdu(Ok((action, payload))) => {
                pdu_at = now_us();
                {
                    let mut s = stats.held();
                    match action {
                        ironrdp_pdu::Action::FastPath => count_fastpath(&payload, &mut s),
                        ironrdp_pdu::Action::X224 => s.bytes_x224 += payload.len() as u64,
                    }
                }
                let look = match action {
                    ironrdp_pdu::Action::X224 => guard.look(&payload),
                    ironrdp_pdu::Action::FastPath => Look::Pass,
                };
                match look {
                    Look::Refuse(why) => break Err(Closed::new(CloseReason::Protocol, format!("session: {why}"))),
                    Look::Drop => Vec::new(),
                    Look::Pass => match stage.process(&mut image, action, &payload, framed.last_read_at()) {
                        Ok(o) => o,
                        Err(e) => break Err(Closed::new(CloseReason::Protocol, format!("session: {e}"))),
                    },
                }
            }
            Step::Command(Command::Close) => match stage.graceful_shutdown() {
                Ok(o) => {
                    for out in o {
                        if let ActiveStageOutput::ResponseFrame(frame) = out {
                            let _ = framed.write_all(&frame).await;
                        }
                    }
                    break Ok(());
                }
                Err(e) => break Err(Closed::new(CloseReason::Internal, format!("shutdown: {e}"))),
            },
            Step::Command(Command::PointerRelative { dx, dy, buttons: b }) => {
                if relative {
                    let events = relative_mouse_events(dx, dy, buttons, b, pointer_at);
                    buttons = b;
                    match stage.process_fastpath_input(&mut image, &events) {
                        Ok(o) => o,
                        Err(e) => break Err(Closed::new(CloseReason::Internal, format!("input: {e}"))),
                    }
                } else {
                    // Not asked for, or not taken by this server: nothing is sent, said once.
                    if !relative_refused_told {
                        relative_refused_told = true;
                        notifier.json(event::INFO, serde_json::json!({ "relative_mouse_unavailable": true, "at_us": now_us() }));
                    }
                    Vec::new()
                }
            }
            Step::Command(Command::Pointer { x, y, buttons: b }) => {
                let events = mouse_events(x, y, buttons, b);
                buttons = b;
                pointer_at = (x, y);
                match stage.process_fastpath_input(&mut image, &events) {
                    Ok(o) => o,
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("input: {e}"))),
                }
            }
            Step::Command(Command::Key { keysym, scancode, down }) => {
                match stage.process_fastpath_input(&mut image, &key_events(keysym, scancode, down)) {
                    Ok(o) => o,
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("input: {e}"))),
                }
            }
            Step::Command(Command::Resize { width, height }) => {
                want_layout = Some(Layout::single(width, height, layout.scale()));
                Vec::new()
            }
            Step::Command(Command::Layout(displays)) => {
                match Layout::of(&displays) {
                    Ok(wanted) => want_layout = Some(wanted),
                    // Not one a server takes: nothing is asked, and the app is told why.
                    Err(why) => notifier.json(event::INFO, serde_json::json!({ "layout_refused": why, "at_us": now_us() })),
                }
                Vec::new()
            }
            Step::Command(Command::FullRefresh) => {
                match stage.request_full_redraw(w, h, refresh_rect, suppress_output) {
                    Ok(frames) => frames.into_iter().map(ActiveStageOutput::ResponseFrame).collect(),
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("refresh: {e}"))),
                }
            }
            Step::Command(c @ (Command::Pause | Command::Resume)) => {
                let pause = matches!(c, Command::Pause);
                if pause == paused {
                    Vec::new()
                } else {
                    paused = pause;
                    let how = match (suppress_output, refresh_rect) {
                        (true, _) => "suppress_output",
                        (false, true) if !pause => "refresh_rect",
                        _ => "none (the server takes no Suppress Output)",
                    };
                    notifier.json(event::INFO, serde_json::json!({ "paused": pause, "how": how }));
                    match pause_frames(&stage, pause, w, h, refresh_rect, suppress_output) {
                        Ok(frames) => frames.into_iter().map(ActiveStageOutput::ResponseFrame).collect(),
                        Err(e) => break Err(Closed::new(CloseReason::Internal, format!("pause: {e}"))),
                    }
                }
            }
            Step::Command(Command::Clipboard(text)) => {
                match clipboard_frames(&mut stage, clipboard_channel.is_some(), |clip| clip.offer(text)) {
                    Ok(o) => o,
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("clipboard: {e}"))),
                }
            }
            Step::Command(Command::Sound(on)) => {
                #[cfg(feature = "sound")]
                if let Some((_, shared)) = &sound {
                    shared.set_on(on);
                }
                #[cfg(not(feature = "sound"))]
                let _ = on;
                Vec::new()
            }
            Step::Command(Command::ClipboardShare(on)) => {
                match clipboard_frames(&mut stage, clipboard_channel.is_some(), |clip| clip.share(on)) {
                    Ok(o) => o,
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("clipboard: {e}"))),
                }
            }
            Step::Tick => {
                resizes = 0;
                cursors.tick();
                // A size asked for and no channel to ask on: the app shows the picture fitted
                // instead, and says so once.
                if resize_wait.tick(want_layout.is_some()) {
                    notifier.json(event::INFO, serde_json::json!({ "resize_unavailable": true, "at_us": now_us() }));
                }
                match clipboard_frames(&mut stage, clipboard_channel.is_some(), Clipboard::tick) {
                    Ok(o) => o,
                    Err(e) => break Err(Closed::new(CloseReason::Internal, format!("clipboard: {e}"))),
                }
            }
        };
        // The server's clipboard text that came with this step, to the app (which decides what
        // becomes of it), and a text too long to take, said once for each.
        if clipboard_channel.is_some() {
            if let Some(text) = stage.get_svc_processor_mut::<Clipboard>().and_then(Clipboard::take) {
                notifier.bytes(event::CLIPBOARD, 0, text.into_bytes());
            }
            let too_long = guard.take_dropped();
            if too_long > 0 {
                if let Some(clip) = stage.get_svc_processor_mut::<Clipboard>() {
                    clip.lost();
                }
                notifier.json(event::INFO, serde_json::json!({ "clipboard_too_long": too_long, "at_us": now_us() }));
            }
        }

        let mut changed = false;
        let mut ended = None;
        for out in outputs {
            match out {
                ActiveStageOutput::ResponseFrame(frame) => {
                    if let Err(e) = framed.write_all(&frame).await {
                        ended = Some(Err(io_closed("write", e, pipe)));
                        break;
                    }
                }
                ActiveStageOutput::GraphicsUpdate(_) => changed = true,
                ActiveStageOutput::DeactivateAll => {
                    // The Deactivation-Reactivation Sequence (a resize, among others): read it
                    // through to the end here, then go on with the new size.
                    let mut sequence = activation_factory.create();
                    let mut buf = WriteBuf::new();
                    let finalized = loop {
                        let written = match single_sequence_step_read(&mut framed, &mut sequence, &mut buf).await {
                            Ok(written) => written,
                            Err(e) => break Err(io_closed("reactivation", e, pipe)),
                        };
                        if written.size().is_some() {
                            if let Err(e) = framed.write_all(buf.filled()).await {
                                break Err(io_closed("reactivation", e, pipe));
                            }
                        }
                        if let ConnectionActivationState::Finalized {
                            desktop_size,
                            share_id,
                            enable_server_pointer,
                            pointer_software_rendering,
                            static_channel_chunk_size,
                            ..
                        } = sequence.connection_activation_state()
                        {
                            stage.reactivate(
                                sequence.io_channel_id(),
                                sequence.user_channel_id(),
                                share_id,
                                enable_server_pointer,
                                pointer_software_rendering,
                                static_channel_chunk_size,
                            );
                            break Ok(desktop_size);
                        }
                    };
                    match finalized
                        .and_then(|size| server_size(&limits, size.width, size.height))
                        .and_then(|size| resized(&mut resizes).map(|()| size))
                    {
                        Ok(size) => {
                            (w, h) = size;
                            image = DecodedImage::new(PixelFormat::RgbA32, w, h);
                            session.frame.held().resize(w.into(), h.into());
                            notifier.signal(event::RESIZE, (i64::from(w) << 32) | i64::from(h));
                            tell_displays = true;
                        }
                        Err(e) => {
                            ended = Some(Err(e));
                            break;
                        }
                    }
                }
                ActiveStageOutput::Terminate(reason) => {
                    ended = Some(ended_by_server(reason));
                    break;
                }
                // The server's pointer: its shape, hidden, or the system's own. (Where the server
                // puts it is not followed: the app's pointer is where the person's is.)
                ActiveStageOutput::PointerBitmap(pointer) => cursors.set(cursor_shape(&pointer)),
                ActiveStageOutput::PointerHidden => cursors.set(cursor_hidden()),
                ActiveStageOutput::PointerDefault => cursors.set(cursor_default()),
                // Layouts, session facts.
                _ => {}
            }
        }
        if let Some(end) = ended {
            break end;
        }
        if let Some((a, bytes)) = cursors.due() {
            notifier.bytes(event::CURSOR, a, bytes);
        }

        // The graphics pipeline: a new output size, then the frames it completed, straight into
        // the framebuffer (IronRDP's picture is not involved).
        let at = if pdu_at == 0 { now_us() } else { pdu_at };
        let mut gfx_changed = false;
        if let Some(mut channel) = stage.get_dvc_mut::<Gfx>() {
            let gfx = channel.processor_mut();
            let reset = gfx.take_reset();
            let updates = gfx.drain();
            if let Some((rw, rh)) = reset {
                if (rw, rh) != (w, h) {
                    (w, h) = match server_size(&limits, rw, rh).and_then(|size| resized(&mut resizes).map(|()| size)) {
                        Ok(size) => size,
                        Err(closed) => break Err(closed),
                    };
                    image = DecodedImage::new(PixelFormat::RgbA32, w, h);
                    session.frame.held().resize(w.into(), h.into());
                    notifier.signal(event::RESIZE, (i64::from(w) << 32) | i64::from(h));
                    tell_displays = true;
                }
            }
            if !updates.is_empty() {
                let mut f = session.frame.held();
                for u in &updates {
                    let r = &u.region;
                    let (rw, rh) = (u32::from(r.right - r.left), u32::from(r.bottom - r.top));
                    f.put(r.left.into(), r.top.into(), rw, rh, &u.data, at);
                }
                gfx_changed = true;
            }
        }
        if gfx_changed && !changed {
            let (tell, seq) = {
                let mut f = session.frame.held();
                (f.update_done(now_us()), f.seq())
            };
            if tell {
                notifier.signal(event::FRAME, seq as i64);
            }
        }

        // What the server sends: told when a new kind comes, else about once a second while bytes
        // come.
        {
            let (kinds, bytes) = {
                let s = stats.held();
                (s.kinds(), s.bytes_fastpath + s.bytes_x224)
            };
            let now = now_us();
            if kinds != told_kinds || (bytes != told_bytes && now - told_at >= 1_000_000) {
                (told_kinds, told_bytes, told_at) = (kinds, bytes, now);
                report(&stats);
            }
        }

        if changed {
            let regions = stage.take_damage_regions();
            let (tell, seq) = {
                let mut f = session.frame.held();
                let data = image.data();
                let iw = u32::from(image.width());
                for r in &regions {
                    let (x, y) = (u32::from(r.left), u32::from(r.top));
                    let (rw, rh) = (u32::from(r.right) + 1 - x, u32::from(r.bottom) + 1 - y);
                    f.put_from_image(data, iw, x, y, rw, rh, at);
                }
                if regions.is_empty() {
                    f.put_from_image(data, iw, 0, 0, iw, u32::from(image.height()), at);
                }
                (f.update_done(now_us()), f.seq())
            };
            if tell {
                notifier.signal(event::FRAME, seq as i64);
            }
        }

        // The picture has another size: the displays asked for last are the server's now where
        // it made their desktop, and the ceilings come down to it. Then the app is told.
        if tell_displays {
            tell_displays = false;
            if let Some(asked) = asked_layout.take_if(|a| a.size() == (u32::from(w), u32::from(h))) {
                limits.settle(&asked);
                layout = asked;
            }
            notifier.json(event::DISPLAYS, serde_json::json!({ "displays": displays_of(&layout, w, h) }));
        }

        // The displays the view wants, once the display control channel is there (it opens
        // after the server's capabilities come on the dynamic channel, a little after the first
        // frames). One screen goes as a resize, as before; several as a layout.
        if let Some(wanted) = want_layout.take() {
            let same = wanted.count() == 1 && layout.count() == 1 && wanted.size() == (u32::from(w), u32::from(h));
            if same || wanted == layout && wanted.size() == (u32::from(w), u32::from(h)) {
                // What the server has already.
            } else {
                // Allowed before it is asked for: the server's answer may come at once.
                limits.allow(&wanted);
                let encoded = if wanted.count() == 1 && layout.count() == 1 {
                    let (sw, sh) = wanted.size();
                    let scale = (wanted.scale() != 0).then_some(wanted.scale());
                    stage.encode_resize(sw, sh, scale, None)
                } else {
                    match wanted.display_control() {
                        Ok(entries) => stage.encode_monitor_layout(&entries),
                        Err(e) => break Err(Closed::new(CloseReason::Internal, format!("displays: {e}"))),
                    }
                };
                match encoded {
                    // No channel yet: asked again after the next step.
                    None => want_layout = Some(wanted),
                    Some(Ok(frame)) => {
                        asked_layout = Some(wanted);
                        if let Err(e) = framed.write_all(&frame).await {
                            break Err(io_closed("write", e, pipe));
                        }
                    }
                    // More displays or pixels than this server takes: it keeps what it has.
                    Some(Err(e)) => {
                        notifier.json(event::INFO, serde_json::json!({ "layout_refused": e.to_string(), "at_us": now_us() }));
                    }
                }
            }
        }
    };
    report(&stats);
    // Closed by the app: whatever the loop saw while it stopped (the end of the stream, a write
    // that failed) was only how that looked from inside.
    if session.stopped() { Ok(()) } else { result }
}

/// The speaker for a session whose request asks for the remote's sound (`rdp_sound`), and what
/// feeds it; None where it does not ask, or this device has none (the session connects
/// without: no sound is not a reason to fail). With it what the connected message says:
/// `{"rate", "channels"}`, `{"unavailable": why}`, or null where none was asked for. (Not an
/// event of its own: the speaker opens before the sign-in, before any view listens.)
#[cfg(feature = "sound")]
type SoundParts = Option<(Speaker, Arc<super::rdp_sound::Shared>)>;
#[cfg(not(feature = "sound"))]
type SoundParts = Option<((), ())>;

#[cfg(feature = "sound")]
fn open_sound(asked: Option<&str>) -> Result<(SoundParts, serde_json::Value), Closed> {
    let on = match asked {
        None | Some("none") => return Ok((None, serde_json::Value::Null)),
        Some("on") => true,
        Some("off") => false,
        Some(other) => return Err(Closed::new(CloseReason::Internal, format!("rdp_sound: {other:?} is none of on, off, none"))),
    };
    Ok(match Speaker::open(on) {
        Ok((speaker, shared)) => {
            let said = serde_json::json!({ "rate": shared.rate, "channels": shared.channels });
            (Some((speaker, shared)), said)
        }
        Err(why) => (None, serde_json::json!({ "unavailable": why })),
    })
}

/// Without the `sound` feature: a request that asks for sound is told this build has none.
#[cfg(not(feature = "sound"))]
fn open_sound(asked: Option<&str>) -> Result<(SoundParts, serde_json::Value), Closed> {
    match asked {
        None | Some("none") => Ok((None, serde_json::Value::Null)),
        Some("on" | "off") => Ok((None, serde_json::json!({ "unavailable": "not in this build" }))),
        Some(other) => Err(Closed::new(CloseReason::Internal, format!("rdp_sound: {other:?} is none of on, off, none"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn through_a_gateway_the_sessions_own_reason_is_kept_and_a_bare_end_is_the_gateways() {
        let gateway = || Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the channel to the PC");
        let reach = || Closed::new(CloseReason::Network, "RD Gateway: the gateway could not reach the PC").with_detail("gateway_target");
        // The PC refused the sign-in, and the gateway then closed the channel: the refusal.
        let refused = Closed::new(CloseReason::Auth, "the server refused the sign-in").with_detail("password_expired");
        let e = end_through_gateway(refused, gateway());
        assert_eq!((e.reason, e.detail), (CloseReason::Auth, Some("password_expired")));
        let e = end_through_gateway(Closed::new(CloseReason::Auth, "the server refused the sign-in"), gateway());
        assert_eq!(e.reason, CloseReason::Auth);
        // The PC's certificate, to be asked about.
        let e = end_through_gateway(Closed::certificate(&[0x30, 0x03, 0x02, 0x01, 0x01]), reach());
        assert_eq!(e.reason, CloseReason::Certificate);
        // A server's own reason for ending the session.
        let e = end_through_gateway(Closed::new(CloseReason::ServerClosed, "signed out").with_detail("signed_out"), gateway());
        assert_eq!(e.detail, Some("signed_out"));
        // The stream only ended: the gateway says why.
        let e = end_through_gateway(Closed::new(CloseReason::ServerClosed, "the connection ended"), reach());
        assert_eq!(e.detail, Some("gateway_target"));
        let e = end_through_gateway(Closed::new(CloseReason::Network, "reading: broken pipe"), reach());
        assert_eq!(e.detail, Some("gateway_target"));
    }

    #[test]
    fn a_session_the_server_ended_is_closed_by_the_name_of_its_reason() {
        // As the session library hands it on: the reason's sentence.
        let ended = |info: ErrorInfo| ended_by_server(GracefulDisconnectReason::Other(info.description())).unwrap_err();
        for (info, name) in SERVER_ENDINGS {
            let closed = ended(*info);
            assert_eq!(closed.reason, CloseReason::ServerClosed);
            assert_eq!(closed.detail, Some(*name), "{info:?}");
            assert!(closed.message.contains(&info.description()), "the server's own sentence stays for Copy details");
            // What the app reads: at most 40 characters of a-z and _ (ScreenClosed.detail in Dart).
            assert!(name.len() <= 40 && name.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'), "{name}");
        }
        assert_eq!(ended(ErrorInfo::ProtocolIndependentCode(Ending::IdleTimeout)).detail, Some("idle"));
        assert_eq!(ended(ErrorInfo::ProtocolIndependentCode(Ending::DisconnectedByOtherconnection)).detail, Some("replaced"));
        assert_eq!(ended(ErrorInfo::ProtocolIndependentCode(Ending::LogoffByUser)).detail, Some("signed_out"));
        assert_eq!(ended(ErrorInfo::ProtocolIndependentLicensingCode(Licensing::NoLicenseServer)).detail, Some("licence"));

        // A reason with no name of the app's: as the server said it. Two sentences never are the
        // same, or one reason would be said as another.
        let other = ended(ErrorInfo::ProtocolIndependentCode(Ending::OutOfMemory));
        assert_eq!((other.reason, other.detail), (CloseReason::ServerClosed, None));
        let mut sentences: Vec<String> = SERVER_ENDINGS.iter().map(|(info, _)| info.description()).collect();
        sentences.push(ErrorInfo::ProtocolIndependentCode(Ending::OutOfMemory).description());
        sentences.push(GracefulDisconnectReason::ServerInitiated.description());
        let count = sentences.len();
        sentences.sort();
        sentences.dedup();
        assert_eq!(sentences.len(), count);

        // The server ending it with no reason, and the person's own close.
        let plain = ended_by_server(GracefulDisconnectReason::ServerInitiated).unwrap_err();
        assert_eq!((plain.reason, plain.detail), (CloseReason::ServerClosed, None));
        assert!(ended_by_server(GracefulDisconnectReason::UserInitiated).is_ok());

        // The names are found by the sentence, so the session library must still hand the
        // sentence on (and not, after an update of the fork, something else).
        let stage = include_str!("../../vendor/ironrdp-session/src/active_stage.rs");
        assert!(stage.contains("ErrorInfo(info) => GracefulDisconnectReason::Other(info.description())"));
    }

    #[test]
    fn a_sign_in_the_server_refused_says_why_where_the_server_did() {
        use ironrdp_connector::sspi::credssp::NStatusCode as Status;
        use ironrdp_connector::sspi::{Error, ErrorKind};
        extern "C" fn noop(_: u64, _: u32, _: i64, _: *mut u8, _: usize) {}
        let pipe = Pipe::new(crate::screen::Notifier { handle: 0, callback: noop });
        let refused = |status: Status| {
            // As sspi makes it from the server's errorCode (TsRequest::check_error).
            let e = Error::new_with_nstatus(ErrorKind::InvalidToken, "CredSSP server returned an error status", status);
            let e = ironrdp_connector::ConnectorError::new("CredSSP", ConnectorErrorKind::Credssp(e));
            connector_closed("sign-in", &e, &pipe)
        };
        for (status, name) in [
            (Status::ACCOUNT_LOCKED_OUT, Some("account_locked")),
            (Status::ACCOUNT_DISABLED, Some("account_disabled")),
            (Status::PASSWORD_EXPIRED, Some("password_expired")),
            (Status::PASSWORD_MUST_CHANGE, Some("password_expired")),
            (Status::ACCOUNT_RESTRICTION, Some("account_restricted")),
            (Status::INVALID_LOGON_HOURS, Some("account_restricted")),
            (Status::LOGON_TYPE_NOT_GRANTED, Some("account_restricted")),
            // A wrong password or name, and anything else: refused, no more.
            (Status::LOGON_FAILURE, None),
            (Status::WRONG_PASSWORD, None),
            (Status::NO_SUCH_USER, None),
            (Status::IO_TIMEOUT, None),
        ] {
            let closed = refused(status);
            assert_eq!(closed.reason, CloseReason::Auth, "{status:?}");
            assert_eq!(closed.detail, name, "{status:?}");
        }
        // No status at all (an older server, or NTLM itself failing here).
        let e = Error::new(ErrorKind::LogonDenied, "no");
        let e = ironrdp_connector::ConnectorError::new("CredSSP", ConnectorErrorKind::Credssp(e));
        let closed = connector_closed("sign-in", &e, &pipe);
        assert_eq!((closed.reason, closed.detail), (CloseReason::Auth, None));
    }

    // A server's word for its screen's size was allocated as sent (found in a review before 4.0,
    // and by reading the code).
    #[test]
    fn a_screen_size_from_the_server_past_the_largest_picture_ends_the_session() {
        assert_eq!(server_size(&Limits::default(), 3840, 2160).unwrap(), (3840, 2160));
        assert_eq!(server_size(&Limits::default(), 8192, 1012).unwrap(), (8192, 1012));
        for (w, h) in [(0, 600), (800, 0), (8193, 600), (600, 8193), (3841, 2160), (8192, 8192), (65535, 65535)] {
            let closed = server_size(&Limits::default(), w, h).unwrap_err();
            assert_eq!(closed.reason, CloseReason::Protocol, "{w} by {h}");
        }
    }

    #[test]
    fn a_server_that_changes_its_screens_size_all_the_time_is_ended() {
        let mut count = 0;
        for _ in 0..MAX_RESIZES_A_SECOND {
            resized(&mut count).unwrap();
        }
        assert_eq!(resized(&mut count).unwrap_err().reason, CloseReason::Protocol);
        // A new second starts the count again (the loop's tick sets it to 0).
        count = 0;
        resized(&mut count).unwrap();
    }

    #[test]
    fn the_size_asked_for_is_never_more_than_the_largest_picture() {
        assert_eq!(asked_size(1280, 800), (1280, 800));
        assert_eq!(asked_size(3840, 2160), (3840, 2160));
        // The width even, as the channel wants it.
        assert_eq!(asked_size(1281, 800), (1280, 800));
        for (w, h) in [(8192, 8192), (7680, 4320), (5120, 2880), (8192, 2000), (100_000, 50)] {
            let (aw, ah) = asked_size(w, h);
            assert!((aw as usize) * (ah as usize) <= MAX_PIXELS, "{w} by {h} asked as {aw} by {ah}");
            assert!((200..=8192).contains(&aw) && (200..=8192).contains(&ah) && aw % 2 == 0, "{aw} by {ah}");
            // And what is asked for is a size the app then takes from the server.
            assert!(server_size(&Limits::default(), aw as u16, ah as u16).is_ok());
        }
        // Its shape is kept, about.
        let (aw, ah) = asked_size(7680, 4320);
        assert!((f64::from(aw) / f64::from(ah) - 16.0 / 9.0).abs() < 0.01, "{aw} by {ah}");
    }

    #[test]
    fn buttons_become_presses_releases_and_wheel_notches() {
        let e = mouse_events(10, 20, 0, 1);
        assert_eq!(e.len(), 2);
        let FastPathInputEvent::MouseEvent(m) = e[1] else { panic!() };
        assert_eq!(m.flags, PointerFlags::LEFT_BUTTON | PointerFlags::DOWN);
        assert_eq!((m.x_position, m.y_position), (10, 20));
        let e = mouse_events(10, 20, 1 | 4, 4);
        let FastPathInputEvent::MouseEvent(m) = e[1] else { panic!() };
        assert_eq!(m.flags, PointerFlags::LEFT_BUTTON);
        assert_eq!(e.len(), 2);
        // A wheel notch down while the right button is held; the bit going away sends nothing.
        let e = mouse_events(1, 2, 4, 4 | 16);
        let FastPathInputEvent::MouseEvent(m) = e[1] else { panic!() };
        assert_eq!((m.flags, m.number_of_wheel_rotation_units), (PointerFlags::VERTICAL_WHEEL, -120));
        assert_eq!(mouse_events(1, 2, 4 | 16, 4).len(), 1);
        // A move alone.
        assert_eq!(mouse_events(5, 5, 0, 0).len(), 1);
    }

    #[test]
    fn movement_goes_as_relative_events_and_buttons_with_it() {
        let rel = |e: &FastPathInputEvent| match e {
            FastPathInputEvent::MouseEventRel(m) => (m.flags, m.x_delta, m.y_delta),
            other => panic!("{other:?}"),
        };
        // A movement alone.
        let e = relative_mouse_events(12, -7, 0, 0, (0, 0));
        assert_eq!(e.len(), 1);
        assert_eq!(rel(&e[0]), (PointerRelFlags::MOVE, 12, -7));
        // The left button goes down with it, the right comes up: after the movement.
        let e = relative_mouse_events(1, 1, 4, 1, (0, 0));
        assert_eq!(e.len(), 3);
        assert_eq!(rel(&e[1]), (PointerRelFlags::BUTTON1 | PointerRelFlags::DOWN, 0, 0));
        assert_eq!(rel(&e[2]), (PointerRelFlags::BUTTON2, 0, 0));
        // The middle button is the third.
        let e = relative_mouse_events(0, 0, 0, 2, (0, 0));
        assert_eq!(e.len(), 1, "no movement: no move event");
        assert_eq!(rel(&e[0]), (PointerRelFlags::BUTTON3 | PointerRelFlags::DOWN, 0, 0));
        // Nothing moved and nothing changed: nothing.
        assert!(relative_mouse_events(0, 0, 1, 1, (0, 0)).is_empty());
        // A wheel notch is the wheel event it always was, at the place the pointer last had.
        let e = relative_mouse_events(0, 0, 0, 8, (300, 200));
        let FastPathInputEvent::MouseEvent(m) = e[0] else { panic!() };
        assert_eq!((m.flags, m.number_of_wheel_rotation_units, m.x_position, m.y_position), (PointerFlags::VERTICAL_WHEEL, 120, 300, 200));
    }

    #[test]
    fn a_movement_larger_than_an_event_holds_is_split_and_one_past_all_reason_is_cut() {
        let moved = |dx: i32, dy: i32| -> (i64, i64, usize) {
            let events = relative_mouse_events(dx, dy, 0, 0, (0, 0));
            let (mut x, mut y) = (0i64, 0i64);
            for e in &events {
                let FastPathInputEvent::MouseEventRel(m) = e else { panic!() };
                assert_eq!(m.flags, PointerRelFlags::MOVE);
                x += i64::from(m.x_delta);
                y += i64::from(m.y_delta);
            }
            (x, y, events.len())
        };
        assert_eq!(moved(32_767, -32_767), (32_767, -32_767, 1));
        assert_eq!(moved(40_000, 5), (40_000, 5, 2));
        assert_eq!(moved(-100_000, 100_000), (-100_000, 100_000, 4));
        // The numbers a caller could send at worst: eight events, no overflow, no more.
        let (x, y, n) = moved(i32::MAX, i32::MIN);
        assert_eq!(n, MAX_RELATIVE_EVENTS);
        assert_eq!((x, y), (8 * 32_767, -8 * 32_767));
    }

    #[test]
    fn relative_mouse_is_asked_for_only_by_a_host_that_says_so() {
        // The connection request is the same either way (the version is said later, inside
        // TLS): nothing more crosses before TLS.
        let with = REQUEST.replace("\"rdp_h264\":\"off\"", "\"rdp_h264\":\"off\",\"rdp_relative_mouse\":true");
        assert!(with.contains("rdp_relative_mouse"));
        let refuse: &[u8] = b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x00\x08\x00\x00\x00\x00\x00";
        let (closed, sent) = closed_after_as(&with, refuse);
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
        let (_, plain) = closed_after(refuse);
        assert_eq!(sent.len(), plain.len());
        // The call is taken for any session and any numbers, and for none.
        crate::zest_screen_pointer_relative(0, i32::MAX, i32::MIN, u32::MAX);
    }

    #[test]
    fn keys_go_by_scancode_or_as_unicode() {
        // 'a' (scancode 0x1e) down, Right Ctrl (0xE0 0x1D, QEMU's 0x9d) up.
        assert_eq!(key_events(0x61, 0x1e, true), vec![FastPathInputEvent::KeyboardEvent(KeyboardFlags::empty(), 0x1e)]);
        assert_eq!(
            key_events(0xffe4, 0x9d, false),
            vec![FastPathInputEvent::KeyboardEvent(KeyboardFlags::RELEASE | KeyboardFlags::EXTENDED, 0x1d)]
        );
        // No scancode: a character goes as Unicode (one beyond the BMP as two UTF-16 units).
        assert_eq!(key_events(0xe9, 0, true), vec![FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), 0xe9)]);
        assert_eq!(key_events(0x0101_f600, 0, false).len(), 2);
        // A named key without a scancode is not sent.
        assert!(key_events(0xff0d, 0, true).is_empty());
    }

    fn stage() -> ActiveStage {
        // As a session has it (rdp::connector_config): the server's pointer on, not drawn by
        // IronRDP.
        ActiveStageBuilder {
            static_channels: Default::default(),
            user_channel_id: 1001,
            io_channel_id: 1003,
            message_channel_id: None,
            share_id: 1,
            compression_type: None,
            enable_server_pointer: true,
            pointer_software_rendering: false,
        }
        .build()
    }

    /// One fast-path update with its fragmentation (0 whole, 2 first, 3 next, 1 last).
    fn fragment(code: u8, fragmentation: u8, data: &[u8]) -> Vec<u8> {
        let total = data.len() + 6;
        let mut pdu = vec![0x00, 0x80 | (total >> 8) as u8, total as u8, code | (fragmentation << 4)];
        pdu.extend((data.len() as u16).to_le_bytes());
        pdu.extend_from_slice(data);
        pdu
    }

    /// A new pointer update ([MS-RDPBCGR] 2.2.9.1.1.4.5, fast-path code 0x0b): `side` pixels
    /// square at 32 bits, at `cache`, every pixel `rgba`.
    fn new_pointer(cache: u16, side: u16, rgba: [u8; 4]) -> Vec<u8> {
        let xor_len = usize::from(side) * usize::from(side) * 4;
        let and_len = usize::from(side).div_ceil(16) * 2 * usize::from(side);
        let mut p = Vec::new();
        for v in [32u16, cache, 1, 2, side, side, and_len as u16, xor_len as u16] {
            p.extend(v.to_le_bytes());
        }
        // The colours as the wire has them (blue, green, red, alpha), bottom row first.
        for _ in 0..usize::from(side) * usize::from(side) {
            p.extend([rgba[2], rgba[1], rgba[0], rgba[3]]);
        }
        p.extend(std::iter::repeat_n(0u8, and_len));
        p
    }

    fn pointers(outputs: &[ActiveStageOutput]) -> Vec<String> {
        outputs
            .iter()
            .filter_map(|o| match o {
                ActiveStageOutput::PointerBitmap(p) => Some(format!("shape {}x{}", p.width, p.height)),
                ActiveStageOutput::PointerHidden => Some("hidden".to_owned()),
                ActiveStageOutput::PointerDefault => Some("default".to_owned()),
                _ => None,
            })
            .collect()
    }

    // IronRDP kept the fragments of a fast-path update for as long as a server sent them, with
    // no limit (found by reading, 13 November 2026). Fixed in the app's fork of ironrdp-session.
    #[test]
    fn a_fragmented_update_without_end_ends_the_session_at_eight_megabytes() {
        let mut stage = stage();
        let mut image = DecodedImage::new(PixelFormat::RgbA32, 64, 48);
        let piece = vec![0u8; 16_000];
        let fast = ironrdp_pdu::Action::FastPath;
        stage.process(&mut image, fast, &fragment(1, 2, &piece), None).unwrap();
        let mut sent = piece.len();
        let most = ironrdp_session::fast_path::MAX_FRAGMENTED_UPDATE;
        let refused = loop {
            match stage.process(&mut image, fast, &fragment(1, 3, &piece), None) {
                Ok(_) => sent += piece.len(),
                Err(e) => break e.to_string(),
            }
            assert!(sent <= most, "{sent} bytes were kept");
        };
        assert!(refused.contains("fragmented update past"), "{refused}");
        assert!(sent > most - 2 * piece.len(), "refused only at the limit, not before: {sent}");
        // What was kept went with the error: a new update starts from nothing.
        stage.process(&mut image, fast, &fragment(1, 2, &piece), None).unwrap();
    }

    // The same day, the same way: the pointer cache took any of 65,536 places and the decoder
    // any size. Fixed in the fork; a session has the server's pointer on since this commit.
    #[test]
    fn a_pointer_shape_too_large_or_past_the_cache_is_the_systems_pointer_and_is_not_kept() {
        let mut stage = stage();
        let mut image = DecodedImage::new(PixelFormat::RgbA32, 64, 48);
        let fast = ironrdp_pdu::Action::FastPath;
        let mut tell = |update: Vec<u8>| pointers(&stage.process(&mut image, fast, &update, None).unwrap());
        // A real one: its shape comes, and comes again from the cache.
        assert_eq!(tell(fast_path_update(0x0b, &new_pointer(3, 32, [10, 20, 30, 255]))), ["shape 32x32"]);
        assert_eq!(tell(fast_path_update(0x0a, &3u16.to_le_bytes())), ["hidden", "shape 32x32"]);
        // Past the cache the client said it has (32 places): not kept.
        for cache in [32u16, 500, 65_535] {
            assert_eq!(tell(fast_path_update(0x0b, &new_pointer(cache, 32, [1, 2, 3, 255]))), ["default"], "{cache}");
            assert!(tell(fast_path_update(0x0a, &cache.to_le_bytes())).is_empty(), "place {cache} holds nothing");
        }
        // The server's own hide and default.
        assert_eq!(tell(fast_path_update(5, &[])), ["hidden"]);
        assert_eq!(tell(fast_path_update(6, &[])), ["default"]);
    }

    #[test]
    fn a_pointer_shape_larger_than_the_protocol_allows_is_not_decoded() {
        // 400 pixels a side at 1 bit a pixel is 40 KB on the wire and 640 KB decoded; the
        // protocol's largest is 384. (A large pointer update, fast-path code 0x0c, with 32-bit
        // lengths.)
        let side = 400u16;
        let stride = usize::from(side).div_ceil(16) * 2;
        let len = stride * usize::from(side);
        let mut p = Vec::new();
        for v in [1u16, 0, 0, 0, side, side] {
            p.extend(v.to_le_bytes());
        }
        p.extend((len as u32).to_le_bytes());
        p.extend((len as u32).to_le_bytes());
        p.extend(std::iter::repeat_n(0xffu8, 2 * len));
        let mut stage = stage();
        let mut image = DecodedImage::new(PixelFormat::RgbA32, 64, 48);
        let fast = ironrdp_pdu::Action::FastPath;
        // In fragments, as an update of that size comes.
        let mut outputs = Vec::new();
        let pieces: Vec<&[u8]> = p.chunks(16_000).collect();
        for (i, piece) in pieces.iter().enumerate() {
            let fragmentation = if i == 0 { 2 } else if i + 1 == pieces.len() { 1 } else { 3 };
            outputs.extend(stage.process(&mut image, fast, &fragment(0x0c, fragmentation, piece), None).unwrap());
        }
        assert_eq!(pointers(&outputs), ["default"]);
        assert!(pointers(&stage.process(&mut image, fast, &fast_path_update(0x0a, &[0, 0]), None).unwrap()).is_empty());
    }

    #[test]
    fn a_pointer_shape_goes_to_the_app_multiplied_and_a_large_one_as_the_systems() {
        use ironrdp_graphics::pointer::DecodedPointer;
        let shape = |w: u16, h: u16, px: [u8; 4]| DecodedPointer {
            width: w,
            height: h,
            hotspot_x: 5,
            hotspot_y: 600,
            bitmap_data: px.repeat(usize::from(w) * usize::from(h)),
        };
        // Half clear red: the colour is multiplied by its alpha; the hot spot stays inside.
        let (a, bytes) = cursor_shape(&shape(2, 3, [200, 100, 0, 128]));
        assert_eq!(a, 0);
        assert_eq!(bytes[..8], [2, 0, 3, 0, 1, 0, 2, 0]);
        assert_eq!(bytes.len(), 8 + 2 * 3 * 4);
        assert_eq!(bytes[8..12], [100, 50, 0, 128]);
        // Clear pixels carry no colour, solid ones theirs.
        assert_eq!(cursor_shape(&shape(1, 1, [9, 9, 9, 0])).1[8..], [0, 0, 0, 0]);
        assert_eq!(cursor_shape(&shape(1, 1, [9, 8, 7, 255])).1[8..], [9, 8, 7, 255]);
        // No size: hidden. Larger than the app takes, or pixels that are not its size: the
        // system's own pointer.
        assert_eq!(cursor_shape(&shape(0, 7, [1, 1, 1, 1])), (0, vec![0; 8]));
        assert_eq!(cursor_shape(&shape(MAX_CURSOR, MAX_CURSOR, [1, 1, 1, 255])).0, 0);
        assert_eq!(cursor_shape(&shape(MAX_CURSOR + 1, 4, [1, 1, 1, 255])), (1, vec![0; 8]));
        let mut short = shape(4, 4, [1, 1, 1, 255]);
        short.bitmap_data.truncate(10);
        assert_eq!(cursor_shape(&short), (1, vec![0; 8]));
    }

    #[test]
    fn a_server_that_takes_no_resize_is_said_once_after_five_seconds_of_waiting() {
        let mut wait = ResizeWait::default();
        // Nothing asked: nothing said, however long.
        assert!((0..100).all(|_| !wait.tick(false)));
        // A size waits: said at the fifth second, and only then.
        let said: Vec<bool> = (0..20).map(|_| wait.tick(true)).collect();
        assert_eq!(said.iter().filter(|s| **s).count(), 1);
        assert!(said[RESIZE_WAIT_SECONDS as usize - 1]);
        // The channel came after all, the size went, and a later one waits again: not said twice.
        assert!(!wait.tick(false));
        assert!((0..20).all(|_| !wait.tick(true)));
        // A size that goes within the time is never spoken of.
        let mut quick = ResizeWait::default();
        assert!(!quick.tick(true) && !quick.tick(true) && !quick.tick(false));
        assert!((0..3).all(|_| !quick.tick(true)));
    }

    #[test]
    fn the_app_is_told_twenty_pointer_shapes_a_second_and_the_last_of_a_burst() {
        let mut cursors = Cursors::default();
        let mut told = Vec::new();
        for i in 0..1000i64 {
            cursors.set((i, Vec::new()));
            told.extend(cursors.due().map(|c| c.0));
        }
        assert_eq!(told.len(), MAX_CURSORS_A_SECOND as usize);
        assert!(cursors.due().is_none());
        // The next second the last one goes, once.
        cursors.tick();
        assert_eq!(cursors.due().map(|c| c.0), Some(999));
        assert!(cursors.due().is_none());
    }

    /// A fast-path output PDU of one update (`code`, then its data).
    fn fast_path_update(code: u8, data: &[u8]) -> Vec<u8> {
        let total = u16::try_from(data.len() + 6).unwrap();
        let mut pdu = vec![0x00, 0x80 | (total >> 8) as u8, total as u8, code];
        pdu.extend((data.len() as u16).to_le_bytes());
        pdu.extend_from_slice(data);
        pdu
    }

    /// Set Surface Bits: 4 by 4 pixels at 32 bits, no codec, into (0, 0) to (`right`, `bottom`).
    fn surface_bits(right: u16, bottom: u16) -> Vec<u8> {
        let mut c = vec![1, 0, 0, 0, 0, 0];
        c.extend(right.to_le_bytes());
        c.extend(bottom.to_le_bytes());
        c.extend([32, 0, 0, 0, 4, 0, 4, 0]);
        c.extend(64u32.to_le_bytes());
        c.extend([0x40; 64]);
        fast_path_update(4, &c)
    }

    // Found by fuzzing the session after its sign-in (fuzz/fuzz_targets/rdp_session.rs), in the
    // first seed: IronRDP took 1 off the right and bottom edges of a surface
    // command's rectangle unchecked. Fixed in the app's fork of ironrdp-session.
    #[test]
    fn a_surface_command_with_an_empty_rectangle_is_refused_not_a_panic() {
        let mut stage = stage();
        let mut image = DecodedImage::new(PixelFormat::RgbA32, 64, 48);
        for (right, bottom) in [(0, 4), (4, 0), (0, 0)] {
            let pdu = surface_bits(right, bottom);
            let e = stage.process(&mut image, ironrdp_pdu::Action::FastPath, &pdu, None).err().unwrap();
            assert!(e.to_string().contains("empty destination"), "{right} by {bottom}: {e}");
        }
        // One that has a size is drawn.
        let outputs = stage.process(&mut image, ironrdp_pdu::Action::FastPath, &surface_bits(4, 4), None).unwrap();
        assert!(outputs.iter().any(|o| matches!(o, ActiveStageOutput::GraphicsUpdate(_))), "{outputs:?}");
        assert_eq!(&image.data()[..3], &[0x40, 0x40, 0x40]);
    }

    /// The share data PDU type in a frame (Suppress Output 0x23, Refresh Rect 0x21) and what
    /// follows it: the share data header's type byte sits 4 bytes before the body (type,
    /// compression type, compressed length).
    fn pdu_type_and_body(frame: &[u8]) -> (u8, Vec<u8>) {
        // The body is the frame's tail: Suppress Output is 4 bytes (+ 8 with a rectangle),
        // Refresh Rect 4 + 8 a rectangle.
        for (ty, len) in [(0x23u8, 12usize), (0x23, 4), (0x21, 12)] {
            if frame.len() > len + 4 && frame[frame.len() - len - 4] == ty {
                return (ty, frame[frame.len() - len..].to_vec());
            }
        }
        panic!("no Suppress Output or Refresh Rect in {frame:02x?}");
    }

    #[test]
    fn pause_suppresses_output_and_resume_allows_it_and_asks_for_the_screen() {
        let stage = stage();
        let pause = pause_frames(&stage, true, 1280, 800, true, true).unwrap();
        assert_eq!(pause.len(), 1);
        // allowDisplayUpdates 0, no rectangle.
        assert_eq!(pdu_type_and_body(&pause[0]), (0x23, vec![0, 0, 0, 0]));
        let resume = pause_frames(&stage, false, 1280, 800, true, true).unwrap();
        assert_eq!(resume.len(), 2);
        // allowDisplayUpdates 1 and the desktop (0, 0, 1279, 799), then Refresh Rect for it.
        assert_eq!(pdu_type_and_body(&resume[0]), (0x23, vec![1, 0, 0, 0, 0, 0, 0, 0, 0xff, 0x04, 0x1f, 0x03]));
        assert_eq!(pdu_type_and_body(&resume[1]), (0x21, vec![1, 0, 0, 0, 0, 0, 0, 0, 0xff, 0x04, 0x1f, 0x03]));
        // A server that takes neither: nothing to send.
        assert!(pause_frames(&stage, true, 1280, 800, false, false).unwrap().is_empty());
        assert!(pause_frames(&stage, false, 1280, 800, false, false).unwrap().is_empty());
        // Refresh Rect alone on resume.
        assert_eq!(pause_frames(&stage, false, 1280, 800, true, false).unwrap().len(), 1);
    }

    #[test]
    fn connector_errors_become_close_reasons() {
        use ironrdp_connector::ConnectorError;
        let n = crate::screen::Notifier { handle: 0, callback: noop };
        let pipe = Pipe::new(n);
        let denied = ConnectorError::new("log in", ConnectorErrorKind::AccessDenied);
        assert_eq!(connector_closed("log in", &denied, &pipe).reason, CloseReason::Auth);
        let general = ConnectorError::new("connection request", ConnectorErrorKind::General);
        assert_eq!(connector_closed("connection request", &general, &pipe).reason, CloseReason::Protocol);
        // The same while the channel had ended: the channel's reason.
        pipe.end_with(crate::screen::TransportEnd::Failed { reason: CloseReason::Ssh, message: "SSH: channel closed".into() });
        let c = connector_closed("connection request", &general, &pipe);
        assert_eq!((c.reason, c.message.as_str()), (CloseReason::Ssh, "SSH: channel closed"));
        // A read failing after the server closed cleanly: server_closed.
        let pipe = Pipe::new(n);
        pipe.end();
        assert_eq!(io_closed("read", "end of file", &pipe).reason, CloseReason::ServerClosed);
    }

    extern "C" fn noop(_: u64, _: u32, _: i64, _: *mut u8, _: usize) {}

    /// CLOSED's JSON by session, for the test below.
    fn closed_events() -> &'static (std::sync::Mutex<std::collections::HashMap<u64, String>>, std::sync::Condvar) {
        static C: std::sync::OnceLock<(std::sync::Mutex<std::collections::HashMap<u64, String>>, std::sync::Condvar)> =
            std::sync::OnceLock::new();
        C.get_or_init(Default::default)
    }

    /// What each session sent to its server, for the tests below.
    fn sent_bytes() -> &'static std::sync::Mutex<std::collections::HashMap<u64, Vec<u8>>> {
        static S: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<u64, Vec<u8>>>> = std::sync::OnceLock::new();
        S.get_or_init(Default::default)
    }

    extern "C" fn on_event(handle: u64, kind: u32, _: i64, data: *mut u8, len: usize) {
        let bytes = if data.is_null() {
            Vec::new()
        } else {
            // SAFETY: the session's bytes, freed once.
            let b = unsafe { std::slice::from_raw_parts(data, len) }.to_vec();
            unsafe { crate::screen::free_bytes(data, len) };
            b
        };
        if kind == crate::screen::event::SEND {
            sent_bytes().held().entry(handle).or_default().extend_from_slice(&bytes);
        }
        if kind == crate::screen::event::CLOSED {
            let (m, c) = closed_events();
            m.held().insert(handle, String::from_utf8_lossy(&bytes).into_owned());
            c.notify_all();
        }
    }

    /// A session for alex in CORP, with a password.
    const REQUEST: &str = r#"{"kind":"rdp","username":"alex","password":"hunter2-secret","domain":"CORP","server_name":"rdp.invalid","width":800,"height":600,"rdp_h264":"off"}"#;

    /// That session with `server` as the server's bytes: how it closed, and all it sent.
    fn closed_after(server: &[u8]) -> (serde_json::Value, Vec<u8>) {
        closed_after_as(REQUEST, server)
    }

    /// The same host with "Sign in without NLA".
    const REQUEST_WITHOUT_NLA: &str = r#"{"kind":"rdp","username":"alex","password":"hunter2-secret","domain":"CORP","server_name":"rdp.invalid","width":800,"height":600,"rdp_h264":"off","rdp_nla":false}"#;

    fn closed_after_as(request: &str, server: &[u8]) -> (serde_json::Value, Vec<u8>) {
        let handle = crate::screen::open(request, on_event).unwrap();
        let s = crate::screen::session(handle).unwrap();
        s.pipe.feed(server);
        let (m, c) = closed_events();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut g = m.held();
        while !g.contains_key(&handle) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!left.is_zero(), "no CLOSED");
            g = c.wait_timeout(g, left).unwrap().0;
        }
        let closed: serde_json::Value = serde_json::from_str(&g[&handle]).unwrap();
        drop(g);
        crate::screen::close(handle);
        let sent = sent_bytes().held().remove(&handle).unwrap_or_default();
        (closed, sent)
    }

    /// `word` readable in `bytes`, as bytes or as Windows writes text (UTF-16), in any case.
    fn has(bytes: &[u8], word: &str) -> bool {
        let utf16: Vec<u8> = word.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let found = |needle: &[u8]| bytes.windows(needle.len()).any(|w| w.eq_ignore_ascii_case(needle));
        found(word.as_bytes()) || found(&utf16)
    }

    /// The one message a client sends before TLS: a connection request, naming nobody.
    fn only_the_connection_request(sent: &[u8]) {
        assert!(sent.len() > 11, "nothing was sent");
        assert_eq!(&sent[..2], b"\x03\x00", "not a TPKT");
        assert_eq!(usize::from(u16::from_be_bytes([sent[2], sent[3]])), sent.len(), "more than one message was sent");
        assert_eq!(sent[5], 0xe0, "not an X.224 connection request");
        for word in ["alex", "hunter2", "CORP"] {
            assert!(!has(sent, word), "{word} left before TLS: {sent:02x?}");
        }
    }

    // The plaintext rule. Standard RDP Security (the protocol's own old
    // encryption, which proves nothing about the server) is never asked for, and a server that
    // picks it anyway gets no further.
    #[test]
    fn a_server_that_picks_rdp_without_tls_is_refused_and_told_nothing() {
        // Its Connection Confirm says PROTOCOL_RDP (0): no TLS, no NLA.
        let (closed, sent) = closed_after(b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x00\x08\x00\x00\x00\x00\x00");
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
    }

    #[test]
    fn a_server_from_before_tls_is_refused_and_told_nothing() {
        // A Connection Confirm with no negotiation answer at all (a server older than RDP 5.2,
        // or one made to look like it): Standard RDP Security by default.
        let (closed, sent) = closed_after(b"\x03\x00\x00\x0b\x06\xd0\x00\x00\x12\x34\x00");
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
    }

    #[test]
    fn a_server_that_refuses_tls_is_not_followed_down() {
        // RDP_NEG_FAILURE, SSL_NOT_ALLOWED_BY_SERVER (2): mstsc offers to go on without; we end.
        let (closed, sent) = closed_after(b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x03\x00\x08\x00\x02\x00\x00\x00");
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
    }

    /// A Connection Confirm that picks `protocol` (1 TLS alone, 2 NLA, 8 NLA with the early
    /// result), and a negotiation failure with `code`.
    fn confirm(protocol: u8) -> Vec<u8> {
        [&b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x1f\x08\x00"[..], &[protocol, 0, 0, 0]].concat()
    }

    fn failure(code: u8) -> Vec<u8> {
        [&b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x03\x00\x08\x00"[..], &[code, 0, 0, 0]].concat()
    }

    /// What a connection request asks for: its last four bytes (requestedProtocols).
    fn asked_for(sent: &[u8]) -> u32 {
        let len = usize::from(u16::from_be_bytes([sent[2], sent[3]]));
        u32::from_le_bytes(sent[len - 4..len].try_into().unwrap())
    }

    // NLA by default, "without NLA" a host's own
    // switch. Asking for NLA alone means a server cannot talk the session down to TLS with the
    // password in the Client Info PDU, which proves nothing about who receives it.
    #[test]
    fn a_host_asks_for_nla_and_nothing_less_and_a_server_that_picks_less_is_refused() {
        const HYBRID: u32 = 2;
        const HYBRID_EX: u32 = 8;
        // TLS alone picked, though it was not asked for.
        let (closed, sent) = closed_after(&confirm(1));
        assert_eq!(asked_for(&sent), HYBRID | HYBRID_EX, "{sent:02x?}");
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
        // The server says it has TLS only (SSL_REQUIRED_BY_SERVER): the host's setting does not
        // fit its server, and the app is told which way.
        let (closed, sent) = closed_after(&failure(1));
        assert_eq!(closed["reason"], "protocol", "{closed}");
        assert_eq!(closed["detail"], "nla_missing", "{closed}");
        only_the_connection_request(&sent);
        // Any other refusal is only that.
        let (closed, _) = closed_after(&failure(3));
        assert_eq!(closed["reason"], "protocol");
        assert!(closed.get("detail").is_none(), "{closed}");
    }

    #[test]
    fn without_nla_tls_alone_is_asked_for_and_a_server_that_insists_on_nla_says_so() {
        const SSL: u32 = 1;
        // HYBRID_REQUIRED_BY_SERVER, and its newer twin.
        for code in [5, 6] {
            let (closed, sent) = closed_after_as(REQUEST_WITHOUT_NLA, &failure(code));
            assert_eq!(asked_for(&sent), SSL, "{sent:02x?}");
            assert_eq!(closed["reason"], "protocol", "{closed}");
            assert_eq!(closed["detail"], "nla_required", "{closed}");
            only_the_connection_request(&sent);
        }
        // NLA picked, though the host said without: not what was asked for.
        let (closed, sent) = closed_after_as(REQUEST_WITHOUT_NLA, &confirm(2));
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
    }

    #[test]
    fn with_tls_picked_the_next_thing_sent_is_the_tls_hello() {
        // NLA picked (2), then the server goes quiet: all that follows the connection request
        // is a TLS record (a handshake, type 22), and neither names anyone.
        let handle = crate::screen::open(REQUEST, on_event).unwrap();
        let s = crate::screen::session(handle).unwrap();
        s.pipe.feed(b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x1f\x08\x00\x02\x00\x00\x00");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let sent = loop {
            let sent = sent_bytes().held().get(&handle).cloned().unwrap_or_default();
            let first = if sent.len() >= 4 { usize::from(u16::from_be_bytes([sent[2], sent[3]])) } else { usize::MAX };
            if sent.len() > first.saturating_add(5) {
                break sent;
            }
            assert!(std::time::Instant::now() < deadline, "no TLS hello after {} bytes", sent.len());
            std::thread::sleep(std::time::Duration::from_millis(10));
        };
        crate::screen::close(handle);
        let first = usize::from(u16::from_be_bytes([sent[2], sent[3]]));
        only_the_connection_request(&sent[..first]);
        assert_eq!(sent[first], 22, "not a TLS handshake record: {:02x?}", &sent[first..first + 5]);
        assert_eq!(sent[first + 1], 3, "not a TLS record version");
        for word in ["alex", "hunter2", "CORP"] {
            assert!(!has(&sent, word), "{word} is readable in the TLS hello");
        }
    }

    #[test]
    fn bytes_after_the_connection_confirm_before_tls_are_refused() {
        // Found by fuzzing: the server's Connection Confirm (NLA chosen) and, in the
        // same read, bytes no server sends before the client's TLS hello. IronRDP asserted on
        // them in a debug build (the session's thread died without CLOSED) and dropped them in
        // a release one.
        let request = r#"{"kind":"rdp","username":"alex","password":"secret","server_name":"rdp.invalid","width":800,"height":600,"rdp_h264":"off"}"#;
        let handle = crate::screen::open(request, on_event).unwrap();
        let s = crate::screen::session(handle).unwrap();
        let confirm = b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x1f\x08\x00\x02\x00\x00\x00";
        let mut bytes = confirm.to_vec();
        bytes.extend(b"\x15\x03\x03\x00\x02\x02\x28");
        s.pipe.feed(&bytes);
        let (m, c) = closed_events();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut g = m.held();
        while !g.contains_key(&handle) {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!left.is_zero(), "no CLOSED");
            g = c.wait_timeout(g, left).unwrap().0;
        }
        let closed: serde_json::Value = serde_json::from_str(&g[&handle]).unwrap();
        drop(g);
        crate::screen::close(handle);
        assert_eq!(closed["reason"], "protocol", "{closed}");
        assert_eq!(closed["message"], "the server sent 7 bytes before TLS started");
    }

    const TWO_DISPLAYS: &str = r#"{"kind":"rdp","username":"alex","password":"hunter2-secret","server_name":"rdp.invalid","rdp_h264":"off","displays":[{"x":0,"y":0,"width":1920,"height":1080},{"x":1920,"y":0,"width":1280,"height":1024,"scale":150}]}"#;

    #[test]
    fn displays_a_server_does_not_take_end_the_session_before_a_byte_is_sent() {
        // One over the other.
        let over = TWO_DISPLAYS.replace("\"x\":1920", "\"x\":1000");
        let (closed, sent) = closed_after_as(&over, b"");
        assert_eq!(closed["reason"], "internal", "{closed}");
        assert!(closed["message"].as_str().unwrap().starts_with("displays: "), "{closed}");
        assert!(sent.is_empty(), "{} bytes were sent", sent.len());
        // Five of them.
        let five: Vec<String> = (0..5).map(|i| format!(r#"{{"x":{},"y":0,"width":800,"height":600}}"#, i * 800)).collect();
        let five = format!(r#"{{"kind":"rdp","server_name":"rdp.invalid","displays":[{}]}}"#, five.join(","));
        let (closed, sent) = closed_after_as(&five, b"");
        assert!(closed["message"].as_str().unwrap().contains("at most 4"), "{closed}");
        assert!(sent.is_empty());
    }

    #[test]
    fn a_session_of_several_displays_is_offered_no_h264() {
        assert_eq!(h264_for_displays(1, H264Mode::Avc444), H264Mode::Avc444);
        assert_eq!(h264_for_displays(1, H264Mode::Avc420), H264Mode::Avc420);
        assert_eq!(h264_for_displays(2, H264Mode::Avc444), H264Mode::Off);
        assert_eq!(h264_for_displays(4, H264Mode::Avc420), H264Mode::Off);
        assert_eq!(h264_for_displays(2, H264Mode::Off), H264Mode::Off);
    }

    #[test]
    fn a_session_with_several_displays_says_no_more_before_tls_than_one_with_one() {
        // The server picks RDP without TLS: refused, and all that crossed is the connection
        // request, which names no display, no size and no person.
        let (closed, sent) = closed_after_as(TWO_DISPLAYS, b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x00\x08\x00\x00\x00\x00\x00");
        assert_eq!(closed["reason"], "protocol", "{closed}");
        only_the_connection_request(&sent);
        let (_, one) = closed_after(b"\x03\x00\x00\x13\x0e\xd0\x00\x00\x12\x34\x00\x02\x00\x08\x00\x00\x00\x00\x00");
        assert_eq!(sent.len(), one.len());
    }

    #[test]
    fn the_servers_size_is_held_against_what_was_asked_for_and_the_app_is_told_the_displays() {
        use crate::screen::rdp_layout::DisplaySpec;
        let display = |x: i32, width: u32, height: u32| DisplaySpec { x, y: 0, width, height, scale: 0, primary: false };
        let layout = Layout::of(&[display(0, 3840, 2160), display(3840, 2560, 1440)]).unwrap();
        let limits = Limits::for_layout(&layout);
        // The desktop asked for, and anything inside it.
        assert_eq!(server_size(&limits, 6400, 2160).unwrap(), (6400, 2160));
        assert!(server_size(&limits, 3840, 2160).is_ok());
        // Wider or taller than it, or nothing at all.
        for (w, h) in [(6402, 2160), (6400, 2162), (0, 600), (32_766, 32_766)] {
            let closed = server_size(&limits, w, h).unwrap_err();
            assert_eq!(closed.reason, CloseReason::Protocol, "{w} by {h}");
        }
        // The desktop asked for: its displays, in the picture's pixels. Another size (the
        // server made one screen of it): the whole picture as one display.
        assert_eq!(displays_of(&layout, 6400, 2160), serde_json::json!([[0, 0, 3840, 2160], [3840, 0, 2560, 1440]]));
        assert_eq!(displays_of(&layout, 1920, 1080), serde_json::json!([[0, 0, 1920, 1080]]));
        assert_eq!(displays_of(&Layout::single(1280, 800, 0), 1280, 800), serde_json::json!([[0, 0, 1280, 800]]));
    }

    #[test]
    fn the_displays_call_takes_a_list_of_displays_and_nothing_else() {
        let call = |json: &str| unsafe { crate::zest_screen_displays(0, json.as_ptr(), json.len()) };
        assert_eq!(call(r#"[{"x":0,"y":0,"width":1920,"height":1080,"primary":true},{"x":1920,"width":1280,"height":1024}]"#), 0);
        assert_eq!(call("[]"), 0);
        assert_eq!(call("{}"), -1);
        assert_eq!(call(r#"[{"x":0}]"#), -1, "a display without a size");
        assert_eq!(call("not json"), -1);
        assert_eq!(unsafe { crate::zest_screen_displays(0, std::ptr::null(), 0) }, -1);
    }

    #[test]
    fn the_pin_parses_with_or_without_colons() {
        let hex64 = "44909aa79bda41f449fb18c02236b07badab100d7b3fef7b16f8798e89bdaeae";
        let a = parse_sha256(hex64).unwrap();
        assert_eq!(hex(&a), hex64);
        let colons: Vec<String> = a.iter().map(|b| format!("{b:02X}")).collect();
        assert_eq!(parse_sha256(&colons.join(":")).unwrap(), a);
        assert!(parse_sha256("abc").is_err());
    }
}

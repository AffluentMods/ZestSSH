//! A VNC session on our RFB engine, over the Dart pipe.
//!
//! The engine draws straight into the session's [Framebuffer] (a [DrawTarget]), so pixels never
//! travel through the event queue; this loop hears the rest (the end of each update, resizes,
//! the clipboard) and sends the input. Updates stream by themselves when the server has
//! continuous updates (TigerVNC, with fences); otherwise the next one is asked for after each.

use crate::screen::LockAnyway as _;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::time::Instant;

use crate::vnc::engine::{
    self, ClientKeyEvent, ClientMouseEvent, ConnectOptions, Draw, DrawTarget, Rect, VncEncoding, VncError, VncEvent,
    X11Event,
};
use crate::vnc::{parse_encoding, parse_pin};

use super::{
    CloseReason, Closed, Command, DartStream, Framebuffer, Notifier, OpenRequest, Pipe, Session, event, now_us,
    run_session,
};

/// The session's thread: a runtime of its own, the handshake, then events and input until the
/// end. Always ends with CLOSED.
pub fn run(session: Arc<Session>, request: OpenRequest, notifier: Notifier) {
    run_session(notifier, || session_loop(&session, request, notifier));
}

/// The session's picture as the engine's [DrawTarget]: each rectangle goes in under the
/// picture's lock as it is decoded.
struct FrameTarget(Arc<Mutex<Framebuffer>>);

impl DrawTarget for FrameTarget {
    fn resize(&self, width: u16, height: u16) {
        self.0.held().resize(width.into(), height.into());
    }
    fn fill(&self, r: &Rect, pixel: [u8; 4]) {
        self.0.held().fill(r.x.into(), r.y.into(), r.width.into(), r.height.into(), pixel, now_us());
    }
    fn put(&self, r: &Rect, pixels: &[u8]) {
        self.0.held().put(r.x.into(), r.y.into(), r.width.into(), r.height.into(), pixels, now_us());
    }
    fn copy(&self, dst: &Rect, src: &Rect) {
        self.0.held().copy(
            dst.x.into(),
            dst.y.into(),
            src.x.into(),
            src.y.into(),
            dst.width.into(),
            dst.height.into(),
            now_us(),
        );
    }
}

fn options(request: OpenRequest, session: &Session) -> Result<ConnectOptions, String> {
    let mut options = ConnectOptions {
        username: request.username,
        password: request.password,
        tls_pin: request.tls_pin.as_deref().map(parse_pin).transpose()?,
        require_tls: request.require_tls,
        shared: request.shared.unwrap_or(true),
        continuous_updates: request.continuous_updates.unwrap_or(true),
        draw: Some(Draw(Arc::new(FrameTarget(session.frame.clone())))),
        // Closing the screen stops the decoder at its next piece of work (from a security review).
        stop: Some(session.stop.clone()),
        ..Default::default()
    };
    if let Some(names) = &request.encodings {
        options.encodings = names.iter().map(|n| parse_encoding(n)).collect::<Result<Vec<_>, _>>()?;
        // Encodings by name leave the protocol extensions as the defaults have them.
        for e in [VncEncoding::ContinuousUpdatesPseudo, VncEncoding::FencePseudo] {
            if !options.encodings.contains(&e) {
                options.encodings.push(e);
            }
        }
    }
    if !options.encodings.contains(&VncEncoding::Raw) {
        options.encodings.push(VncEncoding::Raw);
    }
    Ok(options)
}

/// An engine error as a close reason. Errors that are only how the end of the stream looked
/// from inside (end of file, the engine's tasks gone) become the transport's reason.
pub(crate) fn closed_from(e: VncError, pipe: &Pipe) -> Closed {
    let transport = |what: String| Closed::new(CloseReason::Network, what).or_transport(pipe);
    match e {
        VncError::Stopped => Closed::local(),
        // A limit against hostile servers: the engine's sentence says which.
        VncError::Excessive(m) => Closed::new(CloseReason::Protocol, m),
        VncError::UntrustedCertificate { der, .. } => Closed::certificate(&der),
        VncError::Tls(t) => Closed::new(CloseReason::Tls, format!("TLS: {t}")).or_transport_if_io(pipe, &t),
        VncError::AuthFailed(reason) => Closed::new(CloseReason::Auth, format!("the server refused the sign-in: {reason}")),
        VncError::WrongPassword => Closed::new(CloseReason::Auth, "the server refused the password"),
        VncError::NoPassword => Closed::new(CloseReason::Auth, "the server asks for a password and none was given"),
        VncError::IoError(io) => transport(format!("connection: {io}")),
        VncError::ClientNotRunning => transport("the connection ended".into()),
        VncError::General(m) if m == "Channel closed" => transport("the connection ended".into()),
        e @ (VncError::Unsupported(_)
        | VncError::InvalidSecurityTyep(_)
        | VncError::NoEncoding
        | VncError::WrongPixelFormat
        | VncError::WrongServerMessage
        | VncError::InvalidImageData
        | VncError::ConnectError
        | VncError::General(_)) => Closed::new(CloseReason::Protocol, e.to_string()).or_transport_if_eof(pipe),
    }
}

impl Closed {
    /// A TLS error that is really the stream ending (rustls reports a closed stream as an I/O
    /// error inside its own): the transport's reason when it ended.
    fn or_transport_if_io(self, pipe: &Pipe, text: &str) -> Self {
        let lower = text.to_ascii_lowercase();
        if pipe.transport_end().is_some() && (lower.contains("eof") || lower.contains("end of file") || lower.contains("closed")) {
            return self.or_transport(pipe);
        }
        self
    }

    /// A protocol error found while the stream was ending (a message cut short): the transport.
    fn or_transport_if_eof(self, pipe: &Pipe) -> Self {
        if pipe.transport_end().is_some() && pipe.queued() == 0 {
            return self.or_transport(pipe);
        }
        self
    }
}

/// [event::CURSOR]'s bytes: the size and hot spot (the rectangle's place is the hot spot, as the
/// Cursor pseudo-encoding has it), then the pixels. A shape whose pixels do not match its size is
/// sent as hidden rather than half drawn.
fn cursor_bytes(rect: &Rect, rgba: &[u8]) -> Vec<u8> {
    let (w, h) = if rgba.len() == usize::from(rect.width) * usize::from(rect.height) * 4 {
        (rect.width, rect.height)
    } else {
        (0, 0)
    };
    let mut out = Vec::with_capacity(8 + usize::from(w) * usize::from(h) * 4);
    for v in [w, h, rect.x, rect.y] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    if w > 0 && h > 0 {
        out.extend_from_slice(rgba);
    }
    out
}

enum Step {
    Command(Command),
    Event(Result<VncEvent, VncError>),
    /// A held event is due ([Paced]).
    Due,
}

/// How often Dart hears of each event a server can send for next to nothing (from a security
/// review: a BELL a byte, a cursor, a clipboard or a size an update, each a message on Dart's UI
/// isolate, whose queue has no bound). The first goes at once; within the interval after it,
/// only the latest is kept and goes when the interval is over (a bell after a bell is dropped
/// the same way). Frames are merged already (one FRAME until Dart takes the picture).
const BELL_EVERY: Duration = Duration::from_millis(250);
const CLIPBOARD_EVERY: Duration = Duration::from_millis(100);
const CURSOR_EVERY: Duration = Duration::from_millis(50);
const RESIZE_EVERY: Duration = Duration::from_millis(100);

/// One kind of event at most once per [Paced::every], the latest kept meanwhile.
struct Paced<T> {
    every: Duration,
    last: Option<Instant>,
    held: Option<T>,
}

impl<T> Paced<T> {
    fn new(every: Duration) -> Self {
        Self { every, last: None, held: None }
    }

    /// [item] to send now, or None when it is held (as the latest) until [Paced::due].
    fn offer(&mut self, item: T, now: Instant) -> Option<T> {
        match self.last {
            Some(last) if now < last + self.every => {
                self.held = Some(item);
                None
            }
            _ => {
                self.last = Some(now);
                self.held = None;
                Some(item)
            }
        }
    }

    /// When the held event may go.
    fn due(&self) -> Option<Instant> {
        self.held.as_ref().and(self.last.map(|last| last + self.every))
    }

    /// The held event, once it is due.
    fn take_due(&mut self, now: Instant) -> Option<T> {
        if self.due().is_some_and(|due| now >= due) {
            self.last = Some(now);
            return self.held.take();
        }
        None
    }
}

/// The events [Paced] holds back, and how each goes to Dart.
struct Pacing {
    bell: Paced<()>,
    clipboard: Paced<String>,
    cursor: Paced<Vec<u8>>,
    resize: Paced<i64>,
}

impl Pacing {
    fn new() -> Self {
        Self {
            bell: Paced::new(BELL_EVERY),
            clipboard: Paced::new(CLIPBOARD_EVERY),
            cursor: Paced::new(CURSOR_EVERY),
            resize: Paced::new(RESIZE_EVERY),
        }
    }

    fn due(&self) -> Option<Instant> {
        [self.bell.due(), self.clipboard.due(), self.cursor.due(), self.resize.due()].into_iter().flatten().min()
    }

    fn bell(notifier: Notifier, _: ()) {
        notifier.signal(event::BELL, 0);
    }
    fn clipboard(notifier: Notifier, text: String) {
        notifier.bytes(event::CLIPBOARD, 0, text.into_bytes());
    }
    fn cursor(notifier: Notifier, bytes: Vec<u8>) {
        notifier.bytes(event::CURSOR, 0, bytes);
    }
    fn resize(notifier: Notifier, size: i64) {
        notifier.signal(event::RESIZE, size);
    }

    /// Sends what is due.
    fn send_due(&mut self, notifier: Notifier, now: Instant) {
        if let Some(b) = self.bell.take_due(now) {
            Self::bell(notifier, b);
        }
        if let Some(t) = self.clipboard.take_due(now) {
            Self::clipboard(notifier, t);
        }
        if let Some(c) = self.cursor.take_due(now) {
            Self::cursor(notifier, c);
        }
        if let Some(r) = self.resize.take_due(now) {
            Self::resize(notifier, r);
        }
    }
}

async fn session_loop(session: &Session, request: OpenRequest, notifier: Notifier) -> Result<(), Closed> {
    let options = options(request, session).map_err(|e| Closed::new(CloseReason::Internal, e))?;
    let stream = DartStream::new(session.pipe.clone(), notifier);
    let started = now_us();
    let (client, info) = match engine::connect(stream, options).await {
        Ok(v) => v,
        // Closed by the app during the handshake: the end of the stream was ours.
        Err(_) if session.stopped() => return Ok(()),
        Err(e) => return Err(closed_from(e, &session.pipe)),
    };
    notifier.json(
        event::CONNECTED,
        serde_json::json!({
            "rfb_version": info.version,
            "security": info.security,
            "security_types_offered": info.security_types_offered,
            "tls": info.tls.map(|t| serde_json::json!({
                "subtype": t.subtype, "protocol": t.protocol, "cipher_suite": t.cipher_suite,
                "cert_sha256": engine::hex(&t.cert_sha256),
            })),
            "name": info.name,
            "width": info.width,
            "height": info.height,
            "handshake_us": now_us() - started,
        }),
    );

    let mut pacing = Pacing::new();
    let result = loop {
        // The engine takes input and gives events independently (receiving holds no lock input
        // needs), so a plain select is enough: whichever comes first; the other is cancel safe.
        let due = pacing.due();
        let step = tokio::select! {
            c = session.commands.recv() => Step::Command(c),
            e = client.recv_event() => Step::Event(e),
            () = tokio::time::sleep_until(due.unwrap_or_else(Instant::now)), if due.is_some() => Step::Due,
        };
        match step {
            Step::Due => pacing.send_due(notifier, Instant::now()),
            Step::Command(Command::Close) => break Ok(()),
            // A VNC desktop keeps its size for now (ExtendedDesktopSize's SetDesktopSize later).
            // Nor is a VNC server told movement (QEMU's own extension apart, which is not used).
            Step::Command(
                Command::Resize { .. }
                | Command::Layout(_)
                | Command::ClipboardShare(_)
                | Command::PointerRelative { .. }
                | Command::Sound(_),
            ) => {}
            Step::Command(c) => {
                let input = match c {
                    Command::Pointer { x, y, buttons } => {
                        X11Event::PointerEvent(ClientMouseEvent { position_x: x, position_y: y, bottons: buttons })
                    }
                    Command::Key { keysym, scancode: 0, down } => {
                        X11Event::KeyEvent(ClientKeyEvent { keycode: keysym, down })
                    }
                    Command::Key { keysym, scancode, down } => X11Event::ScancodeKey { keysym, scancode, down },
                    Command::Clipboard(text) => X11Event::CopyText(text),
                    Command::FullRefresh => X11Event::FullRefresh,
                    Command::Pause => X11Event::Pause,
                    Command::Resume => X11Event::Resume,
                    Command::Close
                    | Command::Resize { .. }
                    | Command::Layout(_)
                    | Command::ClipboardShare(_)
                    | Command::PointerRelative { .. }
                    | Command::Sound(_) => {
                        unreachable!()
                    }
                };
                let info = match &input {
                    X11Event::Pause => Some(serde_json::json!({
                        "paused": true,
                        "how": if client.continuous_updates() { "continuous_updates_off" } else { "no_requests" },
                    })),
                    X11Event::Resume => Some(serde_json::json!({ "paused": false })),
                    _ => None,
                };
                if let Err(e) = client.input(input).await {
                    break Err(closed_from(e, &session.pipe));
                }
                if let Some(info) = info {
                    notifier.json(event::INFO, info);
                }
            }
            Step::Event(Err(e)) => break Err(closed_from(e, &session.pipe)),
            Step::Event(Ok(ev)) => {
                let now = now_us();
                let at = Instant::now();
                match ev {
                    // The picture was resized by the engine already (before the new pixels; a
                    // frame carries its size too, so a RESIZE held back by its pacing is never
                    // needed to draw it).
                    VncEvent::SetResolution(screen) => {
                        let size = (i64::from(screen.width) << 32) | i64::from(screen.height);
                        if let Some(size) = pacing.resize.offer(size, at) {
                            Pacing::resize(notifier, size);
                        }
                    }
                    VncEvent::UpdateDone => {
                        let (tell, seq) = {
                            let mut f = session.frame.held();
                            (f.update_done(now), f.seq())
                        };
                        if tell {
                            notifier.signal(event::FRAME, seq as i64);
                        }
                        // Without continuous updates (and when not paused): the next update,
                        // asked for at once, so the server sends changes as they come (frames
                        // Dart has not taken yet are merged, never queued).
                        if client.wants_requests() {
                            if let Err(e) = client.input(X11Event::Refresh).await {
                                break Err(closed_from(e, &session.pipe));
                            }
                        }
                    }
                    VncEvent::ContinuousUpdates(on) => {
                        notifier.json(event::INFO, serde_json::json!({ "continuous_updates": on }));
                    }
                    VncEvent::Text(text) => {
                        if let Some(text) = pacing.clipboard.offer(text, at) {
                            Pacing::clipboard(notifier, text);
                        }
                    }
                    VncEvent::Bell => {
                        if let Some(b) = pacing.bell.offer((), at) {
                            Pacing::bell(notifier, b);
                        }
                    }
                    VncEvent::SetCursor(rect, rgba) => {
                        if let Some(c) = pacing.cursor.offer(cursor_bytes(&rect, &rgba), at) {
                            Pacing::cursor(notifier, c);
                        }
                    }
                    VncEvent::Error(e) => {
                        break Err(Closed::new(CloseReason::Protocol, e).or_transport(&session.pipe));
                    }
                    // Layouts, QEMU keys confirmed (the engine sends scancodes from then on),
                    // rectangle headers.
                    _ => {}
                }
            }
        }
    };
    // Closed by the app: whatever the engine said while it stopped (the end of the stream, a
    // decoder stopped mid-update) was only how that looked from inside.
    let result = if session.stopped() { Ok(()) } else { result };
    let _ = client.close().await;
    result
}

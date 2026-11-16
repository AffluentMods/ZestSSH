//! The VNC probe (feature "probes", developer builds only, never the app's): connects over TCP
//! or a Unix socket, runs the engine's handshake (None, VNC auth, Apple Remote Desktop or VeNCrypt
//! X509 with a pinned certificate), asks for RGBA pixels, waits for the first update, then reads
//! for a while longer, drawing what comes into a picture and counting the rectangles by encoding.
//! examples/vnc_probe.rs and `zest_vnc_probe` run it against tool/remote_screens_test_servers.sh.

use std::collections::BTreeMap;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

use super::engine::{self, ConnectOptions, Rect, VncEncoding, VncEvent, X11Event};
use super::{encoding_name, parse_encoding, parse_pin};

/// What to connect to, and how long to wait.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProbeRequest {
    /// Host and port of the server (or of a local SSH forward to it).
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    /// A Unix socket to connect to instead of host and port (not on Windows).
    #[serde(default)]
    pub unix_path: Option<String>,
    /// For Apple Remote Desktop and VeNCrypt X509Plain.
    #[serde(default)]
    pub username: Option<String>,
    /// The VNC password (or the account's, for ARD and X509Plain).
    #[serde(default)]
    pub password: Option<String>,
    /// VeNCrypt: the certificate's SHA-256 (hex) to trust; without it the probe reports the
    /// certificate and stops (as the app will ask the person).
    #[serde(default)]
    pub tls_pin: Option<String>,
    /// Only VeNCrypt.
    #[serde(default)]
    pub require_tls: bool,
    /// The encodings offered, in order of preference (names as in [parse_encoding], any case);
    /// the engine's defaults when not given. Raw is always added last, as RFC 6143 asks.
    #[serde(default)]
    pub encodings: Option<Vec<String>>,
    /// Text to put on the server's clipboard once connected.
    #[serde(default)]
    pub clipboard: Option<String>,
    /// The whole probe's time limit.
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// How long to keep reading updates after the first one.
    #[serde(default = "default_settle_ms")]
    pub settle_ms: u64,
}

fn default_timeout_ms() -> u64 {
    20_000
}
fn default_settle_ms() -> u64 {
    1_500
}

/// What happened. Times are milliseconds from the start.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ProbeReport {
    /// The server's banner ("RFB 003.008").
    pub rfb_version: String,
    /// The security types the server offered (RFB numbers: 1 None, 2 VNC auth, 19 VeNCrypt, 30 ARD).
    pub security_types_offered: Vec<u8>,
    /// The one used: "None", "VncAuth", "AppleRemoteDesktop" or "VeNCrypt".
    pub security_type: String,
    /// VeNCrypt: subtype, TLS version, cipher suite, certificate SHA-256.
    pub tls: Option<[String; 4]>,
    pub desktop_name: String,
    pub desktop_width: u16,
    pub desktop_height: u16,
    pub encodings_offered: Vec<String>,
    /// The rectangles of each framebuffer update, by encoding, in order (the first 20 updates).
    pub update_encodings: Vec<Vec<String>>,
    /// Every rectangle of the run, counted by encoding.
    pub rectangles_by_encoding: BTreeMap<String, u32>,
    pub updates: u32,
    /// Updates that carried no pixels before the first pixels (TigerVNC's layout-only answer;
    /// the engine asks again after each).
    pub layout_only_updates_first: u32,
    pub connect_ms: u64,
    /// Handshake, authentication and ServerInit done.
    pub connected_ms: u64,
    pub first_update_ms: u64,
    /// The first rectangle drawn: x, y, width, height.
    pub first_update: [u16; 4],
    /// Every pixel of the screen drawn at least once (None when the settle time ended first).
    pub full_screen_ms: Option<u64>,
    pub pixel_rectangles: u32,
    pub copies: u32,
    pub cursors: u32,
    pub other_events: u32,
    /// The server confirmed QEMU extended key events.
    pub qemu_key_events: bool,
    /// Text the server's clipboard sent.
    pub clipboard_received: Vec<String>,
    pub bytes_received: u64,
    pub bytes_sent: u64,
    /// Pixels that are not black in the picture after the settle time.
    pub painted_pixels: u64,
    /// The picture, RGBA, desktop_width x desktop_height.
    #[serde(skip)]
    pub rgba: Vec<u8>,
}

/// Runs the probe on a runtime of its own (one thread). Blocks.
pub fn probe(request: &ProbeRequest) -> Result<ProbeReport, String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()
        .map_err(|e| format!("runtime: {e}"))?;
    let limit = Duration::from_millis(request.timeout_ms);
    runtime.block_on(async {
        match tokio::time::timeout(limit, run(request)).await {
            Ok(result) => result,
            Err(_) => Err(format!("no first screen update within {} ms", request.timeout_ms)),
        }
    })
}

/// The JSON form: a ProbeRequest in, {"report": ...} or {"error": "..."} out.
pub fn probe_json(request: &str) -> String {
    let answer = match serde_json::from_str::<ProbeRequest>(request) {
        Ok(request) => match probe(&request) {
            Ok(report) => serde_json::json!({ "report": report }),
            Err(error) => serde_json::json!({ "error": error }),
        },
        Err(e) => serde_json::json!({ "error": format!("request: {e}") }),
    };
    answer.to_string()
}

/// Any stream the probe can run on.
trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// Bytes each way (TLS included).
#[derive(Default)]
struct Counted {
    received: u64,
    sent: u64,
}

/// The stream the engine runs on: passes everything through and counts it.
struct Tap {
    inner: Box<dyn Io>,
    counted: Arc<Mutex<Counted>>,
}

impl AsyncRead for Tap {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let poll = Pin::new(&mut *self.inner).poll_read(cx, buf);
        if let Poll::Ready(Ok(())) = &poll {
            self.counted.lock().unwrap().received += (buf.filled().len() - before) as u64;
        }
        poll
    }
}

impl AsyncWrite for Tap {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, data: &[u8]) -> Poll<std::io::Result<usize>> {
        let poll = Pin::new(&mut *self.inner).poll_write(cx, data);
        if let Poll::Ready(Ok(n)) = &poll {
            self.counted.lock().unwrap().sent += *n as u64;
        }
        poll
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut *self.inner).poll_shutdown(cx)
    }
}

async fn open(request: &ProbeRequest) -> Result<Box<dyn Io>, String> {
    if let Some(path) = &request.unix_path {
        #[cfg(unix)]
        {
            let s = tokio::net::UnixStream::connect(path).await.map_err(|e| format!("connect to {path}: {e}"))?;
            return Ok(Box::new(s));
        }
        #[cfg(not(unix))]
        return Err(format!("no Unix sockets here ({path})"));
    }
    let tcp = tokio::net::TcpStream::connect((request.host.as_str(), request.port))
        .await
        .map_err(|e| format!("TCP connect to {}:{}: {e}", request.host, request.port))?;
    tcp.set_nodelay(true).map_err(|e| format!("TCP: {e}"))?;
    Ok(Box::new(tcp))
}

async fn run(request: &ProbeRequest) -> Result<ProbeReport, String> {
    let start = Instant::now();
    let ms = |at: Instant| u64::try_from(at.duration_since(start).as_millis()).unwrap_or(u64::MAX);
    let mut report = ProbeReport::default();

    let mut options = ConnectOptions {
        username: request.username.clone(),
        password: request.password.clone().map(Into::into),
        tls_pin: request.tls_pin.as_deref().map(parse_pin).transpose()?,
        tls_server_name: (!request.host.is_empty()).then(|| request.host.clone()),
        require_tls: request.require_tls,
        ..Default::default()
    };
    if let Some(names) = &request.encodings {
        options.encodings = names.iter().map(|n| parse_encoding(n)).collect::<Result<Vec<_>, _>>()?;
    }
    if !options.encodings.contains(&VncEncoding::Raw) {
        options.encodings.push(VncEncoding::Raw);
    }
    report.encodings_offered = options.encodings.iter().map(|e| encoding_name(*e)).collect();

    let stream = open(request).await?;
    report.connect_ms = ms(Instant::now());
    let counted = Arc::new(Mutex::new(Counted::default()));
    let tap = Tap { inner: stream, counted: counted.clone() };
    let (client, info) = engine::connect(tap, options).await.map_err(|e| match e {
        engine::VncError::UntrustedCertificate { sha256, .. } => format!(
            "the server's certificate is not trusted: SHA-256 {} (pin it with ZS_VNC_TLS_PIN after checking it)",
            engine::hex(&sha256)
        ),
        e => format!("RFB handshake: {e}"),
    })?;
    report.connected_ms = ms(Instant::now());
    report.rfb_version = info.version;
    report.security_types_offered = info.security_types_offered;
    report.security_type = info.security;
    report.tls = info.tls.map(|t| [t.subtype, t.protocol, t.cipher_suite, engine::hex(&t.cert_sha256)]);
    report.desktop_name = info.name;
    // The clipboard text goes once the first pixels came (the server's extended clipboard caps
    // come with its first answers; before them the engine can only send Latin-1).
    let mut clipboard = request.clipboard.clone();

    let mut canvas = Canvas::default();
    let mut first_at: Option<Instant> = None;
    let mut last_refresh = Instant::now();
    let mut current: Vec<String> = Vec::new();
    let mut current_has_pixels = false;

    let result: Result<(), String> = async {
        loop {
            let wait = match first_at {
                // Before the first update the caller's time limit applies.
                None => Duration::from_millis(100),
                Some(at) => {
                    let end = at + Duration::from_millis(request.settle_ms);
                    let now = Instant::now();
                    if now >= end {
                        return Ok(());
                    }
                    (end - now).min(Duration::from_millis(100))
                }
            };
            let event = match tokio::time::timeout(wait, client.recv_event()).await {
                Ok(Ok(event)) => Some(event),
                Ok(Err(e)) => return Err(format!("engine: {e}")),
                Err(_) => None,
            };
            // Ask for what changed since, as a viewer does on each frame.
            if first_at.is_some() && last_refresh.elapsed() >= Duration::from_millis(100) {
                let _ = client.input(X11Event::Refresh).await;
                last_refresh = Instant::now();
            }
            let Some(event) = event else { continue };
            let drawn = match event {
                VncEvent::SetResolution(screen) => {
                    canvas.resize(screen.width as usize, screen.height as usize);
                    report.desktop_width = screen.width;
                    report.desktop_height = screen.height;
                    None
                }
                VncEvent::Rectangle(_, encoding) => {
                    let name = encoding_name(encoding);
                    *report.rectangles_by_encoding.entry(name.clone()).or_default() += 1;
                    current.push(name);
                    None
                }
                VncEvent::UpdateDone => {
                    report.updates += 1;
                    if first_at.is_none() && !current_has_pixels {
                        report.layout_only_updates_first += 1;
                    }
                    if report.update_encodings.len() < 20 {
                        report.update_encodings.push(std::mem::take(&mut current));
                    }
                    current.clear();
                    current_has_pixels = false;
                    None
                }
                VncEvent::RawImage(rect, data) => {
                    report.pixel_rectangles += 1;
                    canvas.put(&rect, Some(&data));
                    Some(rect)
                }
                VncEvent::Fill(rect, pixel) => {
                    report.pixel_rectangles += 1;
                    let picture = pixel.repeat(rect.width as usize * rect.height as usize);
                    canvas.put(&rect, Some(&picture));
                    Some(rect)
                }
                VncEvent::Copy(dst, src) => {
                    report.copies += 1;
                    let pixels = canvas.copy_out(&src);
                    canvas.put(&dst, Some(&pixels));
                    Some(dst)
                }
                VncEvent::SetCursor(..) => {
                    report.cursors += 1;
                    None
                }
                VncEvent::QemuKeyEvents => {
                    report.qemu_key_events = true;
                    None
                }
                VncEvent::Text(text) => {
                    report.clipboard_received.push(text);
                    None
                }
                VncEvent::Error(e) => return Err(format!("engine: {e}")),
                _ => {
                    report.other_events += 1;
                    None
                }
            };
            if let Some(rect) = drawn {
                current_has_pixels = true;
                if first_at.is_none() {
                    let now = Instant::now();
                    first_at = Some(now);
                    report.first_update_ms = ms(now);
                    report.first_update = [rect.x, rect.y, rect.width, rect.height];
                }
                if let Some(text) = clipboard.take() {
                    client.input(X11Event::CopyText(text)).await.map_err(|e| format!("clipboard: {e}"))?;
                }
            }
            if report.full_screen_ms.is_none() && canvas.complete() {
                report.full_screen_ms = Some(ms(Instant::now()));
            }
        }
    }
    .await;
    let _ = client.close().await;
    result?;

    let counted = counted.lock().unwrap();
    report.bytes_received = counted.received;
    report.bytes_sent = counted.sent;
    report.painted_pixels =
        canvas.rgba.chunks_exact(4).filter(|p| p[0] != 0 || p[1] != 0 || p[2] != 0).count() as u64;
    report.rgba = canvas.rgba;
    Ok(report)
}

/// The screen as the events draw it, and which pixels were drawn at least once.
#[derive(Default)]
struct Canvas {
    width: usize,
    height: usize,
    rgba: Vec<u8>,
    drawn: Vec<bool>,
    drawn_count: usize,
}

impl Canvas {
    fn resize(&mut self, width: usize, height: usize) {
        *self = Canvas {
            width,
            height,
            rgba: vec![0; width * height * 4],
            drawn: vec![false; width * height],
            drawn_count: 0,
        };
    }

    fn fits(&self, r: &Rect) -> bool {
        r.x as usize + r.width as usize <= self.width && r.y as usize + r.height as usize <= self.height
    }

    /// Draws [pixels] (RGBA, the rectangle's size) into [r], or only marks it drawn.
    fn put(&mut self, r: &Rect, pixels: Option<&[u8]>) {
        if !self.fits(r) {
            return;
        }
        let (x0, y0, w, h) = (r.x as usize, r.y as usize, r.width as usize, r.height as usize);
        for row in 0..h {
            let at = ((y0 + row) * self.width + x0) * 4;
            if let Some(src) = pixels.and_then(|p| p.get(row * w * 4..(row + 1) * w * 4)) {
                self.rgba[at..at + w * 4].copy_from_slice(src);
            }
            for col in 0..w {
                let i = (y0 + row) * self.width + x0 + col;
                if !self.drawn[i] {
                    self.drawn[i] = true;
                    self.drawn_count += 1;
                }
            }
        }
    }

    fn copy_out(&self, r: &Rect) -> Vec<u8> {
        if !self.fits(r) {
            return Vec::new();
        }
        let mut out = Vec::with_capacity(r.width as usize * r.height as usize * 4);
        for row in 0..r.height as usize {
            let at = ((r.y as usize + row) * self.width + r.x as usize) * 4;
            out.extend_from_slice(&self.rgba[at..at + r.width as usize * 4]);
        }
        out
    }

    fn complete(&self) -> bool {
        self.width > 0 && self.drawn_count == self.width * self.height
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_encodings_are_refused_before_connecting() {
        let r = ProbeRequest {
            host: "127.0.0.1".into(),
            port: 1,
            encodings: Some(vec!["CoRRE".into()]),
            timeout_ms: 1000,
            ..Default::default()
        };
        let e = probe(&r).unwrap_err();
        assert!(e.contains("CoRRE"), "{e}");
    }
}

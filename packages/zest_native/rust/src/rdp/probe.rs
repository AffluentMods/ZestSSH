//! The RDP probe (feature "probes", developer builds only, never the app's): connects over TCP,
//! upgrades to TLS (pinned, or the certificate shown taken as first seen), does NLA when the server
//! asks for it, logs in and waits for the first screen update, then a little longer for the rest.
//! examples/rdp_probe.rs and `zest_rdp_probe` run it against tool/remote_screens_test_servers.sh.

use std::time::{Duration, Instant};

use ironrdp_connector::{ClientConnector, Config};
use ironrdp_graphics::image_processing::PixelFormat;
use ironrdp_session::image::DecodedImage;
use ironrdp_session::{ActiveStageBuilder, ActiveStageOutput};
use ironrdp_tokio::{FramedWrite as _, TokioFramed};
use serde::{Deserialize, Serialize};

use super::{Graphics, Nla, SignedIn, TlsFailure, connector_config, hex, hold_credentials, parse_pin, tls_upgrade};

/// What to connect to, and how long to wait.
#[derive(Debug, Clone, Deserialize)]
pub struct ProbeRequest {
    pub host: String,
    pub port: u16,
    /// The name the certificate is checked against (the host when not given).
    #[serde(default)]
    pub server_name: Option<String>,
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default = "default_width")]
    pub width: u16,
    #[serde(default = "default_height")]
    pub height: u16,
    /// The SHA-256 of the certificate trusted before (hex): any other is refused. None: the probe
    /// takes the certificate it is shown and reports it, as a first connection would ask.
    #[serde(default)]
    pub cert_sha256: Option<String>,
    /// The whole probe's time limit.
    #[serde(default = "default_timeout_ms")]
    pub timeout_ms: u64,
    /// How long to keep reading updates after the first one.
    #[serde(default = "default_settle_ms")]
    pub settle_ms: u64,
    /// How to sign in: "required" (NLA and nothing less, as a session's default), "without" (TLS
    /// alone and no password sent, as a host's "Sign in without NLA"), or anything else, none
    /// given among it: whatever the server picks, the password in the Client Info PDU where it
    /// picks TLS alone (the probe's own way, for measuring against any test server).
    #[serde(default)]
    pub nla: Option<String>,
}

fn default_width() -> u16 {
    1280
}
fn default_height() -> u16 {
    800
}
fn default_timeout_ms() -> u64 {
    20_000
}
fn default_settle_ms() -> u64 {
    1_500
}

/// What happened. Times are milliseconds from the start.
#[derive(Debug, Clone, Serialize)]
pub struct ProbeReport {
    pub tls_version: Option<String>,
    pub tls_cipher: Option<String>,
    pub cert_sha256: String,
    /// "pinned" (it matched cert_sha256) or "first use" (nothing was pinned).
    pub cert_check: String,
    /// NLA (CredSSP) was done: the server asked for it.
    pub nla: bool,
    pub desktop_width: u16,
    pub desktop_height: u16,
    pub tcp_ms: u64,
    pub tls_ms: u64,
    pub connected_ms: u64,
    pub first_update_ms: u64,
    /// The first update's rectangle: left, top, right, bottom (inclusive).
    pub first_update: [u16; 4],
    pub updates: u32,
    pub bytes_received: u64,
    /// Pixels that are not black in the picture after the settle time.
    pub painted_pixels: u64,
    /// The picture, RGBA, desktop_width x desktop_height.
    #[serde(skip)]
    pub rgba: Vec<u8>,
}

/// Runs the probe on a runtime of its own (one thread). Blocks.
pub fn probe(request: &ProbeRequest) -> Result<ProbeReport, String> {
    // ring is the only provider rustls is built with here; installed explicitly all the same.
    let _ = rustls::crypto::ring::default_provider().install_default();
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


fn config(request: &ProbeRequest) -> Config {
    connector_config(
        request.width,
        request.height,
        request.username.clone(),
        request.password.clone(),
        request.domain.clone(),
        Graphics::Bitmap,
        match request.nla.as_deref() {
            Some("required") => Nla::Required,
            Some("without") => Nla::Without,
            // Whatever the test server picks (xrdp has no NLA, Windows asks for it).
            _ => Nla::Offered,
        },
    )
}

async fn run(request: &ProbeRequest) -> Result<ProbeReport, String> {
    let start = Instant::now();
    let ms = |at: Instant| u64::try_from(at.duration_since(start).as_millis()).unwrap_or(u64::MAX);
    let server_name = request.server_name.clone().unwrap_or_else(|| request.host.clone());
    let pin = request.cert_sha256.as_ref().map(|p| p.to_ascii_lowercase().replace(':', ""));

    let tcp = tokio::net::TcpStream::connect((request.host.as_str(), request.port))
        .await
        .map_err(|e| format!("TCP connect to {}:{}: {e}", request.host, request.port))?;
    tcp.set_nodelay(true).map_err(|e| format!("TCP: {e}"))?;
    let client_addr = tcp.local_addr().map_err(|e| format!("TCP: {e}"))?;
    let tcp_ms = ms(Instant::now());

    let mut framed = TokioFramed::new(tcp);
    let mut config = config(request);
    let credentials = hold_credentials(&mut config);
    let mut connector = ClientConnector::new(config, client_addr);
    let should_upgrade = ironrdp_tokio::connect_begin(&mut framed, &mut connector)
        .await
        .map_err(|e| format!("connection request: {e}"))?;
    // Nothing may come before TLS (see the session's stream_before_tls).
    let (tcp, leftover) = framed.into_inner();
    if !leftover.is_empty() {
        return Err(format!("the server sent {} bytes before TLS started", leftover.len()));
    }

    // Our TLS: the pinned certificate only; with no pin, the one shown is taken and reported as
    // first seen (a first connection would ask the person).
    let pin = pin.as_deref().map(parse_pin).transpose()?;
    let secured = tls_upgrade(tcp, &server_name, pin, pin.is_none()).await.map_err(|e| match e {
        TlsFailure::Untrusted { sha256: seen, .. } => format!(
            "TLS: certificate {} is not the pinned {}",
            hex(&seen),
            pin.map(|p| hex(&p)).unwrap_or_default()
        ),
        e => e.to_string(),
    })?;
    let tls_ms = ms(Instant::now());
    let cert_sha256 = hex(&secured.facts().cert_sha256);
    let cert_check = if secured.facts().pinned { "pinned" } else { "first use" };

    let SignedIn { connection, mut framed, facts, nla, .. } =
        secured.sign_in(should_upgrade, connector, credentials, &server_name).await.map_err(|e| format!("log in: {e}"))?;
    let connected_ms = ms(Instant::now());

    let (width, height) = (connection.desktop_size.width, connection.desktop_size.height);
    let mut image = DecodedImage::new(PixelFormat::RgbA32, width, height);
    let mut stage = ActiveStageBuilder {
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

    let mut first: Option<([u16; 4], u64)> = None;
    let mut settle_until: Option<Instant> = None;
    let mut updates = 0u32;
    let mut bytes_received = 0u64;
    loop {
        let read = match settle_until {
            Some(until) => {
                let left = until.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                match tokio::time::timeout(left, framed.read_pdu()).await {
                    Ok(read) => read,
                    Err(_) => break,
                }
            }
            None => framed.read_pdu().await,
        };
        let (action, payload) = read.map_err(|e| format!("session: {e}"))?;
        bytes_received += payload.len() as u64;
        let outputs = stage
            .process(&mut image, action, &payload, framed.last_read_at())
            .map_err(|e| format!("session: {e}"))?;
        for output in outputs {
            match output {
                ActiveStageOutput::ResponseFrame(frame) => {
                    framed.write_all(&frame).await.map_err(|e| format!("session: {e}"))?;
                }
                ActiveStageOutput::GraphicsUpdate(r) => {
                    updates += 1;
                    if first.is_none() {
                        first = Some(([r.left, r.top, r.right, r.bottom], ms(Instant::now())));
                        settle_until = Some(Instant::now() + Duration::from_millis(request.settle_ms));
                    }
                }
                ActiveStageOutput::Terminate(reason) => {
                    if first.is_none() {
                        return Err(format!("the server ended the session: {reason:?}"));
                    }
                    settle_until = Some(Instant::now());
                }
                _ => {}
            }
        }
    }
    // Leave politely (the session stays on the server, disconnected, as mstsc leaves it).
    if let Ok(outputs) = stage.graceful_shutdown() {
        for output in outputs {
            if let ActiveStageOutput::ResponseFrame(frame) = output {
                let _ = framed.write_all(&frame).await;
            }
        }
    }

    let (first_update, first_update_ms) = first.ok_or("no screen update")?;
    let rgba = image.data().to_vec();
    let painted_pixels = rgba.chunks_exact(4).filter(|p| p[0] != 0 || p[1] != 0 || p[2] != 0).count() as u64;
    Ok(ProbeReport {
        tls_version: Some(facts.protocol),
        tls_cipher: Some(facts.cipher_suite),
        cert_sha256,
        cert_check: cert_check.to_owned(),
        nla,
        desktop_width: width,
        desktop_height: height,
        tcp_ms,
        tls_ms,
        connected_ms,
        first_update_ms,
        first_update,
        updates,
        bytes_received,
        painted_pixels,
        rgba,
    })
}

/// The probe behind JSON: a [ProbeRequest] in, `{"report": ProbeReport}` or `{"error": "..."}` out.
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

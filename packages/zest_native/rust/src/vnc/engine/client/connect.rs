//! [connect]: the engine's front door (ours, ZestSSH). The RFB handshake and security over any
//! stream, then a running [VncClient] with our additions on.

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use super::ard;
use super::auth::AuthHelper;
pub use super::vencrypt::TlsInfo;
use super::vencrypt::{self, Io};
use crate::secret::Secret;
use crate::vnc::engine::{DrawTarget, PixelFormat, VncClient, VncEncoding, VncError};

/// The app's picture for [ConnectOptions::draw].
#[derive(Clone)]
pub struct Draw(pub std::sync::Arc<dyn DrawTarget>);

impl std::fmt::Debug for Draw {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Draw")
    }
}

/// How to connect. [Default] gives RGBA pixels, a shared session and [default_encodings].
#[derive(Debug, Clone)]
pub struct ConnectOptions {
    /// For Apple Remote Desktop and VeNCrypt X509Plain.
    pub username: Option<String>,
    /// For VNC authentication (also inside VeNCrypt), Apple Remote Desktop and X509Plain. Wiped
    /// once the security handshake is over (or failed), as are the username's bytes.
    pub password: Option<Secret>,
    /// The SHA-256 of the certificate the person accepted (VeNCrypt).
    pub tls_pin: Option<[u8; 32]>,
    /// The name sent in TLS's SNI; the pin decides trust, not the name.
    pub tls_server_name: Option<String>,
    /// Refuse every security type but VeNCrypt (for a VNC server reached without SSH).
    pub require_tls: bool,
    /// Leave other viewers connected.
    pub shared: bool,
    pub pixel_format: PixelFormat,
    /// In order of preference; Raw is added last when missing (RFC 6143 asks for it).
    pub encodings: Vec<VncEncoding>,
    /// Use continuous updates when the server has them (with Fence): the server sends changes
    /// as they come instead of one update per request and round trip. Off: the pseudo encodings
    /// are not offered, and the app asks for each update (the fallback).
    pub continuous_updates: bool,
    /// Draw pixels straight into the app's picture ([DrawTarget]) instead of sending them as
    /// events.
    pub draw: Option<Draw>,
    /// Ours: set from any thread to stop the engine at once. The decoder looks at it before each
    /// message, rectangle, RRE subrectangle and Hextile tile, so a session closes within one
    /// piece of work however much the server sent (closing a screen must never wait for a flood
    /// to be decoded). [VncClient::close] sets it too.
    pub stop: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}

impl Default for ConnectOptions {
    fn default() -> Self {
        Self {
            username: None,
            password: None,
            tls_pin: None,
            tls_server_name: None,
            require_tls: false,
            shared: true,
            pixel_format: PixelFormat::rgba(),
            encodings: default_encodings(),
            continuous_updates: true,
            draw: None,
            stop: None,
        }
    }
}

/// What the app offers by default: Tight with JPEG quality 7 and compression level 2 first (good
/// over a WAN and through SSH), then ZRLE (TigerVNC never uses TRLE), Hextile, Zlib, RRE, CopyRect,
/// and the pseudo encodings.
pub fn default_encodings() -> Vec<VncEncoding> {
    use VncEncoding::*;
    vec![
        Tight,
        Zrle,
        Hextile,
        Zlib,
        Rre,
        CopyRect,
        JpegQuality(7),
        CompressionLevel(2),
        CursorPseudo,
        ExtendedDesktopSizePseudo,
        DesktopSizePseudo,
        LastRectPseudo,
        QemuExtendedKeyEventPseudo,
        ExtendedClipboardPseudo,
        ContinuousUpdatesPseudo,
        FencePseudo,
    ]
}

/// What the server said during the handshake.
#[derive(Debug, Clone, Default)]
pub struct SessionInfo {
    /// Its banner ("RFB 003.008").
    pub version: String,
    /// The security types it offered (RFB numbers: 1 None, 2 VNC auth, 19 VeNCrypt, 30 ARD).
    pub security_types_offered: Vec<u8>,
    /// The one used: "None", "VncAuth", "AppleRemoteDesktop", "VeNCrypt".
    pub security: String,
    /// VeNCrypt's TLS session.
    pub tls: Option<TlsInfo>,
    pub name: String,
    pub width: u16,
    pub height: u16,
}

/// The RFB name of a security type.
pub fn security_type_name(t: u8) -> String {
    match t {
        1 => "None".into(),
        2 => "VncAuth".into(),
        5 => "RA2".into(),
        6 => "RA2ne".into(),
        16 => "Tight".into(),
        19 => "VeNCrypt".into(),
        30 => "AppleRemoteDesktop".into(),
        t => format!("security type {t}"),
    }
}

/// Picks the security type: VeNCrypt first (TLS), then None, then Apple Remote Desktop when a
/// username and a password are given, then VNC authentication with a password.
pub(crate) fn choose_security(offered: &[u8], options: &ConnectOptions) -> Result<u8, VncError> {
    let has_password = options.password.is_some();
    let has_user = options.username.is_some();
    let order: &[(u8, bool)] = &[
        (19, true),
        (1, !options.require_tls),
        (30, !options.require_tls && has_user && has_password),
        (2, !options.require_tls && has_password),
    ];
    for (t, usable) in order {
        if *usable && offered.contains(t) {
            return Ok(*t);
        }
    }
    let names = offered.iter().map(|t| security_type_name(*t)).collect::<Vec<_>>().join(", ");
    Err(if offered.contains(&2) || offered.contains(&30) {
        if options.require_tls {
            VncError::Unsupported(format!("the server offers {names}, none with TLS"))
        } else {
            VncError::NoPassword
        }
    } else {
        VncError::Unsupported(format!("the server offers {names}; the engine can do None, VncAuth, VeNCrypt (X509) and AppleRemoteDesktop"))
    })
}

async fn reason<S: AsyncRead + Unpin>(stream: &mut S) -> Result<String, VncError> {
    crate::vnc::engine::limits::string(stream, crate::vnc::engine::limits::MAX_NAME).await
}

/// The SecurityResult (RFC 6143, 7.1.3): 0 OK; else the reason (3.8) or "authentication failed".
async fn security_result<S: AsyncRead + Unpin>(stream: &mut S, version: u8) -> Result<(), VncError> {
    match stream.read_u32().await? {
        0 => Ok(()),
        _ if version >= 8 => Err(VncError::AuthFailed(reason(stream).await?)),
        _ => Err(VncError::AuthFailed("the server gave no reason".into())),
    }
}

/// Connects over [stream]: the RFB handshake (3.3, 3.7 or 3.8), the security type and its
/// authentication, ClientInit and ServerInit, the pixel format and the encodings, then the first
/// full update request. The events and the input go through the [VncClient].
pub async fn connect<S>(stream: S, mut options: ConnectOptions) -> Result<(VncClient, SessionInfo), VncError>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut stream: Box<dyn Io> = Box::new(stream);
    let mut info = SessionInfo::default();

    let mut banner = [0u8; 12];
    stream.read_exact(&mut banner).await?;
    info.version = String::from_utf8_lossy(&banner).trim_end().to_string();
    // Minor version: 3.8 when the server has it (or newer), 3.7, else 3.3 (RFC 6143, 7.1.1).
    let version = match &banner {
        b"RFB 003.007\n" => 7,
        b if b.starts_with(b"RFB 003.") && b[8..11] >= b"008"[..] => 8,
        b if b.starts_with(b"RFB 004.") || b.starts_with(b"RFB 005.") => 8,
        _ => 3,
    };
    stream.write_all(format!("RFB 003.00{version}\n").as_bytes()).await?;

    let chosen = if version == 3 {
        // The server decides: a U32.
        let t = stream.read_u32().await?;
        if t == 0 {
            return Err(VncError::General(reason(&mut stream).await?));
        }
        let t = u8::try_from(t).map_err(|_| VncError::InvalidSecurityTyep(255))?;
        info.security_types_offered = vec![t];
        if !matches!(t, 1 | 2) || options.require_tls {
            return Err(choose_security(&[t], &options).err().unwrap_or(VncError::InvalidSecurityTyep(t)));
        }
        t
    } else {
        let count = stream.read_u8().await? as usize;
        if count == 0 {
            return Err(VncError::General(reason(&mut stream).await?));
        }
        let mut offered = vec![0u8; count];
        stream.read_exact(&mut offered).await?;
        info.security_types_offered = offered.clone();
        let t = choose_security(&offered, &options)?;
        stream.write_all(&[t]).await?;
        t
    };
    info.security = security_type_name(chosen);

    let password = options.password.as_deref();
    match chosen {
        1 => {
            if version == 8 {
                security_result(&mut stream, version).await?;
            }
        }
        2 => {
            let auth = AuthHelper::read(&mut stream, password.ok_or(VncError::NoPassword)?).await?;
            auth.write(&mut stream).await?;
            security_result(&mut stream, version).await?;
        }
        30 => {
            let user = options.username.as_deref().ok_or(VncError::NoPassword)?;
            ard::authenticate(&mut stream, user, password.ok_or(VncError::NoPassword)?).await?;
            security_result(&mut stream, version).await?;
        }
        19 => {
            let server_name = options.tls_server_name.clone().unwrap_or_else(|| "vnc.invalid".into());
            let vencrypt_options = vencrypt::Options {
                username: options.username.as_deref(),
                password,
                pin: options.tls_pin,
                server_name: &server_name,
            };
            let (tls, tls_info) = vencrypt::negotiate(stream, &vencrypt_options).await?;
            stream = tls;
            info.tls = Some(tls_info);
            security_result(&mut stream, 8).await?;
        }
        _ => unreachable!("chosen from the supported ones"),
    }
    // The credentials are not needed again: wiped now, not when the session ends. (An early
    // return above wipes them too, as the options are dropped.)
    drop(options.password.take());
    drop(options.username.take().map(Secret::from));

    let mut encodings = options.encodings.clone();
    if !options.continuous_updates {
        encodings.retain(|e| !matches!(e, VncEncoding::ContinuousUpdatesPseudo | VncEncoding::FencePseudo));
    }
    if !encodings.contains(&VncEncoding::Raw) {
        encodings.push(VncEncoding::Raw);
    }
    if encodings.iter().all(|e| e.is_level()) {
        return Err(VncError::NoEncoding);
    }
    options.pixel_format.validate()?;
    let client = VncClient::start(
        stream,
        options.shared,
        Some(options.pixel_format),
        encodings,
        true,
        options.draw.map(|d| d.0),
        options.stop,
    )
    .await?;
    info.name = client.desktop_name().await;
    (info.width, info.height) = client.screen_size().await;
    Ok((client, info))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vnc::engine::{Rect, VncEvent, X11Event};
    use std::time::Duration;
    use tokio::io::{duplex, DuplexStream};

    fn opts(password: Option<&str>) -> ConnectOptions {
        ConnectOptions { password: password.map(Into::into), ..Default::default() }
    }

    #[test]
    fn security_preference_and_refusals() {
        assert_eq!(choose_security(&[2, 19, 1], &opts(None)).unwrap(), 19);
        assert_eq!(choose_security(&[2, 1], &opts(Some("p"))).unwrap(), 1);
        assert_eq!(choose_security(&[2, 30], &opts(Some("p"))).unwrap(), 2);
        let ard = ConnectOptions { username: Some("u".into()), ..opts(Some("p")) };
        assert_eq!(choose_security(&[2, 30], &ard).unwrap(), 30);
        assert!(matches!(choose_security(&[2], &opts(None)), Err(VncError::NoPassword)));
        let tls_only = ConnectOptions { require_tls: true, ..opts(Some("p")) };
        assert!(matches!(choose_security(&[1, 2], &tls_only), Err(VncError::Unsupported(_))));
        assert!(matches!(choose_security(&[5, 16], &opts(Some("p"))), Err(VncError::Unsupported(_))));
    }

    async fn server_init(server: &mut DuplexStream, width: u16, height: u16) {
        server.write_u16(width).await.unwrap();
        server.write_u16(height).await.unwrap();
        server.write_all(&Vec::<u8>::from(PixelFormat::rgba())).await.unwrap();
        server.write_u32(4).await.unwrap();
        server.write_all(b"demo").await.unwrap();
    }

    fn header(x: u16, y: u16, w: u16, h: u16, encoding: i32) -> Vec<u8> {
        let mut b = Vec::new();
        for v in [x, y, w, h] {
            b.extend(v.to_be_bytes());
        }
        b.extend(encoding.to_be_bytes());
        b
    }

    async fn next(client: &VncClient) -> VncEvent {
        tokio::time::timeout(Duration::from_secs(2), client.recv_event()).await.unwrap().unwrap()
    }

    /// Reads the client's messages up to and including the next FramebufferUpdateRequest,
    /// returning it (incremental flag, x, y, w, h) and the extended clipboard bodies seen.
    async fn read_until_request(server: &mut DuplexStream) -> ((u8, u16, u16, u16, u16), Vec<Vec<u8>>) {
        let mut clip = Vec::new();
        loop {
            match server.read_u8().await.unwrap() {
                0 => {
                    let mut pf = [0; 19];
                    server.read_exact(&mut pf).await.unwrap();
                }
                2 => {
                    server.read_u8().await.unwrap();
                    let n = server.read_u16().await.unwrap();
                    let mut e = vec![0; 4 * n as usize];
                    server.read_exact(&mut e).await.unwrap();
                }
                3 => {
                    let inc = server.read_u8().await.unwrap();
                    let mut r = [0u16; 4];
                    for v in &mut r {
                        *v = server.read_u16().await.unwrap();
                    }
                    return ((inc, r[0], r[1], r[2], r[3]), clip);
                }
                6 => {
                    let mut pad = [0; 3];
                    server.read_exact(&mut pad).await.unwrap();
                    let len = server.read_i32().await.unwrap();
                    let mut body = vec![0; len.unsigned_abs() as usize];
                    server.read_exact(&mut body).await.unwrap();
                    if len < 0 {
                        clip.push(body);
                    }
                }
                other => panic!("unexpected client message {other}"),
            }
        }
    }

    #[tokio::test]
    async fn layout_first_then_pixels_rectangles_and_the_end_of_each_update() {
        let (stream, mut server) = duplex(1 << 16);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            server.write_all(&[1, 2]).await.unwrap();
            let mut got = [0u8; 13];
            server.read_exact(&mut got).await.unwrap();
            assert_eq!(got[12], 2);
            let mut challenge_answer = [0u8; 16];
            server.write_all(&[0; 16]).await.unwrap();
            server.read_exact(&mut challenge_answer).await.unwrap();
            server.write_u32(0).await.unwrap();
            assert_eq!(server.read_u8().await.unwrap(), 1); // shared
            server_init(&mut server, 4, 2).await;
            // The first full request: answered with the layout alone, as TigerVNC does.
            let (req, _) = read_until_request(&mut server).await;
            assert_eq!(req, (0, 0, 0, 4, 2));
            let mut b = vec![0, 0, 0, 1];
            b.extend(header(0, 0, 4, 2, -308));
            b.extend([1, 0, 0, 0]);
            b.extend(1u32.to_be_bytes());
            b.extend([0, 0, 0, 0, 0, 4, 0, 2]);
            b.extend(0u32.to_be_bytes());
            server.write_all(&b).await.unwrap();
            // The engine asks again (incremental: the whole screen is owed already).
            let (req, _) = read_until_request(&mut server).await;
            assert_eq!(req, (1, 0, 0, 4, 2));
            // Pixels: one Hextile tile, a solid background.
            let mut b = vec![0, 0, 0, 1];
            b.extend(header(0, 0, 4, 2, 5));
            b.push(2);
            b.extend([9, 8, 7, 255]);
            server.write_all(&b).await.unwrap();
            server
        });
        let (client, info) = connect(stream, opts(Some("pw"))).await.unwrap();
        assert_eq!((info.security.as_str(), info.name.as_str(), info.width, info.height), ("VncAuth", "demo", 4, 2));
        assert_eq!(info.security_types_offered, vec![2]);
        assert!(matches!(next(&client).await, VncEvent::SetResolution(_)));
        assert!(matches!(next(&client).await, VncEvent::Rectangle(_, VncEncoding::ExtendedDesktopSizePseudo)));
        assert!(matches!(next(&client).await, VncEvent::DesktopUpdate(_)));
        assert!(matches!(next(&client).await, VncEvent::UpdateDone));
        assert!(matches!(next(&client).await, VncEvent::Rectangle(Rect { width: 4, height: 2, .. }, VncEncoding::Hextile)));
        assert!(matches!(next(&client).await, VncEvent::RawImage(_, p) if p == [9, 8, 7, 255].repeat(8)));
        assert!(matches!(next(&client).await, VncEvent::UpdateDone));
        let _server = task.await.unwrap();
        let _ = client.close().await;
    }

    #[tokio::test]
    async fn extended_clipboard_and_qemu_keys() {
        let (stream, mut server) = duplex(1 << 16);
        let (to_test, mut from_server) = tokio::sync::mpsc::channel::<Vec<u8>>(8);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            server.write_all(&[1, 1]).await.unwrap();
            let mut got = [0u8; 13];
            server.read_exact(&mut got).await.unwrap();
            server.write_u32(0).await.unwrap();
            server.read_u8().await.unwrap();
            server_init(&mut server, 2, 2).await;
            read_until_request(&mut server).await;
            // QEMU key events confirmed, and the server's clipboard caps.
            let mut b = vec![0, 0, 0, 1];
            b.extend(header(0, 0, 2, 2, -258));
            let caps = super::super::clipboard::CAPS
                | super::super::clipboard::TEXT
                | super::super::clipboard::REQUEST
                | super::super::clipboard::NOTIFY
                | super::super::clipboard::PROVIDE;
            let mut body = caps.to_be_bytes().to_vec();
            body.extend(0u32.to_be_bytes());
            b.extend([3, 0, 0, 0]);
            b.extend((-(body.len() as i32)).to_be_bytes());
            b.extend(&body);
            // Then a notify that text is there.
            let notify = super::super::clipboard::notify(true);
            b.extend([3, 0, 0, 0]);
            b.extend((-(notify.len() as i32)).to_be_bytes());
            b.extend(&notify);
            server.write_all(&b).await.unwrap();
            // Everything the client sends from now on goes to the test.
            let mut buf = [0u8; 4096];
            loop {
                let n = server.read(&mut buf).await.unwrap();
                if n == 0 || to_test.send(buf[..n].to_vec()).await.is_err() {
                    break;
                }
                if buf[..n].contains(&255) {
                    // After the QEMU key event, provide the text the client asked for.
                    let provide = super::super::clipboard::provide(Some("héllo\nwörld"));
                    let mut b = vec![3, 0, 0, 0];
                    b.extend((-(provide.len() as i32)).to_be_bytes());
                    b.extend(&provide);
                    server.write_all(&b).await.unwrap();
                }
            }
        });
        let (client, info) = connect(stream, opts(None)).await.unwrap();
        assert_eq!(info.security, "None");
        loop {
            if let VncEvent::QemuKeyEvents = next(&client).await {
                break;
            }
        }
        // Give the decoder time to take the caps and answer the notify.
        // The update with the QEMU rectangle carried no pixels, so the engine also asks for the
        // screen again (an incremental FramebufferUpdateRequest, 10 bytes): leave those out.
        let mut sent = Vec::new();
        while sent.len() < (8 + 8) + (8 + 4) {
            sent.extend(tokio::time::timeout(Duration::from_secs(2), from_server.recv()).await.unwrap().unwrap());
            while sent.first() == Some(&3) && sent.len() >= 10 {
                sent.drain(..10);
            }
        }
        // Our caps (ClientCutText, length -8), then a request for the text (length -4).
        let mut want = vec![6, 0, 0, 0];
        want.extend((-8i32).to_be_bytes());
        want.extend(super::super::clipboard::caps());
        want.extend([6, 0, 0, 0]);
        want.extend((-4i32).to_be_bytes());
        want.extend(super::super::clipboard::request_text());
        assert_eq!(sent[..want.len()], want[..]);

        client.input(X11Event::ScancodeKey { keysym: 0xff53, scancode: 0xcd, down: true }).await.unwrap();
        let key = tokio::time::timeout(Duration::from_secs(2), from_server.recv()).await.unwrap().unwrap();
        assert_eq!(key, [255, 0, 0, 1, 0, 0, 0xff, 0x53, 0, 0, 0, 0xcd]);
        loop {
            match next(&client).await {
                VncEvent::Text(t) => {
                    assert_eq!(t, "héllo\nwörld");
                    break;
                }
                _ => continue,
            }
        }
        // Copying sends a notify (the server takes notify).
        client.input(X11Event::CopyText("ü".into())).await.unwrap();
        let notify = tokio::time::timeout(Duration::from_secs(2), from_server.recv()).await.unwrap().unwrap();
        let mut want = vec![6, 0, 0, 0];
        want.extend((-4i32).to_be_bytes());
        want.extend(super::super::clipboard::notify(true));
        assert_eq!(notify, want);
        let _ = client.close().await;
        drop(from_server);
        let _ = task.await;
    }

    #[tokio::test]
    async fn a_failed_authentication_gives_the_servers_reason() {
        let (stream, mut server) = duplex(1024);
        server.write_all(b"RFB 003.008\n").await.unwrap();
        server.write_all(&[1, 2]).await.unwrap();
        server.write_all(&[0; 16]).await.unwrap();
        server.write_u32(1).await.unwrap();
        server.write_u32(6).await.unwrap();
        server.write_all(b"denied").await.unwrap();
        let e = connect(stream, opts(Some("x"))).await.err().unwrap();
        assert!(matches!(&e, VncError::AuthFailed(r) if r == "denied"), "{e}");
        assert_eq!(e.to_string(), "authentication failed: denied");
    }
}

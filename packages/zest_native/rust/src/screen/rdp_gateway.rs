//! RD Gateway (4.0): an RDP session reached through a Remote Desktop Gateway, as
//! Windows' own client reaches one (MS-TSGU, its HTTP transport upgraded to a WebSocket).
//!
//! The engine opens no connection of its own: the app hands it the TCP connection to the gateway
//! as it hands it any other, and everything here runs on that one stream, in order:
//!
//! 1. TLS to the gateway under the gateway's own name ([gateway_tls]). Trusted when an authority
//!    vouches for it (Mozilla's roots, and the system's own check on Windows), or by the SHA-256
//!    the person accepted for the gateway, pinned apart from the PC's. Any other certificate ends
//!    the session with it and the detail `gateway`, so the app asks about the gateway's.
//! 2. `RDG_OUT_DATA /remoteDesktopGateway/` asking for a WebSocket, signed in with NTLM in the
//!    HTTP headers (sspi, as CredSSP's), all on that one connection ([upgrade]): a redirect is
//!    not followed, and nothing else is connected to. The sign-in is bound to that TLS
//!    connection (RFC 5929's `tls-server-end-point`, Windows' Extended Protection, which a
//!    gateway may insist on): a sign-in taken from it would not be accepted on another.
//! 3. MS-TSGU inside the WebSocket ([tunnel]): the handshake, the tunnel, the tunnel's sign-in,
//!    and the channel to the PC.
//! 4. The channel's bytes as a stream ([open]): the RDP connection, its own TLS to the PC (the
//!    PC's pin) and NLA included, runs inside it exactly as it runs over an SSH channel. So the
//!    gateway sees which PC is asked for and carries the PC's TLS, which it cannot read.
//!
//! Bounded: an HTTP answer's head at [MAX_HEAD] bytes and [MAX_HEADER_LINES] lines, a body that
//! comes with a refusal skipped up to [MAX_SKIPPED_BODY], three HTTP rounds, a WebSocket message
//! at [MAX_MESSAGE] (one MS-TSGU packet each), each step of the setting up at [STEP_TIMEOUT]. A
//! byte of the gateway's that cannot be read ends the session with what it was; nothing here
//! panics on one (fuzz/fuzz_targets/rdp_gateway.rs).
//!
//! Not done (said by the session's end, never fallen back to): the older transport of two HTTP
//! connections (a gateway that answers 200), a sign-in other than NTLM (Basic, Digest, a smart
//! card, the gateway's own cookie), a gateway that asks for a consent message to be shown, and
//! one that asks to sign in again while the session runs.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use ironrdp_connector::sspi::{
    self, AuthIdentity, BufferType, ClientRequestFlags, CredentialUse, DataRepresentation, SecurityBuffer, SecurityStatus,
    Sspi as _, SspiImpl as _, Username,
};
use rustls::pki_types::ServerName;
use tokio::io::{AsyncRead, AsyncReadExt as _, AsyncWrite, AsyncWriteExt as _, DuplexStream};

use super::{CloseReason, Closed, GatewayRequest};
use crate::ftps::verify::{Policy, ZestVerifier};

/// The head of one HTTP answer (its status line and headers) may be this long.
pub(crate) const MAX_HEAD: usize = 16 * 1024;
/// And hold this many lines.
pub(crate) const MAX_HEADER_LINES: usize = 64;
/// A refusal's body (a 401's) is read past up to this long; a longer one ends the session.
pub(crate) const MAX_SKIPPED_BODY: usize = 64 * 1024;
/// Asked without a sign-in (what the gateway offers), NTLM's first message, NTLM's last.
const MAX_ROUNDS: usize = 3;
/// One MS-TSGU packet comes in one WebSocket message, and the longest a gateway sends is a data
/// packet: its header, its length, and 65,535 bytes.
pub(crate) const MAX_MESSAGE: usize = 8 + 2 + 65_535;
/// Each step of the setting up: one HTTP round (its head and a refusal's body), one packet of
/// the tunnel's (however many keepalives, pings or service messages come before it).
#[cfg(not(test))]
pub(crate) const STEP_TIMEOUT: Duration = Duration::from_secs(20);
#[cfg(test)]
pub(crate) const STEP_TIMEOUT: Duration = Duration::from_secs(2);
/// The TLS handshake to the gateway, and then the whole of the rest of the setting up (the HTTP
/// rounds, the tunnel and the channel), each at most this.
#[cfg(not(test))]
pub(crate) const SETUP_TIMEOUT: Duration = Duration::from_secs(60);
#[cfg(test)]
pub(crate) const SETUP_TIMEOUT: Duration = Duration::from_secs(5);
/// The most of the gateway's data waiting for the session to read it; while it is full, the
/// gateway is not read (its TCP slows it), and the session's own bytes still go out.
const MAX_PENDING: usize = 256 * 1024;
/// A keepalive while nothing else goes (a gateway ends an idle tunnel).
const KEEPALIVE: Duration = Duration::from_secs(5 * 60);
/// A ping is answered at most this often: a pong goes to the app's socket whatever the gateway
/// reads, so one for every ping would let a gateway that pings without end, and reads nothing,
/// fill the app's memory with them. (RFC 6455 lets a client answer the latest ping only.)
const PONG_EVERY: Duration = Duration::from_secs(1);
/// How much of the session's bytes go in one data packet.
const DATA_CHUNK: usize = 16 * 1024;
/// The name the tunnel's sign-in gives for this device (as the RDP connection's client name).
const CLIENT_NAME: &str = "zestssh";
/// The PC's port when the host does not say.
pub(crate) const DEFAULT_TARGET_PORT: u16 = 3389;

// MS-TSGU packet types (2.2.5.3.3, HTTP_PACKET_TYPE).
pub(crate) const PKT_HANDSHAKE_REQUEST: u16 = 0x01;
pub(crate) const PKT_HANDSHAKE_RESPONSE: u16 = 0x02;
pub(crate) const PKT_EXTENDED_AUTH: u16 = 0x03;
pub(crate) const PKT_TUNNEL_CREATE: u16 = 0x04;
pub(crate) const PKT_TUNNEL_RESPONSE: u16 = 0x05;
pub(crate) const PKT_TUNNEL_AUTH: u16 = 0x06;
pub(crate) const PKT_TUNNEL_AUTH_RESPONSE: u16 = 0x07;
pub(crate) const PKT_CHANNEL_CREATE: u16 = 0x08;
pub(crate) const PKT_CHANNEL_RESPONSE: u16 = 0x09;
pub(crate) const PKT_DATA: u16 = 0x0A;
pub(crate) const PKT_SERVICE_MESSAGE: u16 = 0x0B;
pub(crate) const PKT_REAUTH_MESSAGE: u16 = 0x0C;
pub(crate) const PKT_KEEPALIVE: u16 = 0x0D;
pub(crate) const PKT_CLOSE_CHANNEL: u16 = 0x10;
pub(crate) const PKT_CLOSE_CHANNEL_RESPONSE: u16 = 0x11;

/// The tunnel's capabilities asked for: the consent message and signing in again (what Windows'
/// client says; gateways were seen to refuse a tunnel without them). A gateway that then sends
/// either is refused with words, not followed.
const TUNNEL_CAPS: u32 = 0x04 | 0x10;
/// The channel's protocol: RDP.
const CHANNEL_PROTOCOL_RDP: u16 = 3;

/// Where the gateway's end goes when it ends the stream it handed the session, so the session
/// says the gateway's reason rather than "the connection ended".
pub type GatewayEnd = Arc<Mutex<Option<Closed>>>;

fn protocol(what: impl std::fmt::Display) -> Closed {
    Closed::new(CloseReason::Protocol, format!("RD Gateway: {what}"))
}

fn network(what: &str, e: impl std::fmt::Display) -> Closed {
    Closed::new(CloseReason::Network, format!("RD Gateway, {what}: {e}"))
}

fn timed_out(what: &str) -> Closed {
    Closed::new(CloseReason::Network, format!("RD Gateway: no answer to {what} within {} seconds", STEP_TIMEOUT.as_secs()))
}

/// The session's stream through the gateway: TLS to it, the HTTP sign-in, the tunnel and the
/// channel to the PC, then the channel's bytes, carried by a task of their own. What ended that
/// task, where it was not the session, goes into the [GatewayEnd].
pub(crate) async fn open<S>(stream: S, gw: &GatewayRequest) -> Result<(DuplexStream, GatewayEnd), Closed>
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let pin = gw.tls_pin.as_deref().map(super::parse_sha256).transpose().map_err(|e| Closed::new(CloseReason::Internal, e))?;
    let tls = tokio::time::timeout(SETUP_TIMEOUT, gateway_tls(stream, &gw.host, pin))
        .await
        .map_err(|_| Closed::new(CloseReason::Network, format!("RD Gateway: no TLS within {} seconds", SETUP_TIMEOUT.as_secs())))??;
    let binding = tls.get_ref().1.peer_certificates().and_then(|c| c.first()).map(|der| tls_server_end_point(der.as_ref()));
    through(tls, gw, binding).await
}

/// RFC 5929's `tls-server-end-point` for the gateway's certificate, as NTLM binds a sign-in to
/// it: the label and the certificate's hash, by the hash its signature uses (SHA-256 for MD5,
/// SHA-1 and SHA-256, and for any it does not know).
pub(crate) fn tls_server_end_point(der: &[u8]) -> Vec<u8> {
    use sha2::Digest as _;
    use x509_cert::der::Decode as _;
    let oid = x509_cert::Certificate::from_der(der).map(|c| c.signature_algorithm().oid.to_string()).unwrap_or_default();
    let hash: Vec<u8> = match oid.as_str() {
        // sha384WithRSAEncryption, ecdsa-with-SHA384
        "1.2.840.113549.1.1.12" | "1.2.840.10045.4.3.3" => sha2::Sha384::digest(der).to_vec(),
        // sha512WithRSAEncryption, ecdsa-with-SHA512
        "1.2.840.113549.1.1.13" | "1.2.840.10045.4.3.4" => sha2::Sha512::digest(der).to_vec(),
        _ => sha2::Sha256::digest(der).to_vec(),
    };
    let mut out = b"tls-server-end-point:".to_vec();
    out.extend_from_slice(&hash);
    out
}

/// Everything after TLS (the tests and the fuzz target start here). `binding` is TLS's channel
/// binding for the NTLM sign-in ([tls_server_end_point]).
pub async fn through<T>(tls: T, gw: &GatewayRequest, binding: Option<Vec<u8>>) -> Result<(DuplexStream, GatewayEnd), Closed>
where
    T: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let target = gw.target.trim();
    if target.is_empty() {
        return Err(Closed::new(CloseReason::Internal, "RD Gateway: no PC named"));
    }
    let port = gw.target_port.unwrap_or(DEFAULT_TARGET_PORT);
    let (read, write) = tokio::io::split(tls);
    let mut writer = WsWriter::new(write);
    let mut leftover = Vec::new();
    let mut read = read;
    // The whole of the setting up within SETUP_TIMEOUT, whatever its steps do.
    let reader = tokio::time::timeout(SETUP_TIMEOUT, async {
        upgrade(&mut read, &mut writer, &mut leftover, gw, binding.as_deref()).await?;
        let mut reader = WsReader::new(read, std::mem::take(&mut leftover));
        tunnel(&mut reader, &mut writer, target, port).await?;
        Ok::<_, Closed>(reader)
    })
    .await
    .map_err(|_| {
        Closed::new(CloseReason::Network, format!("RD Gateway: the tunnel was not open within {} seconds", SETUP_TIMEOUT.as_secs()))
    })??;
    let (session_side, ours) = tokio::io::duplex(4 * DATA_CHUNK);
    let end: GatewayEnd = Arc::new(Mutex::new(None));
    let said = end.clone();
    tokio::spawn(async move {
        if let Err(e) = carry(reader, writer, ours).await {
            *said.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(e);
        }
    });
    Ok((session_side, end))
}

/// What the gateway's certificate is checked by: a certificate accepted for this gateway is the
/// only one taken from then on, as a host key is (a different one is asked about, whoever signed
/// it); before one is accepted, an authority's for the gateway's name is taken.
pub(crate) fn gateway_policy(pin: Option<[u8; 32]>) -> Policy {
    Policy { pinned: pin, allow_authority: pin.is_none() }
}

/// TLS to the gateway: an authority's certificate for its name, or the one pinned for it. No
/// key log, no resumption.
async fn gateway_tls<S>(stream: S, host: &str, pin: Option<[u8; 32]>) -> Result<tokio_rustls::client::TlsStream<S>, Closed>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let verifier = Arc::new(
        ZestVerifier::new(provider.clone(), gateway_policy(pin)).map_err(|e| Closed::new(CloseReason::Internal, e))?,
    );
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| Closed::new(CloseReason::Internal, e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(verifier.clone())
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();
    let name = ServerName::try_from(host.trim_start_matches('[').trim_end_matches(']').to_owned())
        .map_err(|_| Closed::new(CloseReason::Internal, format!("RD Gateway: {host:?} is not a name TLS takes")))?;
    match tokio_rustls::TlsConnector::from(Arc::new(config)).connect(name, stream).await {
        Ok(tls) => Ok(tls),
        Err(e) => match verifier.refused() {
            Some(seen) => Err(Closed::certificate(&seen.der).with_detail("gateway")),
            None => Err(Closed::new(CloseReason::Tls, format!("RD Gateway TLS: {e}"))),
        },
    }
}

// HTTP: the upgrade and its sign-in.

/// The head of an HTTP answer, as far as the upgrade needs it.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Head {
    pub status: u16,
    /// Every `WWW-Authenticate` value, as sent.
    pub authenticate: Vec<String>,
    pub content_length: Option<usize>,
    pub chunked: bool,
    pub close: bool,
    pub upgrade_websocket: bool,
}

/// Reads an answer's head from `bytes` (without its blank line).
pub fn parse_head(bytes: &[u8]) -> Result<Head, Closed> {
    let text = std::str::from_utf8(bytes).map_err(|_| protocol("an answer's head is not text"))?;
    let mut lines = text.split("\r\n");
    let status_line = lines.next().unwrap_or_default();
    let mut parts = status_line.splitn(3, ' ');
    let version = parts.next().unwrap_or_default();
    let code = parts.next().unwrap_or_default();
    if !version.starts_with("HTTP/1.") || code.len() != 3 || !code.bytes().all(|b| b.is_ascii_digit()) {
        return Err(protocol("not an HTTP answer"));
    }
    let mut head = Head { status: code.parse().unwrap_or(0), ..Head::default() };
    for (i, line) in lines.enumerate() {
        if i >= MAX_HEADER_LINES {
            return Err(protocol(format!("an answer of more than {MAX_HEADER_LINES} lines")));
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(protocol("a header line without a name"));
        };
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "www-authenticate" => head.authenticate.push(value.to_owned()),
            "content-length" => {
                let n: usize = value.parse().map_err(|_| protocol("a Content-Length that is not a number"))?;
                if head.content_length.is_some_and(|m| m != n) {
                    return Err(protocol("two Content-Length headers that differ"));
                }
                head.content_length = Some(n);
            }
            "transfer-encoding" => head.chunked |= value.to_ascii_lowercase().contains("chunked"),
            "connection" => head.close |= value.split(',').any(|t| t.trim().eq_ignore_ascii_case("close")),
            "upgrade" => head.upgrade_websocket |= value.eq_ignore_ascii_case("websocket"),
            _ => {}
        }
    }
    Ok(head)
}

async fn read_head<R: AsyncRead + Unpin>(io: &mut R, buf: &mut Vec<u8>) -> Result<Head, Closed> {
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = parse_head(&buf[..end])?;
            buf.drain(..end + 4);
            return Ok(head);
        }
        if buf.len() > MAX_HEAD {
            return Err(protocol(format!("an answer's head longer than {MAX_HEAD} bytes")));
        }
        let mut chunk = [0u8; 4096];
        let n = io.read(&mut chunk).await.map_err(|e| network("reading its answer", e))?;
        if n == 0 {
            return Err(Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the connection before it answered"));
        }
        buf.extend_from_slice(&chunk[..n]);
    }
}

async fn skip_body<R: AsyncRead + Unpin>(io: &mut R, buf: &mut Vec<u8>, head: &Head) -> Result<(), Closed> {
    if head.chunked {
        return Err(protocol("a refusal with a chunked body"));
    }
    let mut left = head.content_length.unwrap_or(0);
    if left > MAX_SKIPPED_BODY {
        return Err(protocol(format!("a refusal with a body longer than {MAX_SKIPPED_BODY} bytes")));
    }
    let here = left.min(buf.len());
    buf.drain(..here);
    left -= here;
    let mut chunk = [0u8; 4096];
    while left > 0 {
        let n = io.read(&mut chunk[..left.min(4096)]).await.map_err(|e| network("reading its answer", e))?;
        if n == 0 {
            return Err(Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the connection during the sign-in"));
        }
        left -= n;
    }
    Ok(())
}

/// The sign-in the gateway offers that this version does: NTLM, or Negotiate (which takes an
/// NTLM message as it is). Its name, as the headers will say it.
pub fn pick_scheme(authenticate: &[String]) -> Option<&'static str> {
    let offers = |name: &str| authenticate.iter().any(|v| v.split_whitespace().next().is_some_and(|s| s.eq_ignore_ascii_case(name)));
    if offers("NTLM") {
        Some("NTLM")
    } else if offers("Negotiate") {
        Some("Negotiate")
    } else {
        None
    }
}

/// The gateway's NTLM message in its answer (`<scheme> <base64>`).
pub fn challenge_of(authenticate: &[String], scheme: &str) -> Option<Vec<u8>> {
    authenticate.iter().find_map(|v| {
        let (name, token) = v.split_once(' ')?;
        if !name.eq_ignore_ascii_case(scheme) {
            return None;
        }
        base64::engine::general_purpose::STANDARD.decode(token.trim()).ok().filter(|t| !t.is_empty())
    })
}

fn random<const N: usize>() -> Result<[u8; N], Closed> {
    let mut out = [0u8; N];
    rustls::crypto::ring::default_provider()
        .secure_random
        .fill(&mut out)
        .map_err(|_| Closed::new(CloseReason::Internal, "RD Gateway: no random numbers"))?;
    Ok(out)
}

/// `{xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx}`, new for each connection.
fn connection_id() -> Result<String, Closed> {
    let mut b: [u8; 16] = random()?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = super::hex(&b);
    Ok(format!("{{{}-{}-{}-{}-{}}}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..]))
}

/// The gateway's address as the Host header says it (a port only when it is not 443).
pub(crate) fn host_header(host: &str, port: Option<u16>) -> String {
    let host = if host.contains(':') && !host.starts_with('[') { format!("[{host}]") } else { host.to_owned() };
    match port {
        Some(p) if p != 443 => format!("{host}:{p}"),
        _ => host,
    }
}

pub(crate) fn upgrade_request(host: &str, key: &str, connection_id: &str, authorization: Option<&str>) -> Vec<u8> {
    let mut r = format!(
        "RDG_OUT_DATA /remoteDesktopGateway/ HTTP/1.1\r\n\
         Host: {host}\r\n\
         Accept: */*\r\n\
         Cache-Control: no-cache\r\n\
         Pragma: no-cache\r\n\
         Connection: Upgrade\r\n\
         Upgrade: websocket\r\n\
         Sec-WebSocket-Version: 13\r\n\
         Sec-WebSocket-Key: {key}\r\n\
         RDG-Connection-Id: {connection_id}\r\n"
    );
    if let Some(a) = authorization {
        r.push_str("Authorization: ");
        r.push_str(a);
        r.push_str("\r\n");
    }
    r.push_str("\r\n");
    r.into_bytes()
}

/// NTLM for the HTTP headers, the gateway's own account (sspi's client, as CredSSP's).
struct NtlmHttp {
    ntlm: sspi::Ntlm,
    handle: Option<sspi::AuthIdentityBuffers>,
    spn: String,
}

impl NtlmHttp {
    fn new(gw: &GatewayRequest, binding: Option<&[u8]>) -> Result<Self, Closed> {
        let refused = |what: String| Closed::new(CloseReason::Auth, format!("RD Gateway: {what}")).with_detail("gateway_sign_in");
        let user = gw.username.as_deref().filter(|u| !u.is_empty()).ok_or_else(|| refused("no user name for the gateway".into()))?;
        let password = gw.password.as_deref().ok_or_else(|| refused("no password for the gateway".into()))?;
        let username =
            Username::new(user, gw.domain.as_deref().filter(|d| !d.is_empty())).map_err(|e| refused(format!("the user name: {e}")))?;
        let identity = AuthIdentity { username, password: password.to_owned().into() };
        let mut ntlm = sspi::Ntlm::new();
        if let Some(binding) = binding {
            ntlm.set_channel_bindings(binding);
        }
        let handle = ntlm
            .acquire_credentials_handle()
            .with_credential_use(CredentialUse::Outbound)
            .with_auth_data(&identity)
            .execute(&mut ntlm)
            .map_err(|e| Closed::new(CloseReason::Internal, format!("RD Gateway, NTLM: {e}")))?
            .credentials_handle;
        Ok(Self { ntlm, handle, spn: format!("HTTP/{}", gw.host.trim_start_matches('[').trim_end_matches(']')) })
    }

    /// The next message, from the gateway's last (none at first).
    fn step(&mut self, input: Option<Vec<u8>>) -> Result<Vec<u8>, Closed> {
        let mut input = [SecurityBuffer::new(input.unwrap_or_default(), BufferType::Token)];
        let mut output = [SecurityBuffer::new(Vec::new(), BufferType::Token)];
        let mut builder = self
            .ntlm
            .initialize_security_context()
            .with_credentials_handle(&mut self.handle)
            .with_context_requirements(
                ClientRequestFlags::ALLOCATE_MEMORY | ClientRequestFlags::CONFIDENTIALITY | ClientRequestFlags::INTEGRITY,
            )
            .with_target_data_representation(DataRepresentation::Native)
            .with_target_name(&self.spn)
            .with_input(&mut input)
            .with_output(&mut output);
        let result = self
            .ntlm
            .initialize_security_context_impl(&mut builder)
            .and_then(|mut g| g.resolve_to_result())
            .map_err(|e| protocol(format!("its NTLM message: {e}")))?;
        match result.status {
            SecurityStatus::Ok | SecurityStatus::ContinueNeeded | SecurityStatus::CompleteNeeded => {}
            other => return Err(protocol(format!("NTLM: {other:?}"))),
        }
        let token = std::mem::take(&mut output[0].buffer);
        if token.is_empty() {
            return Err(protocol("NTLM made no message"));
        }
        Ok(token)
    }
}

/// The upgrade to a WebSocket, signed in on the way: asked first without a sign-in (the answer
/// says what the gateway offers), then NTLM's two messages, all on this connection. What the
/// gateway sent after its 101 is left in `leftover` for the WebSocket.
async fn upgrade<R, W>(
    read: &mut R,
    writer: &mut WsWriter<W>,
    leftover: &mut Vec<u8>,
    gw: &GatewayRequest,
    binding: Option<&[u8]>,
) -> Result<(), Closed>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let host = host_header(&gw.host, gw.port);
    let id = connection_id()?;
    let mut authorization: Option<String> = None;
    let mut ntlm: Option<(NtlmHttp, &'static str)> = None;
    for round in 0..MAX_ROUNDS {
        let key = base64::engine::general_purpose::STANDARD.encode(random::<16>()?);
        let asked = upgrade_request(&host, &key, &id, authorization.take().as_deref());
        writer.raw(&asked).await?;
        let head = tokio::time::timeout(STEP_TIMEOUT, read_head(read, leftover)).await.map_err(|_| timed_out("the upgrade"))??;
        match head.status {
            101 if head.upgrade_websocket => return Ok(()),
            101 => return Err(protocol("a 101 that is not to a WebSocket")),
            401 => {
                tokio::time::timeout(STEP_TIMEOUT, skip_body(read, leftover, &head))
                    .await
                    .map_err(|_| timed_out("the sign-in"))??;
                if head.close {
                    return Err(protocol("the gateway closes the connection on the way through its sign-in"));
                }
                let next = match (round, ntlm.as_mut()) {
                    (0, _) => {
                        let scheme = pick_scheme(&head.authenticate).ok_or_else(|| {
                            Closed::new(
                                CloseReason::Protocol,
                                format!(
                                    "RD Gateway: the gateway signs in with {} and this version with NTLM",
                                    offered(&head.authenticate)
                                ),
                            )
                            .with_detail("gateway_sign_in_kind")
                        })?;
                        let mut client = NtlmHttp::new(gw, binding)?;
                        let first = client.step(None)?;
                        ntlm = Some((client, scheme));
                        (scheme, first)
                    }
                    (1, Some((client, scheme))) => {
                        let challenge = challenge_of(&head.authenticate, scheme)
                            .ok_or_else(|| protocol(format!("no {scheme} challenge in the gateway's answer")))?;
                        (*scheme, client.step(Some(challenge))?)
                    }
                    _ => {
                        return Err(Closed::new(CloseReason::Auth, "RD Gateway: the gateway refused the sign-in").with_detail("gateway_sign_in"));
                    }
                };
                authorization = Some(format!("{} {}", next.0, base64::engine::general_purpose::STANDARD.encode(next.1)));
            }
            200 => {
                return Err(protocol("the gateway offers only its older transport (HTTP 200, no WebSocket), which this version does not use")
                    .with_detail("gateway_old"));
            }
            403 => {
                return Err(Closed::new(CloseReason::Auth, "RD Gateway: the gateway refused this account (HTTP 403)").with_detail("gateway_not_allowed"));
            }
            404 => return Err(protocol("no RD Gateway at this address (HTTP 404)").with_detail("gateway_none")),
            300..=399 => return Err(protocol(format!("the gateway sends elsewhere (HTTP {}); not followed", head.status)).with_detail("gateway_none")),
            other => return Err(protocol(format!("the gateway answered HTTP {other}"))),
        }
    }
    Err(Closed::new(CloseReason::Auth, "RD Gateway: the gateway refused the sign-in").with_detail("gateway_sign_in"))
}

/// The sign-ins a gateway offers, by name, for a refusal's words.
fn offered(authenticate: &[String]) -> String {
    // A scheme's name is a token: letters, digits and a few marks, short. Whatever else a gateway
    // puts there does not reach the log or Copy details.
    let token = |n: &&str| n.len() <= 32 && n.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.+".contains(&b));
    let names: Vec<&str> =
        authenticate.iter().filter_map(|v| v.split_whitespace().next()).filter(token).take(8).collect();
    if names.is_empty() { "nothing it names".to_owned() } else { names.join(", ") }
}

// The WebSocket (RFC 6455), a client's side.

/// What one read of the WebSocket gave.
#[derive(Debug, PartialEq, Eq)]
pub enum Frame {
    /// A whole binary message.
    Message(Vec<u8>),
    Ping(Vec<u8>),
    Close,
}

pub(crate) struct WsReader<R> {
    io: R,
    buf: Vec<u8>,
    /// A binary message in pieces, while its last piece has not come.
    pieces: Option<Vec<u8>>,
}

impl<R: AsyncRead + Unpin> WsReader<R> {
    pub(crate) fn new(io: R, leftover: Vec<u8>) -> Self {
        Self { io, buf: leftover, pieces: None }
    }

    /// The next message, ping or close. Safe to drop at any await: what was read stays in the
    /// reader.
    pub(crate) async fn next(&mut self) -> Result<Frame, Closed> {
        loop {
            if let Some(frame) = parse_frame(&mut self.buf, &mut self.pieces)? {
                return Ok(frame);
            }
            let mut chunk = [0u8; 8192];
            let n = self.io.read(&mut chunk).await.map_err(|e| network("reading", e))?;
            if n == 0 {
                return Err(Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the connection"));
            }
            self.buf.extend_from_slice(&chunk[..n]);
        }
    }
}

/// One frame off the front of `buf`, if a whole one is there. A server's frame is never masked,
/// a message is binary (a text one is not MS-TSGU), and nothing is longer than [MAX_MESSAGE].
pub fn parse_frame(buf: &mut Vec<u8>, pieces: &mut Option<Vec<u8>>) -> Result<Option<Frame>, Closed> {
    loop {
        if buf.len() < 2 {
            return Ok(None);
        }
        let (b0, b1) = (buf[0], buf[1]);
        if b0 & 0x70 != 0 {
            return Err(protocol("a WebSocket frame with extension bits"));
        }
        if b1 & 0x80 != 0 {
            return Err(protocol("a masked WebSocket frame from the gateway"));
        }
        let fin = b0 & 0x80 != 0;
        let opcode = b0 & 0x0f;
        let (len, at) = match b1 & 0x7f {
            126 => {
                if buf.len() < 4 {
                    return Ok(None);
                }
                (u64::from(u16::from_be_bytes([buf[2], buf[3]])), 4)
            }
            127 => {
                if buf.len() < 10 {
                    return Ok(None);
                }
                let mut b = [0u8; 8];
                b.copy_from_slice(&buf[2..10]);
                (u64::from_be_bytes(b), 10)
            }
            n => (u64::from(n), 2),
        };
        if len > MAX_MESSAGE as u64 {
            return Err(protocol(format!("a WebSocket frame of {len} bytes")));
        }
        let len = len as usize;
        if buf.len() < at + len {
            return Ok(None);
        }
        let payload: Vec<u8> = buf[at..at + len].to_vec();
        buf.drain(..at + len);
        let control = opcode & 0x08 != 0;
        if control && (!fin || len > 125) {
            return Err(protocol("a WebSocket control frame in pieces or over 125 bytes"));
        }
        match opcode {
            0x0 => {
                let Some(message) = pieces.as_mut() else {
                    return Err(protocol("a WebSocket piece with no message begun"));
                };
                if message.len() + payload.len() > MAX_MESSAGE {
                    return Err(protocol("a WebSocket message too long"));
                }
                message.extend_from_slice(&payload);
                if fin {
                    return Ok(pieces.take().map(Frame::Message));
                }
            }
            0x2 => {
                if pieces.is_some() {
                    return Err(protocol("a WebSocket message begun inside another"));
                }
                if fin {
                    return Ok(Some(Frame::Message(payload)));
                }
                *pieces = Some(payload);
            }
            0x1 => return Err(protocol("a WebSocket text message")),
            0x8 => return Ok(Some(Frame::Close)),
            0x9 => return Ok(Some(Frame::Ping(payload))),
            0xA => {}
            other => return Err(protocol(format!("a WebSocket frame of kind {other}"))),
        }
    }
}

pub(crate) struct WsWriter<W> {
    io: W,
}

impl<W: AsyncWrite + Unpin> WsWriter<W> {
    pub(crate) fn new(io: W) -> Self {
        Self { io }
    }

    async fn raw(&mut self, bytes: &[u8]) -> Result<(), Closed> {
        self.io.write_all(bytes).await.map_err(|e| network("writing", e))?;
        self.io.flush().await.map_err(|e| network("writing", e))
    }

    async fn frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), Closed> {
        let mask: [u8; 4] = random()?;
        self.raw(&frame_bytes(opcode, payload, mask)).await
    }

    pub(crate) async fn binary(&mut self, payload: &[u8]) -> Result<(), Closed> {
        self.frame(0x2, payload).await
    }

    async fn pong(&mut self, payload: &[u8]) -> Result<(), Closed> {
        self.frame(0xA, payload).await
    }

    async fn close(&mut self) {
        let _ = self.frame(0x8, &[]).await;
        let _ = self.io.shutdown().await;
    }
}

/// A client's frame: whole, masked.
pub(crate) fn frame_bytes(opcode: u8, payload: &[u8], mask: [u8; 4]) -> Vec<u8> {
    let mut out = Vec::with_capacity(payload.len() + 14);
    out.push(0x80 | opcode);
    match payload.len() {
        n if n < 126 => out.push(0x80 | n as u8),
        n if n <= 0xFFFF => {
            out.push(0x80 | 126);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(0x80 | 127);
            out.extend_from_slice(&(n as u64).to_be_bytes());
        }
    }
    out.extend_from_slice(&mask);
    out.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    out
}

// MS-TSGU packets (2.2.10), little-endian, one in each WebSocket message.

fn packet_bytes(ty: u16, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + body.len());
    out.extend_from_slice(&ty.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out.extend_from_slice(&((8 + body.len()) as u32).to_le_bytes());
    out.extend_from_slice(body);
    out
}

/// A name as MS-TSGU writes one: its UTF-16LE bytes and a NUL, after their count in bytes.
fn utf16_counted(text: &str) -> Vec<u8> {
    let units: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    let mut out = Vec::with_capacity(2 + units.len() * 2);
    out.extend_from_slice(&((units.len() * 2) as u16).to_le_bytes());
    for u in units {
        out.extend_from_slice(&u.to_le_bytes());
    }
    out
}

/// Version 1.0, no extended sign-in (the HTTP headers did it).
pub(crate) fn handshake_request() -> Vec<u8> {
    packet_bytes(PKT_HANDSHAKE_REQUEST, &[1, 0, 0, 0, 0, 0])
}

pub(crate) fn tunnel_create() -> Vec<u8> {
    let mut body = TUNNEL_CAPS.to_le_bytes().to_vec();
    body.extend_from_slice(&[0, 0, 0, 0]);
    packet_bytes(PKT_TUNNEL_CREATE, &body)
}

pub(crate) fn tunnel_auth(client_name: &str) -> Vec<u8> {
    let mut body = vec![0, 0];
    body.extend_from_slice(&utf16_counted(client_name));
    packet_bytes(PKT_TUNNEL_AUTH, &body)
}

/// The PC (as the gateway knows it: the host's address) and its port. A name longer than a
/// host name can be is refused before it is sent.
pub(crate) fn channel_create(target: &str, port: u16) -> Result<Vec<u8>, Closed> {
    if target.chars().count() > 255 || target.chars().any(char::is_control) {
        return Err(Closed::new(CloseReason::Internal, "RD Gateway: the PC's name is not one a gateway takes"));
    }
    let mut body = vec![1, 0];
    body.extend_from_slice(&port.to_le_bytes());
    body.extend_from_slice(&CHANNEL_PROTOCOL_RDP.to_le_bytes());
    body.extend_from_slice(&utf16_counted(target));
    Ok(packet_bytes(PKT_CHANNEL_CREATE, &body))
}

pub(crate) fn data_packet(bytes: &[u8]) -> Vec<u8> {
    debug_assert!(bytes.len() <= 0xFFFF);
    let mut body = Vec::with_capacity(2 + bytes.len());
    body.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
    body.extend_from_slice(bytes);
    packet_bytes(PKT_DATA, &body)
}

fn keepalive_packet() -> Vec<u8> {
    packet_bytes(PKT_KEEPALIVE, &[])
}

fn close_channel_response() -> Vec<u8> {
    packet_bytes(PKT_CLOSE_CHANNEL_RESPONSE, &[0, 0, 0, 0])
}

/// A packet's type and body, its length checked against the message it came in.
pub fn packet(message: &[u8]) -> Result<(u16, &[u8]), Closed> {
    if message.len() < 8 {
        return Err(protocol(format!("a packet of {} bytes", message.len())));
    }
    let ty = u16::from_le_bytes([message[0], message[1]]);
    let length = u32::from_le_bytes([message[4], message[5], message[6], message[7]]) as usize;
    if length != message.len() {
        return Err(protocol(format!("a packet that says {length} bytes in a message of {}", message.len())));
    }
    Ok((ty, &message[8..]))
}

/// Reads a packet's body, every read checked.
struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
    what: &'static str,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8], what: &'static str) -> Self {
        Self { bytes, at: 0, what }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], Closed> {
        let end = self.at.checked_add(n).filter(|e| *e <= self.bytes.len()).ok_or_else(|| protocol(format!("{} too short", self.what)))?;
        let out = &self.bytes[self.at..end];
        self.at = end;
        Ok(out)
    }

    fn u8(&mut self) -> Result<u8, Closed> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, Closed> {
        let b = self.take(2)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }

    fn u32(&mut self) -> Result<u32, Closed> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
}

/// What a gateway's error code means for the person, by MS-TSGU 2.2.6's codes (their short
/// form, or with the facility 0x8007).
pub(crate) fn gateway_code(step: &str, code: u32) -> Closed {
    let short = if code >> 16 == 0 || code >> 16 == 0x8007 { code & 0xFFFF } else { code };
    let (reason, detail, what) = match short {
        0x8009_030C | 0x59F8 => (CloseReason::Auth, "gateway_sign_in", "the gateway refused the sign-in"),
        0x0005 | 0x59DA => {
            (CloseReason::Auth, "gateway_not_allowed", "the gateway's policy does not let this account through to this PC")
        }
        0x59DB | 0x59ED => (CloseReason::Auth, "gateway_not_allowed", "the gateway's network or health policy refused this device"),
        0x59DD => (CloseReason::Network, "gateway_target", "the gateway could not reach the PC"),
        0x59E6 => (CloseReason::Protocol, "gateway_refused", "the gateway has as many connections as it takes"),
        0x59E8 | 0x59E9 | 0x59F9 => {
            (CloseReason::Protocol, "gateway_sign_in_kind", "the gateway asks for something this version does not do")
        }
        _ => (CloseReason::Protocol, "gateway_refused", "the gateway refused"),
    };
    Closed::new(reason, format!("RD Gateway, {step}: {what} (0x{code:08x})")).with_detail(detail)
}

pub fn read_handshake_response(body: &[u8]) -> Result<(), Closed> {
    let mut c = Cursor::new(body, "the handshake's answer");
    let error = c.u32()?;
    if error != 0 {
        return Err(gateway_code("the handshake", error));
    }
    let (major, minor) = (c.u8()?, c.u8()?);
    if (major, minor) != (1, 0) {
        return Err(protocol(format!("version {major}.{minor} of the gateway's protocol")));
    }
    Ok(())
}

pub fn read_tunnel_response(body: &[u8]) -> Result<(), Closed> {
    let mut c = Cursor::new(body, "the tunnel's answer");
    let _server_version = c.u16()?;
    let status = c.u32()?;
    if status != 0 {
        return Err(gateway_code("the tunnel", status));
    }
    // Which optional fields follow (the tunnel's id, its capabilities, a health statement's nonce
    // and certificate, a consent message): none of them is used but the consent's presence, so
    // they are not read (a field read at the wrong size would refuse a gateway for nothing).
    let present = c.u16()?;
    if present & 0x10 != 0 {
        return Err(Closed::new(
            CloseReason::Protocol,
            "RD Gateway: the gateway asks for its consent message to be shown and agreed to, which this version does not do",
        )
        .with_detail("gateway_consent"));
    }
    Ok(())
}

pub fn read_tunnel_auth_response(body: &[u8]) -> Result<(), Closed> {
    let error = Cursor::new(body, "the tunnel sign-in's answer").u32()?;
    if error != 0 {
        return Err(gateway_code("the tunnel's sign-in", error));
    }
    Ok(())
}

pub fn read_channel_response(body: &[u8]) -> Result<(), Closed> {
    let error = Cursor::new(body, "the channel's answer").u32()?;
    if error != 0 {
        return Err(gateway_code("the channel to the PC", error));
    }
    Ok(())
}

/// A data packet's bytes.
pub fn read_data(body: &[u8]) -> Result<&[u8], Closed> {
    let mut c = Cursor::new(body, "a data packet");
    let n = c.u16()? as usize;
    c.take(n)
}

/// Which pings get their pong: the first, and then one every [PONG_EVERY].
#[derive(Default)]
struct Pongs {
    last: Option<tokio::time::Instant>,
}

impl Pongs {
    fn due(&mut self) -> bool {
        let now = tokio::time::Instant::now();
        if self.last.is_some_and(|l| now.duration_since(l) < PONG_EVERY) {
            return false;
        }
        self.last = Some(now);
        true
    }
}

/// The next packet of `want`, past keepalives and service messages; a ping is answered.
async fn expect<R, W>(reader: &mut WsReader<R>, writer: &mut WsWriter<W>, want: u16, what: &str) -> Result<Vec<u8>, Closed>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    // One deadline for the step: a keepalive or a ping does not start it again.
    let deadline = tokio::time::Instant::now() + STEP_TIMEOUT;
    let mut pongs = Pongs::default();
    loop {
        // Looked at here too: while frames that are not the answer keep coming, the read below
        // is ready each time and its time limit is never asked.
        if tokio::time::Instant::now() >= deadline {
            return Err(timed_out(what));
        }
        let frame = tokio::time::timeout_at(deadline, reader.next()).await.map_err(|_| timed_out(what))??;
        match frame {
            Frame::Ping(p) => {
                if pongs.due() {
                    writer.pong(&p).await?;
                }
            }
            Frame::Close => {
                return Err(Closed::new(CloseReason::ServerClosed, format!("RD Gateway: the gateway closed the connection at {what}")));
            }
            Frame::Message(m) => {
                let (ty, body) = packet(&m)?;
                match ty {
                    t if t == want => return Ok(body.to_vec()),
                    PKT_KEEPALIVE | PKT_SERVICE_MESSAGE => {}
                    PKT_CLOSE_CHANNEL => return Err(closed_channel(body)),
                    PKT_EXTENDED_AUTH => {
                        return Err(protocol("the gateway asks for its own NTLM inside the tunnel, which this version does not do")
                            .with_detail("gateway_sign_in_kind"));
                    }
                    other => return Err(protocol(format!("packet type {other:#04x} at {what}"))),
                }
            }
        }
    }
}

fn closed_channel(body: &[u8]) -> Closed {
    match Cursor::new(body, "the gateway's close").u32() {
        Ok(0) | Err(_) => Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the channel to the PC"),
        Ok(code) => gateway_code("the channel to the PC", code),
    }
}

/// The handshake, the tunnel, its sign-in and the channel to `target`.
async fn tunnel<R, W>(reader: &mut WsReader<R>, writer: &mut WsWriter<W>, target: &str, port: u16) -> Result<(), Closed>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let channel = channel_create(target, port)?;
    writer.binary(&handshake_request()).await?;
    read_handshake_response(&expect(reader, writer, PKT_HANDSHAKE_RESPONSE, "the handshake").await?)?;
    writer.binary(&tunnel_create()).await?;
    read_tunnel_response(&expect(reader, writer, PKT_TUNNEL_RESPONSE, "the tunnel").await?)?;
    writer.binary(&tunnel_auth(CLIENT_NAME)).await?;
    read_tunnel_auth_response(&expect(reader, writer, PKT_TUNNEL_AUTH_RESPONSE, "the tunnel's sign-in").await?)?;
    writer.binary(&channel).await?;
    read_channel_response(&expect(reader, writer, PKT_CHANNEL_RESPONSE, "the channel to the PC").await?)
}

/// The channel's bytes both ways until either side ends: the gateway's data packets to the
/// session, the session's bytes in data packets to the gateway, a keepalive now and then.
///
/// Never waits on the session's pipe without reading it: the gateway's data waits in a buffer of
/// its own (at most [MAX_PENDING]) written as the session takes it, while the session's own
/// bytes are read and sent on. (Waiting on a full pipe to the session while the session waited
/// on a full pipe to here held both for good: a large clipboard answer while the screen moved.)
async fn carry<R, W>(mut reader: WsReader<R>, mut writer: WsWriter<W>, session: DuplexStream) -> Result<(), Closed>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (mut from_session, mut to_session) = tokio::io::split(session);
    let mut out = vec![0u8; DATA_CHUNK];
    let mut pending: Vec<u8> = Vec::new();
    let mut keepalive = tokio::time::interval_at(tokio::time::Instant::now() + KEEPALIVE, KEEPALIVE);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut pongs = Pongs::default();
    // The gateway's last data reaches the session before the channel's end does (within a step's
    // time: a session that reads nothing more is not waited for).
    async fn flush<T: AsyncWrite + Unpin>(to: &mut T, pending: &[u8]) {
        if !pending.is_empty() {
            let _ = tokio::time::timeout(STEP_TIMEOUT, to.write_all(pending)).await;
        }
    }
    loop {
        tokio::select! {
            frame = reader.next(), if pending.len() < MAX_PENDING => match frame {
                // The gateway's connection ended: what it sent before still reaches the session.
                Err(e) => {
                    flush(&mut to_session, &pending).await;
                    return Err(e);
                }
                Ok(frame) => match frame {
                Frame::Ping(p) => {
                    if pongs.due() {
                        writer.pong(&p).await?;
                    }
                    // Pings without end are ready without end: the session's own work has its turn.
                    tokio::task::yield_now().await;
                }
                Frame::Close => {
                    flush(&mut to_session, &pending).await;
                    return Err(Closed::new(CloseReason::ServerClosed, "RD Gateway: the gateway closed the connection"));
                }
                Frame::Message(m) => {
                    let (ty, body) = packet(&m)?;
                    match ty {
                        PKT_DATA => pending.extend_from_slice(read_data(body)?),
                        // As for pings: the session's own work has its turn.
                        PKT_KEEPALIVE | PKT_SERVICE_MESSAGE => tokio::task::yield_now().await,
                        PKT_CLOSE_CHANNEL => {
                            let _ = writer.binary(&close_channel_response()).await;
                            flush(&mut to_session, &pending).await;
                            return Err(closed_channel(body));
                        }
                        PKT_CLOSE_CHANNEL_RESPONSE => {
                            flush(&mut to_session, &pending).await;
                            return Ok(());
                        }
                        PKT_REAUTH_MESSAGE => {
                            flush(&mut to_session, &pending).await;
                            return Err(Closed::new(
                                CloseReason::ServerClosed,
                                "RD Gateway: the gateway asks to sign in again, which this version does not do",
                            )
                            .with_detail("gateway_reauth"));
                        }
                        other => return Err(protocol(format!("packet type {other:#04x} in the channel"))),
                    }
                }
                },
            },
            written = to_session.write(&pending), if !pending.is_empty() => match written {
                Ok(n) if n > 0 => {
                    pending.drain(..n);
                }
                // The session went first.
                _ => {
                    writer.close().await;
                    return Ok(());
                }
            },
            n = from_session.read(&mut out) => {
                let n = n.unwrap_or(0);
                if n == 0 {
                    writer.close().await;
                    return Ok(());
                }
                writer.binary(&data_packet(&out[..n])).await?;
            }
            _ = keepalive.tick() => writer.binary(&keepalive_packet()).await?,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gw() -> GatewayRequest {
        GatewayRequest {
            host: "rdg.example.test".into(),
            port: None,
            tls_pin: None,
            username: Some("alex".into()),
            password: Some("made-up-password".into()),
            domain: Some("EXAMPLE".into()),
            target: "pc1.example.test".into(),
            target_port: None,
        }
    }

    #[test]
    fn the_packets_sent_are_as_windows_client_writes_them() {
        assert_eq!(handshake_request(), [1, 0, 0, 0, 14, 0, 0, 0, 1, 0, 0, 0, 0, 0]);
        assert_eq!(tunnel_create(), [4, 0, 0, 0, 16, 0, 0, 0, 0x14, 0, 0, 0, 0, 0, 0, 0]);
        // "ab": 2 characters and a NUL, 6 bytes.
        assert_eq!(tunnel_auth("ab"), [6, 0, 0, 0, 18, 0, 0, 0, 0, 0, 6, 0, b'a', 0, b'b', 0, 0, 0]);
        let c = channel_create("pc", 3390).unwrap();
        assert_eq!(c, [8, 0, 0, 0, 22, 0, 0, 0, 1, 0, 0x3e, 0x0d, 3, 0, 6, 0, b'p', 0, b'c', 0, 0, 0]);
        assert_eq!(data_packet(&[9, 8]), [0x0a, 0, 0, 0, 12, 0, 0, 0, 2, 0, 9, 8]);
        // A name outside ASCII counts its UTF-16 units, not its UTF-8 bytes.
        let c = channel_create("\u{e9}", 3389).unwrap();
        assert_eq!(u32::from_le_bytes([c[4], c[5], c[6], c[7]]) as usize, c.len());
        assert_eq!(&c[14..16], &[4, 0]);
        assert!(channel_create(&"a".repeat(256), 3389).is_err());
        assert!(channel_create("pc\r\nHost: x", 3389).is_err());
    }

    #[test]
    fn a_packet_must_be_as_long_as_it_says_and_every_read_is_checked() {
        assert!(packet(&[]).is_err());
        assert!(packet(&[2, 0, 0, 0, 9, 0, 0, 0]).is_err(), "says 9, is 8");
        assert!(packet(&[2, 0, 0, 0, 0, 0, 0, 0]).is_err(), "says 0");
        assert!(packet(&[2, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]).is_err());
        let (ty, body) = packet(&[0x0a, 0, 0, 0, 10, 0, 0, 0, 0, 0]).unwrap();
        assert_eq!((ty, body), (PKT_DATA, &[0u8, 0][..]));
        assert_eq!(read_data(body).unwrap(), &[] as &[u8]);
        assert!(read_data(&[5, 0, 1, 2]).is_err(), "says 5 bytes, has 2");
        assert!(read_data(&[0xff, 0xff]).is_err());
        assert!(read_data(&[1]).is_err());
        for short in 0..10 {
            assert!(read_handshake_response(&[0u8; 10][..short]).is_err() || short >= 6);
        }
        // The optional fields are not read: their presence alone changes nothing but the consent's.
        assert!(read_tunnel_response(&[0, 0, 0, 0, 0, 0, 0x0f, 0, 0, 0]).is_ok(), "fields said, none there");
        assert!(read_tunnel_response(&[0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0]).is_err(), "the consent among them");
        assert!(read_tunnel_response(&[0, 0, 0, 0, 0, 0]).is_err(), "no flags at all");
        assert_eq!(offered(&["NTLM".into(), "Basic realm=x".into(), format!("{} x", "A".repeat(40)), "bad\u{1b}[2J".into()]), "NTLM, Basic");
    }

    #[test]
    fn the_gateways_answers_are_read_and_its_refusals_said() {
        assert!(read_handshake_response(&[0, 0, 0, 0, 1, 0, 0, 0, 0, 0]).is_ok());
        assert!(read_handshake_response(&[0, 0, 0, 0, 2, 0, 0, 0, 0, 0]).is_err());
        let refused = read_handshake_response(&[0xda, 0x59, 0x07, 0x80, 1, 0, 0, 0, 0, 0]).unwrap_err();
        assert_eq!(refused.detail, Some("gateway_not_allowed"));
        // A tunnel with its id, capabilities and the gateway's certificate, no consent.
        let mut ok = vec![0, 0, 0, 0, 0, 0, 0x07, 0, 0, 0];
        ok.extend_from_slice(&[1, 0, 0, 0, 0x14, 0, 0, 0, 7, 0, 3, 0, 1, 2, 3]);
        assert!(read_tunnel_response(&ok).is_ok());
        let consent = read_tunnel_response(&[0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0, 2, 0, b'x', 0]).unwrap_err();
        assert_eq!(consent.detail, Some("gateway_consent"));
        assert!(read_tunnel_auth_response(&[0, 0, 0, 0, 0, 0, 0, 0]).is_ok());
        assert_eq!(read_channel_response(&[0xdd, 0x59, 0, 0, 0, 0, 0, 0]).unwrap_err().detail, Some("gateway_target"));
        assert_eq!(read_channel_response(&[5, 0, 0, 0, 0, 0, 0, 0]).unwrap_err().detail, Some("gateway_not_allowed"));
    }

    #[test]
    fn a_code_says_what_it_is() {
        let say = |code| gateway_code("x", code);
        assert_eq!(say(0x8009_030C).reason, CloseReason::Auth);
        assert_eq!(say(0x8009_030C).detail, Some("gateway_sign_in"));
        assert_eq!(say(0x800759DA).detail, Some("gateway_not_allowed"));
        assert_eq!(say(0x59DA).detail, Some("gateway_not_allowed"));
        assert_eq!(say(0x800759DD).reason, CloseReason::Network);
        assert_eq!(say(0x800759F9).detail, Some("gateway_sign_in_kind"));
        assert_eq!(say(0x1234_59DA).detail, Some("gateway_refused"), "another facility is not the same code");
        assert!(say(0x800759DA).message.contains("0x800759da"));
    }

    #[test]
    fn an_answers_head_is_read_within_its_bounds() {
        let h = parse_head(
            b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: Negotiate\r\nWWW-Authenticate: NTLM\r\nwww-authenticate: Basic\r\nContent-Length: 0",
        )
        .unwrap();
        assert_eq!(h.status, 401);
        assert_eq!(h.authenticate, ["Negotiate", "NTLM", "Basic"]);
        assert_eq!(h.content_length, Some(0));
        assert_eq!(pick_scheme(&h.authenticate), Some("NTLM"));
        assert_eq!(pick_scheme(&["Negotiate".into()]), Some("Negotiate"));
        assert_eq!(pick_scheme(&["Basic realm=x".into(), "Digest x".into()]), None);
        let up = parse_head(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade").unwrap();
        assert!(up.upgrade_websocket && !up.close);
        assert!(parse_head(b"SSH-2.0-x").is_err());
        assert!(parse_head(b"HTTP/1.1 4011 x").is_err());
        assert!(parse_head(b"HTTP/1.1 200 OK\r\nno colon").is_err());
        assert!(parse_head(b"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2").is_err());
        let many = format!("HTTP/1.1 200 OK{}", "\r\nX: y".repeat(MAX_HEADER_LINES + 1));
        assert!(parse_head(many.as_bytes()).is_err());
        assert_eq!(challenge_of(&["NTLM TlRMTVNTUAAC".into()], "NTLM"), Some(b"NTLMSSP\0\x02".to_vec()));
        assert_eq!(challenge_of(&["NTLM".into()], "NTLM"), None);
        assert_eq!(challenge_of(&["NTLM !!!".into()], "NTLM"), None);
    }

    #[test]
    fn the_upgrade_asks_as_windows_client_asks_and_carries_no_secret_but_its_own() {
        let r = String::from_utf8(upgrade_request("rdg.example.test", "a2V5", "{id}", None)).unwrap();
        assert!(r.starts_with("RDG_OUT_DATA /remoteDesktopGateway/ HTTP/1.1\r\nHost: rdg.example.test\r\n"));
        assert!(r.contains("\r\nUpgrade: websocket\r\n") && r.contains("\r\nRDG-Connection-Id: {id}\r\n"));
        assert!(!r.contains("Authorization") && r.ends_with("\r\n\r\n"));
        assert_eq!(host_header("rdg.example.test", Some(443)), "rdg.example.test");
        assert_eq!(host_header("rdg.example.test", Some(8443)), "rdg.example.test:8443");
        assert_eq!(host_header("2001:db8::7", None), "[2001:db8::7]");
        let id = connection_id().unwrap();
        assert_eq!((id.len(), &id[15..16]), (38, "4"));
    }

    #[test]
    fn websocket_frames_are_read_whole_bounded_and_never_masked() {
        let mut pieces = None;
        let mut buf = vec![0x82, 2, 7, 8, 0x89, 1, 5];
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), Some(Frame::Message(vec![7, 8])));
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), Some(Frame::Ping(vec![5])));
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), None);
        // In pieces, a pong between them.
        let mut buf = vec![0x02, 1, 1, 0x8A, 0, 0x80, 1, 2];
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), Some(Frame::Message(vec![1, 2])));
        // Half a frame waits.
        let mut buf = vec![0x82, 126, 0];
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), None);
        for bad in [
            vec![0x82, 0x81, 0, 0, 0, 0, 1],                  // masked
            vec![0x81, 1, b'x'],                                // text
            vec![0xC2, 1, 0],                                   // an extension bit
            vec![0x80, 1, 0],                                   // a piece with nothing begun
            vec![0x09, 0],                                      // a ping in pieces
            vec![0x82, 127, 0, 0, 0, 0, 0, 1, 0, 0x0a],         // 65,546: one byte past a message
            vec![0x82, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff],
            vec![0x83, 0],                                      // a kind that is none
        ] {
            let mut pieces = None;
            let mut buf = bad.clone();
            assert!(parse_frame(&mut buf, &mut pieces).is_err(), "{bad:?}");
        }
        // Pieces that add up to more than a message.
        let mut pieces = Some(vec![0; MAX_MESSAGE - 1]);
        let mut buf = vec![0x80, 2, 0, 0];
        assert!(parse_frame(&mut buf, &mut pieces).is_err());
        // Ours: masked, whole.
        assert_eq!(frame_bytes(0x2, &[1, 2], [0xff, 0, 0xff, 0]), [0x82, 0x82, 0xff, 0, 0xff, 0, 0xfe, 2]);
        assert_eq!(&frame_bytes(0x2, &[0; 300], [0; 4])[..4], &[0x82, 0xfe, 1, 44]);
    }

    /// A played gateway, on the other end of an in-memory stream (after TLS): it signs the
    /// client in with sspi's own NTLM server (so a wrong password is refused as a gateway
    /// would), upgrades, answers the tunnel's packets as [Played] says, and echoes the channel's
    /// data back.
    #[derive(Clone, Copy, Default)]
    struct Played {
        /// The password the gateway's account has.
        wrong_password: bool,
        /// Answer the upgrade with 200 (the older transport).
        old_transport: bool,
        /// The tunnel asks for its consent message to be agreed to.
        consent: bool,
        /// The channel's answer: an error code.
        channel_error: u32,
    }

    async fn head_of(io: &mut DuplexStream, buf: &mut Vec<u8>) -> String {
        loop {
            if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8(buf[..end].to_vec()).unwrap();
                buf.drain(..end + 4);
                return head;
            }
            let mut chunk = [0u8; 4096];
            let n = io.read(&mut chunk).await.unwrap();
            assert!(n > 0, "the client went");
            buf.extend_from_slice(&chunk[..n]);
        }
    }

    fn authorization(head: &str) -> Option<Vec<u8>> {
        head.lines().find_map(|l| l.strip_prefix("Authorization: NTLM ")).map(|t| base64::engine::general_purpose::STANDARD.decode(t).unwrap())
    }

    /// A client's frame: unmasked payload.
    async fn client_frame(io: &mut DuplexStream, buf: &mut Vec<u8>) -> Vec<u8> {
        loop {
            if buf.len() >= 2 {
                assert_eq!(buf[1] & 0x80, 0x80, "a client's frame is masked");
                let (len, at) = match buf[1] & 0x7f {
                    126 if buf.len() >= 4 => (u16::from_be_bytes([buf[2], buf[3]]) as usize, 4),
                    126 => (usize::MAX, 0),
                    n => (n as usize, 2),
                };
                if len != usize::MAX && buf.len() >= at + 4 + len {
                    let mask = [buf[at], buf[at + 1], buf[at + 2], buf[at + 3]];
                    let payload = buf[at + 4..at + 4 + len].iter().enumerate().map(|(i, b)| b ^ mask[i % 4]).collect();
                    buf.drain(..at + 4 + len);
                    return payload;
                }
            }
            let mut chunk = [0u8; 4096];
            let n = io.read(&mut chunk).await.unwrap();
            assert!(n > 0, "the client went");
            buf.extend_from_slice(&chunk[..n]);
        }
    }

    async fn server_send(io: &mut DuplexStream, packet: &[u8]) {
        let mut f = vec![0x82];
        if packet.len() < 126 {
            f.push(packet.len() as u8);
        } else {
            f.push(126);
            f.extend_from_slice(&(packet.len() as u16).to_be_bytes());
        }
        f.extend_from_slice(packet);
        io.write_all(&f).await.unwrap();
    }

    async fn play(mut io: DuplexStream, how: Played) -> Vec<String> {
        let mut seen = Vec::new();
        let mut buf = Vec::new();
        let identity = AuthIdentity {
            username: Username::new("alex", Some("EXAMPLE")).unwrap(),
            password: (if how.wrong_password { "another-password" } else { "made-up-password" }).to_owned().into(),
        };
        let mut server = sspi::Ntlm::new();
        let mut handle = server
            .acquire_credentials_handle()
            .with_credential_use(CredentialUse::Inbound)
            .with_auth_data(&identity)
            .execute(&mut server)
            .unwrap()
            .credentials_handle;
        let mut accept = |token: Vec<u8>| {
            let mut input = [SecurityBuffer::new(token, BufferType::Token)];
            let mut output = [SecurityBuffer::new(Vec::new(), BufferType::Token)];
            let status = server
                .accept_security_context()
                .with_credentials_handle(&mut handle)
                .with_context_requirements(sspi::ServerRequestFlags::ALLOCATE_MEMORY)
                .with_target_data_representation(DataRepresentation::Native)
                .with_input(&mut input)
                .with_output(&mut output)
                .execute(&mut server)
                .and_then(|mut g| g.resolve_to_result())
                .map(|r| r.status);
            // The password is checked here (sspi's server: the last message read, then this).
            let ok = match status {
                Ok(SecurityStatus::CompleteNeeded) => server.complete_auth_token(&mut []).is_ok(),
                Ok(_) => true,
                Err(_) => false,
            };
            if ok { Ok(std::mem::take(&mut output[0].buffer)) } else { Err(()) }
        };
        let deny = b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: Negotiate\r\nWWW-Authenticate: NTLM\r\nContent-Length: 5\r\n\r\ndenied";
        // 1: asked without a sign-in.
        let head = head_of(&mut io, &mut buf).await;
        assert!(authorization(&head).is_none());
        seen.push(head.lines().next().unwrap().to_owned());
        io.write_all(&deny[..deny.len() - 1]).await.unwrap();
        // 2: NTLM's first message; the challenge.
        let head = head_of(&mut io, &mut buf).await;
        let challenge = accept(authorization(&head).expect("NTLM's first message")).unwrap();
        assert!(challenge.starts_with(b"NTLMSSP\0\x02"), "a challenge: {} bytes", challenge.len());
        let answer = format!(
            "HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: NTLM {}\r\nContent-Length: 0\r\n\r\n",
            base64::engine::general_purpose::STANDARD.encode(challenge)
        );
        io.write_all(answer.as_bytes()).await.unwrap();
        // 3: NTLM's last message.
        let head = head_of(&mut io, &mut buf).await;
        let last = authorization(&head).expect("NTLM's last message");
        assert!(!last.windows(8).any(|w| w == b"made-up-"), "no password in the clear");
        if accept(last).is_err() {
            seen.push("refused".into());
            io.write_all(&deny[..deny.len() - 1]).await.unwrap();
            let _ = head_of(&mut io, &mut buf).await;
            return seen;
        }
        if how.old_transport {
            io.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789").await.unwrap();
            return seen;
        }
        io.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").await.unwrap();
        seen.push("upgraded".into());
        // The tunnel, packet by packet.
        let p = client_frame(&mut io, &mut buf).await;
        assert_eq!(p, handshake_request());
        // A keepalive first: passed over.
        server_send(&mut io, &packet_bytes(PKT_KEEPALIVE, &[])).await;
        server_send(&mut io, &packet_bytes(PKT_HANDSHAKE_RESPONSE, &[0, 0, 0, 0, 1, 0, 0, 0, 0, 0])).await;
        assert_eq!(client_frame(&mut io, &mut buf).await, tunnel_create());
        let mut tunnel = vec![0, 0, 0, 0, 0, 0];
        if how.consent {
            tunnel.extend_from_slice(&[0x10, 0, 0, 0, 4, 0, b'o', 0, 0, 0]);
        } else {
            tunnel.extend_from_slice(&[0x01, 0, 0, 0, 7, 0, 0, 0]);
        }
        server_send(&mut io, &packet_bytes(PKT_TUNNEL_RESPONSE, &tunnel)).await;
        if how.consent {
            return seen;
        }
        assert_eq!(client_frame(&mut io, &mut buf).await, tunnel_auth(CLIENT_NAME));
        server_send(&mut io, &packet_bytes(PKT_TUNNEL_AUTH_RESPONSE, &[0; 8])).await;
        let channel = client_frame(&mut io, &mut buf).await;
        assert_eq!(channel, channel_create("pc1.example.test", 3389).unwrap());
        seen.push("channel".into());
        let mut answer = how.channel_error.to_le_bytes().to_vec();
        answer.extend_from_slice(&[0; 4]);
        server_send(&mut io, &packet_bytes(PKT_CHANNEL_RESPONSE, &answer)).await;
        if how.channel_error != 0 {
            return seen;
        }
        // The channel: what comes is sent back, then the gateway closes it.
        let (ty, body) = {
            let m = client_frame(&mut io, &mut buf).await;
            let (ty, body) = packet(&m).unwrap();
            (ty, body.to_vec())
        };
        assert_eq!(ty, PKT_DATA);
        let echoed = read_data(&body).unwrap().to_vec();
        server_send(&mut io, &data_packet(&echoed)).await;
        seen.push(format!("data {}", String::from_utf8_lossy(&echoed)));
        server_send(&mut io, &packet_bytes(PKT_CLOSE_CHANNEL, &[0xdd, 0x59, 0x07, 0x80])).await;
        let m = client_frame(&mut io, &mut buf).await;
        assert_eq!(packet(&m).unwrap().0, PKT_CLOSE_CHANNEL_RESPONSE);
        seen
    }

    async fn through_played(how: Played) -> (Result<(DuplexStream, GatewayEnd), Closed>, tokio::task::JoinHandle<Vec<String>>) {
        let (client, server) = tokio::io::duplex(1 << 20);
        let played = tokio::spawn(play(server, how));
        (through(client, &gw(), None).await, played)
    }

    #[tokio::test]
    async fn through_a_gateway_signed_in_with_ntlm_the_channel_carries_the_sessions_bytes() {
        let (opened, played) = through_played(Played::default()).await;
        let (mut stream, end) = opened.unwrap();
        stream.write_all(b"hello").await.unwrap();
        let mut back = [0u8; 5];
        stream.read_exact(&mut back).await.unwrap();
        assert_eq!(&back, b"hello");
        // The gateway closed the channel with a code: the stream ends, and the end says why.
        let mut rest = Vec::new();
        let _ = stream.read_to_end(&mut rest).await;
        let seen = played.await.unwrap();
        assert_eq!(seen, ["RDG_OUT_DATA /remoteDesktopGateway/ HTTP/1.1", "upgraded", "channel", "data hello"]);
        let said = end.lock().unwrap().take().unwrap();
        assert_eq!(said.detail, Some("gateway_target"));
    }

    #[tokio::test]
    async fn a_refused_sign_in_and_every_refusal_of_the_gateway_says_what_it_was() {
        let detail = |r: Result<(DuplexStream, GatewayEnd), Closed>| r.err().unwrap().detail;
        let (r, _) = through_played(Played { wrong_password: true, ..Played::default() }).await;
        let e = r.err().unwrap();
        assert_eq!((e.reason, e.detail), (CloseReason::Auth, Some("gateway_sign_in")));
        assert!(!e.message.contains("made-up-password"));
        let (r, _) = through_played(Played { old_transport: true, ..Played::default() }).await;
        assert_eq!(detail(r), Some("gateway_old"));
        let (r, _) = through_played(Played { consent: true, ..Played::default() }).await;
        assert_eq!(detail(r), Some("gateway_consent"));
        let (r, _) = through_played(Played { channel_error: 0x800759DA, ..Played::default() }).await;
        assert_eq!(detail(r), Some("gateway_not_allowed"));
    }

    #[tokio::test]
    async fn a_gateway_that_offers_no_ntlm_or_goes_is_refused() {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let played = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 401 x\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\n\r\n").await.unwrap();
            server
        });
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.detail, Some("gateway_sign_in_kind"));
        assert!(e.message.contains("Basic"), "{}", e.message);
        drop(played.await.unwrap());

        // A gateway that goes without a word.
        let (client, server) = tokio::io::duplex(1 << 16);
        drop(server);
        let e = through(client, &gw(), None).await.err().unwrap();
        assert!(matches!(e.reason, CloseReason::Network | CloseReason::ServerClosed), "{e:?}");
    }

    /// Against a real gateway, run by hand (never in a suite: it is ignored, and it needs these
    /// set). Through the gateway, then the PC's TLS and NLA as a session's, to the connected
    /// desktop's size. In Git Bash, from packages/zest_native/rust:
    ///
    ///   export ZS_RDG_HOST=<gateway address> ZS_RDG_PIN=<its certificate's SHA-256, if not an authority's>
    ///   export ZS_RDG_TARGET=<the PC as the gateway knows it> ZS_USER=<account> ZS_DOMAIN=<optional>
    ///   read -rs ZS_PASSWORD; export ZS_PASSWORD
    ///   cargo +1.99.1 test --features vnc,rdp,mosh,sound --lib live_through_a_gateway -- --ignored --nocapture
    ///
    /// Optional: ZS_RDG_PORT (443), ZS_RDG_USER and ZS_RDG_PASSWORD (the gateway's own sign-in;
    /// the PC's when not set), ZS_RDP_CERT_SHA256 (the PC's pin; not set: the PC's certificate is
    /// reported, nothing signed in to it). Prints each step; the password is never printed.
    #[test]
    #[ignore]
    fn live_through_a_gateway() {
        let var = |n: &str| std::env::var(n).ok().filter(|v| !v.is_empty());
        let (Some(host), Some(target), Some(user), Some(password)) =
            (var("ZS_RDG_HOST"), var("ZS_RDG_TARGET"), var("ZS_USER"), var("ZS_PASSWORD"))
        else {
            panic!("set ZS_RDG_HOST, ZS_RDG_TARGET, ZS_USER and ZS_PASSWORD (see this test's comment)");
        };
        let port: u16 = var("ZS_RDG_PORT").map(|p| p.parse().unwrap()).unwrap_or(443);
        let domain = var("ZS_DOMAIN");
        let request = GatewayRequest {
            host: host.clone(),
            port: Some(port),
            tls_pin: var("ZS_RDG_PIN"),
            username: Some(var("ZS_RDG_USER").unwrap_or_else(|| user.clone())),
            password: Some(var("ZS_RDG_PASSWORD").unwrap_or_else(|| password.clone()).into()),
            domain: domain.clone(),
            target: target.clone(),
            target_port: None,
        };
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async move {
            let tcp = tokio::net::TcpStream::connect((host.as_str(), port)).await.expect("TCP to the gateway");
            println!("TCP to the gateway: up");
            let (tunnel, end) = match open(tcp, &request).await {
                Ok(t) => t,
                Err(e) => {
                    println!("the gateway: {:?} {:?}: {}", e.reason, e.detail, e.message);
                    if let Some(c) = &e.certificate {
                        println!("its certificate: SHA-256 {}", c.sha256);
                    }
                    return;
                }
            };
            println!("the gateway: signed in, tunnel and channel to {target} open");
            let pc_pin = var("ZS_RDP_CERT_SHA256").map(|p| super::super::parse_sha256(&p).unwrap());
            let mut framed = ironrdp_tokio::TokioFramed::new(tunnel);
            let (name, pass) = if pc_pin.is_some() { (user, password) } else { (String::new(), String::new()) };
            let mut config =
                crate::rdp::connector_config(1280, 800, name, pass, domain, crate::rdp::Graphics::Gfx, crate::rdp::Nla::Required);
            let held = crate::rdp::hold_credentials(&mut config);
            let mut connector = ironrdp_connector::ClientConnector::new(config, std::net::SocketAddr::from(([127, 0, 0, 1], 0)));
            let should_upgrade = match ironrdp_tokio::connect_begin(&mut framed, &mut connector).await {
                Ok(s) => s,
                Err(e) => {
                    println!("the PC's connection request: {e}");
                    println!("the gateway's end: {:?}", end.lock().unwrap().take().map(|c| c.message));
                    return;
                }
            };
            let (stream, _) = framed.into_inner();
            let secured = match crate::rdp::tls_upgrade(stream, &target, pc_pin, false).await {
                Ok(s) => s,
                Err(crate::rdp::TlsFailure::Untrusted { sha256, .. }) => {
                    // No pin given: the PC's certificate, through the gateway; nothing sent to it.
                    println!("the PC's certificate, through the gateway: SHA-256 {}", super::super::hex(&sha256));
                    return;
                }
                Err(e) => {
                    println!("the PC's TLS: {e}");
                    return;
                }
            };
            println!("the PC's TLS through the gateway: {} {}", secured.facts().protocol, secured.facts().cipher_suite);
            match secured.sign_in(should_upgrade, connector, held, &target).await {
                Ok(signed) => println!(
                    "signed in to the PC (NLA {}): desktop {}x{}",
                    signed.nla, signed.connection.desktop_size.width, signed.connection.desktop_size.height
                ),
                Err(e) => println!("the PC's sign-in: {e}"),
            }
            println!("the gateway's end: {:?}", end.lock().unwrap().take().map(|c| c.message));
        });
    }

    /// A played gateway that lets anyone in (101 at once) and opens the tunnel and the channel.
    async fn open_gateway(io: &mut DuplexStream, buf: &mut Vec<u8>) {
        let _ = head_of(io, buf).await;
        io.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n").await.unwrap();
        let _ = client_frame(io, buf).await;
        server_send(io, &packet_bytes(PKT_HANDSHAKE_RESPONSE, &[0, 0, 0, 0, 1, 0, 0, 0, 0, 0])).await;
        let _ = client_frame(io, buf).await;
        server_send(io, &packet_bytes(PKT_TUNNEL_RESPONSE, &[0; 10])).await;
        let _ = client_frame(io, buf).await;
        server_send(io, &packet_bytes(PKT_TUNNEL_AUTH_RESPONSE, &[0; 8])).await;
        let _ = client_frame(io, buf).await;
        server_send(io, &packet_bytes(PKT_CHANNEL_RESPONSE, &[0; 8])).await;
    }

    /// Both ways full at once: the gateway sends 320 KiB and reads nothing until it has, while
    /// the session writes 320 KiB before it reads (a large clipboard answer while the screen
    /// moves). Both get through: the carrier never waits on the session without reading it.
    #[tokio::test]
    async fn the_gateways_data_and_the_sessions_both_get_through_when_neither_reads_first() {
        let (client, mut server) = tokio::io::duplex(1 << 21);
        const TOTAL: usize = 20 * DATA_CHUNK;
        let gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            open_gateway(&mut server, &mut buf).await;
            for _ in 0..TOTAL / DATA_CHUNK {
                server_send(&mut server, &data_packet(&[7u8; DATA_CHUNK])).await;
            }
            // Then what the session sent.
            let mut got = 0;
            while got < TOTAL {
                let m = client_frame(&mut server, &mut buf).await;
                let (ty, body) = packet(&m).unwrap();
                if ty == PKT_DATA {
                    got += read_data(body).unwrap().len();
                }
            }
            got
        });
        let (stream, _end) = through(client, &gw(), None).await.unwrap();
        let (mut r, mut w) = tokio::io::split(stream);
        let done = tokio::time::timeout(Duration::from_secs(10), async {
            w.write_all(&vec![9u8; TOTAL]).await.unwrap();
            let mut back = vec![0u8; TOTAL];
            if let Err(e) = r.read_exact(&mut back).await {
                panic!("{e}: the carrier ended with {:?}", _end.lock().unwrap().take());
            }
            assert!(back.iter().all(|b| *b == 7));
            gateway.await.unwrap()
        })
        .await
        .expect("the session and the gateway held each other");
        assert_eq!(done, TOTAL);
    }

    /// A gateway that stops talking: a refusal whose body never comes, and a tunnel step answered
    /// only by keepalives. Each ends within its step's time, said as the network's failure.
    #[tokio::test]
    async fn a_gateway_that_stops_answering_is_given_up_on_within_a_step() {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let _gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server
                .write_all(b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: NTLM\r\nContent-Length: 60000\r\n\r\nonly this")
                .await
                .unwrap();
            // ... and nothing more, with the connection kept open.
            tokio::time::sleep(Duration::from_secs(30)).await;
            drop(server);
        });
        let started = std::time::Instant::now();
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(started.elapsed() < STEP_TIMEOUT + Duration::from_secs(1), "{:?}", started.elapsed());

        let (client, mut server) = tokio::io::duplex(1 << 16);
        let _gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n").await.unwrap();
            let _ = client_frame(&mut server, &mut buf).await;
            // Keepalives, never the handshake's answer.
            loop {
                server_send(&mut server, &packet_bytes(PKT_KEEPALIVE, &[])).await;
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        });
        let started = std::time::Instant::now();
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(e.message.contains("the handshake"), "{}", e.message);
        assert!(started.elapsed() < STEP_TIMEOUT + Duration::from_secs(1), "{:?}", started.elapsed());
    }

    #[test]
    fn a_pinned_gateway_certificate_is_the_only_one_taken() {
        use crate::ftps::verify::{Decision, decide};
        let pinned = gateway_policy(Some([1; 32]));
        assert_eq!(decide(&pinned, None, &[1; 32], false), Decision::Trusted);
        assert_eq!(decide(&pinned, None, &[2; 32], true), Decision::Refused, "another, even an authority's, is asked about");
        let first = gateway_policy(None);
        assert_eq!(decide(&first, None, &[2; 32], true), Decision::Trusted, "before one is accepted, an authority's");
        assert_eq!(decide(&first, None, &[2; 32], false), Decision::Refused);
    }

    #[test]
    fn the_gateways_sign_in_needs_a_name_and_a_password() {
        let mut g = gw();
        g.username = None;
        assert_eq!(NtlmHttp::new(&g, None).err().unwrap().detail, Some("gateway_sign_in"));
        let mut g = gw();
        g.password = None;
        assert_eq!(NtlmHttp::new(&g, None).err().unwrap().detail, Some("gateway_sign_in"));
        let mut client = NtlmHttp::new(&gw(), Some(b"tls-server-end-point:x")).unwrap();
        let first = client.step(None).unwrap();
        assert!(first.starts_with(b"NTLMSSP\0\x01"), "NTLM's first message");
    }

    // A gateway that is hostile or broken, after TLS: what it can make the client do.

    /// An answer's head that never ends: sent a byte at a time for ever, or longer than a head
    /// may be. The first ends within a step's time, the second as soon as it is too long.
    #[tokio::test]
    async fn a_head_that_never_ends_is_given_up_on() {
        let (client, mut server) = tokio::io::duplex(1 << 16);
        let _gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 401 Access Denied\r\n").await.unwrap();
            loop {
                if server.write_all(b"X").await.is_err() {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        });
        let started = std::time::Instant::now();
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(started.elapsed() < STEP_TIMEOUT + Duration::from_secs(1), "{:?}", started.elapsed());

        let (client, mut server) = tokio::io::duplex(1 << 16);
        let gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            let line = [b'a'; 1024];
            let mut sent = 0usize;
            // Until the client goes: it must, long before this much.
            while sent < 64 * MAX_HEAD && server.write_all(&line).await.is_ok() {
                sent += line.len();
            }
            sent
        });
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Protocol, "{e:?}");
        assert!(e.message.contains("head longer"), "{}", e.message);
        // What it took before it said so: the head's bound and what was on the way, no more.
        assert!(gateway.await.unwrap() <= MAX_HEAD + (1 << 16) + 8192);
    }

    /// A redirect is not followed and a sign-in that goes wrong is not tried again: one request
    /// for the first, two for the second, and nothing more is asked of the gateway.
    #[tokio::test]
    async fn a_redirect_is_not_followed_and_a_bad_challenge_ends_the_sign_in() {
        async fn requests(mut server: DuplexStream, answers: &'static [&'static [u8]]) -> usize {
            let mut buf = Vec::new();
            let mut asked = 0;
            for answer in answers {
                let _ = head_of(&mut server, &mut buf).await;
                asked += 1;
                server.write_all(answer).await.unwrap();
            }
            // Anything more the client asks is counted, until it goes.
            let mut chunk = [0u8; 4096];
            loop {
                match tokio::time::timeout(Duration::from_secs(1), server.read(&mut chunk)).await {
                    Ok(Ok(n)) if n > 0 => asked += 1,
                    _ => return asked,
                }
            }
        }
        let (client, server) = tokio::io::duplex(1 << 16);
        let gateway = tokio::spawn(requests(
            server,
            &[b"HTTP/1.1 302 Found\r\nLocation: https://other.example.test/remoteDesktopGateway/\r\nContent-Length: 0\r\n\r\n"],
        ));
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.detail, Some("gateway_none"));
        assert!(!e.message.contains("other.example"), "where it sends is not repeated: {}", e.message);
        assert_eq!(gateway.await.unwrap(), 1);

        // A challenge that is no NTLM message.
        let (client, server) = tokio::io::duplex(1 << 16);
        let gateway = tokio::spawn(requests(
            server,
            &[
                b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: NTLM\r\nContent-Length: 0\r\n\r\n",
                b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: NTLM AAAAAAAAAAAAAAAA\r\nContent-Length: 0\r\n\r\n",
            ],
        ));
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Protocol, "{e:?}");
        assert!(!e.message.contains("made-up-password"));
        assert_eq!(gateway.await.unwrap(), 2);

        // A gateway that asks for Basic once NTLM has begun gets no password: the sign-in ends.
        let (client, server) = tokio::io::duplex(1 << 16);
        let gateway = tokio::spawn(async move {
            let mut server = server;
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: NTLM\r\nContent-Length: 0\r\n\r\n").await.unwrap();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 401 Access Denied\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\n\r\n").await.unwrap();
            let mut all = Vec::new();
            let _ = tokio::time::timeout(Duration::from_secs(1), server.read_to_end(&mut all)).await;
            all
        });
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Protocol, "{e:?}");
        let after = gateway.await.unwrap();
        assert!(!String::from_utf8_lossy(&after).contains("Basic"), "no Basic sign-in is sent");
        assert!(!after.windows(8).any(|w| w == b"made-up-"));
    }

    /// Pings without end in place of a tunnel step's answer, from a gateway that reads none of
    /// the pongs: the setting up still ends, within its whole time at the latest.
    #[tokio::test]
    async fn pings_without_end_do_not_hold_the_setting_up() {
        // A small pipe: the pongs fill it, as they fill a socket whose other end reads nothing.
        let (client, mut server) = tokio::io::duplex(2048);
        let _gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            let _ = head_of(&mut server, &mut buf).await;
            server.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n").await.unwrap();
            let _ = client_frame(&mut server, &mut buf).await;
            let ping = [0x89u8, 4, b'p', b'i', b'n', b'g'];
            loop {
                if tokio::time::timeout(Duration::from_millis(200), server.write_all(&ping)).await.is_err() {
                    // Full both ways: held, with the connection kept open.
                    tokio::time::sleep(Duration::from_secs(60)).await;
                }
            }
        });
        let started = std::time::Instant::now();
        let e = through(client, &gw(), None).await.err().unwrap();
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(started.elapsed() < SETUP_TIMEOUT + Duration::from_secs(1), "{:?}", started.elapsed());
    }

    /// Data without end for a session that reads none of it: the carrier keeps [MAX_PENDING] and
    /// a packet, the pipe to the session its own, and then the gateway is not read any more.
    #[tokio::test]
    async fn data_without_end_is_not_kept_for_a_session_that_does_not_read() {
        const PIPE: usize = 1 << 16;
        let (client, mut server) = tokio::io::duplex(PIPE);
        let gateway = tokio::spawn(async move {
            let mut buf = Vec::new();
            open_gateway(&mut server, &mut buf).await;
            let packet = data_packet(&[7u8; 0xFFFF]);
            let mut sent = 0usize;
            loop {
                let mut f = vec![0x82, 127];
                f.extend_from_slice(&(packet.len() as u64).to_be_bytes());
                f.extend_from_slice(&packet);
                match tokio::time::timeout(Duration::from_secs(1), server.write_all(&f)).await {
                    Ok(Ok(())) => sent += packet.len(),
                    // Not taken any more: the client stopped reading.
                    _ => return (sent, server),
                }
            }
        });
        let (stream, _end) = through(client, &gw(), None).await.unwrap();
        let (sent, _server) = gateway.await.unwrap();
        // What the client holds: its buffer of the gateway's data, one more packet, the pipe to
        // the session, the pipe from the gateway and a read's worth.
        let most = MAX_PENDING + 2 * 0x1_0000 + 4 * DATA_CHUNK + PIPE + 0x1_0000;
        assert!(sent <= most, "{sent} bytes taken from a gateway nobody reads (at most {most})");
        assert!(sent >= MAX_PENDING, "{sent}");
        drop(stream);
    }

    /// The app's own stream, as the engine sees it: a read is ready whenever bytes wait, and a
    /// write is taken at once whatever the other end does (it is handed to the app's socket).
    /// It gives `first`, then `again` over and over, `rounds` times, then ends.
    struct Flood {
        first: Vec<u8>,
        again: &'static [u8],
        rounds: usize,
        written: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl AsyncRead for Flood {
        fn poll_read(
            mut self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            buf: &mut tokio::io::ReadBuf<'_>,
        ) -> std::task::Poll<std::io::Result<()>> {
            if !self.first.is_empty() {
                let n = self.first.len().min(buf.remaining());
                buf.put_slice(&self.first[..n]);
                self.first.drain(..n);
                return std::task::Poll::Ready(Ok(()));
            }
            while self.rounds > 0 && buf.remaining() >= self.again.len() {
                buf.put_slice(self.again);
                self.rounds -= 1;
            }
            std::task::Poll::Ready(Ok(()))
        }
    }

    impl AsyncWrite for Flood {
        fn poll_write(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut std::task::Context<'_>,
            data: &[u8],
        ) -> std::task::Poll<std::io::Result<usize>> {
            self.written.fetch_add(data.len(), std::sync::atomic::Ordering::SeqCst);
            std::task::Poll::Ready(Ok(data.len()))
        }
        fn poll_flush(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
        fn poll_shutdown(self: std::pin::Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> std::task::Poll<std::io::Result<()>> {
            std::task::Poll::Ready(Ok(()))
        }
    }

    /// `through` over a [Flood], on a thread of its own: how it ended, how long it took and how
    /// many bytes it wrote; None where it had not ended `within`.
    fn through_a_flood(again: &'static [u8], rounds: usize, within: Duration) -> Option<(Closed, Duration, usize)> {
        let written = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let flood = Flood {
            first: b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_vec(),
            again,
            rounds,
            written: written.clone(),
        };
        let (done, ended) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            let started = std::time::Instant::now();
            let e = runtime.block_on(through(flood, &gw(), None)).err().unwrap();
            let _ = done.send((e, started.elapsed()));
        });
        let (e, took) = ended.recv_timeout(within).ok()?;
        Some((e, took, written.load(std::sync::atomic::Ordering::SeqCst)))
    }

    /// Pings as fast as they can be read, in place of a tunnel step's answer, on a stream that
    /// is always ready (the app's own): the step still ends in its time, and the gateway is not
    /// sent a pong for each (a write to the app's socket is never refused, so each one would
    /// wait in the app for a gateway that reads none).
    #[test]
    fn a_flood_of_pings_neither_holds_a_step_nor_gets_a_pong_each() {
        const PING: &[u8] = &[0x89, 4, b'p', b'i', b'n', b'g'];
        // Enough to last far longer than a step (it ends by itself in the end, so a failing
        // run does not spin for ever).
        let (e, took, written) = through_a_flood(PING, 400_000_000, STEP_TIMEOUT + Duration::from_secs(3))
            .expect("the step did not end in its time: the flood held it");
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(e.message.contains("the handshake"), "{}", e.message);
        assert!(took < STEP_TIMEOUT + Duration::from_secs(1), "{took:?}");
        // The upgrade's request, the handshake, and a pong now and then: not one for each ping.
        assert!(written < 4096, "{written} bytes written to a gateway that only pings");
    }

    /// The same with keepalives, which ask for no answer: the step ends in its time.
    #[test]
    fn a_flood_of_keepalives_does_not_hold_a_step() {
        const KEEPALIVE_FRAME: &[u8] = &[0x82, 8, 0x0d, 0, 0, 0, 8, 0, 0, 0];
        let (e, took, _) = through_a_flood(KEEPALIVE_FRAME, 400_000_000, STEP_TIMEOUT + Duration::from_secs(3))
            .expect("the step did not end in its time: the flood held it");
        assert_eq!(e.reason, CloseReason::Network, "{e:?}");
        assert!(took < STEP_TIMEOUT + Duration::from_secs(1), "{took:?}");
    }

    /// The same once the channel is open, where no step's time runs: the session's own work
    /// still has its turn (a timer of its own fires), and the pongs stay few.
    #[test]
    fn a_flood_of_pings_in_the_channel_leaves_the_session_its_turn() {
        const PING: &[u8] = &[0x89, 4, b'p', b'i', b'n', b'g'];
        fn framed(packet: &[u8]) -> Vec<u8> {
            let mut f = vec![0x82, packet.len() as u8];
            f.extend_from_slice(packet);
            f
        }
        let mut first = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".to_vec();
        first.extend(framed(&packet_bytes(PKT_HANDSHAKE_RESPONSE, &[0, 0, 0, 0, 1, 0, 0, 0, 0, 0])));
        first.extend(framed(&packet_bytes(PKT_TUNNEL_RESPONSE, &[0; 10])));
        first.extend(framed(&packet_bytes(PKT_TUNNEL_AUTH_RESPONSE, &[0; 8])));
        first.extend(framed(&packet_bytes(PKT_CHANNEL_RESPONSE, &[0; 8])));
        let written = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let flood = Flood { first, again: PING, rounds: 400_000_000, written: written.clone() };
        let (done, ended) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
            runtime.block_on(async move {
                let (stream, _end) = through(flood, &gw(), None).await.unwrap();
                // The session's own work, beside the carrier on the one thread.
                tokio::time::sleep(Duration::from_millis(1500)).await;
                let _ = done.send(());
                drop(stream);
            });
        });
        ended.recv_timeout(Duration::from_secs(6)).expect("the session's timer never fired: the flood held the thread");
        let written = written.load(std::sync::atomic::Ordering::SeqCst);
        assert!(written < 4096, "{written} bytes written to a gateway that only pings");
    }

    /// Frames a gateway may not send, each refused as it is read, before any of it is kept.
    #[test]
    fn frames_a_gateway_may_not_send_are_refused_without_being_kept() {
        let refused = |bytes: &[u8]| parse_frame(&mut bytes.to_vec(), &mut None).is_err();
        // A length of 2^63 and of 2^64 - 1 in the 64 bit form: refused on its ten bytes.
        assert!(refused(&[0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0]));
        assert!(refused(&[0x82, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]));
        // One more than a message may be, in the 64 bit form.
        let mut over = vec![0x82, 127];
        over.extend_from_slice(&((MAX_MESSAGE as u64) + 1).to_be_bytes());
        assert!(refused(&over));
        // Pieces that add up to more than a message: refused at the piece that goes over.
        let mut buf = vec![0x02, 126, 0xff, 0xff];
        buf.extend_from_slice(&[0u8; 0xFFFF]);
        let mut pieces = None;
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), None);
        let mut more = vec![0x00, 126, 0x00, 0x20];
        more.extend_from_slice(&[0u8; 0x20]);
        assert!(parse_frame(&mut more, &mut pieces).is_err());
        // Empty pieces without end keep nothing and end with the bytes given.
        let mut pieces = None;
        let mut buf = vec![0x02, 0];
        for _ in 0..10_000 {
            buf.extend_from_slice(&[0x00, 0]);
        }
        assert_eq!(parse_frame(&mut buf, &mut pieces).unwrap(), None);
        assert!(buf.is_empty());
        assert_eq!(pieces.as_deref(), Some(&[][..]));
        // A data packet that says more bytes than it has, and a packet shorter than its header.
        assert!(read_data(&[0xff, 0xff, 1, 2, 3]).is_err());
        assert!(packet(&[0x0a, 0, 0, 0, 8, 0, 0]).is_err());
    }
}

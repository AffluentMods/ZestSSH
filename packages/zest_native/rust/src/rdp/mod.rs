//! RDP (4.0, feature "rdp"): what IronRDP needs from us for a session
//! over rustls with ring (the TLS upgrade with a pinned certificate, the connector's settings),
//! used by the screen module's RDP session (src/screen/rdp_session.rs), and the developer probe
//! ([probe], feature "probes").
//!
//! TLS is ours ([tls_upgrade]: tokio-rustls with ring and a pin check), for the probe and the
//! screen session alike. ironrdp-tls is not used: its rustls config writes TLS secrets to the
//! file `SSLKEYLOGFILE` names, and it brought rustls-native-certs for a check against the
//! platform's roots that an RDP server's self-signed certificate never passes anyway.
//!
//! RDP never runs without TLS, and that is a type here, not a check someone has to remember:
//! [tls_upgrade] is the only thing that makes a [Secured] stream, and the sign-in
//! ([Secured::sign_in], where the user name and the password leave and the session's stream
//! comes from) is a method of it. IronRDP's own two calls for that step take any stream, so they
//! are made in this file and nowhere else (the test `only_the_tls_step_signs_in` reads the
//! crate's source for them).
//!
//! Nothing that names the person crosses before TLS either: the user name and the password are
//! kept out of the connector until then ([hold_credentials] says why).
//!
//! Self-contained (nothing from the rest of the crate), so the example can compile it directly.

#[cfg(feature = "probes")]
pub mod probe;
#[cfg(feature = "probes")]
pub use probe::{ProbeReport, ProbeRequest, probe, probe_json};

use std::sync::{Arc, Mutex};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName as TlsServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use tokio::io::{AsyncRead, AsyncWrite};

use ironrdp_connector::credssp::CredsspSequence;
use ironrdp_connector::sspi::credssp::TsRequest;
use ironrdp_connector::sspi::generator::{GeneratorState, NetworkRequest};
use ironrdp_connector::{
    BitmapConfig, ClientConnector, ClientConnectorState, Config, ConnectionResult, ConnectorError, ConnectorErrorKind,
    ConnectorResult, Credentials, DesktopSize, ServerName, custom_err, general_err, reason_err,
};
use ironrdp_pdu::WriteBuf;
use ironrdp_pdu::gcc::{ConnectionType, KeyboardType};
use ironrdp_pdu::rdp::capability_sets::{BitmapCodecs, MajorPlatformType, RailSupportLevel, client_codecs_capabilities};
use ironrdp_pdu::rdp::client_info::{PerformanceFlags, TimezoneInfo};
use ironrdp_tokio::{FramedWrite as _, NetworkClient, ShouldUpgrade, TokioFramed};
use sha2::{Digest as _, Sha256};

/// Kerberos would ask the KDC through this; sessions do NTLM only for now.
pub struct NoNetwork;

impl NetworkClient for NoNetwork {
    async fn send(&mut self, _request: &NetworkRequest) -> ConnectorResult<Vec<u8>> {
        Err(general_err!("no KDC is reached (NTLM only)"))
    }
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256(der: &[u8]) -> [u8; 32] {
    Sha256::digest(der).into()
}

/// The certificate check: the pinned fingerprint (or, for the probe's first use, any). What was
/// shown is kept for the error.
#[derive(Debug)]
struct PinVerifier {
    pin: Option<[u8; 32]>,
    accept_unpinned: bool,
    shown: Arc<Mutex<Option<(Vec<u8>, bool)>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &TlsServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let trusted = match self.pin {
            Some(pin) => pin == sha256(end_entity.as_ref()),
            None => self.accept_unpinned,
        };
        *self.shown.lock().unwrap() = Some((end_entity.as_ref().to_vec(), trusted));
        if trusted {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(rustls::Error::General("certificate not pinned".into()))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// What TLS settled on.
#[derive(Debug, Clone)]
pub struct TlsFacts {
    pub protocol: String,
    pub cipher_suite: String,
    pub cert_sha256: [u8; 32],
    /// The certificate's subject public key (CredSSP binds to it).
    pub public_key: Vec<u8>,
    /// It matched the pin (false: nothing was pinned and the probe took it as first seen).
    pub pinned: bool,
}

/// Why TLS did not come up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TlsFailure {
    /// The certificate is not the pinned one (or nothing was pinned): its SHA-256 and the
    /// certificate itself (DER), for the question the app asks.
    Untrusted { sha256: [u8; 32], der: Vec<u8> },
    /// The handshake failed otherwise.
    Failed(String),
}

impl std::fmt::Display for TlsFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TlsFailure::Untrusted { sha256, .. } => write!(f, "certificate not trusted: SHA-256 {}", hex(sha256)),
            TlsFailure::Failed(e) => write!(f, "TLS: {e}"),
        }
    }
}

/// The user name and the password, kept out of the connector until TLS is up.
///
/// IronRDP writes the user name into the connection request (`Cookie: mstshash=<name>`, which a
/// load balancer may read), and that request is the one message that crosses before TLS: on a
/// direct connection anyone on the path would read the account's name, and so would a server
/// that has not shown its certificate yet. A connector whose user name is empty sends no cookie,
/// so [hold_credentials] takes both out of the settings, and [Secured::sign_in] puts them back,
/// inside TLS. The sign-in asks for this value and only [hold_credentials] makes one, so a
/// session cannot be written that leaves the step out. (Found by the test
/// `a_server_that_picks_rdp_without_tls_is_refused_and_told_nothing`.)
pub struct HeldCredentials(Credentials);

/// Takes the credentials out of `config`, for [Secured::sign_in] to put back.
pub fn hold_credentials(config: &mut Config) -> HeldCredentials {
    let nobody = Credentials::UsernamePassword { username: String::new(), password: String::new() };
    HeldCredentials(std::mem::replace(&mut config.credentials, nobody))
}

fn give_back(connector: &mut ClientConnector, held: HeldCredentials) {
    connector.config.credentials = held.0;
}

/// A stream TLS has come up on, with what TLS settled.
///
/// Its fields are private and [tls_upgrade] is the only thing that fills them, so holding one
/// is the proof that the handshake ran and the certificate was the pinned one. The sign-in
/// takes this and nothing else ([Secured::sign_in]).
pub struct Secured<T> {
    framed: TokioFramed<T>,
    facts: TlsFacts,
}

/// Signed in: the connector's result and the stream the session goes on with, the one TLS came
/// up on. Made only by [Secured::sign_in] (the last field is private).
pub struct SignedIn<T> {
    pub connection: ConnectionResult,
    pub framed: TokioFramed<T>,
    pub facts: TlsFacts,
    /// The server asked for NLA, and CredSSP ran before anything else was sent.
    pub nla: bool,
    _only_from_sign_in: (),
}

impl<T> Secured<T> {
    pub fn facts(&self) -> &TlsFacts {
        &self.facts
    }

    /// For the fuzz targets only (they build with `--cfg fuzzing`, which no build of the app
    /// sets): a stream taken as if TLS had come up on it, so the bytes a target feeds reach the
    /// sign-in and the session as a server's would after the handshake.
    #[cfg(fuzzing)]
    pub fn for_fuzzing(framed: TokioFramed<T>) -> Self {
        let facts = TlsFacts {
            protocol: "none (fuzzing)".into(),
            cipher_suite: String::new(),
            cert_sha256: [0; 32],
            public_key: vec![7; 32],
            pinned: false,
        };
        Self { framed, facts }
    }
}

impl<T> Secured<T>
where
    T: AsyncRead + AsyncWrite + Send + Sync + Unpin,
{
    /// The rest of the connection sequence, inside TLS: the credentials go back into the
    /// connector, then CredSSP when the server asked for NLA (bound to the certificate's public
    /// key), the settings, the channels, the licence and the capabilities. A server that
    /// redirects to another session is not followed.
    pub async fn sign_in(
        self,
        should_upgrade: ShouldUpgrade,
        mut connector: ClientConnector,
        credentials: HeldCredentials,
        server_name: &str,
    ) -> ConnectorResult<SignedIn<T>> {
        let Secured { mut framed, facts } = self;
        give_back(&mut connector, credentials);
        let upgraded = ironrdp_tokio::mark_as_upgraded(should_upgrade, &mut connector);
        let nla = connector.should_perform_credssp();
        if nla {
            // Ours, so that IronRDP's own (inside the call below) finds it done.
            credssp(&mut connector, &mut framed, server_name, &facts.public_key).await?;
        }
        let outcome = ironrdp_tokio::connect_finalize(
            upgraded,
            connector,
            &mut framed,
            &mut NoNetwork,
            ServerName::new(server_name),
            facts.public_key.clone(),
            None,
        )
        .await?;
        let connection = outcome.into_connected()?;
        Ok(SignedIn { connection, framed, facts, nla, _only_from_sign_in: () })
    }
}

/// The size of an NTLM signature, which sspi takes off the front of the server's proof.
const CREDSSP_SIGNATURE: usize = 16;

/// A CredSSP message of the server's, looked at before sspi gets it.
///
/// sspi 0.23.0 and 0.23.1 split the server's proof of the TLS key (`pubKeyAuth`) at 16 bytes
/// without looking at its length (src/credssp/mod.rs, `decrypt_message`), so a shorter proof
/// panicked: any server a person connects to could end the app with one message, after its
/// certificate was accepted and before it had signed anyone in. Found by fuzzing the sign-in
/// (fuzz/fuzz_targets/rdp_credssp.rs) within three minutes.
fn fit_for_sspi(message: &TsRequest) -> ConnectorResult<()> {
    match &message.pub_key_auth {
        Some(proof) if proof.len() < CREDSSP_SIGNATURE => Err(reason_err!(
            "CredSSP",
            "the server's proof of the TLS key is {} bytes, shorter than a signature",
            proof.len()
        )),
        _ => Ok(()),
    }
}

/// CredSSP (NLA), inside TLS: NTLM, bound to the certificate's public key. The steps are those of
/// IronRDP's own loop (ironrdp-async 0.12.0, `perform_credssp`, which this stands in for), with
/// one thing added: each message of the server's passes [fit_for_sspi] first.
async fn credssp<T>(
    connector: &mut ClientConnector,
    framed: &mut TokioFramed<T>,
    server_name: &str,
    public_key: &[u8],
) -> ConnectorResult<()>
where
    T: AsyncRead + AsyncWrite + Send + Sync + Unpin,
{
    let ClientConnectorState::Credssp { selected_protocol, .. } = connector.state else {
        return Err(general_err!("the connector is not at CredSSP"));
    };
    let (mut sequence, mut message) = CredsspSequence::init(
        connector.config.credentials.clone(),
        connector.config.domain.as_deref(),
        selected_protocol,
        ServerName::new(server_name),
        public_key.to_vec(),
        None,
    )?;
    let mut buf = WriteBuf::new();
    loop {
        let ours = {
            let mut generator = sequence.process_ts_request(message);
            let mut state = generator.start();
            loop {
                match state {
                    // Kerberos would ask its KDC here; [NoNetwork] refuses.
                    GeneratorState::Suspended(request) => {
                        let answer = NoNetwork.send(&request).await?;
                        state = generator.resume(Ok(answer));
                    }
                    GeneratorState::Completed(done) => {
                        break done.map_err(|e| ConnectorError::new("CredSSP", ConnectorErrorKind::Credssp(e)))?;
                    }
                }
            }
        };
        buf.clear();
        let written = sequence.handle_process_result(ours, &mut buf)?;
        if let Some(len) = written.size() {
            framed.write_all(&buf[..len]).await.map_err(|e| custom_err!("write all", e))?;
        }
        let Some(hint) = sequence.next_pdu_hint() else { break };
        let pdu = framed.read_by_hint(hint).await.map_err(|e| custom_err!("read frame by hint", e))?;
        match sequence.decode_server_message(&pdu)? {
            Some(next) => {
                fit_for_sspi(&next)?;
                message = next;
            }
            None => break,
        }
    }
    connector.mark_credssp_as_done();
    Ok(())
}

/// TLS over [stream], the certificate trusted only by [pin] (or any, with [accept_unpinned], for
/// the probe's first use). Signatures are verified with ring's algorithms; no key log, no
/// resumption (each connection is new).
pub async fn tls_upgrade<S>(
    stream: S,
    server_name: &str,
    pin: Option<[u8; 32]>,
    accept_unpinned: bool,
) -> Result<Secured<tokio_rustls::client::TlsStream<S>>, TlsFailure>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let shown = Arc::new(Mutex::new(None));
    let verifier = PinVerifier { pin, accept_unpinned, shown: shown.clone(), provider: provider.clone() };
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| TlsFailure::Failed(e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    config.resumption = rustls::client::Resumption::disabled();
    let name = TlsServerName::try_from(server_name.to_owned())
        .unwrap_or_else(|_| TlsServerName::try_from("rdp.invalid").unwrap());
    let tls = match tokio_rustls::TlsConnector::from(Arc::new(config)).connect(name, stream).await {
        Ok(tls) => tls,
        Err(e) => {
            if let Some((der, false)) = shown.lock().unwrap().take() {
                return Err(TlsFailure::Untrusted { sha256: sha256(&der), der });
            }
            return Err(TlsFailure::Failed(e.to_string()));
        }
    };
    let (_, conn) = tls.get_ref();
    let der = conn
        .peer_certificates()
        .and_then(|c| c.first())
        .ok_or_else(|| TlsFailure::Failed("no certificate".into()))?;
    let public_key = {
        use x509_cert::der::Decode as _;
        let cert = x509_cert::Certificate::from_der(der.as_ref()).map_err(|e| TlsFailure::Failed(format!("certificate: {e}")))?;
        cert.tbs_certificate()
            .subject_public_key_info()
            .subject_public_key
            .as_bytes()
            .ok_or_else(|| TlsFailure::Failed("the certificate has no public key".into()))?
            .to_vec()
    };
    let cert_sha256 = sha256(der.as_ref());
    let facts = TlsFacts {
        protocol: conn.protocol_version().map(|v| format!("{v:?}")).unwrap_or_default(),
        cipher_suite: conn.negotiated_cipher_suite().map(|c| format!("{:?}", c.suite())).unwrap_or_default(),
        cert_sha256,
        public_key,
        pinned: pin == Some(cert_sha256),
    };
    Ok(Secured { framed: TokioFramed::new(tls), facts })
}

/// A SHA-256 in hex (colons allowed, either case).
pub fn parse_pin(hex: &str) -> Result<[u8; 32], String> {
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

/// What the client offers for the picture. The server picks: a server with the graphics pipeline
/// (MS-RDPEGFX) on the dynamic channel uses it when it is offered; one without it but with
/// RemoteFX uses RemoteFX in fast-path surface commands; any other sends bitmap updates (planar
/// or interleaved RLE, or uncompressed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Graphics {
    /// Bitmap updates only (day 3: no codec offered).
    Bitmap,
    /// RemoteFX in surface commands (the Bitmap Codecs capability set), no graphics pipeline.
    RemoteFx,
    /// The graphics pipeline (its RemoteFX Progressive, RemoteFX, planar, ClearCodec and the
    /// rest; AVC only with an H.264 decoder), and RemoteFX in surface commands for a server
    /// without it. The default.
    Gfx,
}

impl Graphics {
    /// "bitmap", "remotefx", "gfx" (or "auto", the default).
    pub fn parse(name: Option<&str>) -> Result<Self, String> {
        match name.map(str::to_ascii_lowercase).as_deref() {
            None | Some("") | Some("auto") | Some("gfx") => Ok(Self::Gfx),
            Some("remotefx") | Some("rfx") => Ok(Self::RemoteFx),
            Some("bitmap") | Some("none") => Ok(Self::Bitmap),
            Some(other) => Err(format!("unknown RDP graphics mode: {other} (bitmap, remotefx or gfx)")),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Bitmap => "bitmap",
            Self::RemoteFx => "remotefx",
            Self::Gfx => "gfx",
        }
    }
}

/// How a session signs in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Nla {
    /// Network Level Authentication or nothing (a host's default): only CredSSP is asked for,
    /// so the name and the password go to a server only inside CredSSP, which proves both
    /// sides know the password and binds the sign-in to the TLS certificate. A server without
    /// NLA is refused, never fallen back to.
    Required,
    /// The host's "Sign in without NLA": TLS alone is asked for, and the app sends no password
    /// at all (the server shows its own sign-in screen, and the person types into the picture).
    Without,
    /// Whatever the server picks, the password in the Client Info PDU where it picks TLS alone:
    /// the developer probe's way, for measuring against any test server. Never a session's.
    Offered,
}

/// IronRDP's settings for a session: TLS always (never Standard RDP Security), NLA as `nla`
/// says, a US keyboard, no audio, the graphics `graphics` says. The screen session uses it too.
pub fn connector_config(
    width: u16,
    height: u16,
    username: String,
    password: String,
    domain: Option<String>,
    graphics: Graphics,
    nla: Nla,
) -> Config {
    // Without NLA the password is not the app's to send: it would reach a server that has
    // proved nothing but its certificate.
    let password = if nla == Nla::Without { String::new() } else { password };
    // RemoteFX (IronRDP's only surface command codec without its qoi features) at 32 bits a
    // pixel; lossless bitmap compression otherwise (no colour subsampling asked for).
    let bitmap = match graphics {
        Graphics::Bitmap => None,
        Graphics::RemoteFx | Graphics::Gfx => Some(BitmapConfig {
            lossy_compression: false,
            color_depth: 32,
            codecs: client_codecs_capabilities(&[]).unwrap_or(BitmapCodecs(Vec::new())),
        }),
    };
    Config {
        desktop_size: DesktopSize { width, height },
        monitor_layout: None,
        desktop_scale_factor: 0,
        desktop_physical_size: None,
        desktop_orientation: None,
        device_scale_factor: None,
        monitor_extended_layout: None,
        relative_mouse_input: false,
        // What the connection request asks for ([Nla]); never Standard RDP Security. Either
        // way the connection is inside TLS: CredSSP runs on top of it.
        enable_tls: nla != Nla::Required,
        enable_credssp: nla != Nla::Without,
        enable_standard_rdp_security: false,
        credentials: Credentials::UsernamePassword { username, password },
        domain,
        client_build: 0,
        client_name: "zestssh".to_owned(),
        keyboard_type: KeyboardType::IBM_ENHANCED,
        keyboard_subtype: 0,
        keyboard_functional_keys_count: 12,
        keyboard_layout: 0x0409,
        connection_type: ConnectionType::Lan,
        ime_file_name: String::new(),
        bitmap,
        dig_product_id: String::new(),
        client_dir: "C:\\Windows\\System32\\mstscax.dll".to_owned(),
        alternate_shell: String::new(),
        work_dir: String::new(),
        remote_application_mode: false,
        rail_support_level: RailSupportLevel::empty(),
        platform: platform(),
        hardware_id: None,
        request_data: None,
        // The password in the Client Info PDU, inside TLS: after NLA (Windows signs the person
        // in with what CredSSP already checked), or for the probe; never without NLA.
        autologon: nla != Nla::Without,
        enable_audio_playback: false,
        enable_audio_capture: false,
        performance_flags: PerformanceFlags::default(),
        license_cache: None,
        timezone_info: TimezoneInfo::default(),
        compression_type: None,
        // The server's pointer shapes come as they are (not drawn into IronRDP's picture, which
        // a session with the graphics pipeline does not show): the app draws them, as VNC's.
        enable_server_pointer: true,
        pointer_software_rendering: false,
        multitransport_flags: None,
        // The early capability flag that tells the server the client takes the graphics
        // pipeline (xrdp then opens it once the dynamic channels are up).
        support_dyn_vc_gfx_protocol: graphics == Graphics::Gfx,
    }
}

pub fn platform() -> MajorPlatformType {
    if cfg!(windows) {
        MajorPlatformType::WINDOWS
    } else if cfg!(target_os = "ios") {
        MajorPlatformType::IOS
    } else if cfg!(target_os = "macos") {
        MajorPlatformType::MACINTOSH
    } else if cfg!(target_os = "android") {
        MajorPlatformType::ANDROID
    } else {
        MajorPlatformType::UNIX
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_credssp_proof_shorter_than_a_signature_never_reaches_sspi() {
        let with = |proof: Option<Vec<u8>>| TsRequest { pub_key_auth: proof, ..Default::default() };
        for short in [0, 1, 15] {
            let e = fit_for_sspi(&with(Some(vec![0; short]))).err().unwrap();
            assert!(e.to_string().contains("CredSSP"), "{e}");
            assert!(matches!(e.kind(), ConnectorErrorKind::Reason(_)), "{e:?}");
        }
        assert!(fit_for_sspi(&with(Some(vec![0; 16]))).is_ok());
        assert!(fit_for_sspi(&with(Some(vec![0; 300]))).is_ok());
        // The first messages carry no proof yet.
        assert!(fit_for_sspi(&with(None)).is_ok());
    }

    // What advisories-accepted.txt rests on for `rsa` (RUSTSEC-2023-0071, a private key leaking
    // through timing): a session signs in with a name and a password and nothing that holds an
    // RSA private key (a smart card, a client certificate).
    #[test]
    fn a_session_signs_in_with_a_name_and_a_password_and_no_private_key() {
        for graphics in [Graphics::Gfx, Graphics::RemoteFx, Graphics::Bitmap] {
            for nla in [Nla::Required, Nla::Without, Nla::Offered] {
                let config = connector_config(800, 600, "alex".into(), "hunter2".into(), None, graphics, nla);
                assert!(matches!(config.credentials, Credentials::UsernamePassword { .. }));
                assert!(config.enable_tls || config.enable_credssp, "always inside TLS");
                assert!(!config.enable_standard_rdp_security);
            }
        }
    }

    // NLA by default; without it, no password is sent.
    #[test]
    fn nla_is_asked_for_alone_by_default_and_without_it_the_password_is_not_sent() {
        let pair = |c: &Config| match &c.credentials {
            Credentials::UsernamePassword { username, password } => (username.clone(), password.clone()),
            other => panic!("{other:?}"),
        };
        let with = |nla| connector_config(800, 600, "alex".into(), "hunter2".into(), None, Graphics::Gfx, nla);
        let required = with(Nla::Required);
        assert!(required.enable_credssp && !required.enable_tls, "NLA or nothing: no fall back to TLS alone");
        assert_eq!(pair(&required), ("alex".to_owned(), "hunter2".to_owned()));
        let without = with(Nla::Without);
        assert!(without.enable_tls && !without.enable_credssp);
        assert_eq!(pair(&without), ("alex".to_owned(), String::new()), "the name alone");
        assert!(!without.autologon);
        let offered = with(Nla::Offered);
        assert!(offered.enable_tls && offered.enable_credssp && offered.autologon);
    }

    #[test]
    fn the_credentials_are_out_of_the_connector_until_the_sign_in() {
        let mut config =
            connector_config(800, 600, "alex".into(), "hunter2".into(), Some("CORP".into()), Graphics::Gfx, Nla::Required);
        let held = hold_credentials(&mut config);
        let pair = |c: &Credentials| match c {
            Credentials::UsernamePassword { username, password } => (username.clone(), password.clone()),
            other => panic!("{other:?}"),
        };
        assert_eq!(pair(&config.credentials), (String::new(), String::new()));
        let mut connector = ClientConnector::new(config, std::net::SocketAddr::from(([127, 0, 0, 1], 0)));
        give_back(&mut connector, held);
        assert_eq!(pair(&connector.config.credentials), ("alex".to_owned(), "hunter2".to_owned()));
        assert_eq!(connector.config.domain.as_deref(), Some("CORP"));
    }

    /// Every `.rs` file under `dir`, with its text.
    fn sources(dir: &std::path::Path, into: &mut Vec<(String, String)>) {
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                sources(&path, into);
            } else if path.extension().is_some_and(|e| e == "rs") {
                let name = path.to_string_lossy().replace('\\', "/");
                into.push((name, std::fs::read_to_string(&path).unwrap()));
            }
        }
    }

    /// "No RDP without TLS" as a type holds only while nothing goes around the type. IronRDP's
    /// own calls for the step after TLS take any stream, and the fuzz targets have a way past
    /// the handshake: so the crate's source is read here. The first are called in this file
    /// alone, the second exists only where `--cfg fuzzing` is set (no build of the app sets it).
    #[test]
    fn only_the_tls_step_signs_in() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = Vec::new();
        sources(&src, &mut files);
        assert!(files.len() > 10, "the crate's source was not found at {}", src.display());
        // Written in pieces, so this test is not itself a use.
        let around_tls: Vec<String> = [
            ["mark_as_", "upgraded"],
            ["connect_", "finalize"],
            ["skip_connect_", "begin"],
            ["mark_security_upgrade_", "as_done"],
            ["into_inner_no_", "leftover"],
        ]
        .iter()
        .map(|p| p.concat())
        .collect();
        let fuzz_only: Vec<String> = [["for_", "fuzzing("], ["fuzz_as_", "if_tls"]].iter().map(|p| p.concat()).collect();
        let gate = ["#[cfg(", "fuzzing)]"].concat();
        let mut seen_here = 0;
        for (name, text) in &files {
            let here = name.ends_with("src/rdp/mod.rs");
            let lines: Vec<&str> = text.lines().collect();
            for (i, line) in lines.iter().enumerate() {
                let code = line.split("//").next().unwrap_or("");
                for call in &around_tls {
                    if code.contains(call.as_str()) {
                        assert!(here, "{name}:{}: {call} is called outside rdp/mod.rs", i + 1);
                        seen_here += 1;
                    }
                }
                for word in &fuzz_only {
                    if code.contains(word.as_str()) {
                        let gated = lines[i.saturating_sub(4)..i].iter().any(|l| l.trim() == gate);
                        assert!(gated, "{name}:{}: {word} is not behind {gate}", i + 1);
                    }
                }
            }
        }
        // Both of IronRDP's calls are still here: if they moved, this test must move with them.
        assert_eq!(seen_here, 2, "sign_in no longer makes IronRDP's two calls");
    }
}

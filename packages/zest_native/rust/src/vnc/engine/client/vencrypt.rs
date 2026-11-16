//! VeNCrypt (security type 19, rfbproto): TLS, then authentication inside it. Ours (ZestSSH).
//!
//! Subtypes taken: X509None (260), X509Vnc (261), X509Plain (262): TLS with the server's
//! certificate, through rustls with ring. The certificate is trusted only when its SHA-256
//! fingerprint is the pinned one (as FTPS's x509-sha256); otherwise the handshake stops and
//! [VncError::UntrustedCertificate] carries the certificate, so the app can ask the person and
//! connect again with it pinned (trust on first use is the app's).
//!
//! Not taken: Plain (256, the password in clear) and the anonymous TLS subtypes TLSNone, TLSVnc,
//! TLSPlain (257 to 259): they use anonymous Diffie-Hellman cipher suites, which rustls (rightly)
//! does not implement, and which no one can authenticate.

use std::sync::{Arc, Mutex};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use super::auth::AuthHelper;
use crate::vnc::engine::VncError;

pub(crate) const PLAIN: u32 = 256;
pub(crate) const TLS_NONE: u32 = 257;
pub(crate) const TLS_VNC: u32 = 258;
pub(crate) const TLS_PLAIN: u32 = 259;
pub(crate) const X509_NONE: u32 = 260;
pub(crate) const X509_VNC: u32 = 261;
pub(crate) const X509_PLAIN: u32 = 262;

pub(crate) fn subtype_name(n: u32) -> String {
    match n {
        PLAIN => "Plain".into(),
        TLS_NONE => "TLSNone".into(),
        TLS_VNC => "TLSVnc".into(),
        TLS_PLAIN => "TLSPlain".into(),
        X509_NONE => "X509None".into(),
        X509_VNC => "X509Vnc".into(),
        X509_PLAIN => "X509Plain".into(),
        n => format!("subtype {n}"),
    }
}

/// Any stream the session can continue on (the plain one, or TLS over it).
pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}

/// The TLS session's facts, for the app (and the probe).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TlsInfo {
    /// "X509Vnc", "X509Plain" or "X509None".
    pub subtype: String,
    pub protocol: String,
    pub cipher_suite: String,
    /// SHA-256 of the server's certificate (DER).
    pub cert_sha256: [u8; 32],
}

/// X509Plain when a username is given and the server offers it (the account's login); otherwise
/// the server's subtypes in its order of preference, the first we can do with what we have.
pub(crate) fn choose(offered: &[u32], username: Option<&str>, password: Option<&str>) -> Result<u32, VncError> {
    if username.is_some() && password.is_some() && offered.contains(&X509_PLAIN) {
        return Ok(X509_PLAIN);
    }
    let pick = offered.iter().copied().find(|t| match *t {
        X509_VNC => password.is_some(),
        X509_PLAIN => username.is_some() && password.is_some(),
        X509_NONE => true,
        _ => false,
    });
    pick.ok_or_else(|| {
        let names = offered.iter().map(|t| subtype_name(*t)).collect::<Vec<_>>().join(", ");
        let anonymous = offered.iter().any(|t| matches!(*t, TLS_NONE | TLS_VNC | TLS_PLAIN));
        VncError::Unsupported(format!(
            "VeNCrypt: the server offers {names}; usable are X509Vnc (with a password), X509Plain (with a username and a password) and X509None{}",
            if anonymous { "; anonymous TLS (TLSNone, TLSVnc, TLSPlain) cannot be checked and is not supported" } else { "" }
        ))
    })
}

/// The certificate check: the pinned fingerprint or nothing. What was shown is kept for the error.
#[derive(Debug)]
struct PinVerifier {
    pin: Option<[u8; 32]>,
    shown: Arc<Mutex<Option<(Vec<u8>, bool)>>>,
    provider: Arc<CryptoProvider>,
}

pub(crate) fn sha256(der: &[u8]) -> [u8; 32] {
    ring::digest::digest(&ring::digest::SHA256, der).as_ref().try_into().unwrap()
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let trusted = self.pin == Some(sha256(end_entity.as_ref()));
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

/// What VeNCrypt needs from the caller.
pub(crate) struct Options<'a> {
    pub username: Option<&'a str>,
    pub password: Option<&'a str>,
    pub pin: Option<[u8; 32]>,
    /// The name sent in SNI (and nothing else: the pin decides). An IP address sends none.
    pub server_name: &'a str,
}

/// Runs VeNCrypt after the client chose type 19, up to (not including) the SecurityResult,
/// which comes inside the TLS stream returned.
pub(crate) async fn negotiate(mut stream: Box<dyn Io>, options: &Options<'_>) -> Result<(Box<dyn Io>, TlsInfo), VncError> {
    let major = stream.read_u8().await?;
    let minor = stream.read_u8().await?;
    if (major, minor) < (0, 2) {
        return Err(VncError::Unsupported(format!("VeNCrypt {major}.{minor} (0.2 is needed)")));
    }
    stream.write_all(&[0, 2]).await?;
    if stream.read_u8().await? != 0 {
        return Err(VncError::General("VeNCrypt: the server refused version 0.2".into()));
    }
    let count = stream.read_u8().await? as usize;
    let mut offered = Vec::with_capacity(count);
    for _ in 0..count {
        offered.push(stream.read_u32().await?);
    }
    let subtype = choose(&offered, options.username, options.password)?;
    stream.write_u32(subtype).await?;
    // The server's acknowledgement for the TLS subtypes: 1 accepts.
    if stream.read_u8().await? != 1 {
        return Err(VncError::General(format!("VeNCrypt: the server refused {}", subtype_name(subtype))));
    }

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let shown = Arc::new(Mutex::new(None));
    let verifier = PinVerifier { pin: options.pin, shown: shown.clone(), provider: provider.clone() };
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| VncError::Tls(e.to_string()))?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    let name = ServerName::try_from(options.server_name.to_string())
        .unwrap_or_else(|_| ServerName::try_from("vnc.invalid").unwrap());
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let mut tls = match connector.connect(name, stream).await {
        Ok(tls) => tls,
        Err(e) => {
            if let Some((der, false)) = shown.lock().unwrap().take() {
                return Err(VncError::UntrustedCertificate { sha256: sha256(&der), der });
            }
            return Err(VncError::Tls(e.to_string()));
        }
    };
    let (_, session) = tls.get_ref();
    let info = TlsInfo {
        subtype: subtype_name(subtype),
        protocol: session.protocol_version().map(|v| format!("{v:?}")).unwrap_or_default(),
        cipher_suite: session.negotiated_cipher_suite().map(|c| format!("{:?}", c.suite())).unwrap_or_default(),
        cert_sha256: session.peer_certificates().and_then(|c| c.first()).map(|c| sha256(c.as_ref())).unwrap_or([0; 32]),
    };

    match subtype {
        X509_VNC => {
            let auth = AuthHelper::read(&mut tls, options.password.unwrap_or_default()).await?;
            auth.write(&mut tls).await?;
        }
        X509_PLAIN => {
            let (user, pass) = (options.username.unwrap_or_default(), options.password.unwrap_or_default());
            let mut out = zeroize::Zeroizing::new((user.len() as u32).to_be_bytes().to_vec());
            out.extend_from_slice(&(pass.len() as u32).to_be_bytes());
            out.extend_from_slice(user.as_bytes());
            out.extend_from_slice(pass.as_bytes());
            tls.write_all(&out).await?;
        }
        _ => {}
    }
    tls.flush().await?;
    Ok((Box::new(tls), info))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_usable_subtype_in_the_servers_order_is_chosen() {
        let all = [X509_VNC, X509_PLAIN, X509_NONE];
        assert_eq!(choose(&all, None, Some("p")).unwrap(), X509_VNC);
        assert_eq!(choose(&[X509_PLAIN, X509_VNC], Some("u"), Some("p")).unwrap(), X509_PLAIN);
        assert_eq!(choose(&all, Some("u"), Some("p")).unwrap(), X509_PLAIN);
        assert_eq!(choose(&[X509_PLAIN, X509_VNC], None, Some("p")).unwrap(), X509_VNC);
        assert_eq!(choose(&all, None, None).unwrap(), X509_NONE);
        // Plain and anonymous TLS are never chosen, and the error says why.
        let e = choose(&[PLAIN, TLS_VNC, TLS_PLAIN], Some("u"), Some("p")).unwrap_err().to_string();
        assert!(e.contains("Plain, TLSVnc, TLSPlain") && e.contains("anonymous"), "{e}");
    }

    #[tokio::test]
    async fn the_exchange_before_tls_and_a_refused_subtype() {
        // Version 0.2, OK, three subtypes; the client picks X509Vnc; the server refuses (0).
        let (client, mut server) = tokio::io::duplex(256);
        let mut s = vec![0, 2, 0, 3];
        for t in [TLS_VNC, X509_VNC, X509_NONE] {
            s.extend(t.to_be_bytes());
        }
        s.push(0);
        server.write_all(&s).await.unwrap();
        let options = Options { username: None, password: Some("p"), pin: None, server_name: "localhost" };
        let e = negotiate(Box::new(client), &options).await.err().unwrap().to_string();
        assert!(e.contains("refused X509Vnc"), "{e}");
        let mut sent = [0u8; 6];
        server.read_exact(&mut sent).await.unwrap();
        assert_eq!(sent, [0, 2, 0, 0, 1, 5]); // version, then 261
        // A server below 0.2 is refused before anything is sent.
        let (client, mut server) = tokio::io::duplex(256);
        server.write_all(&[0, 1]).await.unwrap();
        assert!(negotiate(Box::new(client), &options).await.is_err());
    }

    /// A TLS handshake against a rustls server with the FTPS tests' self-signed certificate: the
    /// wrong pin (or none) gives the certificate back; the right pin connects, and X509Vnc's
    /// challenge and answer run inside TLS.
    #[tokio::test]
    async fn the_pin_decides_and_the_certificate_comes_back() {
        let (cert, key) = test_identity();
        let pin = sha256(cert.as_ref());
        for (given, ok) in [(None, false), (Some([7u8; 32]), false), (Some(pin), true)] {
            let (client, server) = tokio::io::duplex(64 * 1024);
            let server_task = tokio::spawn(fake_server(server, cert.clone(), key.clone_key()));
            let options = Options { username: None, password: Some("secret"), pin: given, server_name: "localhost" };
            let result = negotiate(Box::new(client), &options).await;
            match (result, ok) {
                (Ok((_, info)), true) => {
                    assert_eq!(info.subtype, "X509Vnc");
                    assert_eq!(info.cert_sha256, pin);
                    assert!(info.protocol.contains("TLS"), "{}", info.protocol);
                    // The server got a 16-byte answer to its challenge, inside TLS.
                    assert_eq!(server_task.await.unwrap(), Some(16));
                }
                (Err(VncError::UntrustedCertificate { sha256: shown, der }), false) => {
                    assert_eq!(shown, pin);
                    assert_eq!(der, cert.as_ref());
                }
                (other, _) => panic!("{:?}", other.map(|(_, i)| i)),
            }
        }
    }

    fn test_identity() -> (CertificateDer<'static>, rustls::pki_types::PrivateKeyDer<'static>) {
        use rustls::pki_types::pem::PemObject;
        let pem = include_str!("vencrypt_test_identity.pem");
        let cert = CertificateDer::from_pem_slice(pem.as_bytes()).unwrap();
        let key = rustls::pki_types::PrivateKeyDer::from_pem_slice(pem.as_bytes()).unwrap();
        (cert, key)
    }

    /// Plays the server's side: VeNCrypt 0.2 offering X509Vnc, TLS, a challenge; returns how
    /// many answer bytes came (None when the handshake failed).
    async fn fake_server(
        mut s: tokio::io::DuplexStream,
        cert: CertificateDer<'static>,
        key: rustls::pki_types::PrivateKeyDer<'static>,
    ) -> Option<usize> {
        s.write_all(&[0, 2]).await.ok()?;
        let mut v = [0; 2];
        s.read_exact(&mut v).await.ok()?;
        s.write_all(&[0, 1]).await.ok()?;
        s.write_all(&X509_VNC.to_be_bytes()).await.ok()?;
        assert_eq!(s.read_u32().await.ok()?, X509_VNC);
        s.write_all(&[1]).await.ok()?;
        let config = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        let mut tls = tokio_rustls::TlsAcceptor::from(Arc::new(config)).accept(s).await.ok()?;
        tls.write_all(&[9; 16]).await.ok()?;
        tls.flush().await.ok()?;
        let mut answer = [0; 16];
        tls.read_exact(&mut answer).await.ok()?;
        Some(answer.len())
    }
}

//! The certificate check of every FTPS connection, the control one and each data one alike.
//!
//! A certificate is trusted when it is the one the person accepted (its SHA-256 fingerprint,
//! pinned), or, where the caller allows it, when an authority vouches for it for this host:
//! Mozilla's roots, the same on every platform, and on Windows also the system's own check (its
//! trust store, where a company's own authority is installed). Anything else is refused, and what was shown is
//! kept so the app can ask the person about it, the way it asks about an SSH host key; the
//! handshake itself never waits on a person (a server would time it out).
//!
//! Once one certificate has been accepted on a connection, every later handshake on it (the data
//! connections) must show that same certificate: a data connection cannot be answered by another
//! server. A data connection that resumes the control connection's TLS session (what vsftpd and
//! ProFTPD ask for) shows no certificate at all, and needs none: the session was checked here.

use std::sync::{Arc, Mutex};

use rustls::client::WebPkiServerVerifier;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::CryptoProvider;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, RootCertStore, SignatureScheme};
use sha2::{Digest, Sha256};

/// A certificate a server showed: its fingerprint, whether a public authority signed it for the
/// host the app asked for, and the certificate itself (DER), which the app keeps beside the
/// fingerprint as it keeps an SSH host key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Seen {
    pub sha256: [u8; 32],
    pub by_authority: bool,
    pub der: Vec<u8>,
}

/// What decides a certificate, apart from the signature checks.
#[derive(Debug, Default)]
pub struct Policy {
    /// The fingerprint the person accepted for this host, if any.
    pub pinned: Option<[u8; 32]>,
    /// Whether a certificate a public authority signed for the host is trusted without a pin.
    pub allow_authority: bool,
}

#[derive(Debug, Default)]
struct State {
    policy: Policy,
    accepted: Option<Seen>,
    refused: Option<Seen>,
}

/// What [`decide`] says of one certificate.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Trusted,
    Refused,
}

/// The rule, on its own so it can be tested without a handshake: the pinned fingerprint, or an
/// authority's signature where that is allowed and nothing was accepted yet on this connection.
pub fn decide(policy: &Policy, accepted: Option<&Seen>, sha256: &[u8; 32], by_authority: bool) -> Decision {
    if let Some(first) = accepted {
        // A data connection: the control connection's certificate and no other.
        return if &first.sha256 == sha256 { Decision::Trusted } else { Decision::Refused };
    }
    if policy.pinned.as_ref() == Some(sha256) {
        return Decision::Trusted;
    }
    if policy.allow_authority && by_authority {
        return Decision::Trusted;
    }
    Decision::Refused
}

/// The SHA-256 of a certificate's DER.
pub fn fingerprint(der: &[u8]) -> [u8; 32] {
    Sha256::digest(der).into()
}

#[derive(Debug)]
pub struct ZestVerifier {
    webpki: Arc<WebPkiServerVerifier>,
    /// The system's own check, where the platform has one this library uses (Windows).
    system: Option<Arc<dyn ServerCertVerifier>>,
    state: Mutex<State>,
}

/// The system's certificate check (Windows' CertGetCertificateChain, through
/// rustls-platform-verifier): its trust store, a company's authorities among them.
#[cfg(windows)]
fn system_verifier(provider: Arc<CryptoProvider>) -> Option<Arc<dyn ServerCertVerifier>> {
    rustls_platform_verifier::Verifier::new(provider).ok().map(|v| Arc::new(v) as Arc<dyn ServerCertVerifier>)
}

/// None elsewhere for now (see Cargo.toml): Mozilla's roots, then trust on first use.
#[cfg(not(windows))]
fn system_verifier(_provider: Arc<CryptoProvider>) -> Option<Arc<dyn ServerCertVerifier>> {
    None
}

impl ZestVerifier {
    pub fn new(provider: Arc<CryptoProvider>, policy: Policy) -> Result<Self, String> {
        let roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        let webpki = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone())
            .build()
            .map_err(|e| e.to_string())?;
        let system = system_verifier(provider);
        Ok(Self { webpki, system, state: Mutex::new(State { policy, ..State::default() }) })
    }

    /// Whether the system's own check is used on this platform.
    pub fn has_system_check(&self) -> bool {
        self.system.is_some()
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The certificate this connection accepted (its control connection's), if any yet.
    pub fn accepted(&self) -> Option<Seen> {
        self.state().accepted.clone()
    }

    /// The last certificate refused on this connection, if any.
    pub fn refused(&self) -> Option<Seen> {
        self.state().refused.clone()
    }
}

impl ServerCertVerifier for ZestVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp_response: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let sha256 = fingerprint(end_entity.as_ref());
        let mut by_authority = self
            .webpki
            .verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now)
            .is_ok();
        // The system's check only where it can decide something: the first certificate of the
        // connection, not the pinned one, an authority allowed, and Mozilla's roots said no. (It
        // may go to the network for revocation; a data connection never asks it.)
        if !by_authority {
            if let Some(system) = &self.system {
                let ask = {
                    let state = self.state();
                    state.accepted.is_none() && state.policy.allow_authority && state.policy.pinned != Some(sha256)
                };
                if ask {
                    by_authority =
                        system.verify_server_cert(end_entity, intermediates, server_name, ocsp_response, now).is_ok();
                }
            }
        }
        let mut state = self.state();
        match decide(&state.policy, state.accepted.as_ref(), &sha256, by_authority) {
            Decision::Trusted => {
                if state.accepted.is_none() {
                    state.accepted = Some(Seen { sha256, by_authority, der: end_entity.as_ref().to_vec() });
                }
                Ok(ServerCertVerified::assertion())
            }
            Decision::Refused => {
                state.refused = Some(Seen { sha256, by_authority, der: end_entity.as_ref().to_vec() });
                Err(rustls::Error::General(CERT_REFUSED.to_string()))
            }
        }
    }

    // The handshake's signatures are checked as any TLS client checks them: the server must hold
    // the key of the certificate it showed, whoever signed that certificate.
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        self.webpki.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.webpki.supported_verify_schemes()
    }
}

/// The error a refused certificate fails the handshake with.
pub const CERT_REFUSED: &str = "zest: certificate not trusted";

#[cfg(test)]
mod tests {
    use super::*;

    fn seen(b: u8) -> Seen {
        Seen { sha256: [b; 32], by_authority: false, der: vec![b] }
    }

    #[test]
    fn nothing_pinned_and_no_authority_is_refused() {
        let p = Policy { pinned: None, allow_authority: true };
        assert_eq!(decide(&p, None, &[1; 32], false), Decision::Refused);
    }

    #[test]
    fn the_pinned_certificate_is_trusted() {
        let p = Policy { pinned: Some([7; 32]), allow_authority: false };
        assert_eq!(decide(&p, None, &[7; 32], false), Decision::Trusted);
        assert_eq!(decide(&p, None, &[8; 32], false), Decision::Refused);
    }

    #[test]
    fn an_authority_counts_only_where_allowed() {
        let allowed = Policy { pinned: None, allow_authority: true };
        let not = Policy { pinned: None, allow_authority: false };
        assert_eq!(decide(&allowed, None, &[3; 32], true), Decision::Trusted);
        assert_eq!(decide(&not, None, &[3; 32], true), Decision::Refused);
    }

    #[test]
    fn a_data_connection_must_show_the_control_connections_certificate() {
        let p = Policy { pinned: Some([1; 32]), allow_authority: true };
        let first = seen(1);
        assert_eq!(decide(&p, Some(&first), &[1; 32], false), Decision::Trusted);
        // Another certificate, even one an authority signed, or the pinned one's neighbour: no.
        assert_eq!(decide(&p, Some(&first), &[2; 32], true), Decision::Refused);
    }

    /// A self-signed certificate made for the test (a made-up name), which no authority and no
    /// system store vouches for.
    fn self_signed() -> Vec<u8> {
        // Generated once with openssl (a made-up name, files.example.test); its key is not kept.
        base64_der(SELF_SIGNED_PEM)
    }

    fn base64_der(pem: &str) -> Vec<u8> {
        use base64::Engine;
        let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
        base64::engine::general_purpose::STANDARD.decode(body).unwrap()
    }

    const SELF_SIGNED_PEM: &str = include_str!("testdata/self_signed.pem");

    #[test]
    fn the_system_check_is_used_on_windows_only_for_now() {
        let v = ZestVerifier::new(Arc::new(rustls::crypto::ring::default_provider()), Policy::default()).unwrap();
        assert_eq!(v.has_system_check(), cfg!(windows));
    }

    #[test]
    fn a_self_signed_certificate_is_vouched_for_by_neither_check_and_is_refused() {
        let v = ZestVerifier::new(
            Arc::new(rustls::crypto::ring::default_provider()),
            Policy { pinned: None, allow_authority: true },
        )
        .unwrap();
        let der = self_signed();
        let name = ServerName::try_from("files.example.test").unwrap();
        let r = v.verify_server_cert(&CertificateDer::from(der.clone()), &[], &name, &[], UnixTime::now());
        assert!(r.is_err());
        let seen = v.refused().unwrap();
        assert!(!seen.by_authority);
        assert_eq!(seen.sha256, fingerprint(&der));
    }

    #[test]
    fn the_fingerprint_is_sha256_of_the_der() {
        // SHA-256 of "abc".
        let f = fingerprint(b"abc");
        assert_eq!(f[0], 0xba);
        assert_eq!(f[31], 0xad);
    }
}

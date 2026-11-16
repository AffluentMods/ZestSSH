use thiserror::Error;

#[non_exhaustive]
#[derive(Debug, Error)]
pub enum VncError {
    #[error("Auth is required but no password provided")]
    NoPassword,
    #[error("No VNC encoding selected")]
    NoEncoding,
    #[error("Unknow VNC security type: {0}")]
    InvalidSecurityTyep(u8),
    #[error("Wrong password")]
    WrongPassword,
    /// The server refused the credentials (SecurityResult failed), with its reason.
    #[error("authentication failed: {0}")]
    AuthFailed(String),
    #[error("Connect error with unknown reason")]
    ConnectError,
    #[error("Unknown pixel format")]
    WrongPixelFormat,
    #[error("Unkonw server message")]
    WrongServerMessage,
    #[error("Image data cannot be decoded correctly")]
    InvalidImageData,
    #[error("The VNC client isn't started. Or it is already closed")]
    ClientNotRunning,
    #[error(transparent)]
    IoError(#[from] std::io::Error),
    #[error("VNC Error with message: {0}")]
    General(String),
    /// The server's TLS certificate is not the pinned one (or no pin was given). The app shows
    /// the fingerprint, and connects again with it pinned once the person accepts it.
    #[error("the server's certificate (SHA-256 {}) is not the trusted one", hex(sha256))]
    UntrustedCertificate { sha256: [u8; 32], der: Vec<u8> },
    #[error("TLS: {0}")]
    Tls(String),
    /// The server offers nothing the engine (or the caller's options) can use.
    #[error("{0}")]
    Unsupported(String),
    /// Ours: the server asked for more work than the engine does for one message (a limit
    /// against hostile servers: a few bytes must not keep the session busy for minutes).
    #[error("{0}")]
    Excessive(String),
    /// Ours: the caller stopped the engine ([crate::vnc::engine::ConnectOptions::stop]).
    #[error("the session was closed")]
    Stopped,
}

/// Lower-case hexadecimal.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl<T> From<tokio::sync::mpsc::error::SendError<T>> for VncError {
    fn from(_value: tokio::sync::mpsc::error::SendError<T>) -> Self {
        VncError::General("Channel closed".to_string())
    }
}

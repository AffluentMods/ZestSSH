//! ZestSSH's VNC (RFB) engine: our fork of vnc-rs, as zest_ssh_core is our fork of dartssh2.
//!
//! Forked from vnc-rs 0.6.0 (https://github.com/HsuJv/vnc-rs, commit
//! 41f974dd928bbe521ccc63faf73d9c5d0b230026, by Jovi Hsu and its contributors), MIT OR
//! Apache-2.0: both licence texts are beside this file (LICENSE-MIT, LICENSE-APACHE) and NOTICE
//! says what we changed.
//!
//! # The API
//!
//! [connect] runs the handshake over any stream (`AsyncRead + AsyncWrite`: a TCP socket, a Unix
//! socket, or later an SSH channel the app hands over) and returns a [VncClient] and what the
//! server said ([SessionInfo]). Then:
//!
//! - events, from [VncClient::recv_event]: [VncEvent::SetResolution] (a resize),
//!   [VncEvent::Rectangle] (a rectangle's place and encoding, before its pixels),
//!   [VncEvent::RawImage] and [VncEvent::Copy] (pixels, in the pixel format asked for),
//!   [VncEvent::SetCursor], [VncEvent::UpdateDone] (the end of one framebuffer update),
//!   [VncEvent::Text] (the server's clipboard, UTF-8 when the extended clipboard is on),
//!   [VncEvent::Bell], [VncEvent::DesktopUpdate] (a layout), [VncEvent::Error];
//! - input, through [VncClient::input]: [X11Event::KeyEvent] (a keysym),
//!   [X11Event::ScancodeKey] (a keysym and its XT scancode: QEMU's extended key event when the
//!   server confirmed it, the keysym alone otherwise), [X11Event::PointerEvent],
//!   [X11Event::CopyText] (the clipboard), [X11Event::Refresh] and [X11Event::FullRefresh].
//!
//! Security types: None, VNC authentication, Apple Remote Desktop (30, Diffie-Hellman and
//! AES-128) and VeNCrypt (19) with X509None, X509Vnc and X509Plain over rustls with ring. The
//! certificate is trusted only by its SHA-256 fingerprint ([ConnectOptions::tls_pin]); trust on
//! first use is the app's: without a pin, or with another one, [connect] fails with
//! [VncError::UntrustedCertificate], which carries the certificate.
//!
//! Encodings: Raw, CopyRect, RRE, Hextile, Zlib, Tight (with JPEG, decoded by zune-jpeg), TRLE,
//! ZRLE; pseudo: Cursor, DesktopSize, ExtendedDesktopSize, LastRect, JPEG quality and compression
//! levels, QEMU extended key events, extended clipboard.

/// Logging is off in our fork (vnc-rs used `tracing`): these keep its calls, and their
/// arguments type-checked, without writing anything.
macro_rules! trace {
    ($($t:tt)*) => {{
        let _ = format_args!($($t)*);
    }};
}
macro_rules! info {
    ($($t:tt)*) => {{
        let _ = format_args!($($t)*);
    }};
}
macro_rules! error {
    ($($t:tt)*) => {{
        let _ = format_args!($($t)*);
    }};
}

pub mod client;
mod codec;
pub mod config;
mod desktop;
pub mod error;
pub mod event;
pub use desktop::*;

pub use client::VncClient;
pub use client::VncConnector;
pub use client::connect::{ConnectOptions, Draw, SessionInfo, TlsInfo, connect, default_encodings, security_type_name};
pub use config::*;
pub use error::*;
pub use event::*;

mod limits;

/// For the fuzz targets only (packages/zest_native/rust/fuzz builds with `--cfg fuzzing`; the
/// app's builds never set it): Tight's JPEG decoder (zune-jpeg) on its own, for a rectangle of
/// [width] x [height].
#[cfg(fuzzing)]
pub fn fuzz_decode_jpeg(data: &[u8], width: u16, height: u16) -> Result<Vec<u8>, VncError> {
    codec::decode_jpeg(data, &Rect { x: 0, y: 0, width, height })
}

/// Polls a future once (the tests' stand-in for `futures::poll!`).
#[cfg(test)]
pub(crate) async fn poll_once<F: std::future::Future + Unpin>(mut f: F) -> std::task::Poll<F::Output> {
    std::future::poll_fn(|cx| std::task::Poll::Ready(std::pin::Pin::new(&mut f).poll(cx))).await
}

#[cfg(test)]
mod authentication_tests;

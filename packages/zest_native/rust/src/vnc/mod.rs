//! VNC (4.0, feature "vnc"): our RFB engine ([engine], a fork of vnc-rs 0.6.0) and the names the
//! screen session reads its options by. The screen module (src/screen/vnc_session.rs) runs it over
//! the app's SSH channel; the developer probe ([probe], feature "probes") over a socket.

pub mod engine;
#[cfg(feature = "probes")]
pub mod probe;
#[cfg(feature = "probes")]
pub use probe::{ProbeReport, ProbeRequest, probe, probe_json};

use engine::VncEncoding;

/// The RFB name of an encoding.
pub fn encoding_name(e: VncEncoding) -> String {
    match e {
        VncEncoding::JpegQuality(q) => format!("JpegQuality{q}"),
        VncEncoding::CompressionLevel(c) => format!("CompressionLevel{c}"),
        VncEncoding::CursorPseudo => "Cursor".into(),
        VncEncoding::DesktopSizePseudo => "DesktopSize".into(),
        VncEncoding::LastRectPseudo => "LastRect".into(),
        VncEncoding::ExtendedDesktopSizePseudo => "ExtendedDesktopSize".into(),
        VncEncoding::QemuExtendedKeyEventPseudo => "QemuExtendedKeyEvent".into(),
        VncEncoding::ExtendedClipboardPseudo => "ExtendedClipboard".into(),
        VncEncoding::ContinuousUpdatesPseudo => "ContinuousUpdates".into(),
        VncEncoding::FencePseudo => "Fence".into(),
        VncEncoding::Zrle => "ZRLE".into(),
        VncEncoding::Trle => "TRLE".into(),
        VncEncoding::Rre => "RRE".into(),
        other => format!("{other:?}"),
    }
}

/// An encoding by name (any case): Raw, CopyRect, RRE, Hextile, Zlib, Tight, TRLE, ZRLE, the
/// pseudo ones Cursor, DesktopSize, ExtendedDesktopSize, LastRect, QemuExtendedKeyEvent,
/// ExtendedClipboard, ContinuousUpdates, Fence, and the levels JpegQuality0 to 9, CompressionLevel0 to 9.
pub fn parse_encoding(name: &str) -> Result<VncEncoding, String> {
    let lower = name.trim().to_ascii_lowercase();
    let level = |prefix: &str| lower.strip_prefix(prefix).and_then(|n| n.parse::<u8>().ok()).filter(|n| *n <= 9);
    if let Some(q) = level("jpegquality") {
        return Ok(VncEncoding::JpegQuality(q));
    }
    if let Some(c) = level("compressionlevel") {
        return Ok(VncEncoding::CompressionLevel(c));
    }
    Ok(match lower.as_str() {
        "raw" => VncEncoding::Raw,
        "copyrect" => VncEncoding::CopyRect,
        "rre" => VncEncoding::Rre,
        "hextile" => VncEncoding::Hextile,
        "zlib" => VncEncoding::Zlib,
        "tight" => VncEncoding::Tight,
        "trle" => VncEncoding::Trle,
        "zrle" => VncEncoding::Zrle,
        "cursor" => VncEncoding::CursorPseudo,
        "desktopsize" => VncEncoding::DesktopSizePseudo,
        "lastrect" => VncEncoding::LastRectPseudo,
        "extendeddesktopsize" => VncEncoding::ExtendedDesktopSizePseudo,
        "qemuextendedkeyevent" => VncEncoding::QemuExtendedKeyEventPseudo,
        "extendedclipboard" => VncEncoding::ExtendedClipboardPseudo,
        "continuousupdates" => VncEncoding::ContinuousUpdatesPseudo,
        "fence" => VncEncoding::FencePseudo,
        _ => return Err(format!("the engine has no encoding {name:?}")),
    })
}

/// A certificate's SHA-256 as the person accepted it: 64 hexadecimal digits, either case, colons
/// allowed between them; anything else is refused (never read past).
pub fn parse_pin(hex: &str) -> Result<[u8; 32], String> {
    let clean: Vec<u8> = hex.bytes().filter(|c| *c != b':').collect();
    if clean.len() != 64 || !clean.iter().all(u8::is_ascii_hexdigit) {
        return Err("tls_pin: 64 hexadecimal digits (SHA-256)".into());
    }
    let digit = |c: u8| (c as char).to_digit(16).unwrap_or(0) as u8;
    let mut pin = [0u8; 32];
    for (i, b) in pin.iter_mut().enumerate() {
        *b = digit(clean[2 * i]) << 4 | digit(clean[2 * i + 1]);
    }
    Ok(pin)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encoding_names_round_trip() {
        for e in engine::default_encodings() {
            assert_eq!(parse_encoding(&encoding_name(e)).unwrap(), e);
        }
        assert_eq!(parse_encoding("jpegquality9").unwrap().wire(), -23);
        assert_eq!(parse_encoding("CompressionLevel0").unwrap().wire(), -256);
        assert!(parse_encoding("JpegQuality10").is_err());
        assert!(parse_pin("ab").is_err());
        assert!(parse_pin(&"zz".repeat(32)).is_err());
        assert!(parse_pin(&format!("{}g", "0".repeat(63))).is_err());
        assert_eq!(parse_pin(&"0a".repeat(32)).unwrap(), [10; 32]);
        assert_eq!(parse_pin(&"0A:".repeat(32)).unwrap(), [10; 32]);
    }
}

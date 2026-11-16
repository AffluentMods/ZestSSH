//! The extended clipboard (rfbproto, "Extended Clipboard Pseudo-Encoding"): UTF-8 text in
//! ServerCutText and ClientCutText with a negative length. Ours (ZestSSH), not from vnc-rs.
//!
//! Only the text format is used. What the engine does:
//! - the server's caps: answer with ours (text; request, peek, notify, provide; size 0, so the
//!   server announces with notify and the engine asks);
//! - notify with text: request it; provide: the text becomes [VncEvent::Text];
//! - request: provide the text the app last copied; peek: notify what there is;
//! - the app copies: notify when the server takes notify (then provide on its request), else
//!   provide at once.

use std::io::Write;

use crate::vnc::engine::VncError;

pub(crate) const TEXT: u32 = 1;
pub(crate) const CAPS: u32 = 1 << 24;
pub(crate) const REQUEST: u32 = 1 << 25;
pub(crate) const PEEK: u32 = 1 << 26;
pub(crate) const NOTIFY: u32 = 1 << 27;
pub(crate) const PROVIDE: u32 = 1 << 28;

/// The most text taken from (or given to) the server, before and after decompression.
pub(crate) const MAX_TEXT: usize = crate::vnc::engine::limits::MAX_TEXT;

/// One extended clipboard message, read.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Message {
    /// The sender's formats and actions, and its size limit for each format.
    Caps { flags: u32, sizes: Vec<u32> },
    Request { text: bool },
    Peek,
    Notify { text: bool },
    /// The text, when the provide carried it (LF line ends, no terminating NUL).
    Provide { text: Option<String> },
}

pub(crate) fn parse(body: &[u8]) -> Result<Message, VncError> {
    let flags = u32::from_be_bytes(body.get(..4).ok_or(VncError::InvalidImageData)?.try_into().unwrap());
    let rest = &body[4..];
    let text = flags & TEXT != 0;
    if flags & CAPS != 0 {
        let formats = (flags & 0xffff).count_ones() as usize;
        let sizes = rest
            .chunks_exact(4)
            .take(formats)
            .map(|c| u32::from_be_bytes(c.try_into().unwrap()))
            .collect::<Vec<_>>();
        if sizes.len() != formats {
            return Err(VncError::InvalidImageData);
        }
        return Ok(Message::Caps { flags, sizes });
    }
    if flags & REQUEST != 0 {
        Ok(Message::Request { text })
    } else if flags & PEEK != 0 {
        Ok(Message::Peek)
    } else if flags & NOTIFY != 0 {
        Ok(Message::Notify { text })
    } else if flags & PROVIDE != 0 {
        Ok(Message::Provide { text: provided_text(flags, rest)? })
    } else {
        Err(VncError::InvalidImageData)
    }
}

/// The text of a provide's zlib stream: for each format in the flags, in bit order, a U32 size
/// and the data; text comes first when there.
fn provided_text(flags: u32, compressed: &[u8]) -> Result<Option<String>, VncError> {
    if flags & TEXT == 0 {
        return Ok(None);
    }
    let inflated = inflate(compressed, MAX_TEXT + 4)?;
    let size = u32::from_be_bytes(inflated.get(..4).ok_or(VncError::InvalidImageData)?.try_into().unwrap()) as usize;
    // Checked: on a 32-bit target 4 + a size near u32::MAX wraps (from a security review).
    let end = size.checked_add(4).ok_or(VncError::InvalidImageData)?;
    let data = inflated.get(4..end).ok_or(VncError::InvalidImageData)?;
    let data = data.strip_suffix(&[0]).unwrap_or(data);
    Ok(Some(String::from_utf8_lossy(data).replace("\r\n", "\n")))
}

/// Inflates a zlib stream that may not be finished (TigerVNC flushes its provide's stream but
/// does not end it), up to [limit] bytes, so a small message cannot unpack into gigabytes.
fn inflate(compressed: &[u8], limit: usize) -> Result<Vec<u8>, VncError> {
    let mut z = flate2::Decompress::new(true);
    let mut out = Vec::with_capacity(compressed.len().saturating_mul(4).min(limit));
    loop {
        let consumed = z.total_in() as usize;
        if out.len() == out.capacity() {
            if out.len() >= limit {
                return Err(VncError::InvalidImageData);
            }
            out.reserve((out.len().max(4096)).min(limit - out.len()));
        }
        let before = out.len();
        let status = z
            .decompress_vec(&compressed[consumed..], &mut out, flate2::FlushDecompress::Sync)
            .map_err(|_| VncError::InvalidImageData)?;
        let done = z.total_in() as usize >= compressed.len();
        match status {
            flate2::Status::StreamEnd => return Ok(out),
            _ if done && out.len() < out.capacity() => return Ok(out),
            _ if out.len() == before && z.total_in() as usize == consumed && out.len() < out.capacity() => {
                // No progress with room to spare: the input is cut short.
                return Ok(out);
            }
            _ => {}
        }
    }
}

/// Our caps: text, and every action; size 0, so text is announced rather than pushed.
pub(crate) fn caps() -> Vec<u8> {
    let mut body = (CAPS | TEXT | REQUEST | PEEK | NOTIFY | PROVIDE).to_be_bytes().to_vec();
    body.extend_from_slice(&0u32.to_be_bytes());
    body
}

pub(crate) fn request_text() -> Vec<u8> {
    (REQUEST | TEXT).to_be_bytes().to_vec()
}

pub(crate) fn notify(has_text: bool) -> Vec<u8> {
    (NOTIFY | if has_text { TEXT } else { 0 }).to_be_bytes().to_vec()
}

/// A provide with the text (CRLF line ends, a terminating NUL), or with no format at all.
pub(crate) fn provide(text: Option<&str>) -> Vec<u8> {
    let Some(text) = text else {
        let mut body = PROVIDE.to_be_bytes().to_vec();
        body.extend(compress(&[]));
        return body;
    };
    let mut data = text.replace("\r\n", "\n").replace('\n', "\r\n").into_bytes();
    data.truncate(MAX_TEXT - 1);
    data.push(0);
    let mut plain = (data.len() as u32).to_be_bytes().to_vec();
    plain.extend_from_slice(&data);
    let mut body = (PROVIDE | TEXT).to_be_bytes().to_vec();
    body.extend(compress(&plain));
    body
}

fn compress(plain: &[u8]) -> Vec<u8> {
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    z.write_all(plain).expect("writing to memory");
    z.finish().expect("writing to memory")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caps_parse_and_ours_are_well_formed() {
        let mut server = (CAPS | TEXT | 2 | REQUEST | NOTIFY | PROVIDE).to_be_bytes().to_vec();
        server.extend_from_slice(&20_971_520u32.to_be_bytes());
        server.extend_from_slice(&0u32.to_be_bytes());
        assert_eq!(
            parse(&server).unwrap(),
            Message::Caps { flags: CAPS | TEXT | 2 | REQUEST | NOTIFY | PROVIDE, sizes: vec![20_971_520, 0] }
        );
        // One size a format: a missing one is refused.
        assert!(parse(&server[..8]).is_err());
        assert_eq!(caps(), [0x1f, 0, 0, 1, 0, 0, 0, 0]);
        assert!(matches!(parse(&caps()).unwrap(), Message::Caps { sizes, .. } if sizes == [0]));
    }

    #[test]
    fn provide_round_trips_utf8_with_crlf_and_the_nul() {
        let body = provide(Some("grüße\n日本語 ✓"));
        let compressed = &body[4..];
        let plain = inflate(compressed, 1 << 20).unwrap();
        let text = "grüße\r\n日本語 ✓\0".as_bytes();
        assert_eq!(&plain[..4], (text.len() as u32).to_be_bytes());
        assert_eq!(&plain[4..], text);
        assert_eq!(parse(&body).unwrap(), Message::Provide { text: Some("grüße\n日本語 ✓".into()) });
        // No text: no format and an empty stream.
        assert_eq!(parse(&provide(None)).unwrap(), Message::Provide { text: None });
    }

    #[test]
    fn a_provide_whose_stream_is_flushed_but_not_ended_is_read() {
        // TigerVNC flushes the zlib stream of its provide (Z_SYNC_FLUSH) without ending it.
        let text = "from X: héllo ✓\r\nline two\0".as_bytes();
        let mut plain = (text.len() as u32).to_be_bytes().to_vec();
        plain.extend_from_slice(text);
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        z.write_all(&plain).unwrap();
        z.flush().unwrap();
        let mut body = (PROVIDE | TEXT).to_be_bytes().to_vec();
        body.extend_from_slice(z.get_ref());
        assert_eq!(parse(&body).unwrap(), Message::Provide { text: Some("from X: héllo ✓\nline two".into()) });
    }

    #[test]
    fn actions_parse_and_a_bomb_is_bounded() {
        assert_eq!(parse(&request_text()).unwrap(), Message::Request { text: true });
        assert_eq!(parse(&notify(true)).unwrap(), Message::Notify { text: true });
        assert_eq!(parse(&notify(false)).unwrap(), Message::Notify { text: false });
        assert_eq!(parse(&PEEK.to_be_bytes()).unwrap(), Message::Peek);
        assert!(parse(&[0, 0]).is_err());
        // A size beyond what the stream holds is refused, not trusted.
        let mut plain = 100_000_000u32.to_be_bytes().to_vec();
        plain.extend(std::iter::repeat_n(b'a', 2 * MAX_TEXT));
        let mut body = (PROVIDE | TEXT).to_be_bytes().to_vec();
        body.extend(compress(&plain));
        assert!(parse(&body).is_err());
        // The largest size a server can write (4 more would wrap a 32-bit usize): refused too.
        let mut plain = u32::MAX.to_be_bytes().to_vec();
        plain.extend(b"text");
        let mut body = (PROVIDE | TEXT).to_be_bytes().to_vec();
        body.extend(compress(&plain));
        assert!(matches!(parse(&body), Err(VncError::InvalidImageData)));
    }
}

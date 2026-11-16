//! Mosh's datagram layer (transport layer, for review with crypto.rs and fragment.rs).
//!
//! On the wire a datagram is the 8-byte sequence word in clear (big-endian), then the sealed body
//! (crypto.rs): the body is a 16-bit timestamp, a 16-bit timestamp reply (both big-endian,
//! milliseconds modulo 65536; a reply of 0xFFFF means none), then one fragment (fragment.rs).
//!
//! The sequence word is the direction in its top bit (set: from the server to the client) and a
//! 63-bit counter each sender raises by one per datagram. A client takes only datagrams whose bit
//! is set: one of its own sent back to it (a reflection) does not open as the server's.
//!
//! The timestamps measure the round trip as the paper describes: each side stamps its datagrams
//! with its clock, and echoes the last stamp it received, moved on by the time it held it, so the
//! sender of a stamp reads the round trip as its clock now minus the echo.

use super::crypto::{Cipher, NONCE_LEN, TAG_LEN, nonce_for};

/// The direction bit of the sequence word: set from the server to the client.
pub const TO_CLIENT: u64 = 1 << 63;
/// The sequence counter's bits.
pub const SEQUENCE_MASK: u64 = TO_CLIENT - 1;
/// A timestamp reply that says there is none.
pub const NO_REPLY: u16 = u16::MAX;
/// The clear sequence word, the two timestamps, the tag: what every datagram carries besides
/// its fragment.
pub const OVERHEAD: usize = 8 + 4 + TAG_LEN;

/// One opened datagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Datagram {
    /// The 63-bit counter.
    pub seq: u64,
    /// Sent by the server (the direction bit set).
    pub to_client: bool,
    pub timestamp: u16,
    /// [NO_REPLY] when the sender had nothing to echo.
    pub timestamp_reply: u16,
    /// The fragment (fragment.rs).
    pub payload: Vec<u8>,
}

/// Why a datagram was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DatagramError {
    /// Shorter than the clear word, the timestamps and the tag.
    Short,
    /// The tag did not match: damaged, forged, or under another key.
    Auth,
    /// It opened, but it travels the other way (a client's own datagram reflected back).
    WrongDirection,
}

/// Seals one datagram from the client ([to_client] false) or, in tests, the server.
pub fn seal(
    cipher: &Cipher,
    seq: u64,
    to_client: bool,
    timestamp: u16,
    timestamp_reply: u16,
    payload: &[u8],
) -> Vec<u8> {
    let word = (seq & SEQUENCE_MASK) | if to_client { TO_CLIENT } else { 0 };
    let mut body = Vec::with_capacity(4 + payload.len());
    body.extend_from_slice(&timestamp.to_be_bytes());
    body.extend_from_slice(&timestamp_reply.to_be_bytes());
    body.extend_from_slice(payload);
    let nonce: [u8; NONCE_LEN] = nonce_for(word);
    let sealed = cipher.seal(&nonce, &body);
    let mut out = Vec::with_capacity(8 + sealed.len());
    out.extend_from_slice(&word.to_be_bytes());
    out.extend_from_slice(&sealed);
    out
}

/// Opens a datagram, which must travel [expect_to_client]'s way.
pub fn open(cipher: &Cipher, bytes: &[u8], expect_to_client: bool) -> Result<Datagram, DatagramError> {
    if bytes.len() < OVERHEAD {
        return Err(DatagramError::Short);
    }
    let mut w = [0u8; 8];
    w.copy_from_slice(&bytes[..8]);
    let word = u64::from_be_bytes(w);
    let body = cipher.open(&nonce_for(word), &bytes[8..]).map_err(|_| DatagramError::Auth)?;
    let to_client = word & TO_CLIENT != 0;
    if to_client != expect_to_client {
        return Err(DatagramError::WrongDirection);
    }
    // OVERHEAD guarantees the four timestamp bytes.
    Ok(Datagram {
        seq: word & SEQUENCE_MASK,
        to_client,
        timestamp: u16::from_be_bytes([body[0], body[1]]),
        timestamp_reply: u16::from_be_bytes([body[2], body[3]]),
        payload: body[4..].to_vec(),
    })
}

/// Milliseconds from [then] to [now] on the 16-bit clock (modulo 65536).
pub fn stamp_diff(now: u16, then: u16) -> u16 {
    now.wrapping_sub(then)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mosh::crypto::Key;

    fn cipher() -> Cipher {
        Cipher::new(&Key::from_bytes([7; 16]))
    }

    #[test]
    fn a_datagram_round_trips_with_its_direction_and_stamps() {
        let c = cipher();
        let d = seal(&c, 5, false, 1234, NO_REPLY, b"frag");
        assert_eq!(d.len(), OVERHEAD + 4);
        assert_eq!(&d[..8], &5u64.to_be_bytes());
        let o = open(&c, &d, false).unwrap();
        assert_eq!(o, Datagram { seq: 5, to_client: false, timestamp: 1234, timestamp_reply: NO_REPLY, payload: b"frag".to_vec() });

        let d = seal(&c, 9, true, 1, 2, b"");
        assert_eq!(d[0] & 0x80, 0x80, "the server's direction bit is the top bit");
        let o = open(&c, &d, true).unwrap();
        assert_eq!((o.seq, o.to_client, o.timestamp, o.timestamp_reply), (9, true, 1, 2));
    }

    #[test]
    fn a_reflected_datagram_is_refused() {
        let c = cipher();
        let mine = seal(&c, 1, false, 0, NO_REPLY, b"keys");
        assert_eq!(open(&c, &mine, true), Err(DatagramError::WrongDirection));
    }

    #[test]
    fn flipping_the_clear_direction_bit_breaks_the_tag() {
        // The direction is in the nonce: an attacker who flips it in clear changes the nonce.
        let c = cipher();
        let mut mine = seal(&c, 1, false, 0, NO_REPLY, b"keys");
        mine[0] ^= 0x80;
        assert_eq!(open(&c, &mine, true), Err(DatagramError::Auth));
    }

    #[test]
    fn short_and_damaged_datagrams_are_dropped() {
        let c = cipher();
        for n in 0..OVERHEAD {
            assert_eq!(open(&c, &vec![0; n], true), Err(DatagramError::Short), "{n} bytes");
        }
        let mut d = seal(&c, 3, true, 0, 0, b"x");
        let last = d.len() - 1;
        d[last] ^= 0x40;
        assert_eq!(open(&c, &d, true), Err(DatagramError::Auth));
        let other = Cipher::new(&Key::from_bytes([8; 16]));
        assert_eq!(open(&other, &seal(&c, 3, true, 0, 0, b"x"), true), Err(DatagramError::Auth));
    }

    #[test]
    fn the_counter_keeps_63_bits() {
        let c = cipher();
        let d = seal(&c, u64::MAX, false, 0, 0, b"");
        let o = open(&c, &d, false).unwrap();
        assert_eq!(o.seq, SEQUENCE_MASK);
    }

    #[test]
    fn the_clock_wraps() {
        assert_eq!(stamp_diff(10, 65530), 16);
        assert_eq!(stamp_diff(500, 100), 400);
    }
}

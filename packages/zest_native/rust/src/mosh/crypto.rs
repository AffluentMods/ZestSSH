//! Mosh's session key and its cipher (transport layer, for review with datagram.rs and
//! fragment.rs).
//!
//! The server prints a 128-bit key as 22 characters of base64 (no padding) on its `MOSH CONNECT`
//! line. Every datagram is sealed with AES-128 in OCB mode (RFC 7253, OCB3) with a 128-bit tag and
//! no associated data. The 96-bit nonce is four zero bytes followed by the datagram's 64-bit
//! sequence word, big-endian; the same 8 bytes go in clear at the front of the datagram
//! (datagram.rs). The sequence word's top bit is the direction (set: server to client), so the two
//! directions never use the same nonce under the one key.
//!
//! Sources: the protocol's description in "Mosh: An Interactive Remote Shell for Mobile Clients"
//! (Winstein and Balakrishnan, USENIX ATC 2012), RFC 7253 for OCB, and what mosh-server 1.4.0
//! prints and accepts. The cipher itself is RustCrypto's `ocb3` over `aes` (MIT or Apache-2.0).

use aes::Aes128;
use ocb3::Ocb3;
use ocb3::aead::array::Array;
use ocb3::aead::consts::{U12, U16};
use ocb3::aead::{AeadInOut as _, KeyInit as _};
use zeroize::Zeroize as _;

/// The key's length in bytes.
pub const KEY_LEN: usize = 16;
/// The tag OCB appends, in bytes.
pub const TAG_LEN: usize = 16;
/// The nonce's length in bytes (four zero bytes, then the 8-byte sequence word).
pub const NONCE_LEN: usize = 12;

/// A session key. Wiped from memory when it goes; never printed.
pub struct Key([u8; KEY_LEN]);

impl Drop for Key {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Key(<redacted>)")
    }
}

/// Why a key was refused. Never says the key itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyError {
    /// Not 22 characters.
    Length(usize),
    /// Not base64 of exactly 16 bytes (a character outside the alphabet, or spare bits set).
    Encoding,
}

impl std::fmt::Display for KeyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Length(n) => write!(f, "the session key has {n} characters, not 22"),
            Self::Encoding => f.write_str("the session key is not base64 of 16 bytes"),
        }
    }
}

impl Key {
    /// The key from its 22 printed characters (standard base64 alphabet, no padding).
    pub fn parse(text: &str) -> Result<Self, KeyError> {
        use base64::Engine as _;
        let text = text.trim();
        if text.len() != 22 {
            return Err(KeyError::Length(text.chars().count()));
        }
        // 22 characters carry 132 bits: the 4 spare ones must be zero, which the strict decoder
        // checks (a key with them set is not one the server made).
        let engine = base64::engine::GeneralPurpose::new(
            &base64::alphabet::STANDARD,
            base64::engine::GeneralPurposeConfig::new()
                .with_decode_padding_mode(base64::engine::DecodePaddingMode::RequireNone),
        );
        let mut bytes = engine.decode(text).map_err(|_| KeyError::Encoding)?;
        if bytes.len() != KEY_LEN {
            bytes.zeroize();
            return Err(KeyError::Encoding);
        }
        let mut key = [0u8; KEY_LEN];
        key.copy_from_slice(&bytes);
        bytes.zeroize();
        Ok(Self(key))
    }

    /// A key from raw bytes (tests, and the fake server).
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    /// The key as the server prints it (tests and the fake server only).
    #[cfg(any(test, fuzzing))]
    pub fn printed(&self) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(self.0)
    }
}

/// The 96-bit nonce for a datagram's 64-bit sequence word.
pub fn nonce_for(word: u64) -> [u8; NONCE_LEN] {
    let mut n = [0u8; NONCE_LEN];
    n[4..].copy_from_slice(&word.to_be_bytes());
    n
}

/// AES-128-OCB3 with a 96-bit nonce and a 128-bit tag, as one session uses it.
///
/// What stays in memory for the session: AES's key schedule, which the `aes` crate wipes when it
/// goes (its feature "zeroize", turned on by the feature "mosh"), and OCB's L table, derived from
/// the key by encrypting zeros, which ocb3 0.2.0 does not wipe: it has no zeroize feature (its
/// features are alloc, getrandom, arrayvec, bytes and rand_core). The copy of the key this makes
/// is wiped in [Cipher::new].
pub struct Cipher {
    ocb: Ocb3<Aes128, U12, U16>,
}

/// A datagram did not open: too short, or its tag did not match (damaged, forged, or another
/// session's key).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenError;

impl Cipher {
    pub fn new(key: &Key) -> Self {
        let mut k = Array::<u8, U16>::from(key.0);
        let ocb = Ocb3::new(&k);
        k.as_mut_slice().zeroize();
        Self { ocb }
    }

    /// [plaintext] sealed under [nonce]: the ciphertext followed by the 16-byte tag.
    pub fn seal(&self, nonce: &[u8; NONCE_LEN], plaintext: &[u8]) -> Vec<u8> {
        self.seal_with_ad(nonce, &[], plaintext)
    }

    /// As [seal] with associated data (Mosh uses none; the RFC's test vectors do).
    pub fn seal_with_ad(&self, nonce: &[u8; NONCE_LEN], ad: &[u8], plaintext: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(plaintext.len() + TAG_LEN);
        out.extend_from_slice(plaintext);
        let n = Array::<u8, U12>::from(*nonce);
        // Fails only past 2^30 bytes (the crate's L table), which no datagram comes near.
        let tag = self
            .ocb
            .encrypt_inout_detached(&n, ad, out.as_mut_slice().into())
            .expect("a datagram is far below OCB's length limit");
        out.extend_from_slice(&tag);
        out
    }

    /// The plaintext of [sealed] (ciphertext and tag) under [nonce], or [OpenError].
    pub fn open(&self, nonce: &[u8; NONCE_LEN], sealed: &[u8]) -> Result<Vec<u8>, OpenError> {
        self.open_with_ad(nonce, &[], sealed)
    }

    pub fn open_with_ad(&self, nonce: &[u8; NONCE_LEN], ad: &[u8], sealed: &[u8]) -> Result<Vec<u8>, OpenError> {
        if sealed.len() < TAG_LEN {
            return Err(OpenError);
        }
        let (body, tag) = sealed.split_at(sealed.len() - TAG_LEN);
        let mut out = body.to_vec();
        let n = Array::<u8, U12>::from(*nonce);
        let t = Array::<u8, U16>::try_from(tag).map_err(|_| OpenError)?;
        match self.ocb.decrypt_inout_detached(&n, ad, out.as_mut_slice().into(), &t) {
            Ok(()) => Ok(out),
            Err(_) => {
                // What was decrypted before the tag was refused is not handed out (the crate
                // decrypts in place first); wiped all the same.
                out.zeroize();
                Err(OpenError)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        let s: String = s.chars().filter(|c| !c.is_whitespace()).collect();
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn rfc_cipher() -> Cipher {
        let k: [u8; 16] = unhex("000102030405060708090A0B0C0D0E0F").try_into().unwrap();
        Cipher::new(&Key::from_bytes(k))
    }

    fn nonce(hex: &str) -> [u8; 12] {
        unhex(hex).try_into().unwrap()
    }

    /// RFC 7253, appendix A: AES-128, 128-bit tag, the sample results whose nonces start
    /// BBAA9988776655443322110x.
    #[test]
    fn rfc7253_sample_results() {
        let c = rfc_cipher();
        let cases = [
            ("BBAA99887766554433221100", "", "", "785407BFFFC8AD9EDCC5520AC9111EE6"),
            (
                "BBAA99887766554433221101",
                "0001020304050607",
                "0001020304050607",
                "6820B3657B6F615A5725BDA0D3B4EB3A257C9AF1F8F03009",
            ),
            ("BBAA99887766554433221102", "0001020304050607", "", "81017F8203F081277152FADE694A0A00"),
            (
                "BBAA99887766554433221103",
                "",
                "0001020304050607",
                "45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9",
            ),
        ];
        for (n, a, p, expected) in cases {
            let sealed = c.seal_with_ad(&nonce(n), &unhex(a), &unhex(p));
            assert_eq!(sealed, unhex(expected), "nonce {n}");
            assert_eq!(c.open_with_ad(&nonce(n), &unhex(a), &sealed).unwrap(), unhex(p), "nonce {n}");
        }
    }

    /// RFC 7253, appendix A, the iterated test for AES-128 with a 128-bit tag: its result is
    /// 67E944D23256C5E0B6C61FA22FDF1EA2.
    #[test]
    fn rfc7253_wider_variety() {
        let mut key = [0u8; 16];
        key[15] = 128;
        let c = Cipher::new(&Key::from_bytes(key));
        let num = |i: usize| {
            let mut n = [0u8; 12];
            n[8..].copy_from_slice(&(i as u32).to_be_bytes());
            n
        };
        let mut all = Vec::new();
        for i in 0..128usize {
            let s = vec![0u8; i];
            all.extend(c.seal_with_ad(&num(3 * i + 1), &s, &s));
            all.extend(c.seal_with_ad(&num(3 * i + 2), &[], &s));
            all.extend(c.seal_with_ad(&num(3 * i + 3), &s, &[]));
        }
        let out = c.seal_with_ad(&num(385), &all, &[]);
        assert_eq!(out, unhex("67E944D23256C5E0B6C61FA22FDF1EA2"));
    }

    #[test]
    fn a_changed_bit_or_another_nonce_does_not_open() {
        let c = rfc_cipher();
        let n = nonce_for(7);
        let sealed = c.seal(&n, b"hello");
        assert_eq!(c.open(&n, &sealed).unwrap(), b"hello");
        for i in 0..sealed.len() {
            let mut bad = sealed.clone();
            bad[i] ^= 1;
            assert_eq!(c.open(&n, &bad), Err(OpenError), "byte {i}");
        }
        assert_eq!(c.open(&nonce_for(8), &sealed), Err(OpenError));
        assert_eq!(c.open(&n, &sealed[..15]), Err(OpenError));
        assert_eq!(c.open(&n, &[]), Err(OpenError));
    }

    #[test]
    fn the_nonce_is_four_zero_bytes_and_the_word_big_endian() {
        assert_eq!(nonce_for(0x8000_0000_0000_0102), [0, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 1, 2]);
    }

    #[test]
    fn a_key_is_22_characters_of_base64() {
        let k = Key::parse("gtwzcEPcVFEmGb/8f6cB6g").unwrap();
        assert_eq!(k.printed(), "gtwzcEPcVFEmGb/8f6cB6g");
        assert_eq!(format!("{k:?}"), "Key(<redacted>)");
        assert!(Key::parse(" gtwzcEPcVFEmGb/8f6cB6g\r\n").is_ok());
        assert_eq!(Key::parse("gtwzcEPcVFEmGb/8f6cB6").unwrap_err(), KeyError::Length(21));
        assert_eq!(Key::parse("gtwzcEPcVFEmGb/8f6cB6g==").unwrap_err(), KeyError::Length(24));
        assert_eq!(Key::parse("gtwzcEPcVFEmGb/8f6cB6!").unwrap_err(), KeyError::Encoding);
        // The last character's spare bits set: not a key the server made.
        assert_eq!(Key::parse("gtwzcEPcVFEmGb/8f6cB6h").unwrap_err(), KeyError::Encoding);
        // URL-safe characters are not the server's alphabet.
        assert_eq!(Key::parse("gtwzcEPcVFEmGb_8f6cB6g").unwrap_err(), KeyError::Encoding);
        assert!(!KeyError::Encoding.to_string().contains("gtwz"));
    }
}

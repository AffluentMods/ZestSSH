//! Apple Remote Desktop authentication, security type 30 ("Diffie-Hellman Authentication" in the
//! community spec, rfbproto). Ours (ZestSSH), written from that spec; RoyalVNC (MIT) was the
//! reference for behaviour only, no code was taken from anywhere.
//!
//! The server sends a generator (U16), the key size (U16), the prime modulus and its public value
//! (key size bytes each). The client picks a private value, computes its public value and the
//! shared secret, takes MD5 of the secret (key size bytes, big-endian) as an AES-128 key, and
//! encrypts 128 bytes in ECB: the username, then the password, each UTF-8, NUL-terminated and
//! padded with random bytes to 64. It sends the 128 encrypted bytes, then its public value.
//!
//! NOT YET CHECKED AGAINST A REAL MAC (the Mac mini has no display); the tests are a round trip
//! against our own server side.

use aes::Aes128;
use aes::cipher::{Array, BlockCipherEncrypt, KeyInit};
use md5::{Digest, Md5};
use num_bigint::BigUint;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

use crate::vnc::engine::VncError;

/// The largest key size taken (bytes): 4096-bit groups. Apple uses 128 (1024 bits).
const MAX_KEY_SIZE: usize = 512;
/// Each field of the credentials block, NUL included.
const FIELD: usize = 64;

/// What the server sent.
#[derive(Debug, Clone)]
pub(crate) struct Params {
    pub generator: u16,
    pub prime: Vec<u8>,
    pub server_public: Vec<u8>,
}

/// What the client sends back: the 128 encrypted bytes and its public value (key size bytes).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Response {
    pub encrypted: [u8; 128],
    pub client_public: Vec<u8>,
}

pub(crate) async fn read_params<S: AsyncRead + Unpin>(stream: &mut S) -> Result<Params, VncError> {
    let generator = stream.read_u16().await?;
    let size = stream.read_u16().await? as usize;
    if size == 0 || size > MAX_KEY_SIZE {
        return Err(VncError::General(format!("Apple Remote Desktop: key size {size} refused")));
    }
    let mut prime = vec![0; size];
    stream.read_exact(&mut prime).await?;
    let mut server_public = vec![0; size];
    stream.read_exact(&mut server_public).await?;
    Ok(Params { generator, prime, server_public })
}

/// Left-pads (or refuses) a big-endian number to [size] bytes.
fn padded(n: &BigUint, size: usize) -> Vec<u8> {
    let bytes = n.to_bytes_be();
    let mut out = vec![0; size.saturating_sub(bytes.len())];
    out.extend_from_slice(&bytes[bytes.len().saturating_sub(size)..]);
    out
}

/// Computes the response. [random] fills a buffer with random bytes (the private value and the
/// padding); the tests pass a fixed one.
pub(crate) fn respond(
    params: &Params,
    username: &str,
    password: &str,
    random: &mut dyn FnMut(&mut [u8]) -> Result<(), VncError>,
) -> Result<Response, VncError> {
    let size = params.prime.len();
    let p = BigUint::from_bytes_be(&params.prime);
    let g = BigUint::from(params.generator);
    let one = BigUint::from(1u8);
    let server_public = BigUint::from_bytes_be(&params.server_public);
    if p <= BigUint::from(3u8) || g <= one || g >= p {
        return Err(VncError::General("Apple Remote Desktop: bad Diffie-Hellman group".into()));
    }
    // A public value of 0, 1 or p - 1 would make the shared secret guessable.
    if server_public <= one || server_public >= &p - &one {
        return Err(VncError::General("Apple Remote Desktop: bad server public value".into()));
    }
    // The private value: random, reduced into 2 ..= p - 2.
    let mut bytes = vec![0; size];
    random(&mut bytes)?;
    let private = BigUint::from_bytes_be(&bytes) % (&p - BigUint::from(3u8)) + BigUint::from(2u8);
    let client_public = padded(&g.modpow(&private, &p), size);
    let shared = padded(&server_public.modpow(&private, &p), size);
    let key: [u8; 16] = Md5::digest(&shared).into();

    // The username and the password in clear until encrypted in place below; wiped on an early
    // return too (the encrypted block is what goes to the server).
    let mut block = zeroize::Zeroizing::new([0u8; 2 * FIELD]);
    random(&mut *block)?;
    for (field, text) in [(0, username), (1, password)] {
        let text = text.as_bytes();
        if text.len() >= FIELD || text.contains(&0) {
            return Err(VncError::General(
                "Apple Remote Desktop: the username and the password must be under 64 bytes, without NUL".into(),
            ));
        }
        let at = field * FIELD;
        block[at..at + text.len()].copy_from_slice(text);
        block[at + text.len()] = 0;
    }
    let cipher = Aes128::new(&Array::from(key));
    for chunk in block.chunks_exact_mut(16) {
        let mut b = Array::from(<[u8; 16]>::try_from(&*chunk).unwrap());
        cipher.encrypt_block(&mut b);
        chunk.copy_from_slice(&b);
    }
    Ok(Response { encrypted: *block, client_public })
}

/// Runs the exchange after the client chose type 30; the caller reads the SecurityResult.
pub(crate) async fn authenticate<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    username: &str,
    password: &str,
) -> Result<(), VncError> {
    let params = read_params(stream).await?;
    let rng = ring::rand::SystemRandom::new();
    let mut random = |buf: &mut [u8]| {
        ring::rand::SecureRandom::fill(&rng, buf).map_err(|_| VncError::General("no random numbers".into()))
    };
    let response = respond(&params, username, password, &mut random)?;
    let mut out = response.encrypted.to_vec();
    out.extend_from_slice(&response.client_public);
    stream.write_all(&out).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockCipherDecrypt;

    /// The 1024-bit MODP group of RFC 2409 (Oakley group 2), the size Apple's servers use.
    const PRIME_1024: &str = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF";

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    /// Our server side: picks a private value, then decrypts what the client sent.
    fn server_reads(prime: &[u8], server_private: &BigUint, response: &Response) -> (String, String) {
        let p = BigUint::from_bytes_be(prime);
        let client_public = BigUint::from_bytes_be(&response.client_public);
        let shared = padded(&client_public.modpow(server_private, &p), prime.len());
        let key: [u8; 16] = Md5::digest(&shared).into();
        let cipher = Aes128::new(&Array::from(key));
        let mut block = response.encrypted;
        for chunk in block.chunks_exact_mut(16) {
            let mut b = Array::from(<[u8; 16]>::try_from(&*chunk).unwrap());
            cipher.decrypt_block(&mut b);
            chunk.copy_from_slice(&b);
        }
        let field = |at: usize| {
            let f = &block[at..at + FIELD];
            String::from_utf8(f[..f.iter().position(|&b| b == 0).unwrap()].to_vec()).unwrap()
        };
        (field(0), field(FIELD))
    }

    #[test]
    fn the_server_side_reads_the_credentials_back() {
        let prime = unhex(PRIME_1024);
        assert_eq!(prime.len(), 128);
        let p = BigUint::from_bytes_be(&prime);
        let server_private = BigUint::from_bytes_be(&[0x5a; 100]);
        let params = Params {
            generator: 2,
            prime: prime.clone(),
            server_public: padded(&BigUint::from(2u8).modpow(&server_private, &p), 128),
        };
        let rng = ring::rand::SystemRandom::new();
        let mut random = |buf: &mut [u8]| ring::rand::SecureRandom::fill(&rng, buf).map_err(|_| VncError::ConnectError);
        let response = respond(&params, "alex", "pässwörd ✓", &mut random).unwrap();
        assert_eq!(response.client_public.len(), 128);
        assert_eq!(server_reads(&prime, &server_private, &response), ("alex".into(), "pässwörd ✓".into()));
    }

    /// A known answer from an independent implementation: Python's hashlib (MD5) and the
    /// cryptography package (AES-128-ECB) with Python's own big integers, given the same group,
    /// server private value and "random" bytes (counting up by 7 from 7), computed by a short
    /// script outside this repository.
    #[test]
    fn matches_an_independent_implementation() {
        let prime = unhex(PRIME_1024);
        let p = BigUint::from_bytes_be(&prime);
        let server_private = BigUint::from_bytes_be(&[0x5a; 100]);
        let params = Params {
            generator: 2,
            prime,
            server_public: padded(&BigUint::from(2u8).modpow(&server_private, &p), 128),
        };
        let mut counter = 0u8;
        let mut fixed = |buf: &mut [u8]| {
            for b in buf.iter_mut() {
                counter = counter.wrapping_add(7);
                *b = counter;
            }
            Ok(())
        };
        let r = respond(&params, "alex", "pässwörd ✓", &mut fixed).unwrap();
        assert_eq!(r.encrypted.to_vec(), unhex("9a1e969130abcff319766f3f6af86cbd1789a2cc58e54596a980b4444307ce878f0b4aba6632ef77f6da12c390034f7dfb6201c3797d1432f667b1296e58b54bd187d3cf0e5ba73a8cac7e3a056207443734a3c5343ef9f4f8b3c1130c746575940064586ba69a3ca9e1c20d99bfe2d6e93b5f41e30ab3a0286315a5b1be8311"));
        assert_eq!(r.client_public, unhex("f23aa83e74f3607b4a3cebd997364f57ca8bc08531a98d4a6936c7b20ea405970865ef727f92742685b65e7c8a938b533acb1ba06ed2cbdd259db59e9827e46c98da534c5472016d0344fc49528566e1eda9eb02727cfac0710c7eb960cd71a79f17d87b77b5b91dedf99c2df46f4a046170696583514d74840a7e81143cd9f2"));
    }

    #[test]
    fn fixed_randomness_gives_a_fixed_answer_and_bad_values_are_refused() {
        // Small group (the Mersenne prime 2^127 - 1), fixed "random" bytes: the same answer every
        // time, and the client's public value is exactly 2^x mod p for the reduced x.
        let p = (BigUint::from(1u8) << 127u32) - BigUint::from(1u8);
        let prime = padded(&p, 16);
        let server_private = BigUint::from(123_456_789u32);
        let params = Params { generator: 2, prime: prime.clone(), server_public: padded(&BigUint::from(2u8).modpow(&server_private, &p), 16) };
        let mut counter = 0u8;
        let mut fixed = |buf: &mut [u8]| {
            for b in buf.iter_mut() {
                counter = counter.wrapping_add(7);
                *b = counter;
            }
            Ok(())
        };
        let a = respond(&params, "u", "p", &mut fixed).unwrap();
        let mut counter = 0u8;
        let mut fixed = |buf: &mut [u8]| {
            for b in buf.iter_mut() {
                counter = counter.wrapping_add(7);
                *b = counter;
            }
            Ok(())
        };
        let b = respond(&params, "u", "p", &mut fixed).unwrap();
        assert_eq!(a, b);
        let x: Vec<u8> = (1..=16u8).map(|i| i.wrapping_mul(7)).collect();
        let x = BigUint::from_bytes_be(&x) % (&p - BigUint::from(3u8)) + BigUint::from(2u8);
        assert_eq!(a.client_public, padded(&BigUint::from(2u8).modpow(&x, &p), 16));
        assert_eq!(server_reads(&prime, &server_private, &a), ("u".into(), "p".into()));

        let mut random = |_: &mut [u8]| Ok(());
        for bad in [vec![0u8; 16], padded(&BigUint::from(1u8), 16), padded(&(&p - BigUint::from(1u8)), 16)] {
            let params = Params { server_public: bad, ..params.clone() };
            assert!(respond(&params, "u", "p", &mut random).is_err());
        }
        assert!(respond(&params, &"x".repeat(64), "p", &mut random).is_err());
        assert!(respond(&Params { generator: 1, ..params.clone() }, "u", "p", &mut random).is_err());
    }

    #[tokio::test]
    async fn the_wire_form_is_parameters_in_and_ciphertext_then_public_value_out() {
        let p = (BigUint::from(1u8) << 127u32) - BigUint::from(1u8);
        let mut server = vec![0, 2, 0, 16];
        server.extend(padded(&p, 16));
        server.extend(padded(&BigUint::from(2u8).modpow(&BigUint::from(99u8), &p), 16));
        let (mut client, mut peer) = tokio::io::duplex(1024);
        peer.write_all(&server).await.unwrap();
        authenticate(&mut client, "u", "p").await.unwrap();
        drop(client);
        let mut sent = Vec::new();
        peer.read_to_end(&mut sent).await.unwrap();
        assert_eq!(sent.len(), 128 + 16);
        let response = Response { encrypted: sent[..128].try_into().unwrap(), client_public: sent[128..].to_vec() };
        assert_eq!(server_reads(&padded(&p, 16), &BigUint::from(99u8), &response), ("u".into(), "p".into()));
        // A key size beyond the limit is refused before reading it.
        let (mut client, mut peer) = tokio::io::duplex(64);
        peer.write_all(&[0, 2, 0x10, 0]).await.unwrap();
        assert!(authenticate(&mut client, "u", "p").await.is_err());
    }
}

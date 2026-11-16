//! A password the native library holds for a moment (a remote screen's, 4.0): wiped from memory
//! when it goes, never printed. The screen session moves it from the open request into the engine,
//! and the engine lets it go once the handshake no longer needs it.
//!
//! What it cannot reach: the JSON text the request came in (Dart's native copy, which Dart zeroes
//! and frees itself), copies a JSON parser makes for escaped characters, and the Dart `String`.

use std::fmt;
use std::ops::Deref;

use zeroize::Zeroize as _;

#[derive(Clone, Default, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    pub fn new(text: impl Into<String>) -> Self {
        Self(text.into())
    }
}

impl Deref for Secret {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl Drop for Secret {
    fn drop(&mut self) {
        // The whole buffer, its spare capacity too.
        self.0.zeroize();
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

impl From<&str> for Secret {
    fn from(text: &str) -> Self {
        Self(text.to_owned())
    }
}

impl From<String> for Secret {
    fn from(text: String) -> Self {
        Self(text)
    }
}

impl<'de> serde::Deserialize<'de> for Secret {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        String::deserialize(d).map(Self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_reads_as_text_and_never_prints() {
        let s: Secret = serde_json::from_str(r#""hunter2""#).unwrap();
        assert_eq!(&*s, "hunter2");
        assert_eq!(format!("{s:?}"), "<redacted>");
        assert_eq!(format!("{:?}", Some(s)), "Some(<redacted>)");
    }

    #[test]
    fn its_bytes_are_wiped_when_it_goes() {
        let mut s = Secret::new(String::with_capacity(32));
        s.0.push_str("hunter2");
        let mut copy = std::mem::ManuallyDrop::new(s);
        // Wipe in place (what Drop does), then read the same buffer through its raw parts.
        let (ptr, cap) = (copy.0.as_ptr(), copy.0.capacity());
        copy.0.zeroize();
        // SAFETY: the String still owns the buffer (zeroize clears and keeps its capacity).
        let bytes = unsafe { std::slice::from_raw_parts(ptr, cap) };
        assert!(bytes.iter().all(|b| *b == 0), "{bytes:?}");
        unsafe { std::mem::ManuallyDrop::drop(&mut copy) };
    }
}

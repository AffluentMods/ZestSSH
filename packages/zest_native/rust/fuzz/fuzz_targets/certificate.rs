//! A server's certificate as the session reads it for the person's question
//! (screen::CertificateFacts, Closed::certificate and its JSON), and the pins and names a request
//! carries (parse_sha256, the VNC and RDP pins, encodings by name).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;
use zest_native::screen::{CertificateFacts, Closed, parse_sha256};

fuzz_target!(|data: &[u8]| {
    harness::init();
    let facts = CertificateFacts::of(data);
    assert_eq!(facts.sha256.len(), 64);
    let _ = Closed::certificate(data).json().to_string();
    if let Ok(text) = std::str::from_utf8(data) {
        let _ = parse_sha256(text);
        let _ = zest_native::vnc::parse_pin(text);
        let _ = zest_native::rdp::parse_pin(text);
        let _ = zest_native::vnc::parse_encoding(text);
    }
});

//! VeNCrypt (security type 19) from its version: the subtypes, the ack, then the TLS handshake
//! (rustls reads the server's records) and the pin check. The first byte picks the options
//! (user and password for X509Plain or X509Vnc).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [flags, rest @ ..] = data else { return };
    let mut server = b"RFB 003.008\n".to_vec();
    server.extend([1u8, 19]);
    server.extend_from_slice(rest);
    let draw = harness::CheckedDraw::new(64);
    let options = harness::options((*flags & 0b0000_1111) | 8, &draw);
    harness::run_vnc(server, options, &draw, Vec::new());
});

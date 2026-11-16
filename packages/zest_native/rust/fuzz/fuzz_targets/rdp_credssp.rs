//! CredSSP (NLA) as the client reads it: the server has picked NLA (the first byte's fourth bit:
//! with the early result), and the input is what it sends from there: TSRequests with its
//! NTLM challenge, its proof of the TLS key and its verdict, then the rest of the connection
//! sequence. sspi's parsers and IronRDP's CredSSP sequence are the code under test; a made-up
//! server cannot pass the key check, so the session after it is the other targets' to reach.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    harness::rdp::write_seeds_if_asked();
    let [pick, rest @ ..] = data else { return };
    let mut server = harness::rdp::confirm(if pick & 8 != 0 { 8 } else { 2 });
    server.extend_from_slice(rest);
    let _ = harness::ffi::session(harness::rdp::request(*pick, true).as_bytes(), &server, 0);
});

//! The RDP connection sequence from the server's first byte, with TLS taken as done
//! (harness/rdp.rs says how): the Connection Confirm, then what a server sends inside TLS up to
//! the session: CredSSP when it picked NLA, the settings (MCS Connect Response), the channels,
//! the licence, the capabilities and the last PDUs of the sequence, and whatever follows them.
//! The first byte picks the request (graphics, a domain, and with its fifth bit a host that signs
//! in without NLA), the rest is the server.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    harness::rdp::write_seeds_if_asked();
    let [pick, server @ ..] = data else { return };
    let _ = harness::ffi::session(harness::rdp::request(*pick, pick & 16 == 0).as_bytes(), server, 0);
});

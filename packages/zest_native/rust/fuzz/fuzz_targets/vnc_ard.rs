//! Apple Remote Desktop authentication (security type 30): the server's generator, key size,
//! prime and public value, then the result, ServerInit and messages.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let mut server = b"RFB 003.008\n".to_vec();
    server.extend([1u8, 30]);
    server.extend_from_slice(data);
    let draw = harness::CheckedDraw::new(64);
    let options = harness::options(0b11, &draw);
    harness::run_vnc(server, options, &draw, Vec::new());
});

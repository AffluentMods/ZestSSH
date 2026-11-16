//! The whole server side from its version banner: the security types (None, VNC authentication,
//! Apple Remote Desktop, VeNCrypt), ServerInit, then its messages. The first byte picks the
//! options (password, user, TLS required, a pin, continuous updates, shared), the second the
//! input sent once connected.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [flags, input, rest @ ..] = data else { return };
    let draw = harness::CheckedDraw::new(64);
    let options = harness::options(*flags, &draw);
    harness::run_vnc(rest.to_vec(), options, &draw, harness::inputs(*input));
});

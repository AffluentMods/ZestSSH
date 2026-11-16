//! The server's messages after a complete handshake: FramebufferUpdate with every encoding,
//! SetColorMapEntries, Bell, ServerCutText and the extended clipboard, EndOfContinuousUpdates,
//! Fence. The first four bytes give the screen's size (up to 1024 x 1024), the fifth the options
//! (continuous updates, shared, tiles), the sixth the input sent once connected.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [w0, w1, h0, h1, flags, input, rest @ ..] = data else { return };
    let width = 1 + u16::from_be_bytes([*w0, *w1]) % 1024;
    let height = 1 + u16::from_be_bytes([*h0, *h1]) % 1024;
    let mut server = harness::handshake(width, height);
    server.extend_from_slice(rest);
    let draw = harness::CheckedDraw::new(if flags & 64 != 0 { 0 } else { 64 });
    let options = harness::options(flags & 0b0011_0000, &draw);
    harness::run_vnc(server, options, &draw, harness::inputs(*input));
});

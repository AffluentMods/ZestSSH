//! The extended clipboard: one ServerCutText with a negative length whose body is the input
//! (flags, then sizes or zlib data), after a handshake; the client has text of its own to offer
//! when the first byte says so. Whatever follows the body is read as more messages.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [flags, split_hi, split_lo, rest @ ..] = data else { return };
    // The body's length (the rest of the input when it is longer).
    let len = usize::from(u16::from_be_bytes([*split_hi, *split_lo])).min(rest.len());
    let mut server = harness::handshake(64, 48);
    server.extend([3u8, 0, 0, 0]);
    server.extend((-(len as i32)).to_be_bytes());
    server.extend_from_slice(rest);
    let draw = harness::CheckedDraw::new(64);
    let options = harness::options(0, &draw);
    harness::run_vnc(server, options, &draw, harness::inputs(*flags & 4));
});

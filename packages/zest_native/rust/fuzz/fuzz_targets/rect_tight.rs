//! One Tight rectangle and whatever follows it (harness::rect_target).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;
use zest_native::vnc::engine::VncEncoding;

fuzz_target!(|data: &[u8]| harness::rect_target(VncEncoding::Tight, data));

//! The RDP session's own reading of fast-path output PDUs for its statistics
//! (screen::rdp_graphics::count_fastpath: update codes, bitmap updates, surface commands).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;
use zest_native::screen::fuzzing::{Stats, count_fastpath};

fuzz_target!(|data: &[u8]| {
    harness::init();
    let mut stats = Stats::new("gfx");
    count_fastpath(data, &mut stats);
});

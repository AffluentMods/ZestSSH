//! The RDP graphics pipeline channel (screen::rdp_graphics::Gfx: IronRDP's client with our
//! handler): the input is a list of channel messages, each a 2-byte length (big-endian) and its
//! bytes (RDP_SEGMENTED_DATA: ZGFX segments of RDPGFX PDUs); after each, the output reset and the
//! updated regions are taken as the session does.
//!
//! IronRDP's ZGFX decompressor had budgets of its own (64 MiB a segment, 256 MiB a message), far
//! over the harness's cap, and this target allowed 600 MiB for them. The app's fork of it
//! (vendor/ironrdp-graphics) has ceilings tied to the largest picture
//! (1 MiB a segment, one picture and 1 MiB a message), and the channel's guard keeps surfaces to
//! two pictures: so the harness's own cap (80 MiB an allocation) holds here as everywhere else,
//! and a run finds anything a server can still make larger.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use std::sync::{Arc, Mutex};

use ironrdp_dvc::DvcProcessor as _;
use libfuzzer_sys::fuzz_target;
use zest_native::screen::fuzzing::{Gfx, H264Mode, Stats};

fuzz_target!(|data: &[u8]| {
    harness::init();
    let stats = Arc::new(Mutex::new(Stats::new("gfx")));
    let mut gfx = Gfx::new(stats, H264Mode::Off);
    let _ = gfx.start(7);
    let mut rest = data;
    while let [a, b, tail @ ..] = rest {
        let len = usize::from(u16::from_be_bytes([*a, *b])).min(tail.len());
        let (message, next) = tail.split_at(len);
        rest = next;
        let _ = gfx.process(7, message);
        let _ = gfx.take_reset();
        for update in gfx.drain() {
            let _ = update;
        }
    }
    gfx.close(7);
});

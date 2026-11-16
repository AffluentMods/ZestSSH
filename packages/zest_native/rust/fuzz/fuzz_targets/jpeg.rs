//! Tight's JPEG decoder on its own (zune-jpeg with its SIMD paths, as codec/tight.rs calls it):
//! the first two bytes give the rectangle's width and height (1 to 256 each), the rest is the
//! JPEG. A decoded picture must be exactly the rectangle's size.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let [w, h, jpeg @ ..] = data else { return };
    let (width, height) = (1 + u16::from(*w), 1 + u16::from(*h));
    if let Ok(rgb) = zest_native::vnc::engine::fuzz_decode_jpeg(jpeg, width, height) {
        assert_eq!(rgb.len(), usize::from(width) * usize::from(height) * 3);
    }
});

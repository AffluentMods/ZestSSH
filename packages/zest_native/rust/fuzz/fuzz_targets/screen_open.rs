//! zest_screen_open with any request (the JSON Dart sends; NUL ends it, as in C): a request that
//! opens a session gets an empty channel, then closes.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let _ = harness::ffi::session(data, &[], 0);
});

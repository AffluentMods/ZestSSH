//! An RDP session after its sign-in, as Dart drives it: a whole sign-in goes first (made by
//! IronRDP's acceptor, harness/rdp.rs), then the input is the server's: fast-path updates
//! (bitmaps, surface commands, pointers), slow-path PDUs (a deactivation and the sequence after
//! it, error info, the end of the session), the static and dynamic channels (display control,
//! the graphics pipeline), while the app sends what the second byte picks (the pointer, keys,
//! pause and resume, a full refresh, a resize). The first byte picks the request (a host that
//! signs in without NLA, which is the sign-in that can be made up).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    harness::init();
    harness::rdp::check();
    let [pick, input, rest @ ..] = data else { return };
    let mut server = harness::rdp::handshake().to_vec();
    server.extend_from_slice(rest);
    let _ = harness::ffi::session(harness::rdp::request(*pick, false).as_bytes(), &server, *input);
});

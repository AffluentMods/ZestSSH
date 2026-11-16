//! RDP's sound channel (ironrdp-rdpsnd's client with screen::rdp_sound's handler, feature
//! `sound`): what a server can send on it, and the app turning sound on and off in between.
//!
//! The input: steps, each a byte for what happens, a 2-byte length (big-endian) and that many
//! bytes:
//!
//!   0, 1, 2: the server's message (the bytes), as the channel gets it after reassembly;
//!   3:       sound is turned on (first byte odd) or off; no bytes: the speaker takes what waits.
//!
//! What the channel answers is encoded, as it would be for the wire. No speaker is opened: the
//! handler's queue is what the speaker would read. A message here is at most 64 KiB (the length
//! field); the session never hands the channel more than rdp_channels.rs lets through (256 KiB).
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use ironrdp_svc::SvcProcessor as _;
use libfuzzer_sys::fuzz_target;
use zest_native::screen::fuzzing::{SoundShared, SoundSink};

fuzz_target!(|data: &[u8]| {
    harness::init();
    let shared = SoundShared::new(48_000, 2, true);
    let mut channel = ironrdp_rdpsnd::client::Rdpsnd::new(Box::new(SoundSink::new(shared.clone())));
    let mut rest = data;
    let mut out = vec![0f32; 4096];
    while let [what, a, b, tail @ ..] = rest {
        let len = usize::from(u16::from_be_bytes([*a, *b])).min(tail.len());
        let (bytes, next) = tail.split_at(len);
        rest = next;
        match what % 4 {
            0..=2 => {
                if let Ok(answers) = channel.process(bytes) {
                    for a in answers {
                        let _ = a.encode_unframed_pdu();
                    }
                }
            }
            _ => match bytes.first() {
                Some(on) => shared.set_on(on & 1 != 0),
                None => shared.fill(&mut out),
            },
        }
        // Never more waits than half a second at the speaker's rate.
        assert!(shared.waiting_ms() <= 500, "{} ms wait", shared.waiting_ms());
    }
});

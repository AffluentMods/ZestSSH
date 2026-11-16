//! RDP's clipboard channel (screen::rdp_clipboard::Clipboard: ours, text only): what a server
//! can send on it, and what the app does to it in between.
//!
//! The input: one byte (bit 0: the clipboard is shared from the start), then steps, each a byte
//! for what happens, a 2-byte length (big-endian) and that many bytes:
//!
//!   0, 1: the server's message (the bytes), as the channel gets it after reassembly;
//!   2:    the app gives this device's text (the bytes, as UTF-8 where they are);
//!   3:    sharing is turned on (first byte odd) or off, or a second passes (no bytes);
//!
//! After each step the text taken from the server is taken off, as the session does, and what
//! the channel answers is encoded, as it would be for the wire.
//!
//! A message here is at most 64 KiB (the length field): the session never hands the channel more
//! than rdp_channels.rs lets through (about 2 MiB), and the lengths inside a message are what
//! the channel must not trust.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use ironrdp_svc::SvcProcessor as _;
use libfuzzer_sys::fuzz_target;
use zest_native::screen::fuzzing::Clipboard;

fuzz_target!(|data: &[u8]| {
    harness::init();
    let Some((&pick, mut rest)) = data.split_first() else { return };
    let mut clip = Clipboard::new(pick & 1 != 0);
    while let [what, a, b, tail @ ..] = rest {
        let len = usize::from(u16::from_be_bytes([*a, *b])).min(tail.len());
        let (bytes, next) = tail.split_at(len);
        rest = next;
        let answers = match what % 4 {
            0 | 1 => clip.process(bytes).unwrap_or_default(),
            2 => clip.offer(String::from_utf8_lossy(bytes).into_owned()),
            _ => match bytes.first() {
                Some(on) => clip.share(on & 1 != 0),
                None => clip.tick(),
            },
        };
        for answer in &answers {
            let _ = answer.encode_unframed_pdu();
        }
        let _ = clip.take();
    }
});

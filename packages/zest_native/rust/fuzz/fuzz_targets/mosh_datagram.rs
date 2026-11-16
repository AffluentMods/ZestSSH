//! Mosh (4.0): what a server's datagrams reach in the built-in client (src/mosh). The input is
//! read once as a datagram straight off the network (it almost never opens: the tag), then as
//! steps: each a mode byte, a 16-bit length and that many bytes, sealed with the session's key so
//! the fuzzer reaches what lies behind the tag: the fragment header and assembly (mode 0: the
//! bytes are a fragment), zlib and the transport instruction's decoder (mode 1: the bytes are an
//! instruction, compressed into one fragment), and the HostMessage decoder and state
//! synchronisation (mode 2: the bytes are a diff from the state shown). Between steps the client
//! sends what is due and is typed into. Then the decoders alone on the whole input.
#![no_main]
#[path = "../harness/mod.rs"]
mod harness;
extern crate sancov_bounds;

use libfuzzer_sys::fuzz_target;
use zest_native::mosh::connection::Connection;
use zest_native::mosh::crypto::{Cipher, Key};
use zest_native::mosh::fragment::{self, Fragment};
use zest_native::mosh::{datagram, wire};

const KEY: [u8; 16] = [0x5a; 16];

fuzz_target!(|data: &[u8]| {
    harness::init();
    let key = Key::from_bytes(KEY);
    let cipher = Cipher::new(&key);
    let mut c = Connection::new(&key);
    c.resize(80, 24, 0);
    let _ = c.incoming(data, 0);

    let mut rest = data;
    let mut seq = 1u64;
    let mut now = 1u64;
    while rest.len() >= 3 {
        let mode = rest[0];
        let len = usize::from(u16::from_be_bytes([rest[1], rest[2]]));
        rest = &rest[3..];
        let (piece, tail) = rest.split_at(len.min(rest.len()));
        rest = tail;
        let payload = match mode % 3 {
            0 => piece.to_vec(),
            1 => Fragment { id: seq, num: 0, last: true, contents: fragment::compress(piece) }.encode(),
            _ => {
                let shown = c.receiver.current();
                let inst = wire::Instruction {
                    protocol_version: Some(wire::PROTOCOL_VERSION),
                    old_num: if mode & 0x80 != 0 { shown.wrapping_sub(1) } else { shown },
                    new_num: if mode & 0x08 != 0 { u64::MAX } else { shown.wrapping_add(1 + u64::from(mode >> 4)) },
                    ack_num: u64::from(mode & 7),
                    throwaway_num: 0,
                    diff: piece.to_vec(),
                    chaff: Vec::new(),
                };
                Fragment { id: seq, num: 0, last: true, contents: fragment::compress(&inst.encode()) }.encode()
            }
        };
        let stamp = (now % 65536) as u16;
        let d = datagram::seal(&cipher, seq, true, stamp, stamp.wrapping_sub(u16::from(mode)), &payload);
        let _ = c.incoming(&d, now);
        if mode & 0x40 != 0 {
            c.keys(&[mode, b'\r'], now);
        }
        if mode & 0x20 != 0 {
            c.resize(u16::from(mode), 24, now);
        }
        let _ = c.outgoing(now, Vec::new());
        seq += 1;
        now += u64::from(mode) * 7;
    }

    let _ = wire::Instruction::decode(data);
    let _ = wire::decode_host_message(data);
    let _ = wire::decode_user_message(data);
    let _ = fragment::decompress(data);
    let _ = Fragment::decode(data);
});

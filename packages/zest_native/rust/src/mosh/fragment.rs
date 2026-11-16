//! Mosh's fragments (transport layer, for review with crypto.rs and datagram.rs).
//!
//! One transport instruction (wire.rs) is serialized, compressed with zlib, and cut into
//! fragments that each fit one datagram. A fragment is the instruction's 64-bit id, a 16-bit word
//! whose top bit marks the last fragment and whose other 15 bits number it from 0 (both
//! big-endian), then its piece of the compressed instruction.
//!
//! The receiver puts together one instruction at a time: a fragment of a newer id starts over
//! (the newer instruction supersedes the older one, as state synchronisation allows), and one of
//! an older id (a late or replayed copy) is ignored, so it cannot throw away the one being put
//! together. What a peer
//! can make this side hold is bounded: [MAX_FRAGMENTS] pieces, [MAX_COMPRESSED] bytes of them, and
//! [MAX_INSTRUCTION] bytes once decompressed.

use std::io::Read as _;

/// The fragment header: the id and the numbered word.
pub const HEADER_LEN: usize = 10;
/// The last fragment's bit in the numbered word.
const FINAL_BIT: u16 = 0x8000;
/// Most fragments one instruction may come in (the 15-bit number allows 32768).
pub const MAX_FRAGMENTS: usize = 4096;
/// Most compressed bytes one instruction may be.
pub const MAX_COMPRESSED: usize = 2 << 20;
/// Most bytes one instruction may decompress to: a full redraw of a very large terminal is well
/// under this.
pub const MAX_INSTRUCTION: usize = 8 << 20;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fragment {
    pub id: u64,
    pub num: u16,
    pub last: bool,
    pub contents: Vec<u8>,
}

/// Why a fragment or an instruction was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FragmentError {
    /// Shorter than its header.
    Short,
    /// Numbered past [MAX_FRAGMENTS], or past the last one already seen, or a second last one.
    Number,
    /// More than [MAX_COMPRESSED] bytes, or a decompressed instruction over [MAX_INSTRUCTION].
    TooLarge,
    /// Not zlib.
    Compression,
}

impl Fragment {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN + self.contents.len());
        out.extend_from_slice(&self.id.to_be_bytes());
        let word = (self.num & !FINAL_BIT) | if self.last { FINAL_BIT } else { 0 };
        out.extend_from_slice(&word.to_be_bytes());
        out.extend_from_slice(&self.contents);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, FragmentError> {
        if bytes.len() < HEADER_LEN {
            return Err(FragmentError::Short);
        }
        let mut id = [0u8; 8];
        id.copy_from_slice(&bytes[..8]);
        let word = u16::from_be_bytes([bytes[8], bytes[9]]);
        Ok(Self {
            id: u64::from_be_bytes(id),
            num: word & !FINAL_BIT,
            last: word & FINAL_BIT != 0,
            contents: bytes[HEADER_LEN..].to_vec(),
        })
    }
}

/// zlib of a serialized instruction.
pub fn compress(bytes: &[u8]) -> Vec<u8> {
    use std::io::Write as _;
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    // Writing to a Vec does not fail.
    let _ = z.write_all(bytes);
    z.finish().unwrap_or_default()
}

/// A compressed instruction back, refusing one over [MAX_INSTRUCTION].
pub fn decompress(bytes: &[u8]) -> Result<Vec<u8>, FragmentError> {
    let mut out = Vec::new();
    let mut z = flate2::read::ZlibDecoder::new(bytes).take(MAX_INSTRUCTION as u64 + 1);
    z.read_to_end(&mut out).map_err(|_| FragmentError::Compression)?;
    if out.len() > MAX_INSTRUCTION {
        return Err(FragmentError::TooLarge);
    }
    Ok(out)
}

/// Cuts instructions into fragments, each with a new id.
#[derive(Debug, Default)]
pub struct Fragmenter {
    next_id: u64,
}

impl Fragmenter {
    /// [instruction] (serialized, not yet compressed) as fragments of at most [max_contents]
    /// bytes of compressed data each (at least one fragment, which may be empty).
    pub fn split(&mut self, instruction: &[u8], max_contents: usize) -> Vec<Fragment> {
        let id = self.next_id;
        self.next_id += 1;
        let data = compress(instruction);
        let size = max_contents.max(1);
        let mut out: Vec<Fragment> = data
            .chunks(size)
            .enumerate()
            .map(|(i, c)| Fragment { id, num: i as u16, last: false, contents: c.to_vec() })
            .collect();
        if out.is_empty() {
            out.push(Fragment { id, num: 0, last: false, contents: Vec::new() });
        }
        if let Some(l) = out.last_mut() {
            l.last = true;
        }
        out
    }
}

/// Puts one instruction at a time back together.
#[derive(Debug, Default)]
pub struct Assembler {
    current: Option<u64>,
    parts: Vec<Option<Vec<u8>>>,
    /// How many there are, once the last one came.
    total: Option<usize>,
    got: usize,
    bytes: usize,
    /// The id last put together: its late copies are ignored.
    done: Option<u64>,
}

impl Assembler {
    fn reset(&mut self, id: Option<u64>) {
        self.current = id;
        self.parts.clear();
        self.total = None;
        self.got = 0;
        self.bytes = 0;
    }

    /// Takes one fragment; returns the compressed instruction once all its fragments came.
    pub fn add(&mut self, f: Fragment) -> Result<Option<Vec<u8>>, FragmentError> {
        // Older than the one being put together, or than the last one put together: a late or
        // replayed copy, ignored (the sender numbers its instructions upwards).
        if self.current.is_some_and(|c| f.id < c) || self.done.is_some_and(|d| f.id <= d) {
            return Ok(None);
        }
        if self.current != Some(f.id) {
            self.reset(Some(f.id));
        }
        let num = usize::from(f.num);
        let bad = num >= MAX_FRAGMENTS
            || self.total.is_some_and(|t| num >= t)
            || (f.last && (self.total.is_some_and(|t| t != num + 1) || self.parts.len() > num + 1));
        if bad {
            self.reset(None);
            return Err(FragmentError::Number);
        }
        if f.last {
            self.total = Some(num + 1);
        }
        if self.parts.len() <= num {
            self.parts.resize(num + 1, None);
        }
        if self.parts[num].is_none() {
            self.bytes += f.contents.len();
            if self.bytes > MAX_COMPRESSED {
                self.reset(None);
                return Err(FragmentError::TooLarge);
            }
            self.parts[num] = Some(f.contents);
            self.got += 1;
        }
        if self.total == Some(self.got) {
            let mut out = Vec::with_capacity(self.bytes);
            for p in self.parts.drain(..) {
                out.extend(p.unwrap_or_default());
            }
            self.done = self.current;
            self.reset(None);
            return Ok(Some(out));
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fragment_round_trips() {
        let f = Fragment { id: 0x0102030405060708, num: 3, last: true, contents: b"abc".to_vec() };
        let b = f.encode();
        assert_eq!(&b[..10], &[1, 2, 3, 4, 5, 6, 7, 8, 0x80, 3]);
        assert_eq!(Fragment::decode(&b).unwrap(), f);
        assert_eq!(Fragment::decode(&b[..9]), Err(FragmentError::Short));
    }

    #[test]
    fn split_and_put_back_together_in_any_order() {
        let data: Vec<u8> = (0..20000u32).flat_map(|i| (i.wrapping_mul(2654435761) ^ (i >> 3)).to_le_bytes()).collect();
        let mut fr = Fragmenter::default();
        let frags = fr.split(&data, 300);
        assert!(frags.len() > 10);
        assert!(frags.iter().all(|f| f.id == 0 && f.contents.len() <= 300));
        assert_eq!(frags.iter().filter(|f| f.last).count(), 1);
        let mut a = Assembler::default();
        let mut order: Vec<usize> = (0..frags.len()).rev().collect();
        // A duplicate in the middle changes nothing.
        order.insert(3, 0);
        let mut whole = None;
        for i in order {
            if let Some(w) = a.add(frags[i].clone()).unwrap() {
                assert!(whole.is_none(), "put together once");
                whole = Some(w);
            }
        }
        assert_eq!(decompress(&whole.unwrap()).unwrap(), data);
        // A late copy of a fragment of the instruction already put together is ignored.
        assert_eq!(a.add(frags[1].clone()).unwrap(), None);
        // The next instruction has the next id.
        assert_eq!(fr.split(b"x", 300)[0].id, 1);
    }

    #[test]
    fn an_empty_instruction_is_one_fragment() {
        let mut fr = Fragmenter::default();
        let f = fr.split(b"", 100);
        assert_eq!(f.len(), 1);
        assert!(f[0].last);
        let mut a = Assembler::default();
        let w = a.add(f[0].clone()).unwrap().unwrap();
        assert_eq!(decompress(&w).unwrap(), b"");
    }

    #[test]
    fn a_newer_instruction_supersedes_a_partial_one() {
        let mut fr = Fragmenter::default();
        let old = fr.split(&(0..5000u32).flat_map(|i| i.wrapping_mul(2654435761).to_le_bytes()).collect::<Vec<u8>>(), 100);
        let new = fr.split(b"new", 100);
        let mut a = Assembler::default();
        assert_eq!(a.add(old[0].clone()).unwrap(), None);
        let w = a.add(new[0].clone()).unwrap().unwrap();
        assert_eq!(decompress(&w).unwrap(), b"new");
    }

    #[test]
    fn an_older_instruction_never_throws_away_the_one_being_put_together() {
        let mut fr = Fragmenter::default();
        let random = |n: u32| (0..n).flat_map(|i| i.wrapping_mul(2654435761).to_le_bytes()).collect::<Vec<u8>>();
        let old = fr.split(&random(400), 100);
        let new = fr.split(&random(3000), 100);
        assert!(old.len() > 1 && new.len() > 2);
        let mut a = Assembler::default();
        // The older instruction comes whole...
        for f in &old {
            a.add(f.clone()).unwrap();
        }
        // ...then the newer one's first piece, a replayed piece of the older one, and the rest.
        assert_eq!(a.add(new[0].clone()).unwrap(), None);
        assert_eq!(a.add(old[0].clone()).unwrap(), None, "an older id is ignored");
        let mut whole = None;
        for f in &new[1..] {
            whole = whole.or(a.add(f.clone()).unwrap());
        }
        assert_eq!(decompress(&whole.unwrap()).unwrap(), random(3000));
        // A replay of either afterwards changes nothing.
        assert_eq!(a.add(old[1].clone()).unwrap(), None);
        assert_eq!(a.add(new[1].clone()).unwrap(), None);
    }

    #[test]
    fn numbers_that_contradict_are_refused() {
        let f = |num: u16, last: bool| Fragment { id: 1, num, last, contents: vec![0] };
        let mut a = Assembler::default();
        a.add(f(2, true)).unwrap();
        assert_eq!(a.add(f(3, false)), Err(FragmentError::Number), "past the last");
        let mut a = Assembler::default();
        a.add(f(5, false)).unwrap();
        assert_eq!(a.add(f(2, true)), Err(FragmentError::Number), "last before one already seen");
        let mut a = Assembler::default();
        a.add(f(2, true)).unwrap();
        assert_eq!(a.add(f(1, true)), Err(FragmentError::Number), "a second last");
        let mut a = Assembler::default();
        assert_eq!(a.add(f(MAX_FRAGMENTS as u16, false)), Err(FragmentError::Number));
    }

    #[test]
    fn what_a_peer_can_make_this_side_hold_is_bounded() {
        let mut a = Assembler::default();
        let big = vec![0u8; 1400];
        let mut refused = false;
        for n in 0..MAX_FRAGMENTS as u16 {
            if a.add(Fragment { id: 9, num: n, last: false, contents: big.clone() }) == Err(FragmentError::TooLarge) {
                refused = true;
                break;
            }
        }
        assert!(refused);
        // A zlib bomb: a few kilobytes that would be gigabytes.
        let bomb = compress(&vec![0u8; MAX_INSTRUCTION + 10]);
        assert!(bomb.len() < 64 << 10);
        assert_eq!(decompress(&bomb), Err(FragmentError::TooLarge));
        assert_eq!(decompress(b"not zlib"), Err(FragmentError::Compression));
    }
}

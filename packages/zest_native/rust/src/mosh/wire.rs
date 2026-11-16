//! Mosh's messages in protocol buffers' encoding (state synchronisation's framing; a parser of
//! what the server sends, for review with sync.rs).
//!
//! Three messages, as the protocol's published .proto files define them (field numbers and types
//! are the protocol's facts; this encoder and decoder are our own and know only these fields):
//!
//! - the transport instruction: protocol_version (1, uint32), old_num (2), new_num (3), ack_num
//!   (4), throwaway_num (5) (uint64 each), diff (6, bytes), chaff (7, bytes);
//! - the client's diff, a UserMessage: repeated instruction (1), each with a keystroke (2: a
//!   message with keys, field 4, bytes) or a resize (3: width 5, height 6, int32);
//! - the server's diff, a HostMessage: repeated instruction (1), each with host bytes (2: a
//!   message with hoststring, field 4, bytes), a resize (3: width 5, height 6) or an echo ack
//!   (7: echo_ack_num, field 8, uint64).
//!
//! The decoder skips fields it does not know (as protocol buffers require) and refuses what is
//! malformed: a varint longer than 10 bytes, a length past the end, a group (wire types 3 and 4),
//! a wire type that does not exist, nesting deeper than these messages have.

/// The protocol version both sides speak (mosh 1.2 and later).
pub const PROTOCOL_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WireError {
    /// Ended inside a field.
    Truncated,
    /// A varint of more than 10 bytes, or one that does not fit 64 bits.
    Varint,
    /// A wire type this decoder refuses (groups, or 6 and 7).
    WireType(u8),
    /// Field number 0.
    FieldZero,
    /// A known field with the wrong wire type.
    Mismatch(u32),
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => f.write_str("a message ended inside a field"),
            Self::Varint => f.write_str("a number is too long"),
            Self::WireType(t) => write!(f, "wire type {t}"),
            Self::FieldZero => f.write_str("field number 0"),
            Self::Mismatch(n) => write!(f, "field {n} has the wrong type"),
        }
    }
}

// --- the encoding itself ---

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn put_key(out: &mut Vec<u8>, field: u32, wire_type: u8) {
    put_varint(out, (u64::from(field) << 3) | u64::from(wire_type));
}

fn put_uint(out: &mut Vec<u8>, field: u32, v: u64) {
    put_key(out, field, 0);
    put_varint(out, v);
}

fn put_int32(out: &mut Vec<u8>, field: u32, v: i32) {
    // int32: a negative value is sign-extended to 64 bits (ten bytes).
    put_uint(out, field, i64::from(v) as u64);
}

fn put_bytes(out: &mut Vec<u8>, field: u32, b: &[u8]) {
    put_key(out, field, 2);
    put_varint(out, b.len() as u64);
    out.extend_from_slice(b);
}

/// A field's value as read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Value<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    /// Fixed 32 or 64 bits: no field of these messages has them; skipped.
    Fixed,
}

struct Reader<'a> {
    rest: &'a [u8],
}

impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { rest: bytes }
    }

    fn varint(&mut self) -> Result<u64, WireError> {
        let mut v: u64 = 0;
        for i in 0..10 {
            let Some((&b, rest)) = self.rest.split_first() else { return Err(WireError::Truncated) };
            self.rest = rest;
            let bits = u64::from(b & 0x7f);
            // The tenth byte may hold only the top bit of 64.
            if i == 9 && bits > 1 {
                return Err(WireError::Varint);
            }
            v |= bits << (7 * i);
            if b & 0x80 == 0 {
                return Ok(v);
            }
        }
        Err(WireError::Varint)
    }

    fn take(&mut self, n: u64) -> Result<&'a [u8], WireError> {
        let n = usize::try_from(n).map_err(|_| WireError::Truncated)?;
        if n > self.rest.len() {
            return Err(WireError::Truncated);
        }
        let (head, tail) = self.rest.split_at(n);
        self.rest = tail;
        Ok(head)
    }

    /// The next field, or None at the end.
    fn field(&mut self) -> Result<Option<(u32, Value<'a>)>, WireError> {
        if self.rest.is_empty() {
            return Ok(None);
        }
        let key = self.varint()?;
        let wire_type = (key & 7) as u8;
        let number = key >> 3;
        if number == 0 {
            return Err(WireError::FieldZero);
        }
        // Field numbers are at most 2^29 - 1; a larger one is simply unknown and skipped.
        let number = u32::try_from(number).unwrap_or(u32::MAX);
        let value = match wire_type {
            0 => Value::Varint(self.varint()?),
            1 => {
                self.take(8)?;
                Value::Fixed
            }
            2 => {
                let n = self.varint()?;
                Value::Bytes(self.take(n)?)
            }
            5 => {
                self.take(4)?;
                Value::Fixed
            }
            t => return Err(WireError::WireType(t)),
        };
        Ok(Some((number, value)))
    }
}

fn want_varint(number: u32, v: Value<'_>) -> Result<u64, WireError> {
    match v {
        Value::Varint(x) => Ok(x),
        _ => Err(WireError::Mismatch(number)),
    }
}

fn want_bytes<'a>(number: u32, v: Value<'a>) -> Result<&'a [u8], WireError> {
    match v {
        Value::Bytes(b) => Ok(b),
        _ => Err(WireError::Mismatch(number)),
    }
}

// --- the transport instruction ---

/// One instruction of state synchronisation: the diff that takes the receiver from state
/// [old_num] to [new_num], the newest of the receiver's states the sender has ([ack_num]), and
/// the oldest state the sender may still diff from ([throwaway_num]).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Instruction {
    pub protocol_version: Option<u32>,
    pub old_num: u64,
    pub new_num: u64,
    pub ack_num: u64,
    pub throwaway_num: u64,
    pub diff: Vec<u8>,
    pub chaff: Vec<u8>,
}

impl Instruction {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(32 + self.diff.len() + self.chaff.len());
        if let Some(v) = self.protocol_version {
            put_uint(&mut out, 1, u64::from(v));
        }
        put_uint(&mut out, 2, self.old_num);
        put_uint(&mut out, 3, self.new_num);
        put_uint(&mut out, 4, self.ack_num);
        put_uint(&mut out, 5, self.throwaway_num);
        if !self.diff.is_empty() {
            put_bytes(&mut out, 6, &self.diff);
        }
        if !self.chaff.is_empty() {
            put_bytes(&mut out, 7, &self.chaff);
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut r = Reader::new(bytes);
        let mut i = Self::default();
        while let Some((n, v)) = r.field()? {
            match n {
                1 => i.protocol_version = Some(want_varint(n, v)? as u32),
                2 => i.old_num = want_varint(n, v)?,
                3 => i.new_num = want_varint(n, v)?,
                4 => i.ack_num = want_varint(n, v)?,
                5 => i.throwaway_num = want_varint(n, v)?,
                // A repeated bytes field read twice keeps the last, as protocol buffers do.
                6 => i.diff = want_bytes(n, v)?.to_vec(),
                7 => i.chaff = want_bytes(n, v)?.to_vec(),
                _ => {}
            }
        }
        Ok(i)
    }
}

// --- the client's side: UserMessage ---

/// What the client's state is made of: what was typed, and the terminal's size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UserEvent {
    Keys(Vec<u8>),
    Resize { width: i32, height: i32 },
}

/// A UserMessage holding [events], in order.
pub fn encode_user_message(events: &[UserEvent]) -> Vec<u8> {
    let mut out = Vec::new();
    for e in events {
        let mut inner = Vec::new();
        match e {
            UserEvent::Keys(keys) => {
                let mut k = Vec::with_capacity(keys.len() + 4);
                put_bytes(&mut k, 4, keys);
                put_bytes(&mut inner, 2, &k);
            }
            UserEvent::Resize { width, height } => {
                let mut r = Vec::new();
                put_int32(&mut r, 5, *width);
                put_int32(&mut r, 6, *height);
                put_bytes(&mut inner, 3, &r);
            }
        }
        put_bytes(&mut out, 1, &inner);
    }
    out
}

fn decode_size(bytes: &[u8]) -> Result<(i32, i32), WireError> {
    let mut r = Reader::new(bytes);
    let (mut w, mut h) = (0i32, 0i32);
    while let Some((n, v)) = r.field()? {
        match n {
            5 => w = want_varint(n, v)? as i32,
            6 => h = want_varint(n, v)? as i32,
            _ => {}
        }
    }
    Ok((w, h))
}

fn decode_bytes_field(bytes: &[u8], field: u32) -> Result<Vec<u8>, WireError> {
    let mut r = Reader::new(bytes);
    let mut out = Vec::new();
    while let Some((n, v)) = r.field()? {
        if n == field {
            out = want_bytes(n, v)?.to_vec();
        }
    }
    Ok(out)
}

/// A UserMessage's events (the fake server's side, and tests).
pub fn decode_user_message(bytes: &[u8]) -> Result<Vec<UserEvent>, WireError> {
    let mut r = Reader::new(bytes);
    let mut out = Vec::new();
    while let Some((n, v)) = r.field()? {
        if n != 1 {
            continue;
        }
        let mut inner = Reader::new(want_bytes(n, v)?);
        while let Some((m, w)) = inner.field()? {
            match m {
                2 => out.push(UserEvent::Keys(decode_bytes_field(want_bytes(m, w)?, 4)?)),
                3 => {
                    let (width, height) = decode_size(want_bytes(m, w)?)?;
                    out.push(UserEvent::Resize { width, height });
                }
                _ => {}
            }
        }
    }
    Ok(out)
}

// --- the server's side: HostMessage ---

/// What one instruction of the server's diff says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostEvent {
    /// Terminal output that takes the screen from the old state to the new one.
    Bytes(Vec<u8>),
    /// The server's terminal is this size now.
    Resize { width: i32, height: i32 },
    /// The server has echoed the client's input through this state (for local echo prediction).
    EchoAck(u64),
}

/// A HostMessage's events, in order. An instruction with none of the known extensions is
/// skipped.
pub fn decode_host_message(bytes: &[u8]) -> Result<Vec<HostEvent>, WireError> {
    let mut r = Reader::new(bytes);
    let mut out = Vec::new();
    while let Some((n, v)) = r.field()? {
        if n != 1 {
            continue;
        }
        let mut inner = Reader::new(want_bytes(n, v)?);
        while let Some((m, w)) = inner.field()? {
            match m {
                2 => out.push(HostEvent::Bytes(decode_bytes_field(want_bytes(m, w)?, 4)?)),
                3 => {
                    let (width, height) = decode_size(want_bytes(m, w)?)?;
                    out.push(HostEvent::Resize { width, height });
                }
                7 => {
                    let mut e = Reader::new(want_bytes(m, w)?);
                    let mut num = 0;
                    while let Some((k, x)) = e.field()? {
                        if k == 8 {
                            num = want_varint(k, x)?;
                        }
                    }
                    out.push(HostEvent::EchoAck(num));
                }
                _ => {}
            }
        }
    }
    Ok(out)
}

/// A HostMessage holding [events] (the fake server's side, and tests).
pub fn encode_host_message(events: &[HostEvent]) -> Vec<u8> {
    let mut out = Vec::new();
    for e in events {
        let mut inner = Vec::new();
        match e {
            HostEvent::Bytes(b) => {
                let mut h = Vec::new();
                put_bytes(&mut h, 4, b);
                put_bytes(&mut inner, 2, &h);
            }
            HostEvent::Resize { width, height } => {
                let mut r = Vec::new();
                put_int32(&mut r, 5, *width);
                put_int32(&mut r, 6, *height);
                put_bytes(&mut inner, 3, &r);
            }
            HostEvent::EchoAck(n) => {
                let mut a = Vec::new();
                put_uint(&mut a, 8, *n);
                put_bytes(&mut inner, 7, &a);
            }
        }
        put_bytes(&mut out, 1, &inner);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_round_trip_and_bad_ones_are_refused() {
        for v in [0u64, 1, 127, 128, 300, u32::MAX as u64, u64::MAX - 1, u64::MAX] {
            let mut b = Vec::new();
            put_varint(&mut b, v);
            assert!(b.len() <= 10);
            assert_eq!(Reader::new(&b).varint().unwrap(), v);
        }
        assert_eq!(Reader::new(&[0x80; 11]).varint(), Err(WireError::Varint));
        // Ten bytes whose last carries more than the 64th bit.
        let mut over = vec![0xff; 9];
        over.push(0x02);
        assert_eq!(Reader::new(&over).varint(), Err(WireError::Varint));
        assert_eq!(Reader::new(&[0x80]).varint(), Err(WireError::Truncated));
    }

    #[test]
    fn an_instruction_round_trips() {
        let i = Instruction {
            protocol_version: Some(PROTOCOL_VERSION),
            old_num: 3,
            new_num: u64::MAX,
            ack_num: 77,
            throwaway_num: 2,
            diff: b"diff".to_vec(),
            chaff: vec![0; 5],
        };
        assert_eq!(Instruction::decode(&i.encode()).unwrap(), i);
        // protocol buffers' known bytes for a small one: version 2, old 0, new 1, ack 0, throw 0.
        let small = Instruction { protocol_version: Some(2), new_num: 1, ..Default::default() };
        assert_eq!(small.encode(), vec![0x08, 2, 0x10, 0, 0x18, 1, 0x20, 0, 0x28, 0]);
    }

    #[test]
    fn unknown_fields_are_skipped() {
        let mut b = Instruction { new_num: 4, ..Default::default() }.encode();
        put_uint(&mut b, 99, 5);
        put_bytes(&mut b, 100, b"zz");
        put_key(&mut b, 101, 1);
        b.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
        put_key(&mut b, 102, 5);
        b.extend_from_slice(&[1, 2, 3, 4]);
        assert_eq!(Instruction::decode(&b).unwrap().new_num, 4);
    }

    #[test]
    fn malformed_messages_are_refused() {
        assert_eq!(Instruction::decode(&[0x32, 5, 1]), Err(WireError::Truncated));
        assert_eq!(Instruction::decode(&[0x33]), Err(WireError::WireType(3)));
        assert_eq!(Instruction::decode(&[0x34]), Err(WireError::WireType(4)));
        assert_eq!(Instruction::decode(&[0x36]), Err(WireError::WireType(6)));
        assert_eq!(Instruction::decode(&[0x00, 0]), Err(WireError::FieldZero));
        assert_eq!(Instruction::decode(&[0x12, 0]), Err(WireError::Mismatch(2)));
        assert_eq!(Instruction::decode(&[0x30, 0]), Err(WireError::Mismatch(6)));
        assert_eq!(Instruction::decode(&[0x32, 0xff, 0xff, 0xff, 0xff, 0x0f]), Err(WireError::Truncated));
    }

    #[test]
    fn user_messages_round_trip() {
        let ev = vec![
            UserEvent::Resize { width: 80, height: 24 },
            UserEvent::Keys(b"ls\r".to_vec()),
            UserEvent::Keys(vec![]),
            UserEvent::Resize { width: -1, height: 0 },
        ];
        assert_eq!(decode_user_message(&encode_user_message(&ev)).unwrap(), ev);
        // The keystroke's known bytes: instruction (1) { keystroke (2) { keys (4) "a" } }.
        assert_eq!(encode_user_message(&[UserEvent::Keys(b"a".to_vec())]), vec![0x0a, 5, 0x12, 3, 0x22, 1, b'a']);
        // A resize: instruction { resize (3) { width (5) 80, height (6) 24 } }.
        assert_eq!(
            encode_user_message(&[UserEvent::Resize { width: 80, height: 24 }]),
            vec![0x0a, 6, 0x1a, 4, 0x28, 80, 0x30, 24]
        );
    }

    #[test]
    fn host_messages_round_trip() {
        let ev = vec![
            HostEvent::Bytes(b"\x1b[H hello".to_vec()),
            HostEvent::Resize { width: 120, height: 40 },
            HostEvent::EchoAck(12),
        ];
        assert_eq!(decode_host_message(&encode_host_message(&ev)).unwrap(), ev);
        assert_eq!(decode_host_message(&[]).unwrap(), vec![]);
        // An instruction with an extension this client does not know: skipped.
        let mut unknown = Vec::new();
        let mut inner = Vec::new();
        put_bytes(&mut inner, 9, b"?");
        put_bytes(&mut unknown, 1, &inner);
        assert_eq!(decode_host_message(&unknown).unwrap(), vec![]);
    }
}

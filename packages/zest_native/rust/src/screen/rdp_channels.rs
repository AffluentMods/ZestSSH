//! What one channel message of a server's may make the app hold (4.0).
//!
//! RDP's channels carry a message in pieces, and the first piece says how long the whole is: up
//! to four gigabytes, on the server's word. IronRDP puts the pieces together as they come and has
//! no limit of its own, neither for a static channel's message (ironrdp-svc 0.10.0,
//! `ChunkProcessor::dechunkify`) nor for a dynamic channel's (ironrdp-dvc 0.10.0,
//! `CompleteData`). Nothing is allocated ahead of the bytes, so the server has to send what it
//! wants held; a server that does can still take every byte a phone has, in under a minute on a
//! fast network, with the app unable to say no. Found by reading, while the clipboard's channel
//! was being written (13 November 2026); the earlier ceilings (the picture, ZGFX) are about
//! what a few bytes can make the app allocate, and did not look here.
//!
//! [ChannelGuard] looks at every frame of the server's before IronRDP gets it, with IronRDP's own
//! decoders for the framing (so the two never read a frame differently), and knows the two
//! channels a session has:
//!
//! - the dynamic channels' carrier (`drdynvc`): one of its own messages is a dynamic channel PDU
//!   of at most 1,600 bytes, so [MAX_CARRIER_MESSAGE] is generous; and a dynamic channel message
//!   (a graphics pipeline message, the display control's few bytes) may be [MAX_DYNAMIC_MESSAGE],
//!   which is what the pipeline's decompressor would take of it anyway;
//! - the clipboard (`cliprdr`): [MAX_CLIPBOARD_MESSAGE], the longest text the app takes, as
//!   UTF-16. A longer one is not an attack by itself (a person copied a long text), so it is let
//!   go by, piece by piece, unheld, and the session goes on. (The channel is told its
//!   answer will not come, `Clipboard::lost`, and asks again when the server's clipboard next
//!   changes.)
//!
//! - the sound (`rdpsnd`, feature `sound`): [MAX_SOUND_MESSAGE], more than half a second of
//!   the largest format the app advertises. A longer one is let go by, as a clipboard's is:
//!   the channel ignores what it cannot read, and the sound goes on with the next block.
//!
//! Anything else that is too long ends the session ("protocol"). Frames that are not channel
//! data, or that do not decode, are IronRDP's to judge.

use ironrdp_pdu::ironrdp_core::{ReadCursor, decode_cursor};
use ironrdp_pdu::rdp::vc::{ChannelControlFlags, ChannelPduHeader};

use super::rdp_session::MAX_PIXELS;

/// The longest message of the dynamic channels' own static channel. Its messages are dynamic
/// channel PDUs, 1,600 bytes at most ([MS-RDPEDYC] 3.1.5.1.4); a long one is itself sent as
/// many of those.
pub(crate) const MAX_CARRIER_MESSAGE: usize = 64 * 1024;

/// The longest message of a dynamic channel: the largest picture the app holds, not compressed,
/// and room for the pipeline's framing. The pipeline's decompressor stops at the picture plus
/// 1 MiB (vendor/ironrdp-graphics), so a longer message could never be drawn.
pub(crate) const MAX_DYNAMIC_MESSAGE: usize = MAX_PIXELS * 4 + 2 * 1024 * 1024;

/// The longest clipboard text taken from a server, in UTF-8 bytes (as VNC's, `MAX_TEXT` of the
/// VNC engine's limits, and the app's `kScreenClipboardMaxBytes`).
pub(crate) const MAX_CLIPBOARD_TEXT: usize = 1024 * 1024;

/// The longest message of the clipboard's channel: [MAX_CLIPBOARD_TEXT] as UTF-16 is at most
/// twice as many bytes, and its header.
pub(crate) const MAX_CLIPBOARD_MESSAGE: usize = 2 * MAX_CLIPBOARD_TEXT + 1024;

/// The longest message of the sound channel (rdp_sound.rs): more than half a second of the
/// largest format the app advertises (48 kHz, stereo, 16 bit: 192,000 bytes a second) and its
/// header.
pub(crate) const MAX_SOUND_MESSAGE: usize = 256 * 1024;

/// What to do with a frame.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Look {
    /// IronRDP gets it.
    Pass,
    /// Not handed on: a piece of a clipboard message too long to take.
    Drop,
    /// The session ends: why.
    Refuse(String),
}

/// A message in pieces on one static channel, as IronRDP's own reassembly sees it.
#[derive(Debug, Default)]
struct Pieces {
    /// A first piece came and the last has not.
    open: bool,
    /// The bytes of the open message so far.
    held: usize,
    /// The open message is being let go by (the clipboard's only).
    dropping: bool,
}

#[derive(Debug)]
pub(crate) struct ChannelGuard {
    /// The MCS channel of `drdynvc`, where the server joined it.
    carrier: Option<u16>,
    /// The MCS channel of `cliprdr`, where the session has one.
    clipboard: Option<u16>,
    /// The MCS channel of `rdpsnd`, where the session has one.
    sound: Option<u16>,
    carrier_pieces: Pieces,
    clipboard_pieces: Pieces,
    sound_pieces: Pieces,
    /// Clipboard messages let go by for their length, since the last [ChannelGuard::take_dropped].
    dropped: u32,
}

impl ChannelGuard {
    pub(crate) fn new(carrier: Option<u16>, clipboard: Option<u16>) -> Self {
        Self {
            carrier,
            clipboard,
            sound: None,
            carrier_pieces: Pieces::default(),
            clipboard_pieces: Pieces::default(),
            sound_pieces: Pieces::default(),
            dropped: 0,
        }
    }

    /// With the sound channel's MCS channel, where the session has one.
    pub(crate) fn with_sound(mut self, sound: Option<u16>) -> Self {
        self.sound = sound;
        self
    }

    /// How many clipboard messages were too long to take since this was last asked.
    pub(crate) fn take_dropped(&mut self) -> u32 {
        std::mem::take(&mut self.dropped)
    }

    /// Looks at one X.224 frame of the server's.
    pub(crate) fn look(&mut self, frame: &[u8]) -> Look {
        let Ok(data) = ironrdp_pdu::mcs::decode_send_data_indication(frame) else {
            return Look::Pass;
        };
        let clipboard = Some(data.channel_id) == self.clipboard;
        let sound = !clipboard && Some(data.channel_id) == self.sound;
        if !clipboard && !sound && Some(data.channel_id) != self.carrier {
            return Look::Pass;
        }
        // The two that are let go by when too long, and not counted alike.
        let letting_go = clipboard || sound;
        let mut cursor = ReadCursor::new(data.user_data);
        let Ok(header) = decode_cursor::<ChannelPduHeader>(&mut cursor) else {
            return Look::Pass;
        };
        let piece = cursor.remaining();
        let first = header.flags.contains(ChannelControlFlags::FLAG_FIRST);
        let last = header.flags.contains(ChannelControlFlags::FLAG_LAST);
        let said = usize::try_from(header.length).unwrap_or(usize::MAX);
        let (pieces, most) = if clipboard {
            (&mut self.clipboard_pieces, MAX_CLIPBOARD_MESSAGE)
        } else if sound {
            (&mut self.sound_pieces, MAX_SOUND_MESSAGE)
        } else {
            (&mut self.carrier_pieces, MAX_CARRIER_MESSAGE)
        };

        if first {
            // A message begins (a new one where the one let go by never ended).
            pieces.dropping = false;
            if said > most {
                if !letting_go {
                    return Look::Refuse(format!("a channel message of {said} bytes (at most {most})"));
                }
                pieces.dropping = !last;
                if clipboard {
                    self.dropped = self.dropped.saturating_add(1);
                }
                return Look::Drop;
            }
            if !letting_go {
                if let Err(why) = dynamic_message(piece, !last) {
                    return Look::Refuse(why);
                }
            }
            if pieces.open {
                // IronRDP refuses a first piece inside a message; it then has nothing open.
                pieces.open = false;
                return Look::Pass;
            }
            pieces.open = !last;
            pieces.held = piece.len();
        } else if pieces.dropping {
            pieces.dropping = !last;
            return Look::Drop;
        } else if pieces.open {
            pieces.held = pieces.held.saturating_add(piece.len());
            pieces.open = !last;
        } else if !last && !letting_go {
            // A whole message in one piece with neither flag, as IronRDP takes it.
            if let Err(why) = dynamic_message(piece, false) {
                return Look::Refuse(why);
            }
        }
        // More than was said: IronRDP refuses that itself, except where the piece is marked
        // compressed, which it lets grow.
        if pieces.held > most {
            return Look::Refuse(format!("a channel message past {most} bytes"));
        }
        Look::Pass
    }
}

/// The start of a message of the dynamic channels' carrier: where it opens a dynamic channel
/// message in pieces (DYNVC_DATA_FIRST, [MS-RDPEDYC] 2.2.3.1, or its compressed twin), the whole
/// may be [MAX_DYNAMIC_MESSAGE] at most. IronRDP then holds no more than was said here (a piece
/// past it is refused there). [more_follows]: the carrier's own message is in pieces, and the
/// first must then hold the header, or the length could hide in the next.
fn dynamic_message(start: &[u8], more_follows: bool) -> Result<(), String> {
    const DATA_FIRST: u8 = 0x02;
    const DATA_FIRST_COMPRESSED: u8 = 0x06;
    let size = |bits: u8| match bits & 0b11 {
        0 => Some(1usize),
        1 => Some(2),
        2 => Some(4),
        _ => None,
    };
    let Some(&head) = start.first() else {
        return if more_follows { Err("a channel message in pieces that begins with none".to_owned()) } else { Ok(()) };
    };
    let cmd = head >> 4;
    if cmd != DATA_FIRST && cmd != DATA_FIRST_COMPRESSED {
        return Ok(());
    }
    // A field size IronRDP does not know: it refuses the message.
    let (Some(id), Some(length)) = (size(head), size(head >> 2)) else {
        return Ok(());
    };
    let Some(field) = start.get(1 + id..1 + id + length) else {
        // Cut short: IronRDP refuses a whole one; a first piece must hold it.
        return if more_follows { Err("a channel message in pieces too small to read".to_owned()) } else { Ok(()) };
    };
    let mut said = [0u8; 4];
    said[..length].copy_from_slice(field);
    let said = usize::try_from(u32::from_le_bytes(said)).unwrap_or(usize::MAX);
    if said > MAX_DYNAMIC_MESSAGE {
        return Err(format!("a dynamic channel message of {said} bytes (at most {MAX_DYNAMIC_MESSAGE})"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::borrow::Cow;

    use ironrdp_pdu::ironrdp_core::encode_vec;
    use ironrdp_pdu::mcs::{McsMessage, SendDataIndication};
    use ironrdp_pdu::x224::X224;

    use super::*;

    const CARRIER: u16 = 1004;
    const CLIPBOARD: u16 = 1005;
    const FIRST: u32 = 0x1;
    const LAST: u32 = 0x2;
    const COMPRESSED: u32 = 0x0020_0000;

    /// A frame as a server sends it: channel data on [channel], the header saying [said] bytes.
    fn frame(channel: u16, said: u32, flags: u32, piece: &[u8]) -> Vec<u8> {
        let mut data = Vec::with_capacity(8 + piece.len());
        data.extend_from_slice(&said.to_le_bytes());
        data.extend_from_slice(&flags.to_le_bytes());
        data.extend_from_slice(piece);
        encode_vec(&X224(McsMessage::SendDataIndication(SendDataIndication {
            initiator_id: 1002,
            channel_id: channel,
            user_data: Cow::Borrowed(&data),
        })))
        .unwrap()
    }

    /// DYNVC_DATA_FIRST for channel 1 with a four byte length.
    fn data_first(said: u32, data: &[u8]) -> Vec<u8> {
        let mut pdu = vec![(0x02 << 4) | (0b10 << 2), 1];
        pdu.extend_from_slice(&said.to_le_bytes());
        pdu.extend_from_slice(data);
        pdu
    }

    fn guard() -> ChannelGuard {
        ChannelGuard::new(Some(CARRIER), Some(CLIPBOARD))
    }

    #[test]
    fn what_a_real_server_sends_passes() {
        let mut g = guard();
        // A dynamic channel PDU, whole, with both flags (Windows and xrdp) or neither.
        let pdu = data_first(40_000, &[7; 1590]);
        assert_eq!(g.look(&frame(CARRIER, pdu.len() as u32, FIRST | LAST, &pdu)), Look::Pass);
        assert_eq!(g.look(&frame(CARRIER, pdu.len() as u32, 0, &pdu)), Look::Pass);
        // A graphics message as long as the largest picture, said in its first PDU.
        let pdu = data_first(MAX_DYNAMIC_MESSAGE as u32, &[7; 100]);
        assert_eq!(g.look(&frame(CARRIER, pdu.len() as u32, FIRST | LAST, &pdu)), Look::Pass);
        // A clipboard text of the longest size, in pieces of 1,600 bytes.
        let said = MAX_CLIPBOARD_MESSAGE as u32;
        assert_eq!(g.look(&frame(CLIPBOARD, said, FIRST, &[0; 1600])), Look::Pass);
        let mut sent = 1600;
        while sent + 1600 < MAX_CLIPBOARD_MESSAGE {
            assert_eq!(g.look(&frame(CLIPBOARD, said, 0, &[0; 1600])), Look::Pass);
            sent += 1600;
        }
        assert_eq!(g.look(&frame(CLIPBOARD, said, LAST, &vec![0; MAX_CLIPBOARD_MESSAGE - sent])), Look::Pass);
        assert_eq!(g.take_dropped(), 0);
        // The I/O channel, another channel, and bytes that are no frame: IronRDP's.
        assert_eq!(g.look(&frame(1003, u32::MAX, FIRST, &[0; 16])), Look::Pass);
        assert_eq!(g.look(&frame(1009, u32::MAX, FIRST, &[0; 16])), Look::Pass);
        assert_eq!(g.look(&[3, 0, 0, 4]), Look::Pass);
        assert_eq!(g.look(&[]), Look::Pass);
    }

    #[test]
    fn a_dynamic_channel_message_longer_than_the_largest_picture_ends_the_session() {
        for said in [MAX_DYNAMIC_MESSAGE as u32 + 1, 1 << 30, u32::MAX] {
            let pdu = data_first(said, &[7; 64]);
            for flags in [FIRST | LAST, 0, FIRST] {
                let look = guard().look(&frame(CARRIER, pdu.len() as u32, flags, &pdu));
                assert!(matches!(&look, Look::Refuse(why) if why.contains("dynamic channel message")), "{said} {flags}: {look:?}");
            }
        }
        // The compressed twin of the same PDU, and the shorter length fields.
        let mut pdu = data_first(u32::MAX, &[7; 64]);
        pdu[0] = (0x06 << 4) | (0b10 << 2);
        assert!(matches!(guard().look(&frame(CARRIER, pdu.len() as u32, FIRST | LAST, &pdu)), Look::Refuse(_)));
        let short = [(0x02 << 4) | (0b01 << 2), 1, 0xff, 0xff, 7, 7];
        assert_eq!(guard().look(&frame(CARRIER, short.len() as u32, FIRST | LAST, &short)), Look::Pass, "65,535 bytes is no danger");
    }

    #[test]
    fn the_carriers_own_message_cannot_be_long_or_hide_a_length_in_a_later_piece() {
        // Said to be long: refused at the first piece, before a byte of it is held.
        let look = guard().look(&frame(CARRIER, u32::MAX, FIRST, &[0x30, 1, 2, 3]));
        assert!(matches!(&look, Look::Refuse(why) if why.contains("channel message of 4294967295 bytes")), "{look:?}");
        // In pieces, the first too small to hold the header of what it begins.
        let pdu = data_first(u32::MAX, &[]);
        for cut in 0..pdu.len() {
            let look = guard().look(&frame(CARRIER, 2000, FIRST, &pdu[..cut]));
            assert!(matches!(look, Look::Refuse(_)), "cut at {cut}: {look:?}");
        }
        // Marked compressed, IronRDP lets a message grow past what was said: not past the most.
        let mut g = guard();
        assert_eq!(g.look(&frame(CARRIER, 2000, FIRST | COMPRESSED, &[0x30; 1600])), Look::Pass);
        let mut refused = false;
        for _ in 0..(MAX_CARRIER_MESSAGE / 1600 + 1) {
            match g.look(&frame(CARRIER, 2000, COMPRESSED, &[0x30; 1600])) {
                Look::Pass => {}
                Look::Refuse(_) => {
                    refused = true;
                    break;
                }
                Look::Drop => panic!("the carrier's pieces are never let go by"),
            }
        }
        assert!(refused);
    }

    #[test]
    fn a_sound_message_too_long_is_let_go_by_and_the_session_goes_on() {
        const SOUND: u16 = 1006;
        let mut g = guard().with_sound(Some(SOUND));
        // A wave block of the longest size passes, in pieces of 1,600 bytes as servers send them.
        let said = MAX_SOUND_MESSAGE as u32;
        assert_eq!(g.look(&frame(SOUND, said, FIRST, &[0; 1600])), Look::Pass);
        let mut sent = 1600;
        while sent + 1600 < MAX_SOUND_MESSAGE {
            assert_eq!(g.look(&frame(SOUND, said, 0, &[0; 1600])), Look::Pass);
            sent += 1600;
        }
        assert_eq!(g.look(&frame(SOUND, said, LAST, &vec![0; MAX_SOUND_MESSAGE - sent])), Look::Pass);
        // Four gigabytes said: every piece of it is let go by, nothing is held, nothing ends.
        assert_eq!(g.look(&frame(SOUND, u32::MAX, FIRST, &[0; 1600])), Look::Drop);
        for _ in 0..1000 {
            assert_eq!(g.look(&frame(SOUND, u32::MAX, 0, &[0; 1600])), Look::Drop);
        }
        assert_eq!(g.look(&frame(SOUND, u32::MAX, LAST, &[0; 16])), Look::Drop);
        // The next message is taken again, and the clipboard's count is not the sound's.
        assert_eq!(g.look(&frame(SOUND, 64, FIRST | LAST, &[0; 64])), Look::Pass);
        assert_eq!(g.take_dropped(), 0);
        // More than said is refused, as for any channel.
        assert_eq!(g.look(&frame(SOUND, said, FIRST, &[0; 1600])), Look::Pass);
        let mut held = 1600;
        let mut ended = false;
        while held <= MAX_SOUND_MESSAGE {
            match g.look(&frame(SOUND, said, 0, &[0; 1600])) {
                Look::Pass => held += 1600,
                Look::Refuse(_) => {
                    ended = true;
                    break;
                }
                Look::Drop => panic!("a message within its length is not let go by"),
            }
        }
        assert!(ended, "a message past its ceiling ends the session");
        // A session without a sound channel: such frames are not the guard's (IronRDP's to judge).
        let mut none = guard();
        assert_eq!(none.look(&frame(SOUND, u32::MAX, FIRST, &[0; 16])), Look::Pass);
    }

    #[test]
    fn a_clipboard_message_too_long_is_let_go_by_and_the_session_goes_on() {
        let mut g = guard();
        let said = MAX_CLIPBOARD_MESSAGE as u32 + 1;
        assert_eq!(g.look(&frame(CLIPBOARD, said, FIRST, &[0; 1600])), Look::Drop);
        for _ in 0..5000 {
            assert_eq!(g.look(&frame(CLIPBOARD, said, 0, &[0; 1600])), Look::Drop);
        }
        // Other channels go on meanwhile.
        let pdu = data_first(1000, &[7; 100]);
        assert_eq!(g.look(&frame(CARRIER, pdu.len() as u32, FIRST | LAST, &pdu)), Look::Pass);
        assert_eq!(g.look(&frame(CLIPBOARD, said, LAST, &[0; 10])), Look::Drop);
        assert_eq!(g.take_dropped(), 1);
        assert_eq!(g.take_dropped(), 0);
        // The next message is taken.
        assert_eq!(g.look(&frame(CLIPBOARD, 12, FIRST | LAST, &[0; 12])), Look::Pass);
        // One that never ends is let go by for as long as it comes, and a new first piece
        // starts over.
        assert_eq!(g.look(&frame(CLIPBOARD, u32::MAX, FIRST, &[0; 1600])), Look::Drop);
        assert_eq!(g.look(&frame(CLIPBOARD, u32::MAX, 0, &[0; 1600])), Look::Drop);
        assert_eq!(g.look(&frame(CLIPBOARD, 12, FIRST | LAST, &[0; 12])), Look::Pass);
        assert_eq!(g.take_dropped(), 1);
        // Marked compressed and growing past what it said: the session ends.
        assert_eq!(g.look(&frame(CLIPBOARD, 100, FIRST | COMPRESSED, &[0; 1600])), Look::Pass);
        let mut refused = false;
        for _ in 0..(MAX_CLIPBOARD_MESSAGE / 1600 + 1) {
            if let Look::Refuse(_) = g.look(&frame(CLIPBOARD, 100, COMPRESSED, &[0; 1600])) {
                refused = true;
                break;
            }
        }
        assert!(refused);
    }

    #[test]
    fn a_session_without_a_clipboard_channel_looks_at_the_carrier_only() {
        let mut g = ChannelGuard::new(Some(CARRIER), None);
        assert_eq!(g.look(&frame(CLIPBOARD, u32::MAX, FIRST, &[0; 16])), Look::Pass, "IronRDP refuses a channel nobody joined");
        assert!(matches!(g.look(&frame(CARRIER, u32::MAX, FIRST, &[0x30; 16])), Look::Refuse(_)));
    }
}

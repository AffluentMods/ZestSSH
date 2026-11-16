//! RDP's clipboard channel (`cliprdr`, [MS-RDPECLIP]), text only (4.0).
//!
//! Ours, on ironrdp-svc's channel trait, and not the ironrdp-cliprdr crate: that one also moves
//! files (their lists, their contents, locks on them), which this app does not do and would then
//! have to keep a server from reaching. What is here is the whole of what a server can make the
//! channel do: say whether its clipboard has text, be asked for that text, ask for ours, and be
//! given it.
//!
//! By the rules the app has for a screen's clipboard (lib/features/screens/session/
//! screen_clipboard.dart):
//!
//! - **A session has the channel only where the app asked for it** (the open request's
//!   `rdp_clipboard`). Without it the server has no clipboard channel to send on or ask through.
//! - **While sharing is off** ([Clipboard::share]) nothing is asked of the server, nothing of this
//!   device's is offered, and a request for it is answered "no".
//! - **This device's text** is what the app last gave ([Clipboard::offer]). RDP does not send it:
//!   the server is told there is text and asks when someone pastes, so it is kept until the app
//!   gives another, the server's own clipboard takes over, or sharing stops; then it is wiped.
//! - **The server's text** is asked for when the server says it has some (the app cannot wait for
//!   a paste, as a Windows program would: it hands the text to this device's clipboard), at most
//!   [MAX_FETCHES_A_SECOND] times a second, one request at a time, and [MAX_CLIPBOARD_TEXT] bytes
//!   of it are taken. A message longer than that never reaches this file (rdp_channels.rs lets
//!   it go by unheld).
//!
//! Every length is the server's word, so every read is by `get`: a message cut short is refused
//! (IronRDP then ends the session, "protocol"), never read past its end.

use ironrdp_pdu::PduResult;
use ironrdp_pdu::gcc::ChannelName;
use ironrdp_svc::{ChannelFlags, SvcClientProcessor, SvcMessage, SvcProcessor};
use sha2::{Digest as _, Sha256};
use zeroize::Zeroizing;

use super::rdp_channels::MAX_CLIPBOARD_TEXT;

/// How often a second the server's text is asked for, however often it says it has new text.
pub(crate) const MAX_FETCHES_A_SECOND: u32 = 4;

/// How often a second this device's text is given, however often the server asks: each answer
/// is the whole text again (up to 4 MiB as UTF-16), and a server asking without end would have
/// the device send without end, on a phone over its mobile data. A paste asks once; a clipboard
/// manager on the remote once more.
pub(crate) const MAX_ANSWERS_A_SECOND: u32 = 4;

// Message types ([MS-RDPECLIP] 2.2.1).
const MONITOR_READY: u16 = 0x0001;
const FORMAT_LIST: u16 = 0x0002;
/// Sent, and when the server sends it (its answer to our list) nothing follows from it.
const FORMAT_LIST_RESPONSE: u16 = 0x0003;
const FORMAT_DATA_REQUEST: u16 = 0x0004;
const FORMAT_DATA_RESPONSE: u16 = 0x0005;
const CLIP_CAPS: u16 = 0x0007;
const FILE_CONTENTS_REQUEST: u16 = 0x0008;
const FILE_CONTENTS_RESPONSE: u16 = 0x0009;

// Message flags.
const RESPONSE_OK: u16 = 0x0001;
const RESPONSE_FAIL: u16 = 0x0002;

/// The general capability set's flag for format names of any length (2.2.2.1.1.1). The only
/// one this client sets: no files, no locks.
const USE_LONG_FORMAT_NAMES: u32 = 0x0000_0002;

/// CF_UNICODETEXT: UTF-16, little endian, ended by a zero.
const UNICODE_TEXT: u32 = 13;

/// One clipboard message with its header.
fn message(kind: u16, flags: u16, data: &[u8]) -> SvcMessage {
    let mut bytes = Vec::with_capacity(8 + data.len());
    bytes.extend_from_slice(&kind.to_le_bytes());
    bytes.extend_from_slice(&flags.to_le_bytes());
    bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
    bytes.extend_from_slice(data);
    // The channel's messages go in pieces, which the server is told to expect by this flag
    // ([MS-RDPBCGR] 2.2.6.1.1), as IronRDP's own clipboard channel sets it.
    SvcMessage::from(bytes).with_flags(ChannelFlags::SHOW_PROTOCOL)
}

fn cut_short(what: &'static str) -> ironrdp_pdu::PduError {
    ironrdp_pdu::pdu_other_err!("clipboard", source: std::io::Error::other(format!("{what} is cut short")))
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes(data.get(at..at + 2)?.try_into().ok()?))
}

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
}

/// At most [MAX_CLIPBOARD_TEXT] bytes of [text], cut between characters.
fn cut(mut text: String) -> String {
    if text.len() > MAX_CLIPBOARD_TEXT {
        let mut end = MAX_CLIPBOARD_TEXT;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

/// The server's CF_UNICODETEXT as this app's text: up to the first zero, what is no UTF-16
/// replaced, Windows' line ends (CR LF) as LF.
fn text_from(data: &[u8]) -> String {
    let units: Vec<u16> =
        data.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]])).take_while(|&unit| unit != 0).collect();
    cut(String::from_utf16_lossy(&units).replace("\r\n", "\n"))
}

/// This app's text as CF_UNICODETEXT: a line end that is LF alone becomes CR LF, as Windows
/// programs expect, and a zero ends it.
fn text_for(text: &str) -> Zeroizing<Vec<u8>> {
    let mut bytes = Zeroizing::new(Vec::with_capacity(text.len() * 2 + 2));
    let mut before = '\0';
    for c in text.chars() {
        if c == '\n' && before != '\r' {
            bytes.extend_from_slice(&u16::from(b'\r').to_le_bytes());
        }
        let mut units = [0u16; 2];
        for unit in c.encode_utf16(&mut units) {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        before = c;
    }
    bytes.extend_from_slice(&[0, 0]);
    bytes
}

/// Whether a format list of the server's has plain text. With long names each entry is an id and
/// a name ended by a zero; without, an id and a name of 32 bytes (2.2.3.1.1 and 2.2.3.1.2).
fn has_text(data: &[u8], long_names: bool) -> PduResult<bool> {
    let mut at = 0;
    let mut found = false;
    while at < data.len() {
        let id = u32_at(data, at).ok_or_else(|| cut_short("a format list"))?;
        at += 4;
        found |= id == UNICODE_TEXT;
        if long_names {
            loop {
                let unit = u16_at(data, at).ok_or_else(|| cut_short("a format's name"))?;
                at += 2;
                if unit == 0 {
                    break;
                }
            }
        } else {
            if data.len() < at + 32 {
                return Err(cut_short("a format's name"));
            }
            at += 32;
        }
    }
    Ok(found)
}

/// The clipboard channel of one session.
#[derive(Debug)]
pub struct Clipboard {
    /// Whether the clipboard is shared now (the app's switch for this host on this device).
    sharing: bool,
    /// The server said it is ready, and was told what this client can do and has.
    ready: bool,
    /// What the server said of format names in its capabilities.
    server_long_names: bool,
    /// Format names of any length: both sides said so (settled when the server is ready).
    long_names: bool,
    /// This device's text, for when the server asks.
    ours: Option<Zeroizing<String>>,
    /// The server's clipboard has text (its last format list).
    theirs: bool,
    /// A request for the server's text is out.
    asked: bool,
    /// The answer to that request is no longer wanted (the server's clipboard changed, or
    /// sharing stopped, after it was asked).
    stale: bool,
    /// The server's text was not asked for because of [MAX_FETCHES_A_SECOND]: at the next tick.
    waiting: bool,
    fetches: u32,
    /// How often this device's text was given this second ([MAX_ANSWERS_A_SECOND]).
    answers: u32,
    /// The server's text, until the session hands it to the app.
    taken: Option<String>,
    /// SHA-256 of the last text taken from the server: the app giving the same text back (it
    /// read this device's clipboard, where that text now is) is not offered to the server as
    /// this device's, which would replace what the server has with its plain text.
    taken_hash: Option<[u8; 32]>,
}

ironrdp_pdu::impl_as_any!(Clipboard);

impl Clipboard {
    pub const NAME: ChannelName = ChannelName::from_static(b"cliprdr\0");

    /// The channel, shared from the start or not ([Clipboard::share]).
    pub fn new(sharing: bool) -> Self {
        Self {
            sharing,
            ready: false,
            server_long_names: false,
            long_names: false,
            ours: None,
            theirs: false,
            asked: false,
            stale: false,
            waiting: false,
            fetches: 0,
            answers: 0,
            taken: None,
            taken_hash: None,
        }
    }

    /// The server's text that came since this was last asked.
    pub fn take(&mut self) -> Option<String> {
        self.taken.take()
    }

    /// This client's format list: plain text, or nothing.
    fn our_list(&self) -> SvcMessage {
        if self.ours.is_none() {
            return message(FORMAT_LIST, 0, &[]);
        }
        let mut data = UNICODE_TEXT.to_le_bytes().to_vec();
        // The name: none (a zero with long names, 32 zeros without).
        data.extend(std::iter::repeat_n(0u8, if self.long_names { 2 } else { 32 }));
        message(FORMAT_LIST, 0, &data)
    }

    /// Asks for the server's text where that is wanted and allowed now.
    fn fetch(&mut self) -> Vec<SvcMessage> {
        if !self.sharing || !self.ready || !self.theirs || self.asked {
            return Vec::new();
        }
        if self.fetches >= MAX_FETCHES_A_SECOND {
            self.waiting = true;
            return Vec::new();
        }
        self.fetches += 1;
        self.waiting = false;
        self.asked = true;
        self.stale = false;
        vec![message(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())]
    }

    /// The app's text for the server ("" for none): kept for when the server asks, and the
    /// server is told there is text. Nothing while sharing is off.
    pub fn offer(&mut self, text: String) -> Vec<SvcMessage> {
        let text = Zeroizing::new(cut(text));
        if !self.sharing {
            return Vec::new();
        }
        if !text.is_empty() && self.taken_hash == Some(Sha256::digest(text.as_bytes()).into()) {
            return Vec::new();
        }
        self.ours = (!text.is_empty()).then_some(text);
        if self.ready { vec![self.our_list()] } else { Vec::new() }
    }

    /// Turns sharing on or off. Off: this device's text is wiped and the server told there is
    /// none; what was asked of the server is not taken when it comes. On: the server's text is
    /// asked for where it has some.
    pub fn share(&mut self, on: bool) -> Vec<SvcMessage> {
        if on == self.sharing {
            return Vec::new();
        }
        self.sharing = on;
        if on {
            return self.fetch();
        }
        let had = self.ours.take().is_some();
        self.taken = None;
        self.waiting = false;
        self.stale = self.asked;
        if had && self.ready { vec![self.our_list()] } else { Vec::new() }
    }

    /// A message of the server's on this channel was too long to take and went by unheld
    /// (rdp_channels.rs): if the server's text was asked for, that was its answer, and no other
    /// will come. The text is asked for again when the server's clipboard next changes.
    pub fn lost(&mut self) {
        self.asked = false;
        self.stale = false;
    }

    /// Once a second: the count for [MAX_FETCHES_A_SECOND] starts again, and a request that
    /// waited for it goes.
    pub fn tick(&mut self) -> Vec<SvcMessage> {
        self.fetches = 0;
        self.answers = 0;
        if self.waiting { self.fetch() } else { Vec::new() }
    }

    fn capabilities(&mut self, data: &[u8]) -> PduResult<()> {
        let count = u16_at(data, 0).ok_or_else(|| cut_short("the clipboard's capabilities"))?;
        let mut at = 4;
        for _ in 0..count {
            let kind = u16_at(data, at).ok_or_else(|| cut_short("a capability set"))?;
            let length = usize::from(u16_at(data, at + 2).ok_or_else(|| cut_short("a capability set"))?);
            if length < 4 || data.len() < at + length {
                return Err(cut_short("a capability set"));
            }
            // The general set: its version, then its flags.
            if kind == 1 {
                let flags = u32_at(data, at + 8).filter(|_| length >= 12).ok_or_else(|| cut_short("the general capability set"))?;
                self.server_long_names = flags & USE_LONG_FORMAT_NAMES != 0;
            }
            at += length;
        }
        Ok(())
    }
}

impl SvcProcessor for Clipboard {
    fn channel_name(&self) -> ChannelName {
        Self::NAME
    }

    fn process(&mut self, payload: &[u8]) -> PduResult<Vec<SvcMessage>> {
        let kind = u16_at(payload, 0).ok_or_else(|| cut_short("a clipboard message"))?;
        let flags = u16_at(payload, 2).ok_or_else(|| cut_short("a clipboard message"))?;
        let length = u32_at(payload, 4).ok_or_else(|| cut_short("a clipboard message"))?;
        let length = usize::try_from(length).map_err(|_| cut_short("a clipboard message"))?;
        // What follows the length it gives is padding ([MS-RDPECLIP] 2.2.1).
        let data = payload.get(8..).and_then(|rest| rest.get(..length)).ok_or_else(|| cut_short("a clipboard message"))?;
        match kind {
            CLIP_CAPS => {
                self.capabilities(data)?;
                Ok(Vec::new())
            }
            MONITOR_READY => {
                self.ready = true;
                self.long_names = self.server_long_names;
                // One general capability set, version 2: long format names and nothing else.
                let mut caps = Vec::with_capacity(16);
                caps.extend_from_slice(&1u16.to_le_bytes());
                caps.extend_from_slice(&0u16.to_le_bytes());
                caps.extend_from_slice(&1u16.to_le_bytes());
                caps.extend_from_slice(&12u16.to_le_bytes());
                caps.extend_from_slice(&2u32.to_le_bytes());
                caps.extend_from_slice(&USE_LONG_FORMAT_NAMES.to_le_bytes());
                Ok(vec![message(CLIP_CAPS, 0, &caps), self.our_list()])
            }
            FORMAT_LIST => {
                self.theirs = has_text(data, self.long_names)?;
                // The server's clipboard is the clipboard now: this device's text is no longer
                // offered, and an answer still to come is to the old one.
                self.ours = None;
                self.stale = self.asked;
                self.waiting = false;
                let mut out = vec![message(FORMAT_LIST_RESPONSE, RESPONSE_OK, &[])];
                out.extend(self.fetch());
                Ok(out)
            }
            FORMAT_DATA_REQUEST => {
                let wanted = u32_at(data, 0).ok_or_else(|| cut_short("a request for the clipboard"))?;
                Ok(vec![match &self.ours {
                    Some(text) if self.sharing && wanted == UNICODE_TEXT && self.answers < MAX_ANSWERS_A_SECOND => {
                        self.answers += 1;
                        message(FORMAT_DATA_RESPONSE, RESPONSE_OK, &text_for(text))
                    }
                    _ => message(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, &[]),
                }])
            }
            FORMAT_DATA_RESPONSE => {
                // Not asked for: not taken.
                if !self.asked {
                    return Ok(Vec::new());
                }
                self.asked = false;
                if std::mem::take(&mut self.stale) {
                    return Ok(self.fetch());
                }
                if self.sharing && flags & RESPONSE_OK != 0 && flags & RESPONSE_FAIL == 0 {
                    let text = text_from(data);
                    self.taken_hash = Some(Sha256::digest(text.as_bytes()).into());
                    self.taken = Some(text);
                }
                Ok(Vec::new())
            }
            // Files are not moved: asked for one's contents, the answer is "no", for its stream.
            FILE_CONTENTS_REQUEST => Ok(match data.get(..4) {
                Some(stream) => vec![message(FILE_CONTENTS_RESPONSE, RESPONSE_FAIL, stream)],
                None => Vec::new(),
            }),
            // The answer to our list ([FORMAT_LIST_RESPONSE]), locks, a temporary directory, an
            // answer about a file nobody asked for, and types there are none of: nothing.
            _ => Ok(Vec::new()),
        }
    }
}

impl SvcClientProcessor for Clipboard {}

impl Drop for Clipboard {
    fn drop(&mut self) {
        // The server's text not yet handed on is wiped with this device's (which wipes itself).
        if let Some(text) = self.taken.take() {
            drop(Zeroizing::new(text));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A message as the server sends it.
    fn from_server(kind: u16, flags: u16, data: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&kind.to_le_bytes());
        bytes.extend_from_slice(&flags.to_le_bytes());
        bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        bytes.extend_from_slice(data);
        bytes
    }

    /// What the client sent: each message's type, flags and data.
    fn sent(messages: &[SvcMessage]) -> Vec<(u16, u16, Vec<u8>)> {
        messages
            .iter()
            .map(|m| {
                let bytes = m.encode_unframed_pdu().unwrap();
                let length = u32_at(&bytes, 4).unwrap() as usize;
                assert_eq!(bytes.len(), 8 + length, "the header's length is the data's");
                (u16_at(&bytes, 0).unwrap(), u16_at(&bytes, 2).unwrap(), bytes[8..].to_vec())
            })
            .collect()
    }

    fn utf16(text: &str) -> Vec<u8> {
        text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect()
    }

    /// The server's capabilities (long names or not) and Monitor Ready.
    fn ready(clip: &mut Clipboard, long_names: bool) -> Vec<(u16, u16, Vec<u8>)> {
        let mut caps = vec![1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0];
        caps.extend_from_slice(&(if long_names { USE_LONG_FORMAT_NAMES } else { 0 }).to_le_bytes());
        assert!(clip.process(&from_server(CLIP_CAPS, 0, &caps)).unwrap().is_empty());
        sent(&clip.process(&from_server(MONITOR_READY, 0, &[])).unwrap())
    }

    /// A format list with these ids, each with an empty name.
    fn list(ids: &[u32], long_names: bool) -> Vec<u8> {
        let mut data = Vec::new();
        for id in ids {
            data.extend_from_slice(&id.to_le_bytes());
            data.extend(std::iter::repeat_n(0u8, if long_names { 2 } else { 32 }));
        }
        from_server(FORMAT_LIST, 0, &data)
    }

    #[test]
    fn the_server_is_told_text_only_and_no_files() {
        let mut clip = Clipboard::new(true);
        let hello = ready(&mut clip, true);
        assert_eq!(hello.len(), 2);
        let (kind, _, caps) = &hello[0];
        assert_eq!(*kind, CLIP_CAPS);
        // One general set, version 2; of the flags only long names: no file streams, no locks.
        assert_eq!(caps[..], [1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0, 2, 0, 0, 0]);
        // And an empty clipboard: nothing of this device's before the app gives it.
        assert_eq!(hello[1], (FORMAT_LIST, 0, vec![]));
    }

    #[test]
    fn the_servers_text_is_asked_for_and_taken() {
        for long_names in [true, false] {
            let mut clip = Clipboard::new(true);
            ready(&mut clip, long_names);
            // Text among other formats (a picture's id 2, a registered one with a name).
            let mut data = 2u32.to_le_bytes().to_vec();
            data.extend(std::iter::repeat_n(0u8, if long_names { 2 } else { 32 }));
            data.extend_from_slice(&0xc0a1u32.to_le_bytes());
            if long_names {
                data.extend(utf16("HTML Format"));
            } else {
                data.extend(std::iter::repeat_n(b'h', 32));
            }
            data.extend_from_slice(&UNICODE_TEXT.to_le_bytes());
            data.extend(std::iter::repeat_n(0u8, if long_names { 2 } else { 32 }));
            let out = sent(&clip.process(&from_server(FORMAT_LIST, 0, &data)).unwrap());
            assert_eq!(out[0], (FORMAT_LIST_RESPONSE, RESPONSE_OK, vec![]));
            assert_eq!(out[1], (FORMAT_DATA_REQUEST, 0, UNICODE_TEXT.to_le_bytes().to_vec()));
            assert_eq!(clip.take(), None);
            // Windows' line ends become this app's; what follows the zero is not text.
            let mut answer = utf16("first\r\nsecond \u{1F600} third");
            answer.extend_from_slice(&utf16("after the end"));
            assert!(clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &answer)).unwrap().is_empty());
            assert_eq!(clip.take().as_deref(), Some("first\nsecond \u{1F600} third"));
            assert_eq!(clip.take(), None);
        }
    }

    #[test]
    fn a_clipboard_without_text_is_not_asked_for_and_an_answer_nobody_asked_for_is_not_taken() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        let out = sent(&clip.process(&list(&[2, 8], true)).unwrap());
        assert_eq!(out, vec![(FORMAT_LIST_RESPONSE, RESPONSE_OK, vec![])]);
        assert!(clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("pushed"))).unwrap().is_empty());
        assert_eq!(clip.take(), None);
        // The server's "no" to a request is no text.
        clip.process(&list(&[UNICODE_TEXT], true)).unwrap();
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, &[])).unwrap();
        assert_eq!(clip.take(), None);
    }

    #[test]
    fn this_devices_text_goes_only_when_the_server_asks_and_only_as_text() {
        let mut clip = Clipboard::new(true);
        // Given before the server is ready: kept, said when it is.
        assert!(clip.offer("one\ntwo\r\nthree".to_owned()).is_empty());
        let hello = ready(&mut clip, true);
        assert_eq!(hello[1], (FORMAT_LIST, 0, vec![13, 0, 0, 0, 0, 0]));
        let ask = |clip: &mut Clipboard, id: u32| sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &id.to_le_bytes())).unwrap());
        // LF alone becomes CR LF; CR LF stays.
        assert_eq!(ask(&mut clip, UNICODE_TEXT), vec![(FORMAT_DATA_RESPONSE, RESPONSE_OK, utf16("one\r\ntwo\r\nthree"))]);
        // Any other format (old text, a file list): no.
        for id in [1, 7, 15, 0xc0a1] {
            assert_eq!(ask(&mut clip, id), vec![(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, vec![])]);
        }
        // A new text takes the old one's place and the server is told (short names: 32 zeros).
        let mut short = Clipboard::new(true);
        ready(&mut short, false);
        let told = sent(&short.offer("new".to_owned()));
        assert_eq!(told.len(), 1);
        assert_eq!((told[0].0, told[0].2.len()), (FORMAT_LIST, 36));
        // "" is nothing to offer: an empty list, and a request is answered "no".
        assert_eq!(sent(&clip.offer(String::new())), vec![(FORMAT_LIST, 0, vec![])]);
        assert_eq!(ask(&mut clip, UNICODE_TEXT), vec![(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, vec![])]);
        // The server's own clipboard taking over ends the offer too.
        clip.offer("mine".to_owned());
        clip.process(&list(&[2], true)).unwrap();
        assert_eq!(ask(&mut clip, UNICODE_TEXT), vec![(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, vec![])]);
        // A file's contents asked for: "no", for its stream.
        let out = sent(&clip.process(&from_server(FILE_CONTENTS_REQUEST, 0, &[9, 0, 0, 0, 1, 2, 3, 4])).unwrap());
        assert_eq!(out, vec![(FILE_CONTENTS_RESPONSE, RESPONSE_FAIL, vec![9, 0, 0, 0])]);
    }

    #[test]
    fn while_sharing_is_off_nothing_is_asked_offered_or_given() {
        let mut clip = Clipboard::new(false);
        let hello = ready(&mut clip, true);
        assert_eq!(hello[1], (FORMAT_LIST, 0, vec![]));
        // The server has text: its list is answered (the protocol wants that) and nothing asked.
        assert_eq!(sent(&clip.process(&list(&[UNICODE_TEXT], true)).unwrap()), vec![(FORMAT_LIST_RESPONSE, RESPONSE_OK, vec![])]);
        assert!(clip.tick().is_empty());
        // The app's text is not kept and the server not told.
        assert!(clip.offer("secret".to_owned()).is_empty());
        let asked = sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())).unwrap());
        assert_eq!(asked, vec![(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, vec![])]);
        // Text pushed anyway is not taken.
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("pushed"))).unwrap();
        assert_eq!(clip.take(), None);

        // Turned on: the text the server said it has is asked for now.
        assert_eq!(sent(&clip.share(true)), vec![(FORMAT_DATA_REQUEST, 0, UNICODE_TEXT.to_le_bytes().to_vec())]);
        // Turned off before the answer: the answer is not taken, this device's text is gone and
        // the server is told so.
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("theirs"))).unwrap();
        assert_eq!(clip.take().as_deref(), Some("theirs"));
        clip.offer("mine".to_owned());
        clip.process(&list(&[UNICODE_TEXT], true)).unwrap();
        clip.offer("mine again".to_owned());
        assert_eq!(sent(&clip.share(false)), vec![(FORMAT_LIST, 0, vec![])]);
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("late"))).unwrap();
        assert_eq!(clip.take(), None);
        let asked = sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())).unwrap());
        assert_eq!(asked, vec![(FORMAT_DATA_RESPONSE, RESPONSE_FAIL, vec![])]);
    }

    #[test]
    fn the_servers_text_given_back_by_the_app_is_not_offered_as_this_devices() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        clip.process(&list(&[UNICODE_TEXT, 0xc0a1], true)).unwrap();
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("rich text, plainly"))).unwrap();
        assert_eq!(clip.take().as_deref(), Some("rich text, plainly"));
        // The app wrote it to this device's clipboard, saw the clipboard change, and gives it.
        assert!(clip.offer("rich text, plainly".to_owned()).is_empty());
        // Another text is this device's.
        assert_eq!(sent(&clip.offer("typed here".to_owned())).len(), 1);
    }

    #[test]
    fn a_server_that_says_new_text_all_the_time_is_asked_four_times_a_second_one_at_a_time() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        let mut requests = 0;
        for _ in 0..1000 {
            let out = sent(&clip.process(&list(&[UNICODE_TEXT], true)).unwrap());
            requests += out.iter().filter(|m| m.0 == FORMAT_DATA_REQUEST).count();
            // No second request while one is out.
        }
        assert_eq!(requests, 1);
        // Each answer is to a clipboard that changed since: not taken, asked again, up to four.
        for _ in 0..1000 {
            let out = sent(&clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("x"))).unwrap());
            requests += out.iter().filter(|m| m.0 == FORMAT_DATA_REQUEST).count();
            clip.process(&list(&[UNICODE_TEXT], true)).unwrap();
        }
        assert!(requests <= MAX_FETCHES_A_SECOND as usize, "{requests}");
        assert_eq!(clip.take(), None);
        assert_eq!(requests, MAX_FETCHES_A_SECOND as usize);
        // The next second the request that waited goes, and its answer is taken.
        assert_eq!(sent(&clip.tick()), vec![(FORMAT_DATA_REQUEST, 0, UNICODE_TEXT.to_le_bytes().to_vec())]);
        assert!(clip.tick().is_empty(), "one at a time");
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("the last one"))).unwrap();
        assert_eq!(clip.take().as_deref(), Some("the last one"));
    }

    #[test]
    fn a_server_that_asks_for_this_devices_text_all_the_time_is_given_it_four_times_a_second() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        clip.offer("x".repeat(1000));
        let mut given = 0;
        for _ in 0..10_000 {
            let out = sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())).unwrap());
            assert_eq!(out.len(), 1, "every request has its answer, yes or no");
            given += usize::from(out[0].1 == RESPONSE_OK);
        }
        assert_eq!(given, MAX_ANSWERS_A_SECOND as usize);
        clip.tick();
        let out = sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())).unwrap());
        assert_eq!(out[0].1, RESPONSE_OK, "the next second it is given again");
    }

    #[test]
    fn after_an_answer_too_long_to_take_the_next_text_is_asked_for() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        let request = (FORMAT_DATA_REQUEST, 0, UNICODE_TEXT.to_le_bytes().to_vec());
        assert!(sent(&clip.process(&list(&[UNICODE_TEXT], true)).unwrap()).contains(&request));
        // The answer went by unheld: the channel is told, and does not wait for it for ever.
        clip.lost();
        assert_eq!(clip.take(), None);
        assert!(sent(&clip.process(&list(&[UNICODE_TEXT], true)).unwrap()).contains(&request));
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("short this time"))).unwrap();
        assert_eq!(clip.take().as_deref(), Some("short this time"));
    }

    #[test]
    fn text_longer_than_the_most_is_cut_between_characters() {
        let mut clip = Clipboard::new(true);
        ready(&mut clip, true);
        clip.process(&list(&[UNICODE_TEXT], true)).unwrap();
        // Three bytes of UTF-8 for each character: the cut falls inside one.
        let long: String = std::iter::repeat_n('\u{20AC}', MAX_CLIPBOARD_TEXT / 3 + 10).collect();
        clip.process(&from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16(&long))).unwrap();
        let taken = clip.take().unwrap();
        assert!(taken.len() <= MAX_CLIPBOARD_TEXT && taken.len() > MAX_CLIPBOARD_TEXT - 3);
        assert!(taken.chars().all(|c| c == '\u{20AC}'));
        // And this device's, the same.
        let told = clip.offer("y".repeat(MAX_CLIPBOARD_TEXT + 500));
        assert_eq!(told.len(), 1);
        let out = sent(&clip.process(&from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes())).unwrap());
        assert_eq!(out[0].2.len(), MAX_CLIPBOARD_TEXT * 2 + 2);
    }

    #[test]
    fn a_message_cut_short_is_refused_and_never_read_past_its_end() {
        let whole = [
            from_server(MONITOR_READY, 0, &[]),
            from_server(CLIP_CAPS, 0, &[1, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0, 2, 0, 0, 0]),
            list(&[UNICODE_TEXT, 2], true),
            list(&[UNICODE_TEXT, 2], false),
            from_server(FORMAT_DATA_REQUEST, 0, &UNICODE_TEXT.to_le_bytes()),
            from_server(FORMAT_DATA_RESPONSE, RESPONSE_OK, &utf16("text")),
            from_server(FILE_CONTENTS_REQUEST, 0, &[1, 0, 0, 0]),
            from_server(0x000a, 0, &[1, 0, 0, 0]),
            from_server(0x7777, 0xffff, &[1, 2, 3]),
        ];
        for long_names in [true, false] {
            for message in &whole {
                for end in 0..=message.len() {
                    let mut clip = Clipboard::new(true);
                    ready(&mut clip, long_names);
                    clip.offer("mine".to_owned());
                    clip.process(&list(&[UNICODE_TEXT], long_names)).unwrap();
                    // Whatever it says: an answer or a refusal, no panic.
                    let _ = clip.process(&message[..end]);
                }
            }
        }
        // The header alone promising more than there is.
        let mut clip = Clipboard::new(true);
        assert!(clip.process(&[5, 0, 1, 0, 0xff, 0xff, 0xff, 0xff]).is_err());
        assert!(clip.process(&[]).is_err());
        // A capability set whose length is less than its own header, or runs past the end.
        assert!(clip.process(&from_server(CLIP_CAPS, 0, &[1, 0, 0, 0, 1, 0, 2, 0])).is_err());
        assert!(clip.process(&from_server(CLIP_CAPS, 0, &[9, 0, 0, 0, 1, 0, 12, 0, 2, 0, 0, 0, 2, 0, 0, 0])).is_err());
        // A format's name that never ends.
        let mut endless = UNICODE_TEXT.to_le_bytes().to_vec();
        endless.extend_from_slice(&[b'a', 0, b'b', 0]);
        ready(&mut clip, true);
        assert!(clip.process(&from_server(FORMAT_LIST, 0, &endless)).is_err());
    }
}

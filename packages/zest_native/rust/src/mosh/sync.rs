//! State synchronisation, the client's half (for review with wire.rs).
//!
//! Mosh synchronises two objects, as the paper describes: the client's (what was typed and the
//! terminal's size, [Sender]) to the server, and the server's (the screen, [Receiver]) to the
//! client. Each side numbers the states of its object; an instruction carries the diff from a
//! state the receiver is believed to have (old_num) to a newer one (new_num), and acknowledges the
//! newest state of the other side's object it has (ack_num). Instructions are idempotent: a lost
//! one is replaced by a newer one, a repeated one changes nothing.
//!
//! The client's object here is a log of events numbered from the session's start; a state is how
//! many events it holds, so the diff between two states is the events between them. The events
//! the server has acknowledged are let go.
//!
//! The screen is not modelled here: the app's terminal emulator is the only copy. A diff from the
//! server is terminal output that takes the screen from its old state to its new one, so it is
//! applied only when the old state is the one the terminal shows (or one known to look the same:
//! a state reached by an empty diff). A diff from any other state is dropped; the server, hearing
//! the acknowledgement of the state shown, sends one from it within its retransmission time. That
//! costs a round trip in rare cases (a lost datagram while the screen changes) and never shows a
//! wrong screen.
//!
//! Timing follows the paper: the round trip estimate and retransmission timeout as RFC 6298
//! computes them (bounded to 50 ms to 1 s), a frame interval of half the round trip (20 to 250
//! ms), a delayed acknowledgement (100 ms) and a heartbeat (every 3 s) so the server knows the
//! client is there and the client hears the server is.

use std::collections::VecDeque;

use super::wire::{HostEvent, Instruction, PROTOCOL_VERSION, UserEvent, WireError, decode_host_message, encode_user_message};

/// The state number that says its sender is shutting down.
pub const SHUTDOWN_NUM: u64 = u64::MAX;
/// The shortest and longest retransmission timeout (ms).
pub const MIN_RTO: u64 = 50;
pub const MAX_RTO: u64 = 1000;
/// The shortest and longest interval between two of the client's frames (ms).
pub const MIN_SEND_INTERVAL: u64 = 20;
pub const MAX_SEND_INTERVAL: u64 = 250;
/// How long new input waits to be sent with what follows it (ms): a key goes nearly at once.
pub const SEND_MINDELAY: u64 = 1;
/// How long an acknowledgement waits to ride on data (ms).
pub const ACK_DELAY: u64 = 100;
/// The heartbeat: something is sent at least this often (ms).
pub const ACK_INTERVAL: u64 = 3000;
/// Most states sent and not acknowledged that are kept to diff from.
const MAX_SENT_STATES: usize = 32;
/// Most state numbers kept as looking the same as the one shown.
const MAX_ALIASES: usize = 32;

/// The round trip estimate (RFC 6298).
#[derive(Debug, Clone)]
pub struct Rtt {
    srtt: f64,
    rttvar: f64,
    sampled: bool,
}

impl Default for Rtt {
    fn default() -> Self {
        Self { srtt: 1000.0, rttvar: 500.0, sampled: false }
    }
}

impl Rtt {
    /// A measured round trip of [ms].
    pub fn sample(&mut self, ms: f64) {
        if !self.sampled {
            self.srtt = ms;
            self.rttvar = ms / 2.0;
            self.sampled = true;
        } else {
            self.rttvar = 0.75 * self.rttvar + 0.25 * (self.srtt - ms).abs();
            self.srtt = 0.875 * self.srtt + 0.125 * ms;
        }
    }

    pub fn srtt(&self) -> f64 {
        self.srtt
    }

    pub fn sampled(&self) -> bool {
        self.sampled
    }

    /// The retransmission timeout (ms).
    pub fn rto(&self) -> u64 {
        ((self.srtt + 4.0 * self.rttvar).ceil() as u64).clamp(MIN_RTO, MAX_RTO)
    }

    /// The interval between two frames (ms).
    pub fn send_interval(&self) -> u64 {
        ((self.srtt / 2.0).ceil() as u64).clamp(MIN_SEND_INTERVAL, MAX_SEND_INTERVAL)
    }
}

#[derive(Debug, Clone, Copy)]
struct SentState {
    num: u64,
    /// How many events the state holds.
    end: u64,
    sent_at: u64,
}

/// The client's object and the states of it sent to the server.
#[derive(Debug)]
pub struct Sender {
    /// Front: the newest state the server acknowledged (state 0, empty, at the start).
    sent: VecDeque<SentState>,
    /// Events from number [log_start] on (those before it the server has).
    log_start: u64,
    log: VecDeque<UserEvent>,
    /// When the oldest input not yet sent came.
    pending_since: Option<u64>,
    last_send: Option<u64>,
    /// When an acknowledgement of the server's newest state must go out.
    ack_due: Option<u64>,
    /// The newest of the server's states, acknowledged in every instruction.
    pub ack_num: u64,
    /// When the client began to shut down (its next state is [SHUTDOWN_NUM]).
    shutdown_since: Option<u64>,
    shutdown_acked: bool,
}

impl Default for Sender {
    fn default() -> Self {
        Self {
            sent: VecDeque::from([SentState { num: 0, end: 0, sent_at: 0 }]),
            log_start: 0,
            log: VecDeque::new(),
            pending_since: None,
            last_send: None,
            ack_due: None,
            ack_num: 0,
            shutdown_since: None,
            shutdown_acked: false,
        }
    }
}

impl Sender {
    fn total(&self) -> u64 {
        self.log_start + self.log.len() as u64
    }

    fn back(&self) -> SentState {
        *self.sent.back().expect("the acknowledged state is always kept")
    }

    fn front(&self) -> SentState {
        *self.sent.front().expect("the acknowledged state is always kept")
    }

    /// The states kept (number, events, sent at) and where the log starts and how long it is: what
    /// a test compares before and after.
    #[cfg(test)]
    pub(crate) fn snapshot(&self) -> (Vec<(u64, u64, u64)>, u64, usize) {
        (self.sent.iter().map(|s| (s.num, s.end, s.sent_at)).collect(), self.log_start, self.log.len())
    }

    /// Input for the server: keys typed, or a new size.
    pub fn push(&mut self, event: UserEvent, now: u64) {
        // Keys typed one after another go as one event, as long as none of them was sent yet.
        let unsent = self.total() > self.back().end;
        if let (UserEvent::Keys(more), Some(UserEvent::Keys(last))) = (&event, self.log.back_mut())
            && unsent
            && last.len() + more.len() <= 1024
        {
            last.extend_from_slice(more);
        } else {
            self.log.push_back(event);
        }
        self.pending_since.get_or_insert(now);
    }

    /// The client is closing: its next state says so, and it waits for the server's
    /// acknowledgement of it ([shutdown_acknowledged]).
    pub fn start_shutdown(&mut self, now: u64) {
        self.shutdown_since.get_or_insert(now);
        self.pending_since.get_or_insert(now);
    }

    pub fn shutting_down_since(&self) -> Option<u64> {
        self.shutdown_since
    }

    pub fn shutdown_acknowledged(&self) -> bool {
        self.shutdown_acked
    }

    /// Whether there is a state to send that was never sent.
    fn has_new(&self) -> bool {
        let back = self.back();
        if back.num == SHUTDOWN_NUM {
            return false;
        }
        self.total() > back.end || self.shutdown_since.is_some()
    }

    /// The server acknowledged the client's state [num]: older ones are let go.
    pub fn acknowledged(&mut self, num: u64) {
        let Some(i) = self.sent.iter().position(|s| s.num == num) else { return };
        self.sent.drain(..i);
        if num == SHUTDOWN_NUM {
            self.shutdown_acked = true;
        }
        let keep_from = self.front().end;
        while self.log_start < keep_from && !self.log.is_empty() {
            self.log.pop_front();
            self.log_start += 1;
        }
    }

    /// A new state of the server's came: acknowledge it soon ([ACK_DELAY]), or at once.
    pub fn ack_soon(&mut self, now: u64, at_once: bool) {
        let due = if at_once { now } else { now + ACK_DELAY };
        self.ack_due = Some(self.ack_due.map_or(due, |d| d.min(due)));
    }

    /// When something must next be sent (ms on the session's clock).
    pub fn next_due(&self, rtt: &Rtt) -> u64 {
        let mut due = self.last_send.map_or(0, |t| t + ACK_INTERVAL);
        if self.has_new() {
            let since = self.pending_since.unwrap_or(0) + SEND_MINDELAY;
            let frame = self.last_send.map_or(0, |t| t + rtt.send_interval());
            due = due.min(since.max(frame));
        }
        if self.sent.len() > 1 {
            due = due.min(self.back().sent_at + rtt.rto());
        }
        if let Some(a) = self.ack_due {
            due = due.min(a);
        }
        due
    }

    /// The state the server is assumed to have: the acknowledged one, or a newer one sent
    /// within the retransmission timeout (in flight, and likely to arrive), never [except].
    /// It stops at the first state that timed out, as Mosh does: each state in flight was a
    /// diff from the one before it, so the server has none of those after one it did not get.
    /// (Going on to a younger one made every diff start from a state the server never
    /// reached, and it ignored them all until the person stopped typing for a timeout.)
    fn assumed(&self, now: u64, rto: u64, except: u64) -> SentState {
        let mut base = self.front();
        for s in self.sent.iter().skip(1) {
            if s.num == except {
                continue;
            }
            if now.saturating_sub(s.sent_at) >= rto {
                break;
            }
            base = *s;
        }
        base
    }

    /// The instruction to send now, if one is due ([chaff] goes in it). Data when there is new
    /// input or the newest state was not acknowledged in time; otherwise an acknowledgement and
    /// heartbeat that repeats the newest state (an empty diff, which the server takes as a
    /// duplicate after reading its acknowledgement).
    pub fn tick(&mut self, now: u64, rtt: &Rtt, chaff: Vec<u8>) -> Option<Instruction> {
        if now < self.next_due(rtt) {
            return None;
        }
        let rto = rtt.rto();
        let resend = self.sent.len() > 1 && now >= self.back().sent_at + rto;
        let (old, new) = if self.has_new() {
            let num = if self.shutdown_since.is_some() { SHUTDOWN_NUM } else { self.back().num + 1 };
            let base = self.assumed(now, rto, num);
            if self.sent.len() >= MAX_SENT_STATES {
                // Too many in flight: the oldest unacknowledged one goes (never the base).
                let at = if self.sent.get(1).is_some_and(|s| s.num == base.num) { 2 } else { 1 };
                if at < self.sent.len() {
                    self.sent.remove(at);
                }
            }
            let state = SentState { num, end: self.total(), sent_at: now };
            self.sent.push_back(state);
            self.pending_since = None;
            (base, state)
        } else if resend {
            let back = self.back();
            let base = self.assumed(now, rto, back.num);
            if let Some(b) = self.sent.back_mut() {
                b.sent_at = now;
            }
            (base, back)
        } else {
            let back = self.back();
            (back, back)
        };
        let from = old.end.max(self.log_start);
        let events: Vec<UserEvent> = self
            .log
            .iter()
            .skip((from - self.log_start) as usize)
            .take(new.end.saturating_sub(from) as usize)
            .cloned()
            .collect();
        self.last_send = Some(now);
        self.ack_due = None;
        Some(Instruction {
            protocol_version: Some(PROTOCOL_VERSION),
            old_num: old.num,
            new_num: new.num,
            ack_num: self.ack_num,
            throwaway_num: self.front().num,
            diff: if old.num == new.num { Vec::new() } else { encode_user_message(&events) },
            chaff,
        })
    }
}

/// What an instruction from the server did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Received {
    /// The screen moved to a new state: these events, in order (terminal output first of all).
    Applied { events: Vec<HostEvent>, shutdown: bool },
    /// A state already shown (or older): nothing to do but acknowledge again.
    Duplicate,
    /// A diff from a state the terminal does not show: dropped.
    NoBase,
}

/// The server's object as far as the client follows it: the number of the state the terminal
/// shows, and numbers known to look the same.
#[derive(Debug)]
pub struct Receiver {
    current: u64,
    same: VecDeque<u64>,
}

impl Default for Receiver {
    fn default() -> Self {
        Self { current: 0, same: VecDeque::from([0]) }
    }
}

/// The server speaks another version of the protocol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VersionMismatch(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiveError {
    Version(VersionMismatch),
    Wire(WireError),
}

impl Receiver {
    /// The state the terminal shows (what the client acknowledges).
    pub fn current(&self) -> u64 {
        self.current
    }

    pub fn shutdown(&self) -> bool {
        self.current == SHUTDOWN_NUM
    }

    pub fn receive(&mut self, inst: &Instruction) -> Result<Received, ReceiveError> {
        if let Some(v) = inst.protocol_version
            && v != PROTOCOL_VERSION
        {
            return Err(ReceiveError::Version(VersionMismatch(v)));
        }
        let shutdown = inst.new_num == SHUTDOWN_NUM;
        if self.same.contains(&inst.new_num) || (inst.new_num < self.current && !shutdown) || self.shutdown() {
            return Ok(Received::Duplicate);
        }
        let from_shown = self.same.contains(&inst.old_num);
        if !from_shown && !shutdown {
            return Ok(Received::NoBase);
        }
        // The server's shutdown is taken whatever it is a diff from: the session ends with it,
        // and its diff is shown only when it fits the screen.
        let events = if from_shown { decode_host_message(&inst.diff).map_err(ReceiveError::Wire)? } else { Vec::new() };
        let changes = events.iter().any(|e| matches!(e, HostEvent::Bytes(b) if !b.is_empty()));
        if changes {
            self.same.clear();
        }
        self.current = inst.new_num;
        self.same.push_back(inst.new_num);
        while self.same.len() > MAX_ALIASES {
            self.same.pop_front();
        }
        Ok(Received::Applied { events, shutdown })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mosh::wire::{decode_user_message, encode_host_message};

    fn rtt() -> Rtt {
        let mut r = Rtt::default();
        r.sample(100.0);
        r
    }

    #[test]
    fn the_round_trip_estimate_follows_rfc_6298() {
        let mut r = Rtt::default();
        assert_eq!(r.rto(), MAX_RTO, "1 s before any sample");
        r.sample(100.0);
        assert_eq!(r.srtt(), 100.0);
        assert_eq!(r.rto(), 300);
        assert_eq!(r.send_interval(), 50);
        r.sample(200.0);
        // rttvar = 0.75 * 50 + 0.25 * 100 = 62.5; srtt = 87.5 + 25 = 112.5
        assert_eq!(r.srtt(), 112.5);
        assert_eq!(r.rto(), 363);
        let mut fast = Rtt::default();
        fast.sample(1.0);
        assert_eq!(fast.rto(), MIN_RTO);
        assert_eq!(fast.send_interval(), MIN_SEND_INTERVAL);
    }

    #[test]
    fn input_goes_as_a_diff_from_the_acknowledged_state() {
        let r = rtt();
        let mut s = Sender::default();
        s.push(UserEvent::Resize { width: 80, height: 24 }, 0);
        let i = s.tick(1, &r, vec![]).expect("input is due after the collection delay");
        assert_eq!((i.old_num, i.new_num, i.throwaway_num), (0, 1, 0));
        assert_eq!(decode_user_message(&i.diff).unwrap(), vec![UserEvent::Resize { width: 80, height: 24 }]);
        // Typed while state 1 is in flight: a diff from state 1 (assumed to arrive), after the
        // frame interval.
        s.push(UserEvent::Keys(b"l".to_vec()), 5);
        s.push(UserEvent::Keys(b"s".to_vec()), 6);
        assert!(s.tick(10, &r, vec![]).is_none(), "the frame interval holds it");
        let i = s.tick(51, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (1, 2));
        assert_eq!(decode_user_message(&i.diff).unwrap(), vec![UserEvent::Keys(b"ls".to_vec())]);
        // The server acknowledges 2: everything before it is let go.
        s.acknowledged(2);
        assert_eq!(s.sent.len(), 1);
        assert!(s.log.is_empty());
        s.push(UserEvent::Keys(b"\r".to_vec()), 400);
        assert!(s.tick(400, &r, vec![]).is_none(), "the collection delay");
        let i = s.tick(401, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num, i.throwaway_num), (2, 3, 2));
        assert_eq!(decode_user_message(&i.diff).unwrap(), vec![UserEvent::Keys(b"\r".to_vec())]);
    }

    #[test]
    fn a_state_not_acknowledged_in_time_is_sent_again_from_the_acknowledged_one() {
        let r = rtt();
        let mut s = Sender::default();
        s.push(UserEvent::Keys(b"a".to_vec()), 0);
        s.tick(1, &r, vec![]).unwrap();
        s.push(UserEvent::Keys(b"b".to_vec()), 60);
        let i = s.tick(61, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (1, 2));
        // Nothing heard: at 61 + rto (300) state 2 goes again, from state 0 (1 timed out too).
        assert!(s.tick(300, &r, vec![]).is_none());
        let i = s.tick(361, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (0, 2));
        assert_eq!(decode_user_message(&i.diff).unwrap(), vec![UserEvent::Keys(b"a".to_vec()), UserEvent::Keys(b"b".to_vec())]);
    }

    #[test]
    fn input_after_a_state_timed_out_is_not_based_on_a_later_state_that_needs_it() {
        let r = rtt();
        let mut s = Sender::default();
        s.push(UserEvent::Keys(b"a".to_vec()), 0);
        s.tick(1, &r, vec![]).unwrap();
        // Typed while state 1 is in flight: state 2 is a diff from state 1.
        s.push(UserEvent::Keys(b"b".to_vec()), 250);
        let i = s.tick(251, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (1, 2));
        // State 1 was lost: nothing is heard, and at 301 it has timed out. State 2 is younger
        // than the timeout, but the server cannot apply it without state 1, so it does not
        // have state 2 either. What is typed now goes from the acknowledged state, with all of
        // it, and is not one more diff from a state the server never reached.
        s.push(UserEvent::Keys(b"c".to_vec()), 310);
        let i = s.tick(320, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (0, 3));
        assert_eq!(
            decode_user_message(&i.diff).unwrap(),
            vec![UserEvent::Keys(b"a".to_vec()), UserEvent::Keys(b"b".to_vec()), UserEvent::Keys(b"c".to_vec())]
        );
    }

    #[test]
    fn an_idle_client_acknowledges_and_beats() {
        let r = rtt();
        let mut s = Sender::default();
        // Nothing sent yet: the first heartbeat is due at once (the server learns the address).
        let i = s.tick(0, &r, vec![1, 2]).unwrap();
        assert_eq!((i.old_num, i.new_num, i.diff.len(), i.chaff.len()), (0, 0, 0, 2));
        assert!(s.tick(2999, &r, vec![]).is_none());
        assert!(s.tick(3000, &r, vec![]).is_some());
        // A new state of the server's: acknowledged within ACK_DELAY.
        s.ack_num = 5;
        s.ack_soon(3010, false);
        assert!(s.tick(3109, &r, vec![]).is_none());
        let i = s.tick(3110, &r, vec![]).unwrap();
        assert_eq!(i.ack_num, 5);
        assert_eq!((i.old_num, i.new_num), (0, 0));
    }

    #[test]
    fn shutdown_is_a_state_of_its_own_until_acknowledged() {
        let r = rtt();
        let mut s = Sender::default();
        s.tick(0, &r, vec![]);
        s.push(UserEvent::Keys(b"x".to_vec()), 10);
        s.start_shutdown(10);
        let i = s.tick(51, &r, vec![]).unwrap();
        assert_eq!((i.old_num, i.new_num), (0, SHUTDOWN_NUM));
        assert_eq!(decode_user_message(&i.diff).unwrap(), vec![UserEvent::Keys(b"x".to_vec())]);
        assert!(!s.shutdown_acknowledged());
        // Sent again when not acknowledged.
        let i = s.tick(51 + 300, &r, vec![]).unwrap();
        assert_eq!(i.new_num, SHUTDOWN_NUM);
        s.acknowledged(SHUTDOWN_NUM);
        assert!(s.shutdown_acknowledged());
    }

    #[test]
    fn too_many_states_in_flight_are_bounded() {
        let r = rtt();
        let mut s = Sender::default();
        let mut now = 0;
        for k in 0..200u8 {
            s.push(UserEvent::Keys(vec![k]), now);
            now += 300;
            s.tick(now, &r, vec![]);
        }
        assert!(s.sent.len() <= MAX_SENT_STATES);
        assert_eq!(s.front().num, 0);
    }

    fn host(old: u64, new: u64, text: &[u8]) -> Instruction {
        Instruction {
            protocol_version: Some(2),
            old_num: old,
            new_num: new,
            diff: if text.is_empty() { vec![] } else { encode_host_message(&[HostEvent::Bytes(text.to_vec())]) },
            ..Default::default()
        }
    }

    #[test]
    fn diffs_apply_only_to_the_state_shown() {
        let mut r = Receiver::default();
        assert_eq!(
            r.receive(&host(0, 1, b"a")).unwrap(),
            Received::Applied { events: vec![HostEvent::Bytes(b"a".to_vec())], shutdown: false }
        );
        assert_eq!(r.current(), 1);
        assert_eq!(r.receive(&host(0, 1, b"a")).unwrap(), Received::Duplicate);
        // From a state never seen (2 was lost): dropped, the screen stays at 1.
        assert_eq!(r.receive(&host(2, 3, b"c")).unwrap(), Received::NoBase);
        assert_eq!(r.current(), 1);
        // The server falls back to the acknowledged state.
        assert!(matches!(r.receive(&host(1, 3, b"bc")).unwrap(), Received::Applied { .. }));
        assert_eq!(r.current(), 3);
        // Older than what is shown: a duplicate.
        assert_eq!(r.receive(&host(1, 2, b"b")).unwrap(), Received::Duplicate);
    }

    #[test]
    fn an_empty_diff_reaches_a_state_that_looks_the_same() {
        let mut r = Receiver::default();
        r.receive(&host(0, 1, b"a")).unwrap();
        r.receive(&host(1, 2, b"")).unwrap();
        assert_eq!(r.current(), 2);
        // A diff from 1 still fits the screen: 2 looks the same as 1.
        assert!(matches!(r.receive(&host(1, 3, b"b")).unwrap(), Received::Applied { .. }));
        // Once the screen changed, 1 and 2 no longer fit.
        assert_eq!(r.receive(&host(2, 4, b"x")).unwrap(), Received::NoBase);
    }

    #[test]
    fn the_servers_shutdown_ends_it_whatever_its_base() {
        let mut r = Receiver::default();
        r.receive(&host(0, 1, b"a")).unwrap();
        assert_eq!(
            r.receive(&host(7, SHUTDOWN_NUM, b"zz")).unwrap(),
            Received::Applied { events: vec![], shutdown: true }
        );
        assert!(r.shutdown());
        assert_eq!(r.current(), SHUTDOWN_NUM);
        assert_eq!(r.receive(&host(1, 9, b"late")).unwrap(), Received::Duplicate);
    }

    #[test]
    fn another_protocol_version_is_an_error() {
        let mut r = Receiver::default();
        let mut i = host(0, 1, b"a");
        i.protocol_version = Some(3);
        assert_eq!(r.receive(&i), Err(ReceiveError::Version(VersionMismatch(3))));
        i.diff = vec![0x33];
        i.protocol_version = Some(2);
        assert_eq!(r.receive(&i), Err(ReceiveError::Wire(WireError::WireType(3))));
    }
}

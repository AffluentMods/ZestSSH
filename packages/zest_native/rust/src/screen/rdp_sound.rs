//! The remote's sound in an RDP session (4.0; feature `sound`).
//!
//! RDP's sound channel (MS-RDPEA, `rdpsnd`) through ironrdp-rdpsnd: playback only, plain 16 bit
//! PCM only (no AAC, no Opus, no ADPCM: the server converts). The speaker is this device's
//! default output through cpal, on a thread of its own that owns the stream (a stream may not
//! leave the thread that made it on every system).
//!
//! Bounded on every side a server can reach:
//! - the formats: the client advertises a few, the server's list is read by the crate and only
//!   those kept ([Sink::get_formats]);
//! - a message on the channel: at most `MAX_SOUND_MESSAGE` bytes (rdp_channels.rs, before
//!   IronRDP has it); a longer one is let go by;
//! - what waits to be played: at most [MOST_MS] milliseconds ([SoundQueue]); what comes when it is
//!   full replaces the oldest, so late sound is never queued without end;
//! - what plays: nothing while the app says no ([Shared::set_on]: muted, the app locked,
//!   recording mode, a phone's app in the background); turning it off empties the queue.
//!
//! Nothing of the device goes to the server: no microphone, and the server is told the device
//! plays sound only for a session the app asked to (the request's `rdp_sound`).

use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use ironrdp_rdpsnd::client::RdpsndClientHandler;
use ironrdp_rdpsnd::pdu::{AudioFormat, PitchPdu, VolumePdu, WaveFormat};

/// The most sound that waits to be played.
pub(crate) const MOST_MS: u32 = 500;

/// The rates advertised besides the speaker's own, played after conversion.
const OTHER_RATES: [u32; 2] = [44_100, 22_050];

/// Sound waiting to be played, as f32 samples for the speaker's channels, at the speaker's rate.
/// The server's PCM is converted as it comes in (its channels to the speaker's, its rate to the
/// speaker's by linear interpolation that runs on across blocks). Allocates only when made.
pub struct SoundQueue {
    buf: Vec<f32>,
    start: usize,
    len: usize,
    channels: usize,
    rate: u32,
    /// The interpolation's place between the last input frame and the next (0..1), its step, and
    /// the last input frame (for the speaker's channels).
    phase: f64,
    from_rate: u32,
    last: [f32; 8],
    have_last: bool,
    /// Frames dropped because the queue was full.
    pub(crate) dropped: u64,
}

impl SoundQueue {
    /// For a speaker with `channels` channels at `rate`, holding at most `most_ms`. The numbers
    /// are clamped (8 to 192 kHz, 1 to 8 channels, 10 ms to 2 s).
    pub(crate) fn new(rate: u32, channels: u16, most_ms: u32) -> Self {
        let channels = usize::from(channels.clamp(1, 8));
        let rate = rate.clamp(8_000, 192_000);
        let frames = (u64::from(rate) * u64::from(most_ms.clamp(10, 2_000)) / 1000) as usize;
        SoundQueue {
            buf: vec![0.0; frames.max(1) * channels],
            start: 0,
            len: 0,
            channels,
            rate,
            phase: 0.0,
            from_rate: 0,
            last: [0.0; 8],
            have_last: false,
            dropped: 0,
        }
    }

    #[cfg(test)]
    pub(crate) fn capacity(&self) -> usize {
        self.buf.len()
    }

    #[cfg(test)]
    pub(crate) fn waiting(&self) -> usize {
        self.len
    }

    /// How long what waits takes to play.
    pub(crate) fn waiting_ms(&self) -> u32 {
        ((self.len / self.channels) as u64 * 1000 / u64::from(self.rate)) as u32
    }

    fn push_frame(&mut self, frame: &[f32]) {
        let cap = self.buf.len();
        if self.len == cap {
            // Full: the oldest frame goes.
            self.start = (self.start + self.channels) % cap;
            self.len -= self.channels;
            self.dropped += 1;
        }
        for &v in frame {
            let at = (self.start + self.len) % cap;
            self.buf[at] = v;
            self.len += 1;
        }
    }

    /// A block of 16 bit little-endian PCM of `channels` channels at `rate`. A last part of a
    /// frame is left out; a format with no channels, or a rate outside 8 to 192 kHz, plays
    /// nothing.
    pub(crate) fn put(&mut self, rate: u32, channels: u16, data: &[u8]) {
        if channels == 0 || !(8_000..=192_000).contains(&rate) {
            return;
        }
        if rate != self.from_rate {
            // Another rate: the interpolation starts again.
            self.from_rate = rate;
            self.phase = 0.0;
            self.have_last = false;
        }
        let from = usize::from(channels);
        let to = self.channels;
        // Input frames for each speaker frame.
        let step = f64::from(rate) / f64::from(self.rate);
        let mut frame = [0f32; 8];
        for bytes in data.chunks_exact(from * 2) {
            let sample = |c: usize| f32::from(i16::from_le_bytes([bytes[c * 2], bytes[c * 2 + 1]])) / 32768.0;
            // The server's frame, in the speaker's channels.
            match (from, to) {
                (1, _) => frame[..to].fill(sample(0)),
                (_, 1) => frame[0] = (sample(0) + sample(1)) / 2.0,
                _ => {
                    for (c, v) in frame[..to].iter_mut().enumerate() {
                        *v = if c < 2 { sample(c) } else { 0.0 };
                    }
                }
            }
            if rate == self.rate {
                // The speaker's own rate: as it is, with no frame of delay.
                self.push_frame(&frame[..to]);
                continue;
            }
            if !self.have_last {
                self.last[..to].copy_from_slice(&frame[..to]);
                self.have_last = true;
            }
            // Every speaker frame that falls between the last input frame and this one.
            while self.phase < 1.0 {
                let t = self.phase as f32;
                let mut out = [0f32; 8];
                for c in 0..to {
                    out[c] = self.last[c] + (frame[c] - self.last[c]) * t;
                }
                self.push_frame(&out[..to]);
                self.phase += step;
            }
            self.phase -= 1.0;
            self.last[..to].copy_from_slice(&frame[..to]);
        }
    }

    /// Fills `out` (interleaved for the speaker) with what waits, times `gain`, and silence for
    /// the rest.
    pub(crate) fn take(&mut self, out: &mut [f32], gain: f32) {
        let cap = self.buf.len();
        for v in out.iter_mut() {
            if self.len == 0 {
                *v = 0.0;
                continue;
            }
            *v = self.buf[self.start] * gain;
            self.start = (self.start + 1) % cap;
            self.len -= 1;
        }
    }

    /// Everything waiting goes.
    pub(crate) fn clear(&mut self) {
        self.start = 0;
        self.len = 0;
        self.have_last = false;
        self.phase = 0.0;
    }
}

/// What the channel and the speaker share.
pub struct Shared {
    queue: Mutex<SoundQueue>,
    on: AtomicBool,
    /// The server's volume, as f32 bits (1.0 until it says).
    gain: AtomicU32,
    pub rate: u32,
    pub channels: u16,
}

impl Shared {
    pub fn new(rate: u32, channels: u16, on: bool) -> Arc<Self> {
        Arc::new(Shared {
            queue: Mutex::new(SoundQueue::new(rate, channels, MOST_MS)),
            on: AtomicBool::new(on),
            gain: AtomicU32::new(1.0f32.to_bits()),
            rate,
            channels,
        })
    }

    /// Sound is played from now on, or not (off empties what waits).
    pub fn set_on(&self, on: bool) {
        self.on.store(on, Ordering::SeqCst);
        if !on {
            lock(&self.queue).clear();
        }
    }

    pub(crate) fn is_on(&self) -> bool {
        self.on.load(Ordering::SeqCst)
    }

    /// The speaker's side: what waits, or silence while off.
    pub fn fill(&self, out: &mut [f32]) {
        if !self.is_on() {
            out.fill(0.0);
            return;
        }
        let gain = f32::from_bits(self.gain.load(Ordering::Relaxed));
        lock(&self.queue).take(out, gain);
    }

    pub fn waiting_ms(&self) -> u32 {
        lock(&self.queue).waiting_ms()
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn pcm(rate: u32, channels: u16) -> AudioFormat {
    AudioFormat {
        format: WaveFormat::PCM,
        n_channels: channels,
        n_samples_per_sec: rate,
        n_avg_bytes_per_sec: rate * u32::from(channels) * 2,
        n_block_align: channels * 2,
        bits_per_sample: 16,
        data: None,
    }
}

/// The channel's side: what is advertised, and each block the server sends.
#[derive(Debug)]
pub struct Sink {
    shared: SharedRef,
    formats: Vec<AudioFormat>,
}

/// [Shared] for the handler, which IronRDP asks to be Debug.
pub(crate) struct SharedRef(pub(crate) Arc<Shared>);

impl std::fmt::Debug for SharedRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "sound for {} Hz, {} channels", self.0.rate, self.0.channels)
    }
}

impl Sink {
    /// The formats a speaker at `shared.rate` takes: 16 bit PCM, stereo then mono, at its own
    /// rate first, then 44.1 and 22.05 kHz (converted as they come).
    pub fn new(shared: Arc<Shared>) -> Self {
        let rate = shared.rate;
        let mut rates = vec![rate];
        rates.extend(OTHER_RATES.iter().copied().filter(|&r| r != rate));
        let formats = [2u16, 1].iter().flat_map(|&c| rates.iter().map(move |&r| pcm(r, c))).collect();
        Sink { shared: SharedRef(shared), formats }
    }
}

impl RdpsndClientHandler for Sink {
    fn get_formats(&self) -> &[AudioFormat] {
        &self.formats
    }

    fn wave(&mut self, format: &AudioFormat, _ts: u32, data: Cow<'_, [u8]>) {
        let shared = &self.shared.0;
        // Only what was advertised plays: plain 16 bit PCM.
        if !shared.is_on() || format.format != WaveFormat::PCM || format.bits_per_sample != 16 {
            return;
        }
        lock(&shared.queue).put(format.n_samples_per_sec, format.n_channels, &data);
    }

    fn playback_latency(&self) -> Duration {
        Duration::from_millis(u64::from(self.shared.0.waiting_ms()))
    }

    fn set_volume(&mut self, volume: VolumePdu) {
        // Each side 0 to 0xFFFF ([MS-RDPEA] 2.2.3.7); both as one.
        let side = |v: u16| f32::from(v) / 65535.0;
        let gain = (side(volume.volume_left) + side(volume.volume_right)) / 2.0;
        self.shared.0.gain.store(gain.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    fn set_pitch(&mut self, _pitch: PitchPdu) {}

    fn close(&mut self) {
        lock(&self.shared.0.queue).clear();
    }
}

/// This device's speaker, on a thread of its own that owns the stream; stopped when dropped.
pub(crate) struct Speaker {
    stop: Option<mpsc::Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl Speaker {
    /// Opens the default output: the speaker and what feeds it, sound on from the start where
    /// [on]. Why not, where it cannot (no device, a sample format it does not take).
    pub(crate) fn open(on: bool) -> Result<(Speaker, Arc<Shared>), String> {
        let (ready_tx, ready_rx) = mpsc::channel::<Result<Arc<Shared>, String>>();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread = std::thread::Builder::new()
            .name("zest-sound".into())
            .spawn(move || speaker_thread(on, ready_tx, stop_rx))
            .map_err(|e| format!("no thread for the speaker: {e}"))?;
        match ready_rx.recv_timeout(Duration::from_secs(5)) {
            Ok(Ok(shared)) => Ok((Speaker { stop: Some(stop_tx), thread: Some(thread) }, shared)),
            Ok(Err(why)) => {
                let _ = thread.join();
                Err(why)
            }
            Err(_) => {
                // Not ready in time: it is told to stop, and not waited for.
                drop(stop_tx);
                Err("the speaker did not open in time".to_owned())
            }
        }
    }
}

impl Drop for Speaker {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn speaker_thread(on: bool, ready: mpsc::Sender<Result<Arc<Shared>, String>>, stop: mpsc::Receiver<()>) {
    use cpal::traits::{DeviceTrait as _, HostTrait as _, StreamTrait as _};

    let opened = (|| -> Result<(cpal::Stream, Arc<Shared>), String> {
        let device = cpal::default_host().default_output_device().ok_or("no output device")?;
        let config = device.default_output_config().map_err(|e| format!("the output's format: {e}"))?;
        let shared = Shared::new(config.sample_rate(), config.channels(), on);
        let error = |e: cpal::Error| stream_error(&e);
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => {
                let feed = shared.clone();
                device.build_output_stream(config.into(), move |out: &mut [f32], _| feed.fill(out), error, None)
            }
            cpal::SampleFormat::I16 => {
                let feed = shared.clone();
                let mut scratch: Vec<f32> = Vec::new();
                device.build_output_stream(
                    config.into(),
                    move |out: &mut [i16], _| {
                        scratch.resize(out.len(), 0.0);
                        feed.fill(&mut scratch);
                        for (o, v) in out.iter_mut().zip(&scratch) {
                            *o = (v.clamp(-1.0, 1.0) * 32767.0) as i16;
                        }
                    },
                    error,
                    None,
                )
            }
            other => return Err(format!("the output takes {other:?} samples")),
        }
        .map_err(|e| format!("the output stream: {e}"))?;
        stream.play().map_err(|e| format!("the output stream did not start: {e}"))?;
        Ok((stream, shared))
    })();
    match opened {
        Ok((stream, shared)) => {
            if ready.send(Ok(shared)).is_err() {
                return;
            }
            // Until the session lets go (the sender dropped).
            let _ = stop.recv();
            drop(stream);
        }
        Err(why) => {
            let _ = ready.send(Err(why));
        }
    }
}

fn stream_error(_e: &cpal::Error) {
    // A stream error (the device unplugged): the stream plays silence or nothing; the session
    // goes on. Nothing of it is logged here: the engine has no log of its own.
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pcm16(samples: &[i16]) -> Vec<u8> {
        samples.iter().flat_map(|s| s.to_le_bytes()).collect()
    }

    #[test]
    fn half_a_second_at_most_and_the_oldest_goes() {
        let mut q = SoundQueue::new(48_000, 2, 500);
        assert_eq!(q.capacity(), 48_000);
        let second: Vec<i16> = (0..96_000).map(|i| (i / 2) as i16).collect();
        q.put(48_000, 2, &pcm16(&second));
        assert_eq!(q.waiting(), 48_000);
        assert_eq!(q.waiting_ms(), 500);
        assert_eq!(q.dropped, 24_000);
        let mut out = [0f32; 2];
        q.take(&mut out, 1.0);
        assert_eq!(out[0], f32::from(24_000i16) / 32768.0, "the first kept is the frame half a second in");
    }

    #[test]
    fn silence_when_nothing_waits_and_after_clear() {
        let mut q = SoundQueue::new(48_000, 2, 500);
        q.put(48_000, 2, &pcm16(&[1000, 1000]));
        let mut out = [1f32; 6];
        q.take(&mut out, 1.0);
        assert!(out[0] > 0.0 && out[1] > 0.0);
        assert_eq!(&out[2..], &[0.0; 4]);
        q.put(48_000, 2, &pcm16(&[1000, 1000]));
        q.clear();
        let mut out = [1f32; 2];
        q.take(&mut out, 1.0);
        assert_eq!(out, [0.0, 0.0]);
    }

    #[test]
    fn channels_are_fitted_to_the_speaker() {
        let mut q = SoundQueue::new(48_000, 2, 500);
        q.put(48_000, 1, &pcm16(&[16384]));
        let mut out = [0f32; 2];
        q.take(&mut out, 1.0);
        assert_eq!(out, [0.5, 0.5], "mono is doubled");

        let mut mono = SoundQueue::new(48_000, 1, 500);
        mono.put(48_000, 2, &pcm16(&[16384, 0]));
        let mut out = [0f32; 1];
        mono.take(&mut out, 1.0);
        assert_eq!(out, [0.25], "stereo is averaged for one speaker");

        let mut six = SoundQueue::new(48_000, 6, 500);
        six.put(48_000, 2, &pcm16(&[16384, -16384]));
        let mut out = [9f32; 6];
        six.take(&mut out, 1.0);
        assert_eq!(out, [0.5, -0.5, 0.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn another_rate_is_converted_and_keeps_its_length() {
        let mut q = SoundQueue::new(48_000, 1, 2_000);
        // One second at 22.05 kHz becomes one second at 48 kHz.
        let second: Vec<i16> = (0..22_050).map(|i| ((i % 100) * 100) as i16).collect();
        q.put(22_050, 1, &pcm16(&second));
        let frames = q.waiting();
        assert!((47_990..=48_010).contains(&frames), "{frames}");
        // Block by block the same as all at once (the interpolation runs on).
        let mut blocks = SoundQueue::new(48_000, 1, 2_000);
        for chunk in second.chunks(441) {
            blocks.put(22_050, 1, &pcm16(chunk));
        }
        assert_eq!(blocks.waiting(), frames);
        let (mut a, mut b) = (vec![0f32; frames], vec![0f32; frames]);
        q.take(&mut a, 1.0);
        blocks.take(&mut b, 1.0);
        assert_eq!(a, b);
        // A constant stays that constant.
        let mut flat = SoundQueue::new(48_000, 2, 500);
        flat.put(44_100, 2, &pcm16(&[8192; 2 * 4410]));
        let mut out = vec![0f32; flat.waiting()];
        flat.take(&mut out, 1.0);
        assert!(out.iter().all(|v| (v - 0.25).abs() < 1e-6));
    }

    #[test]
    fn what_cannot_be_played_is_not() {
        let mut q = SoundQueue::new(48_000, 2, 500);
        q.put(48_000, 0, &pcm16(&[1000, 1000]));
        q.put(4_000, 2, &pcm16(&[1000, 1000]));
        q.put(1_000_000, 2, &pcm16(&[1000, 1000]));
        assert_eq!(q.waiting(), 0);
        // A last odd byte and a half frame are left out.
        q.put(48_000, 2, &[1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(q.waiting(), 2);
    }

    #[test]
    fn hostile_sizes_cost_what_is_kept() {
        let q = SoundQueue::new(u32::MAX, u16::MAX, u32::MAX);
        assert_eq!(q.capacity(), 192_000 * 2 * 8);
        assert!(SoundQueue::new(0, 0, 0).capacity() >= 1);
        let mut q = SoundQueue::new(48_000, 2, 500);
        q.put(48_000, 2, &vec![0u8; 16 * 1024 * 1024]);
        assert_eq!(q.waiting(), q.capacity());
        // A rate far below the speaker's makes many frames of each: still bounded.
        q.put(8_000, 8, &vec![0u8; 1024 * 1024]);
        assert_eq!(q.waiting(), q.capacity());
    }

    #[test]
    fn off_plays_nothing_and_empties_what_waits() {
        let shared = Shared::new(48_000, 2, true);
        let mut sink = Sink::new(shared.clone());
        let format = pcm(48_000, 2);
        sink.wave(&format, 0, Cow::Owned(pcm16(&[1000; 480])));
        assert!(shared.waiting_ms() > 0);
        assert!(sink.playback_latency() > Duration::ZERO);
        shared.set_on(false);
        assert_eq!(shared.waiting_ms(), 0);
        sink.wave(&format, 0, Cow::Owned(pcm16(&[1000; 480])));
        assert_eq!(shared.waiting_ms(), 0, "nothing is queued while off");
        let mut out = [1f32; 4];
        shared.fill(&mut out);
        assert_eq!(out, [0.0; 4]);
        shared.set_on(true);
        sink.wave(&format, 0, Cow::Owned(pcm16(&[16384; 2])));
        // The server's volume.
        sink.set_volume(VolumePdu { volume_left: 0x7FFF, volume_right: 0x7FFF });
        let mut out = [0f32; 2];
        shared.fill(&mut out);
        assert!((out[0] - 0.25).abs() < 0.001, "{}", out[0]);
    }

    #[test]
    fn only_plain_pcm_is_advertised_and_played() {
        let shared = Shared::new(48_000, 2, true);
        let mut sink = Sink::new(shared.clone());
        let formats = sink.get_formats();
        assert!(formats.iter().all(|f| f.format == WaveFormat::PCM && f.bits_per_sample == 16));
        assert_eq!(
            formats.iter().map(|f| (f.n_samples_per_sec, f.n_channels)).collect::<Vec<_>>(),
            [(48_000, 2), (44_100, 2), (22_050, 2), (48_000, 1), (44_100, 1), (22_050, 1)]
        );
        let mut adpcm = pcm(48_000, 2);
        adpcm.format = WaveFormat::ADPCM;
        sink.wave(&adpcm, 0, Cow::Owned(vec![7; 4096]));
        let mut eight = pcm(48_000, 2);
        eight.bits_per_sample = 8;
        sink.wave(&eight, 0, Cow::Owned(vec![7; 4096]));
        assert_eq!(shared.waiting_ms(), 0);
        // A speaker at 44.1 kHz does not advertise it twice.
        let other = Sink::new(Shared::new(44_100, 2, true));
        assert_eq!(other.get_formats().len(), 4);
    }
}

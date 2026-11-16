//! RDP's picture codecs for the screen session: the graphics pipeline (MS-RDPEGFX) on the dynamic
//! channel, drawn straight into the session's framebuffer, and a count of what the server sent
//! (which codec, how many pixels, how many bytes), for the app's log and the spike's measurements.
//!
//! The pipeline is IronRDP's own client (ironrdp-egfx: capabilities, surfaces, the bitmap cache,
//! RemoteFX Progressive, RemoteFX, planar, ClearCodec, solid fills, surface to surface copies,
//! frame acknowledgements; AVC420 and AVC444 with an H.264 decoder: on Windows Media Foundation's,
//! [super::h264_mf], elsewhere none yet, so AVC is not offered there). It is
//! registered under a type of ours, [Gfx], so IronRDP's active stage does not composite it into
//! its own picture: the session drains each completed frame (the compositor commits per EndFrame)
//! into [super::framebuffer::Framebuffer] itself, one copy fewer than the picture's way, and a
//! FRAME is only ever a whole server frame.

use crate::screen::LockAnyway as _;
use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};

use ironrdp_dvc::{DvcClientProcessor, DvcMessage, DvcProcessor};
use ironrdp_egfx::client::{BitmapUpdate, GraphicsPipelineClient, GraphicsPipelineHandler};
use ironrdp_egfx::compositor::OutputUpdate;
use ironrdp_egfx::decode::H264Decoder;
use ironrdp_egfx::pdu::{
    CacheToSurfacePdu, CapabilitiesV8Flags, CapabilitiesV10Flags, CapabilitiesV81Flags, CapabilitiesV103Flags,
    CapabilitiesV104Flags, CapabilitiesV107Flags, CapabilitySet, Codec1Type, GfxPdu, SolidFillPdu,
    SurfaceToSurfacePdu, WireToSurface2Pdu,
};
use ironrdp_graphics::zgfx;
use ironrdp_pdu::geometry::ExclusiveRectangle;
use ironrdp_pdu::{PduResult, decode_cursor};
use ironrdp_pdu::rdp::capability_sets::{CODEC_ID_REMOTEFX, CodecId};
use serde::Serialize;

use super::rdp_layout::Limits;

/// How many of one kind came, their pixels and (where the bytes can be told apart) their bytes.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Count {
    pub count: u64,
    pub pixels: u64,
    pub bytes: u64,
}

impl Count {
    fn add(&mut self, pixels: u64, bytes: u64) {
        self.count += 1;
        self.pixels += pixels;
        self.bytes += bytes;
    }
}

/// What the server sent so far in the session.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Stats {
    /// "bitmap", "remotefx" or "gfx": what the client offered.
    pub offered: &'static str,
    /// The graphics pipeline's version and flags the server confirmed (None: no pipeline).
    pub gfx: Option<String>,
    /// Frames the pipeline completed (EndFrame).
    pub gfx_frames: u64,
    /// The pipeline's decoded updates by codec (RemoteFX Progressive tiles come as
    /// "progressive"), pixels decoded.
    pub gfx_codecs: BTreeMap<String, Count>,
    /// WireToSurface2 (RemoteFX Progressive) PDUs and their bytes.
    pub gfx_progressive_pdus: Count,
    pub gfx_solid_fills: Count,
    pub gfx_surface_to_surface: u64,
    pub gfx_cache_to_surface: u64,
    /// Fast-path updates by kind ("bitmap/planar", "bitmap/rle", "bitmap/raw",
    /// "surface/remotefx", "orders", "pointer" and so on), with the update's bytes.
    pub fastpath: BTreeMap<String, Count>,
    /// Bytes of fast-path PDUs and of X.224 PDUs (slow path and every virtual channel, the
    /// graphics pipeline's too).
    pub bytes_fastpath: u64,
    pub bytes_x224: u64,
    /// The H.264 decoder: which, how it started, what it decoded (None: not tried).
    pub h264: Option<H264Stats>,
    /// The most one pipeline message asked to be drawn, in hundredths of the screen (100: the
    /// whole screen once). [MAX_MESSAGE_COVER] times 100 is where a message is refused: what
    /// real servers reach is read here.
    pub gfx_cover_peak: u64,
    /// The graphics channels open now, and how many the server asked for past
    /// [MAX_GFX_CHANNELS] (each refused).
    pub gfx_channels: u64,
    pub gfx_channels_refused: u64,
}

/// What the H.264 decoder did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct H264Stats {
    /// The decoder's name, or empty when it could not start.
    pub decoder: String,
    /// Why it could not start (then AVC is not offered).
    pub error: Option<String>,
    /// "avc444" (planes to the pipeline: AVC420 and AVC444) or "avc420" (RGBA, ours).
    pub mode: String,
    /// The decoder's output: format, picture size and luma stride (after the last stream change).
    pub output: String,
    /// Time to start it (COM, Media Foundation, the MFT and its types), microseconds.
    pub init_us: u64,
    /// Pictures decoded, the H.264 bytes given, the time in the decoder (and, for "avc420",
    /// in our conversion to RGBA), microseconds.
    pub pictures: u64,
    pub bytes: u64,
    pub decode_us: u64,
    pub max_decode_us: u64,
    pub convert_us: u64,
}

/// H.264 in the graphics pipeline (`rdp_h264` in the request).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum H264Mode {
    /// Not offered.
    Off,
    /// AVC420 only; the decoder converts to RGBA itself.
    Avc420,
    /// AVC420 and AVC444; the pipeline converts the decoder's planes. The default.
    Avc444,
}

impl H264Mode {
    pub fn parse(name: Option<&str>) -> Result<Self, String> {
        match name.map(str::to_ascii_lowercase).as_deref() {
            None | Some("") | Some("auto") | Some("on") | Some("avc444") => Ok(Self::Avc444),
            Some("avc420") => Ok(Self::Avc420),
            Some("off") | Some("none") => Ok(Self::Off),
            Some(other) => Err(format!("unknown RDP H.264 mode: {other} (avc444, avc420 or off)")),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Avc420 => "avc420",
            Self::Avc444 => "avc444",
        }
    }
}

/// The platform's H.264 decoder for `mode`, or None (with the reason in `stats`).
fn h264_decoder(mode: H264Mode, stats: &SharedStats) -> Option<Box<dyn H264Decoder>> {
    if mode == H264Mode::Off {
        return None;
    }
    #[cfg(windows)]
    {
        let started = std::time::Instant::now();
        let made = super::h264_mf::MfH264Decoder::new(mode == H264Mode::Avc444, stats.clone());
        let init_us = started.elapsed().as_micros() as u64;
        let mut s = stats.held();
        let h = s.h264.get_or_insert_with(H264Stats::default);
        h.mode = mode.name().to_owned();
        h.init_us = init_us;
        match made {
            Ok(d) => {
                h.decoder = super::h264_mf::NAME.to_owned();
                h.error = None;
                Some(Box::new(d))
            }
            Err(e) => {
                h.error = Some(e);
                None
            }
        }
    }
    #[cfg(not(windows))]
    {
        let mut s = stats.held();
        let h = s.h264.get_or_insert_with(H264Stats::default);
        h.mode = mode.name().to_owned();
        h.error = Some("no H.264 decoder on this platform yet".to_owned());
        None
    }
}

impl Stats {
    pub fn new(offered: &'static str) -> Self {
        Self { offered, ..Self::default() }
    }

    /// The kinds seen so far, to tell when a new one arrives.
    pub fn kinds(&self) -> usize {
        self.gfx_codecs.len() + self.fastpath.len() + usize::from(self.gfx.is_some())
    }
}

pub type SharedStats = Arc<Mutex<Stats>>;

/// The pipeline's events into [Stats] (the pixels themselves go through the compositor), and
/// the capability sets to advertise: IronRDP's own (AVC in every set from 8.1 up) with an H.264
/// decoder, ours with AVC turned off without one.
struct StatsHandler {
    stats: SharedStats,
    avc: bool,
}

/// IronRDP's default capability list (the trait's own method, with nothing overridden).
struct IronRdpDefaults;
impl GraphicsPipelineHandler for IronRdpDefaults {}

fn codec_name(codec: Codec1Type) -> &'static str {
    match codec {
        Codec1Type::Uncompressed => "uncompressed",
        Codec1Type::RemoteFx => "remotefx",
        Codec1Type::ClearCodec => "clearcodec",
        Codec1Type::Planar => "planar",
        Codec1Type::Avc420 => "avc420",
        Codec1Type::Alpha => "alpha",
        Codec1Type::Avc444 => "avc444",
        Codec1Type::Avc444v2 => "avc444v2",
    }
}

/// The capability sets we advertise without an H.264 decoder: every version from 10.7 down to 8,
/// AVC turned off in each (IronRDP's default list has AVC in every set from 8.1 up and so drops
/// them all when there is no decoder, leaving only 8). The server picks the highest it knows, so
/// a Windows server is not held to Windows 8's version of the pipeline (10.3 and later also allow
/// a protocol reset without closing the channel).
fn capabilities_without_avc() -> Vec<CapabilitySet> {
    let v104 = CapabilitiesV104Flags::SMALL_CACHE | CapabilitiesV104Flags::AVC_DISABLED;
    let v10 = CapabilitiesV10Flags::SMALL_CACHE | CapabilitiesV10Flags::AVC_DISABLED;
    vec![
        CapabilitySet::V10_7 { flags: CapabilitiesV107Flags::SMALL_CACHE | CapabilitiesV107Flags::AVC_DISABLED },
        CapabilitySet::V10_6 { flags: v104 },
        CapabilitySet::V10_5 { flags: v104 },
        CapabilitySet::V10_4 { flags: v104 },
        CapabilitySet::V10_3 { flags: CapabilitiesV103Flags::AVC_DISABLED },
        CapabilitySet::V10_2 { flags: v10 },
        CapabilitySet::V10 { flags: v10 },
        CapabilitySet::V8_1 { flags: CapabilitiesV81Flags::SMALL_CACHE },
        CapabilitySet::V8 { flags: CapabilitiesV8Flags::SMALL_CACHE },
    ]
}

impl GraphicsPipelineHandler for StatsHandler {
    fn capabilities(&self) -> Vec<CapabilitySet> {
        if self.avc { IronRdpDefaults.capabilities() } else { capabilities_without_avc() }
    }

    fn on_capabilities_confirmed(&mut self, caps: &CapabilitySet) {
        self.stats.held().gfx = Some(format!("{caps:?}"));
    }

    fn on_bitmap_updated(&mut self, update: &BitmapUpdate) {
        let pixels = u64::from(update.width) * u64::from(update.height);
        let mut s = self.stats.held();
        // Progressive tiles arrive decoded as "uncompressed"; a server sending real uncompressed
        // WireToSurface1 updates alongside progressive ones would be counted with them.
        let name = if update.codec_id == Codec1Type::Uncompressed && s.gfx_progressive_pdus.count > 0 {
            "progressive"
        } else {
            codec_name(update.codec_id)
        };
        s.gfx_codecs.entry(name.to_owned()).or_default().add(pixels, 0);
    }

    fn on_frame_complete(&mut self, _frame_id: u32) {
        self.stats.held().gfx_frames += 1;
    }

    fn on_solid_fill(&mut self, pdu: &SolidFillPdu) {
        let pixels: u64 = pdu
            .rectangles
            .iter()
            .map(|r| u64::from(r.right.saturating_sub(r.left)) * u64::from(r.bottom.saturating_sub(r.top)))
            .sum();
        self.stats.held().gfx_solid_fills.add(pixels, 0);
    }

    fn on_surface_to_surface(&mut self, _pdu: &SurfaceToSurfacePdu) {
        self.stats.held().gfx_surface_to_surface += 1;
    }

    fn on_cache_to_surface(&mut self, _pdu: &CacheToSurfacePdu) {
        self.stats.held().gfx_cache_to_surface += 1;
    }

    fn on_wire_to_surface2(&mut self, pdu: &WireToSurface2Pdu) {
        self.stats.held().gfx_progressive_pdus.add(0, pdu.bitmap_data.len() as u64);
    }
}

/// Ours: the commands of one pipeline message may draw this many times the screen's pixels in
/// all. A fill, a copy or a cached tile is a few bytes that name a rectangle and as many places
/// to draw it as the sender likes: 65,535 copies of a 4K surface is hours of work for one small
/// message, during which the session cannot be stopped (the VNC engine's same hole was found in a security
/// review). A real frame draws the screen about once (twice with AVC444's two streams, more
/// with a scroll's copy on top); sixteen leaves room for a server that sends several frames in
/// one message.
pub(crate) const MAX_MESSAGE_COVER: u64 = 16;

/// Ours: the surfaces a server has made hold this many times the largest picture at most (one
/// surface for each monitor is the usual; IronRDP's own budget for them is 256 MiB, fixed).
pub(crate) const MAX_SURFACE_PICTURES: u64 = 2;

fn area(r: &ExclusiveRectangle) -> u64 {
    u64::from(r.right.saturating_sub(r.left)) * u64::from(r.bottom.saturating_sub(r.top))
}

/// What the server's graphics commands may cost, looked at before IronRDP runs them. The
/// message is decompressed here (ZGFX, with the fork's ceilings), its commands read and their
/// work added up, and only then handed to IronRDP's client, wrapped again as not compressed.
/// The client's own decompressor then only copies, and needs no history of its own.
struct Guard {
    decompressor: zgfx::Decompressor,
    plain: Vec<u8>,
    /// The surfaces there are, by id: their pixels.
    surfaces: HashMap<u16, u64>,
    /// The bitmap cache's slots in use: the pixels of the tile in each.
    cached: HashMap<u16, u64>,
    /// The output's pixels (ResetGraphics); 0 before one came.
    output: u64,
    /// The largest picture this session holds: one display's until it asked for several.
    limits: Arc<Limits>,
}

impl Guard {
    fn new(limits: Arc<Limits>) -> Self {
        Self {
            limits,
            decompressor: zgfx::Decompressor::new(),
            plain: Vec::new(),
            surfaces: HashMap::new(),
            cached: HashMap::new(),
            output: 0,
        }
    }

    /// The message's commands, decompressed, when they are within the limits; else why not.
    /// Returns too how much of the screen they draw, in hundredths.
    fn admit(&mut self, payload: &[u8]) -> Result<(&[u8], u64), String> {
        let (max_pixels, max_side) = (self.limits.pixels() as u64, self.limits.side());
        self.plain.clear();
        self.plain.shrink_to(1 << 20);
        self.decompressor.decompress(payload, &mut self.plain).map_err(|e| format!("graphics: {e}"))?;

        let mut work: u64 = 0;
        // The largest screen the message had: it may make or reset one before it draws.
        let mut screen = self.screen();
        let mut cursor = ironrdp_pdu::ironrdp_core::ReadCursor::new(self.plain.as_slice());
        while !cursor.is_empty() {
            let pdu: GfxPdu = decode_cursor(&mut cursor).map_err(|e| format!("graphics: {e}"))?;
            match &pdu {
                GfxPdu::ResetGraphics(p) => {
                    if !self.limits.takes(p.width, p.height) {
                        return Err(format!("the server's screen of {} by {} is not one this app shows", p.width, p.height));
                    }
                    // A reset lets every surface go, as IronRDP's client does.
                    self.surfaces.clear();
                    self.output = u64::from(p.width) * u64::from(p.height);
                }
                GfxPdu::CreateSurface(p) => {
                    let pixels = u64::from(p.width) * u64::from(p.height);
                    if u32::from(p.width) > max_side || u32::from(p.height) > max_side || pixels > max_pixels {
                        return Err(format!("the server's surface of {} by {} is larger than a screen this app shows", p.width, p.height));
                    }
                    self.surfaces.insert(p.surface_id, pixels);
                    let held: u64 = self.surfaces.values().sum();
                    if held > MAX_SURFACE_PICTURES * max_pixels {
                        return Err(format!("the server's surfaces hold {held} pixels, more than {MAX_SURFACE_PICTURES} of the largest screen"));
                    }
                }
                GfxPdu::DeleteSurface(p) => {
                    self.surfaces.remove(&p.surface_id);
                }
                GfxPdu::SolidFill(p) => work = work.saturating_add(p.rectangles.iter().map(area).sum::<u64>()),
                GfxPdu::SurfaceToSurface(p) => {
                    work = work.saturating_add(area(&p.source_rectangle).saturating_mul(p.destination_points.len() as u64));
                }
                GfxPdu::SurfaceToCache(p) => {
                    let pixels = area(&p.source_rectangle);
                    self.cached.insert(p.cache_slot, pixels);
                    work = work.saturating_add(pixels);
                }
                GfxPdu::CacheToSurface(p) => {
                    let pixels = self.cached.get(&p.cache_slot).copied().unwrap_or(0);
                    work = work.saturating_add(pixels.saturating_mul(p.destination_points.len() as u64));
                }
                GfxPdu::EvictCacheEntry(p) => {
                    self.cached.remove(&p.cache_slot);
                }
                GfxPdu::WireToSurface1(p) => work = work.saturating_add(area(&p.destination_rectangle)),
                // RemoteFX Progressive names no rectangle: its surface, once.
                GfxPdu::WireToSurface2(p) => {
                    work = work.saturating_add(self.surfaces.get(&p.surface_id).copied().unwrap_or(0));
                }
                _ => {}
            }
            screen = screen.max(self.screen());
        }
        let screen = screen.max(1);
        if work > screen.saturating_mul(MAX_MESSAGE_COVER) {
            return Err(format!(
                "one graphics message draws {} times the screen (at most {MAX_MESSAGE_COVER})",
                work / screen
            ));
        }
        Ok((self.plain.as_slice(), work.saturating_mul(100) / screen))
    }

    /// The pixels a message's work is measured against: the output, or the largest surface.
    fn screen(&self) -> u64 {
        self.output.max(self.surfaces.values().copied().max().unwrap_or(0))
    }
}

/// Ours: the graphics channels a server may have open at once. A server opens the channel by
/// its name with a number of its choosing, as often as it likes, and IronRDP makes a pipeline
/// for each and keeps them all (ironrdp-dvc 0.10.0, `try_create_channel`): two decompressors'
/// histories of 2.5 MB, a decoder, and then the surfaces [MAX_SURFACE_PICTURES] allows each of
/// them. A request of fifty bytes for five megabytes, without end. Found by reading, 13 November
/// 2026. A real server has one pipeline; xrdp opens a second with the same number after a resize,
/// which takes the first one's place.
pub(crate) const MAX_GFX_CHANNELS: usize = 2;

/// The places for a session's graphics channels ([MAX_GFX_CHANNELS]): one is held by each
/// pipeline for as long as it lives.
#[derive(Debug, Clone, Default)]
pub struct GfxSlots(Arc<std::sync::atomic::AtomicUsize>);

#[derive(Debug)]
struct GfxSlot(Arc<std::sync::atomic::AtomicUsize>);

impl GfxSlots {
    fn take(&self) -> Option<GfxSlot> {
        use std::sync::atomic::Ordering::SeqCst;
        let mut open = self.0.load(SeqCst);
        while open < MAX_GFX_CHANNELS {
            match self.0.compare_exchange(open, open + 1, SeqCst, SeqCst) {
                Ok(_) => return Some(GfxSlot(self.0.clone())),
                Err(now) => open = now,
            }
        }
        None
    }

    fn open(&self) -> usize {
        self.0.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl Drop for GfxSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}

/// A pipeline that has its place: IronRDP's client behind [Guard].
struct Pipeline {
    client: GraphicsPipelineClient,
    guard: Guard,
    /// Given back when the pipeline goes.
    _slot: Option<GfxSlot>,
}

/// IronRDP's graphics pipeline client under our own type (see the module's comment), behind
/// [Guard]; or, past [MAX_GFX_CHANNELS], nothing: such a channel does not start, IronRDP then
/// removes it and tells the server there is no listener.
pub struct Gfx {
    pipeline: Option<Pipeline>,
    stats: SharedStats,
}

ironrdp_pdu::impl_as_any!(Gfx);

impl Gfx {
    /// The pipeline with the platform's H.264 decoder when `h264` asks for one and it starts
    /// (made anew each time the channel opens: xrdp opens it again after a resize). With no
    /// count of how many there are: the tests' and the fuzz targets'.
    #[cfg(any(test, fuzzing))]
    pub fn new(stats: SharedStats, h264: H264Mode) -> Self {
        Self { pipeline: Some(Self::pipeline(&stats, h264, None, Arc::default())), stats }
    }

    /// As [Gfx::new] with the ceilings of a session that asked for several displays (tests).
    #[cfg(test)]
    fn with_limits(stats: SharedStats, h264: H264Mode, limits: Arc<Limits>) -> Self {
        Self { pipeline: Some(Self::pipeline(&stats, h264, None, limits)), stats }
    }

    /// As [Gfx::new] for a session, where there is a place left in [slots]; else a channel that
    /// will not start, with nothing made for it.
    pub fn in_slot(slots: &GfxSlots, stats: SharedStats, h264: H264Mode, limits: Arc<Limits>) -> Self {
        let slot = slots.take();
        {
            let mut s = stats.held();
            s.gfx_channels = slots.open() as u64;
            if slot.is_none() {
                s.gfx_channels_refused += 1;
            }
        }
        let pipeline = slot.map(|slot| Self::pipeline(&stats, h264, Some(slot), limits));
        Self { pipeline, stats }
    }

    fn pipeline(stats: &SharedStats, h264: H264Mode, slot: Option<GfxSlot>, limits: Arc<Limits>) -> Pipeline {
        let decoder = h264_decoder(h264, stats);
        let handler = StatsHandler { stats: stats.clone(), avc: decoder.is_some() };
        Pipeline { client: GraphicsPipelineClient::new(Box::new(handler), decoder), guard: Guard::new(limits), _slot: slot }
    }

    /// The new output size the server set (ResetGraphics), once.
    pub fn take_reset(&mut self) -> Option<(u16, u16)> {
        self.pipeline.as_mut()?.client.take_output_reset()
    }

    /// The output regions completed frames changed: RGBA rows, packed, at their place.
    pub fn drain(&mut self) -> Vec<OutputUpdate> {
        self.pipeline.as_mut().map(|p| p.client.drain_output()).unwrap_or_default()
    }
}

fn no_place() -> ironrdp_pdu::PduError {
    ironrdp_pdu::pdu_other_err!(
        "graphics pipeline",
        source: std::io::Error::other(format!("more than {MAX_GFX_CHANNELS} graphics channels at once"))
    )
}

impl DvcProcessor for Gfx {
    fn channel_name(&self) -> &str {
        ironrdp_egfx::CHANNEL_NAME
    }

    fn start(&mut self, channel_id: u32) -> PduResult<Vec<DvcMessage>> {
        self.pipeline.as_mut().ok_or_else(no_place)?.client.start(channel_id)
    }

    fn process(&mut self, channel_id: u32, payload: &[u8]) -> PduResult<Vec<DvcMessage>> {
        let Some(Pipeline { client, guard, .. }) = self.pipeline.as_mut() else {
            return Err(no_place());
        };
        let (plain, cover) = match guard.admit(payload) {
            Ok(admitted) => admitted,
            Err(why) => {
                return Err(ironrdp_pdu::pdu_other_err!(
                    "graphics pipeline",
                    source: std::io::Error::other(why)
                ));
            }
        };
        {
            let mut s = self.stats.held();
            s.gfx_cover_peak = s.gfx_cover_peak.max(cover);
        }
        let wrapped = zgfx::wrap_uncompressed(plain);
        client.process(channel_id, &wrapped)
    }

    fn close(&mut self, channel_id: u32) {
        if let Some(p) = self.pipeline.as_mut() {
            p.client.close(channel_id);
        }
    }
}

impl DvcClientProcessor for Gfx {}

/// Counts a fast-path output PDU's updates ([MS-RDPBCGR] 2.2.9.1.2): the update codes, and for
/// bitmap updates and surface commands what is inside (the first fragment of a fragmented one is
/// read as far as it goes; later fragments count bytes only). An encrypted or compressed update
/// is counted as such (neither happens over TLS with no bulk compression asked for).
pub fn count_fastpath(frame: &[u8], stats: &mut Stats) {
    stats.bytes_fastpath += frame.len() as u64;
    let Some(&first) = frame.first() else { return };
    if first & 0x80 != 0 {
        stats.fastpath.entry("encrypted".to_owned()).or_default().add(0, frame.len() as u64);
        return;
    }
    let Some(&b1) = frame.get(1) else { return };
    let (len, mut i) = if b1 & 0x80 != 0 {
        let Some(&b2) = frame.get(2) else { return };
        ((usize::from(b1 & 0x7f) << 8) | usize::from(b2), 3)
    } else {
        (usize::from(b1), 2)
    };
    let end = len.min(frame.len());
    while i + 3 <= end {
        let header = frame[i];
        i += 1;
        let code = header & 0x0f;
        let fragmentation = (header >> 4) & 0x03;
        let compressed = if (header >> 6) & 0x02 != 0 {
            let flags = frame.get(i).copied().unwrap_or(0);
            i += 1;
            flags & 0x20 != 0
        } else {
            false
        };
        let Some(size) = frame.get(i..i + 2).map(|b| usize::from(u16::from_le_bytes([b[0], b[1]]))) else { return };
        i += 2;
        let data = &frame[i.min(end)..(i + size).min(end)];
        i += size;
        // 0 single, 2 first: the update's start is here.
        let starts = fragmentation == 0 || fragmentation == 2;
        if compressed {
            stats.fastpath.entry("compressed".to_owned()).or_default().add(0, size as u64);
            continue;
        }
        match code {
            0x1 if starts => count_bitmaps(data, stats),
            0x4 if starts => count_surface_commands(data, stats),
            0x1 | 0x4 => {
                let name = if code == 1 { "bitmap/continued" } else { "surface/continued" };
                stats.fastpath.entry(name.to_owned()).or_default().add(0, size as u64);
            }
            _ => {
                let name = match code {
                    0x0 => "orders",
                    0x2 => "palette",
                    0x3 => "synchronize",
                    0x5..=0xc => "pointer",
                    _ => "other",
                };
                stats.fastpath.entry(name.to_owned()).or_default().add(0, size as u64);
            }
        }
    }
}

fn u16_at(d: &[u8], at: usize) -> Option<u16> {
    d.get(at..at + 2).map(|b| u16::from_le_bytes([b[0], b[1]]))
}

/// TS_UPDATE_BITMAP_DATA: each rectangle by its compression (32 bits a pixel compressed is
/// planar, fewer bits interleaved RLE).
fn count_bitmaps(d: &[u8], stats: &mut Stats) {
    let Some(n) = u16_at(d, 2) else { return };
    let mut at = 4;
    for _ in 0..n {
        let (Some(w), Some(h), Some(bpp), Some(flags), Some(len)) =
            (u16_at(d, at + 8), u16_at(d, at + 10), u16_at(d, at + 12), u16_at(d, at + 14), u16_at(d, at + 16))
        else {
            return;
        };
        let name = match (flags & 0x0001 != 0, bpp) {
            (false, _) => "bitmap/raw",
            (true, 32) => "bitmap/planar",
            (true, _) => "bitmap/rle",
        };
        stats.fastpath.entry(name.to_owned()).or_default().add(u64::from(w) * u64::from(h), u64::from(len) + 18);
        at += 18 + usize::from(len);
    }
}

/// TS_SURFCMD: Set and Stream Surface Bits by codec, frame markers by count.
fn count_surface_commands(d: &[u8], stats: &mut Stats) {
    let mut at = 0;
    while let Some(kind) = u16_at(d, at) {
        match kind {
            // Frame marker: type, action, frame id.
            0x0004 => {
                stats.fastpath.entry("surface/frame_marker".to_owned()).or_default().add(0, 8);
                at += 8;
            }
            0x0001 | 0x0006 => {
                // The rectangle (8 bytes), then TS_BITMAP_DATA_EX.
                let ex = at + 10;
                let (Some(&flags), Some(&codec), Some(w), Some(h)) =
                    (d.get(ex + 1), d.get(ex + 3), u16_at(d, ex + 4), u16_at(d, ex + 6))
                else {
                    return;
                };
                let Some(len) = d.get(ex + 8..ex + 12).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]])) else {
                    return;
                };
                let header = if flags & 0x01 != 0 { 24 } else { 0 };
                let name = match codec {
                    0 => "surface/uncompressed".to_owned(),
                    c if CodecId::from_u8(c) == Some(CODEC_ID_REMOTEFX) => "surface/remotefx".to_owned(),
                    c => format!("surface/codec{c}"),
                };
                stats.fastpath.entry(name).or_default().add(u64::from(w) * u64::from(h), u64::from(len));
                at = ex + 12 + header + len as usize;
            }
            _ => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_server_has_two_graphics_channels_at_once_however_many_it_asks_for() {
        use ironrdp_svc::SvcProcessor as _;
        let stats: SharedStats = Arc::new(Mutex::new(Stats::new("gfx")));
        let slots = GfxSlots::default();
        let (for_factory, its_stats) = (slots.clone(), stats.clone());
        // The dynamic channels' carrier as the session makes it, and the server's requests as
        // they come on it: DYNVC_CREATE_REQ ([MS-RDPEDYC] 2.2.2.1) and DYNVC_CLOSE (2.2.4).
        let mut carrier = ironrdp_dvc::DrdynvcClient::new().with_dynamic_channel_factory(ironrdp_egfx::CHANNEL_NAME, move || {
            Gfx::in_slot(&for_factory, its_stats.clone(), H264Mode::Off, Arc::default())
        });
        let create = |id: u32| {
            let mut pdu = vec![(0x01 << 4) | 0b10];
            pdu.extend_from_slice(&id.to_le_bytes());
            pdu.extend_from_slice(ironrdp_egfx::CHANNEL_NAME.as_bytes());
            pdu.push(0);
            pdu
        };
        let close = |id: u32| {
            let mut pdu = vec![(0x04 << 4) | 0b10];
            pdu.extend_from_slice(&id.to_le_bytes());
            pdu
        };

        // A thousand requests of some fifty bytes each: two pipelines, not a thousand.
        for id in 1..=1000 {
            carrier.process(&create(id)).unwrap();
        }
        assert_eq!(slots.open(), MAX_GFX_CHANNELS);
        assert!(carrier.get_dvc_by_channel_id::<Gfx>(1).is_some() && carrier.get_dvc_by_channel_id::<Gfx>(2).is_some());
        for refused in [3, 500, 1000] {
            assert!(carrier.get_dvc_by_channel_id::<Gfx>(refused).is_none(), "channel {refused} is not kept");
        }
        {
            let s = stats.held();
            assert_eq!((s.gfx_channels, s.gfx_channels_refused), (2, 998));
        }

        // A channel the server closes gives its place back.
        carrier.process(&close(1)).unwrap();
        assert_eq!(slots.open(), 1);
        carrier.process(&create(7000)).unwrap();
        assert_eq!(slots.open(), 2);
        assert!(carrier.get_dvc_by_channel_id::<Gfx>(7000).is_some());

        // A server with one pipeline that opens it again under the same number (after a resize)
        // has the new one in the old one's place, as often as it likes.
        carrier.process(&close(2)).unwrap();
        for _ in 0..50 {
            carrier.process(&create(7000)).unwrap();
            assert!(carrier.get_dvc_by_channel_id::<Gfx>(7000).is_some());
            assert_eq!(slots.open(), 1);
        }
        assert_eq!(stats.held().gfx_channels_refused, 998);

        // And the carrier going (the session's end) gives every place back.
        drop(carrier);
        assert_eq!(slots.open(), 0);
    }

    /// A fast-path PDU (no encryption) around the given updates (code, fragmentation, data).
    fn pdu(updates: &[(u8, u8, Vec<u8>)]) -> Vec<u8> {
        let mut body = Vec::new();
        for (code, frag, data) in updates {
            body.push(code | (frag << 4));
            body.extend_from_slice(&(data.len() as u16).to_le_bytes());
            body.extend_from_slice(data);
        }
        let len = body.len() + 3;
        let mut out = vec![0x00, 0x80 | (len >> 8) as u8, len as u8];
        out.extend(body);
        out
    }

    fn le(v: u16) -> [u8; 2] {
        v.to_le_bytes()
    }

    #[test]
    fn bitmap_updates_are_told_apart_by_compression() {
        // Two rectangles: 64 x 64 at 32 bits compressed (planar, 10 bytes), 16 x 8 at 16 bits
        // compressed (RLE, 4 bytes); then an uncompressed one in a second update.
        let rect = |w: u16, h: u16, bpp: u16, flags: u16, len: u16| {
            let mut r = Vec::new();
            for v in [0, 0, w - 1, h - 1, w, h, bpp, flags, len] {
                r.extend_from_slice(&le(v));
            }
            r.extend(std::iter::repeat_n(0xaa, len as usize));
            r
        };
        let mut a = Vec::new();
        a.extend_from_slice(&le(1));
        a.extend_from_slice(&le(2));
        a.extend(rect(64, 64, 32, 0x0401, 10));
        a.extend(rect(16, 8, 16, 0x0401, 4));
        let mut b = Vec::new();
        b.extend_from_slice(&le(1));
        b.extend_from_slice(&le(1));
        b.extend(rect(2, 2, 32, 0, 16));
        let mut s = Stats::new("bitmap");
        let frame = pdu(&[(1, 0, a), (1, 0, b), (0x8, 0, vec![0; 4])]);
        count_fastpath(&frame, &mut s);
        assert_eq!(s.fastpath["bitmap/planar"], Count { count: 1, pixels: 4096, bytes: 28 });
        assert_eq!(s.fastpath["bitmap/rle"], Count { count: 1, pixels: 128, bytes: 22 });
        assert_eq!(s.fastpath["bitmap/raw"], Count { count: 1, pixels: 4, bytes: 34 });
        assert_eq!(s.fastpath["pointer"].count, 1);
        assert_eq!(s.bytes_fastpath, frame.len() as u64);
    }

    #[test]
    fn surface_commands_are_counted_by_codec_and_fragments_by_bytes() {
        // A frame marker, then Stream Surface Bits with RemoteFX, 128 x 64, 6 bytes of data.
        let mut cmds = Vec::new();
        cmds.extend_from_slice(&le(0x0004));
        cmds.extend_from_slice(&le(0));
        cmds.extend_from_slice(&7u32.to_le_bytes());
        cmds.extend_from_slice(&le(0x0006));
        for v in [0u16, 0, 128, 64] {
            cmds.extend_from_slice(&le(v));
        }
        // IronRDP's client gives RemoteFX the codec id 3.
        cmds.extend_from_slice(&[32, 0, 0, 3]);
        cmds.extend_from_slice(&le(128));
        cmds.extend_from_slice(&le(64));
        cmds.extend_from_slice(&6u32.to_le_bytes());
        cmds.extend_from_slice(&[1, 2, 3, 4, 5, 6]);
        let mut s = Stats::new("remotefx");
        // The first fragment carries the start; the last one only bytes.
        count_fastpath(&pdu(&[(4, 2, cmds), (4, 1, vec![9; 100])]), &mut s);
        assert_eq!(s.fastpath["surface/remotefx"], Count { count: 1, pixels: 8192, bytes: 6 });
        assert_eq!(s.fastpath["surface/frame_marker"].count, 1);
        assert_eq!(s.fastpath["surface/continued"], Count { count: 1, pixels: 0, bytes: 100 });
        // A truncated PDU stops without a panic.
        count_fastpath(&[0x00, 0x05, 0x04], &mut s);
        count_fastpath(&[], &mut s);
    }

    /// Bits written first bit first, as ZGFX reads them.
    #[derive(Default)]
    struct BitsOut {
        bytes: Vec<u8>,
        used: usize,
    }

    impl BitsOut {
        fn put(&mut self, value: u32, count: usize) {
            for i in (0..count).rev() {
                if self.used % 8 == 0 {
                    self.bytes.push(0);
                }
                if value >> i & 1 == 1 {
                    *self.bytes.last_mut().unwrap() |= 0x80 >> (self.used % 8);
                }
                self.used += 1;
            }
        }

        /// The segment: the RDP 8 type with "compressed", the bits, and how many of the last
        /// byte's are not used.
        fn segment(mut self) -> Vec<u8> {
            let unused = (8 - self.used % 8) % 8;
            let mut out = vec![0x24];
            out.append(&mut self.bytes);
            out.push(unused as u8);
            out
        }
    }

    /// A compressed ZGFX segment of 9 bytes that says: the byte 0x41, then copy it [copies]
    /// times more ([copies] a power of two, as 2 to the [power]).
    fn expanding_segment(power: u32) -> Vec<u8> {
        let mut bits = BitsOut::default();
        bits.put(0, 1); // a literal
        bits.put(0x41, 8);
        bits.put(0b10001, 5); // a match, its distance in 5 bits
        bits.put(1, 5); // one byte back
        let ones = power as usize - 1;
        for _ in 0..ones {
            bits.put(1, 1);
        }
        bits.put(0, 1);
        bits.put(0, power as usize); // 2 to the power, and nothing more
        bits.segment()
    }

    // A few bytes from a server made the decompressor write 64 MiB a segment and 256 MiB a
    // message (IronRDP's own ceilings: fuzzing, 8 November 2026, and a review before 4.0).
    // The fork's are 1 MiB and the largest picture the app holds (vendor/ironrdp-graphics).
    #[test]
    fn a_segment_that_expands_past_a_mebibyte_is_refused_before_it_is_written() {
        let mut d = ironrdp_graphics::zgfx::Decompressor::new();
        let mut out = Vec::new();
        // Half a mebibyte and the byte before it: taken.
        let mut single = vec![0xe0];
        single.extend(expanding_segment(19));
        assert_eq!(d.decompress(&single, &mut out).unwrap(), (1 << 19) + 1);
        assert!(out.iter().all(|b| *b == 0x41));
        // A mebibyte and the byte before it: refused, and nothing more was written.
        let before = out.len();
        let mut single = vec![0xe0];
        single.extend(expanding_segment(20));
        assert!(single.len() < 16, "{} bytes", single.len());
        let e = d.decompress(&single, &mut out).unwrap_err();
        assert!(e.to_string().contains("per-segment ceiling"), "{e}");
        assert!(out.len() <= before + 1, "{} written", out.len() - before);
    }

    #[test]
    fn a_message_that_expands_past_the_largest_picture_is_refused() {
        use crate::screen::rdp_session::MAX_PIXELS;
        let budget = MAX_PIXELS * 4 + (1 << 20);
        // 70 segments of half a mebibyte each: 35 MiB from under a kilobyte.
        let part = expanding_segment(19);
        let count = 70u16;
        let mut message = vec![0xe1];
        message.extend_from_slice(&count.to_le_bytes());
        message.extend_from_slice(&(u32::from(count) * ((1 << 19) + 1)).to_le_bytes());
        for _ in 0..count {
            message.extend_from_slice(&(part.len() as u32).to_le_bytes());
            message.extend_from_slice(&part);
        }
        assert!(message.len() < 1024, "{} bytes", message.len());
        let mut out = Vec::new();
        let e = ironrdp_graphics::zgfx::Decompressor::new().decompress(&message, &mut out).unwrap_err();
        assert!(e.to_string().contains("budget"), "{e}");
        assert!(out.len() <= budget + (1 << 20), "{} written", out.len());

        // And the pipeline's channel ends on it, as on any message it cannot read.
        let stats: SharedStats = Arc::new(Mutex::new(Stats::new("gfx")));
        let mut g = Gfx::new(stats, H264Mode::Off);
        assert!(g.process(7, &message).is_err());
    }

    // The largest picture the app holds still comes through with no codec at all.
    #[test]
    fn the_largest_picture_sent_plain_fits_the_ceiling() {
        use crate::screen::rdp_session::MAX_PIXELS;
        let total = MAX_PIXELS * 4;
        let piece = vec![0x5a; 65_535];
        let count = total.div_ceil(piece.len());
        let mut message = vec![0xe1];
        message.extend_from_slice(&(count as u16).to_le_bytes());
        message.extend_from_slice(&(total as u32).to_le_bytes());
        let mut left = total;
        for _ in 0..count {
            let n = left.min(piece.len());
            message.extend_from_slice(&(n as u32 + 1).to_le_bytes());
            message.push(0x04); // RDP 8, not compressed
            message.extend_from_slice(&piece[..n]);
            left -= n;
        }
        let mut out = Vec::new();
        assert_eq!(ironrdp_graphics::zgfx::Decompressor::new().decompress(&message, &mut out).unwrap(), total);
    }

    /// Several pipeline PDUs in one message (not compressed), as [Gfx::process] answers them.
    fn message(g: &mut Gfx, pdus: &[ironrdp_egfx::pdu::GfxPdu]) -> PduResult<Vec<DvcMessage>> {
        let mut bytes = Vec::new();
        for pdu in pdus {
            bytes.extend(ironrdp_pdu::encode_vec(pdu).unwrap());
        }
        g.process(7, &ironrdp_graphics::zgfx::wrap_uncompressed(&bytes))
    }

    fn pipeline() -> (Gfx, SharedStats) {
        let stats: SharedStats = Arc::new(Mutex::new(Stats::new("gfx")));
        (Gfx::new(stats.clone(), H264Mode::Off), stats)
    }

    fn screen_of(g: &mut Gfx, width: u16, height: u16) {
        use ironrdp_egfx::pdu::*;
        message(
            g,
            &[
                GfxPdu::ResetGraphics(ResetGraphicsPdu { width: width.into(), height: height.into(), monitors: Vec::new() }),
                GfxPdu::CreateSurface(CreateSurfacePdu { surface_id: 1, width, height, pixel_format: PixelFormat::XRgb }),
            ],
        )
        .unwrap();
    }

    fn rect(left: u16, top: u16, right: u16, bottom: u16) -> ExclusiveRectangle {
        ExclusiveRectangle { left, top, right, bottom }
    }

    // A few bytes name a rectangle and as many places to copy it to as the sender likes: one
    // message was hours of work, and nothing stops a session in the middle of a message (VNC's
    // same hole was found in a security review).
    #[test]
    fn a_message_that_copies_the_screen_again_and_again_is_refused_before_any_of_it_runs() {
        use ironrdp_egfx::pdu::*;
        let (mut g, stats) = pipeline();
        screen_of(&mut g, 640, 480);
        let copy = |places: usize| {
            GfxPdu::SurfaceToSurface(SurfaceToSurfacePdu {
                source_surface_id: 1,
                destination_surface_id: 1,
                source_rectangle: rect(0, 0, 640, 480),
                destination_points: vec![Point { x: 0, y: 0 }; places],
            })
        };
        // Sixteen times the screen is the most; what real servers reach is kept for the log.
        message(&mut g, &[copy(MAX_MESSAGE_COVER as usize)]).unwrap();
        assert_eq!(stats.held().gfx_cover_peak, MAX_MESSAGE_COVER * 100);
        let e = message(&mut g, &[copy(MAX_MESSAGE_COVER as usize + 1)]).err().unwrap();
        assert!(format!("{e:?}").contains("times the screen"), "{e:?}");
        let e = message(&mut g, &[copy(60_000)]).err().unwrap();
        assert!(format!("{e:?}").contains("times the screen"), "{e:?}");
    }

    #[test]
    fn fills_cached_tiles_and_pictures_count_towards_a_messages_work() {
        use ironrdp_egfx::pdu::*;
        let (mut g, _) = pipeline();
        screen_of(&mut g, 640, 480);
        let fill = |count: usize| {
            GfxPdu::SolidFill(SolidFillPdu {
                surface_id: 1,
                fill_pixel: Color { b: 1, g: 2, r: 3, xa: 0 },
                rectangles: vec![rect(0, 0, 640, 480); count],
            })
        };
        message(&mut g, &[fill(16)]).unwrap();
        assert!(message(&mut g, &[fill(17)]).is_err());
        // A tile put in the cache, then drawn in many places.
        let to_cache = GfxPdu::SurfaceToCache(SurfaceToCachePdu {
            surface_id: 1,
            cache_key: 9,
            cache_slot: 3,
            source_rectangle: rect(0, 0, 640, 480),
        });
        let from_cache = |places: usize| {
            GfxPdu::CacheToSurface(CacheToSurfacePdu {
                cache_slot: 3,
                surface_id: 1,
                destination_points: vec![Point { x: 0, y: 0 }; places],
            })
        };
        message(&mut g, &[to_cache.clone(), from_cache(15)]).unwrap();
        assert!(message(&mut g, &[from_cache(17)]).is_err());
        // Work adds up over the kinds of one message, and starts again with the next.
        message(&mut g, &[fill(8), from_cache(8)]).unwrap();
        assert!(message(&mut g, &[fill(8), from_cache(9)]).is_err());
        message(&mut g, &[fill(16)]).unwrap();
    }

    #[test]
    fn a_surface_or_an_output_larger_than_the_largest_picture_is_refused() {
        use ironrdp_egfx::pdu::*;
        let surface = |id: u16, width: u16, height: u16| {
            GfxPdu::CreateSurface(CreateSurfacePdu { surface_id: id, width, height, pixel_format: PixelFormat::XRgb })
        };
        let (mut g, _) = pipeline();
        screen_of(&mut g, 3840, 2160);
        assert!(message(&mut g, &[surface(2, 8192, 8192)]).is_err());
        let (mut g, _) = pipeline();
        screen_of(&mut g, 3840, 2160);
        // Two of the largest are held; a third is one too many.
        message(&mut g, &[surface(2, 3840, 2160)]).unwrap();
        assert!(message(&mut g, &[surface(3, 3840, 2160)]).is_err());
        // One let go makes room again.
        let (mut g, _) = pipeline();
        screen_of(&mut g, 3840, 2160);
        message(&mut g, &[surface(2, 3840, 2160), GfxPdu::DeleteSurface(DeleteSurfacePdu { surface_id: 2 }), surface(3, 3840, 2160)])
            .unwrap();
        let (mut g, _) = pipeline();
        let reset = |width: u32, height: u32| GfxPdu::ResetGraphics(ResetGraphicsPdu { width, height, monitors: Vec::new() });
        assert!(message(&mut g, &[reset(32_766, 32_766)]).is_err());
        assert!(message(&mut g, &[reset(8192, 8192)]).is_err());
        message(&mut g, &[reset(3840, 2160)]).unwrap();
    }

    #[test]
    fn a_session_that_asked_for_several_displays_takes_their_desktop_and_no_more() {
        use crate::screen::rdp_layout::{DisplaySpec, Layout};
        use ironrdp_egfx::pdu::*;
        let reset = |width: u32, height: u32| GfxPdu::ResetGraphics(ResetGraphicsPdu { width, height, monitors: Vec::new() });
        let surface = |id: u16, width: u16, height: u16| {
            GfxPdu::CreateSurface(CreateSurfacePdu { surface_id: id, width, height, pixel_format: PixelFormat::XRgb })
        };
        // One display asked for: a desktop of two is not this session's.
        let (mut g, _) = pipeline();
        assert!(message(&mut g, &[reset(7680, 2160)]).is_err());

        // Two displays of the largest size side by side.
        let display = |x: i32| DisplaySpec { x, y: 0, width: 3840, height: 2160, scale: 0, primary: false };
        let limits = Arc::new(Limits::for_layout(&Layout::of(&[display(0), display(3840)]).unwrap()));
        let two = || {
            let stats: SharedStats = Arc::new(Mutex::new(Stats::new("gfx")));
            Gfx::with_limits(stats, H264Mode::Off, limits.clone())
        };
        let mut g = two();
        message(&mut g, &[reset(7680, 2160)]).unwrap();
        // A surface for each display, or one for the whole desktop.
        message(&mut g, &[surface(1, 3840, 2160), surface(2, 3840, 2160), surface(3, 7680, 2160)]).unwrap();
        // The surfaces hold twice the desktop at most: one more display is one too many.
        assert!(message(&mut g, &[surface(4, 3840, 2160)]).is_err());
        // Nothing past what was asked for: a third display's width, or a taller desktop.
        let mut g = two();
        assert!(message(&mut g, &[reset(11_520, 2160)]).is_err());
        let mut g = two();
        assert!(message(&mut g, &[reset(7680, 4320)]).is_err());
        let mut g = two();
        assert!(message(&mut g, &[surface(1, 7682, 2160)]).is_err());

        // The server took a smaller layout since: the ceilings came down with it, for the
        // pipeline that is open too.
        let mut g = two();
        limits.settle(&Layout::single(1920, 1080, 0));
        assert!(message(&mut g, &[reset(7680, 2160)]).is_err());
    }

    /// One graphics pipeline PDU as the server sends it (ZGFX segment, not compressed).
    fn send(g: &mut Gfx, pdu: ironrdp_egfx::pdu::GfxPdu) -> Vec<DvcMessage> {
        let bytes = ironrdp_pdu::encode_vec(&pdu).unwrap();
        g.process(7, &ironrdp_graphics::zgfx::wrap_uncompressed(&bytes)).unwrap()
    }

    #[test]
    fn the_pipeline_draws_whole_frames_and_counts_them() {
        use ironrdp_egfx::pdu::*;
        let stats: SharedStats = Arc::new(Mutex::new(Stats::new("gfx")));
        let mut g = Gfx::new(stats.clone(), H264Mode::Off);
        assert_eq!(g.channel_name(), "Microsoft::Windows::RDS::Graphics");
        // Without an H.264 decoder: the sets with AVC turned off, all kept by IronRDP's filter.
        assert_eq!(g.start(7).unwrap().len(), 1);
        assert_eq!(capabilities_without_avc().len(), 9);
        assert!(capabilities_without_avc().iter().all(|c| !matches!(c, CapabilitySet::V10_1)));
        send(&mut g, GfxPdu::CapabilitiesConfirm(CapabilitiesConfirmPdu::from_typed(&CapabilitySet::V10_1)));
        send(&mut g, GfxPdu::ResetGraphics(ResetGraphicsPdu { width: 64, height: 32, monitors: vec![] }));
        assert_eq!(g.take_reset(), Some((64, 32)));
        assert_eq!(g.take_reset(), None);
        send(
            &mut g,
            GfxPdu::CreateSurface(CreateSurfacePdu { surface_id: 1, width: 64, height: 32, pixel_format: PixelFormat::XRgb }),
        );
        send(&mut g, GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu { surface_id: 1, output_origin_x: 0, output_origin_y: 0 }));
        let ts = Timestamp { milliseconds: 0, seconds: 0, minutes: 0, hours: 0 };
        send(&mut g, GfxPdu::StartFrame(StartFramePdu { timestamp: ts, frame_id: 1 }));
        let rect = ironrdp_pdu::geometry::ExclusiveRectangle { left: 8, top: 4, right: 24, bottom: 12 };
        send(
            &mut g,
            GfxPdu::SolidFill(SolidFillPdu {
                surface_id: 1,
                fill_pixel: Color { b: 0x30, g: 0x20, r: 0x10, xa: 0 },
                rectangles: vec![rect.clone()],
            }),
        );
        // Nothing before the frame ends: the session never shows half a frame.
        assert!(g.drain().is_empty());
        let acks = send(&mut g, GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }));
        assert_eq!(acks.len(), 1, "a frame acknowledgement goes back");
        let out = g.drain();
        assert!(!out.is_empty());
        // Into a framebuffer as the session does: the filled pixels are RGBA 10 20 30.
        let mut f = super::super::framebuffer::Framebuffer::new(256);
        f.resize(64, 32);
        for u in &out {
            let r = &u.region;
            f.put(r.left.into(), r.top.into(), (r.right - r.left).into(), (r.bottom - r.top).into(), &u.data, 1);
        }
        let px = |x: usize, y: usize| f.rgba()[(y * 64 + x) * 4..(y * 64 + x) * 4 + 4].to_vec();
        assert_eq!(px(8, 4), vec![0x10, 0x20, 0x30, 255]);
        assert_eq!(px(23, 11), vec![0x10, 0x20, 0x30, 255]);
        let s = stats.held().clone();
        assert_eq!(s.gfx.as_deref(), Some("V10_1"));
        assert_eq!(s.gfx_frames, 1);
        assert_eq!(s.gfx_solid_fills, Count { count: 1, pixels: 128, bytes: 0 });
    }
}

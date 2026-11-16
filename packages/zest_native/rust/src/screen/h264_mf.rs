//! H.264 for RDP's graphics pipeline (AVC420, and AVC444 through the pipeline) with Windows' own
//! decoder: the Microsoft H.264 Video Decoder MFT (Media Foundation), software, low latency. No
//! OpenH264 and nothing of x264 in our build.
//!
//! IronRDP's pipeline hands each `RFX_AVC420_BITMAP_STREAM` to [H264Decoder]: an Annex B byte
//! stream (or 4-byte length-prefixed NAL units from servers that followed an older IronRDP note;
//! both are taken), one picture per call. The decoder runs in low latency mode, so each call's
//! picture comes out of that same call (AVC444 pairs each result with the sub-stream it passed
//! in, so a picture held back would pair wrongly).
//!
//! Two ways out:
//! - [H264Decoder::decode_yuv420] (the default, `supports_yuv420` true): the picture's planes. The
//!   pipeline converts them with MS-RDPEGFX's colour transform, and recombines two of them for
//!   AVC444, so both modes work.
//! - [H264Decoder::decode] (`yuv420: false`, AVC420 only): we convert to RGBA ourselves, with the
//!   same full-range BT.709 integer transform as the pipeline (bit for bit), a row pair at a time.
//!
//! mfplat.dll's functions are looked up at run time (`LoadLibraryExW` from System32), never
//! imported, so `zest_native.dll` still loads on Windows editions without Media Foundation (N
//! and KN without the Media Feature Pack): there the decoder fails to start and the pipeline
//! offers no AVC (RemoteFX Progressive and the rest instead).

use crate::screen::LockAnyway as _;
use std::ffi::c_void;
use std::mem::ManuallyDrop;
use std::sync::OnceLock;
use std::time::Instant;

use ironrdp_egfx::decode::{DecodedFrame, DecoderError, DecoderResult, H264Decoder, Yuv420Frame};
use windows::Win32::Media::MediaFoundation::{
    CLSID_MSH264DecoderMFT, IMFMediaBuffer, IMFSample, IMFTransform, MF_E_NOTACCEPTING,
    MF_E_TRANSFORM_NEED_MORE_INPUT, MF_E_TRANSFORM_STREAM_CHANGE, MF_LOW_LATENCY, MF_MT_DEFAULT_STRIDE,
    MF_MT_FRAME_SIZE, MF_MT_SUBTYPE, MF_VERSION, MFSTARTUP_LITE, MFT_MESSAGE_COMMAND_FLUSH,
    MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, MFT_MESSAGE_NOTIFY_START_OF_STREAM, MFT_OUTPUT_DATA_BUFFER,
    MFT_OUTPUT_STREAM_PROVIDES_SAMPLES, MFVideoFormat_H264, MFVideoFormat_I420, MFVideoFormat_IYUV,
    MFVideoFormat_NV12,
};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED, CoCreateInstance, CoInitializeEx, CoUninitialize};
use windows::Win32::System::LibraryLoader::{GetProcAddress, LOAD_LIBRARY_SEARCH_SYSTEM32, LoadLibraryExW};
use windows::core::{HRESULT, Interface, s, w};

use super::rdp_graphics::SharedStats;

/// The decoder's name in the session's report.
pub const NAME: &str = "Microsoft H.264 Video Decoder MFT (Media Foundation, software)";

type MfStartup = unsafe extern "system" fn(u32, u32) -> HRESULT;
type MfShutdown = unsafe extern "system" fn() -> HRESULT;
type MfCreateSample = unsafe extern "system" fn(*mut *mut c_void) -> HRESULT;
type MfCreateMemoryBuffer = unsafe extern "system" fn(u32, *mut *mut c_void) -> HRESULT;

/// mfplat.dll's four functions we use, looked up once per process (the library stays loaded).
struct MfPlat {
    startup: MfStartup,
    shutdown: MfShutdown,
    create_sample: MfCreateSample,
    create_memory_buffer: MfCreateMemoryBuffer,
}

fn mfplat() -> Result<&'static MfPlat, String> {
    static PLAT: OnceLock<Result<MfPlat, String>> = OnceLock::new();
    PLAT.get_or_init(|| unsafe {
        let module = LoadLibraryExW(w!("mfplat.dll"), None, LOAD_LIBRARY_SEARCH_SYSTEM32)
            .map_err(|e| format!("Media Foundation is not on this PC (mfplat.dll: {e})"))?;
        let get = |name: windows::core::PCSTR, label: &str| {
            GetProcAddress(module, name).ok_or_else(|| format!("mfplat.dll has no {label}"))
        };
        // SAFETY: the signatures are mfplat.dll's documented ones.
        Ok(MfPlat {
            startup: std::mem::transmute::<_, MfStartup>(get(s!("MFStartup"), "MFStartup")?),
            shutdown: std::mem::transmute::<_, MfShutdown>(get(s!("MFShutdown"), "MFShutdown")?),
            create_sample: std::mem::transmute::<_, MfCreateSample>(get(s!("MFCreateSample"), "MFCreateSample")?),
            create_memory_buffer: std::mem::transmute::<_, MfCreateMemoryBuffer>(get(
                s!("MFCreateMemoryBuffer"),
                "MFCreateMemoryBuffer",
            )?),
        })
    })
    .as_ref()
    .map_err(Clone::clone)
}

fn sample(plat: &MfPlat) -> windows::core::Result<IMFSample> {
    let mut raw = std::ptr::null_mut();
    unsafe {
        (plat.create_sample)(&mut raw).ok()?;
        Ok(IMFSample::from_raw(raw))
    }
}

fn memory_buffer(plat: &MfPlat, size: u32) -> windows::core::Result<IMFMediaBuffer> {
    let mut raw = std::ptr::null_mut();
    unsafe {
        (plat.create_memory_buffer)(size, &mut raw).ok()?;
        Ok(IMFMediaBuffer::from_raw(raw))
    }
}

fn err(what: &str, e: windows::core::Error) -> DecoderError {
    DecoderError::new(format!("Media Foundation: {what}"), e)
}

/// The output format the decoder agreed to.
#[derive(Debug, Clone, Copy)]
struct OutFormat {
    /// I420 (Y, U, V planes) or NV12 (Y, then U and V interleaved).
    planar: bool,
    width: u32,
    height: u32,
    /// Bytes per luma row (MF_MT_DEFAULT_STRIDE, else the width).
    stride: u32,
}

/// A decoded picture's planes, tightly owned (strides kept).
struct Planes {
    width: u16,
    height: u16,
    y: Vec<u8>,
    u: Vec<u8>,
    v: Vec<u8>,
    luma_stride: usize,
    chroma_stride: usize,
}

/// The decoder (see the module's comment). One per graphics channel; it lives on the session's
/// thread (COM is started there, multithreaded).
pub struct MfH264Decoder {
    mft: Option<IMFTransform>,
    plat: &'static MfPlat,
    format: Option<OutFormat>,
    /// Our output sample when the decoder does not provide its own (the software decoder does
    /// not), and its buffer's size.
    out_sample: Option<(IMFSample, u32)>,
    yuv420: bool,
    time: i64,
    stats: SharedStats,
    /// COM was started by us on this thread (undone on drop, on the same thread only).
    com: Option<std::thread::ThreadId>,
    mf_started: bool,
}

// SAFETY: the decoder MFT is free threaded (registered "Both") and created in the
// multithreaded apartment; the session uses it from one thread at a time.
unsafe impl Send for MfH264Decoder {}

impl MfH264Decoder {
    /// Starts COM (multithreaded) and Media Foundation on this thread and opens the decoder.
    /// `yuv420`: hand the planes to the pipeline (AVC420 and AVC444) rather than RGBA (AVC420).
    pub fn new(yuv420: bool, stats: SharedStats) -> Result<Self, String> {
        let plat = mfplat()?;
        let com = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
        // RPC_E_CHANGED_MODE: the thread is single-threaded already; the MFT works there too.
        let com = com.is_ok().then(std::thread::current).map(|t| t.id());
        let mut me = Self {
            mft: None,
            plat,
            format: None,
            out_sample: None,
            yuv420,
            time: 0,
            stats,
            com,
            mf_started: false,
        };
        unsafe { (plat.startup)(MF_VERSION, MFSTARTUP_LITE) }.ok().map_err(|e| format!("MFStartup: {e}"))?;
        me.mf_started = true;
        let mft: IMFTransform = unsafe { CoCreateInstance(&CLSID_MSH264DecoderMFT, None, CLSCTX_INPROC_SERVER) }
            .map_err(|e| format!("the H.264 decoder MFT: {e}"))?;
        unsafe {
            // Each input's picture comes out at once (no reordering delay).
            if let Ok(attributes) = mft.GetAttributes() {
                let _ = attributes.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            let mut set = false;
            for i in 0.. {
                let Ok(t) = mft.GetInputAvailableType(0, i) else { break };
                if t.GetGUID(&MF_MT_SUBTYPE).is_ok_and(|g| g == MFVideoFormat_H264) {
                    mft.SetInputType(0, &t, 0).map_err(|e| format!("input type: {e}"))?;
                    set = true;
                    break;
                }
            }
            if !set {
                return Err("the decoder takes no H.264 input type".into());
            }
        }
        me.mft = Some(mft);
        me.choose_output().map_err(|e| e.to_string())?;
        unsafe {
            let mft = me.mft.as_ref().unwrap();
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0).map_err(|e| format!("begin streaming: {e}"))?;
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0).map_err(|e| format!("start of stream: {e}"))?;
        }
        Ok(me)
    }

    /// Picks the output type (I420 first: planes as they are; NV12 otherwise) and reads its size
    /// and stride. Called at start and on every stream change.
    fn choose_output(&mut self) -> DecoderResult<()> {
        let mft = self.mft.as_ref().ok_or_else(|| DecoderError::msg("closed"))?;
        let mut best: Option<(usize, windows::Win32::Media::MediaFoundation::IMFMediaType)> = None;
        unsafe {
            for i in 0.. {
                let Ok(t) = mft.GetOutputAvailableType(0, i) else { break };
                let Ok(sub) = t.GetGUID(&MF_MT_SUBTYPE) else { continue };
                let rank = [MFVideoFormat_I420, MFVideoFormat_IYUV, MFVideoFormat_NV12].iter().position(|g| *g == sub);
                if let Some(rank) = rank {
                    if best.as_ref().is_none_or(|(r, _)| rank < *r) {
                        best = Some((rank, t));
                    }
                }
            }
            let Some((rank, t)) = best else { return Err(DecoderError::msg("no I420 or NV12 output")) };
            mft.SetOutputType(0, &t, 0).map_err(|e| err("output type", e))?;
            let t = mft.GetOutputCurrentType(0).map_err(|e| err("output type", e))?;
            let size = t.GetUINT64(&MF_MT_FRAME_SIZE).unwrap_or(0);
            let (width, height) = ((size >> 32) as u32, size as u32);
            let stride = t.GetUINT32(&MF_MT_DEFAULT_STRIDE).map(|s| (s as i32).unsigned_abs()).unwrap_or(0);
            let stride = if stride >= width { stride } else { width };
            self.format = Some(OutFormat { planar: rank < 2, width, height, stride });
            let name = if rank < 2 { "I420" } else { "NV12" };
            if let Some(h) = self.stats.held().h264.as_mut() {
                h.output = format!("{name} {width}x{height}, stride {stride}");
            }
        }
        self.out_sample = None;
        Ok(())
    }

    /// One picture from one access unit (or more: the last picture wins).
    fn decode_planes(&mut self, data: &[u8]) -> DecoderResult<Planes> {
        let started = Instant::now();
        let annex_b = to_annex_b(data);
        let input = self.input_sample(&annex_b).map_err(|e| err("input sample", e))?;
        let mft = self.mft.clone().ok_or_else(|| DecoderError::msg("closed"))?;
        let mut picture = None;
        if let Err(e) = unsafe { mft.ProcessInput(0, &input, 0) } {
            if e.code() != MF_E_NOTACCEPTING {
                return Err(err("input", e));
            }
            // Full: take what is ready, then give the input again.
            picture = self.drain_output(&mft)?;
            unsafe { mft.ProcessInput(0, &input, 0) }.map_err(|e| err("input", e))?;
        }
        if let Some(p) = self.drain_output(&mft)? {
            picture = Some(p);
        }
        let us = started.elapsed().as_micros() as u64;
        let mut s = self.stats.held();
        let h = s.h264.get_or_insert_with(Default::default);
        h.pictures += u64::from(picture.is_some());
        h.bytes += data.len() as u64;
        h.decode_us += us;
        h.max_decode_us = h.max_decode_us.max(us);
        drop(s);
        picture.ok_or_else(|| DecoderError::msg("the decoder gave no picture for this access unit"))
    }

    fn input_sample(&mut self, data: &[u8]) -> windows::core::Result<IMFSample> {
        let buffer = memory_buffer(self.plat, data.len() as u32)?;
        unsafe {
            let mut at = std::ptr::null_mut();
            buffer.Lock(&mut at, None, None)?;
            std::ptr::copy_nonoverlapping(data.as_ptr(), at, data.len());
            buffer.Unlock()?;
            buffer.SetCurrentLength(data.len() as u32)?;
            let sample = sample(self.plat)?;
            sample.AddBuffer(&buffer)?;
            // 100 ns units; one frame a 60th of a second (the decoder needs times, not real ones).
            sample.SetSampleTime(self.time * 166_667)?;
            sample.SetSampleDuration(166_667)?;
            self.time += 1;
            Ok(sample)
        }
    }

    /// Takes every picture the decoder has ready (the last one is returned), handling a stream
    /// change (a new size or format) on the way.
    fn drain_output(&mut self, mft: &IMFTransform) -> DecoderResult<Option<Planes>> {
        let mut last = None;
        for _ in 0..64 {
            let info = unsafe { mft.GetOutputStreamInfo(0) }.map_err(|e| err("output stream info", e))?;
            let provides = info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 != 0;
            let ours = if provides {
                None
            } else {
                if self.out_sample.as_ref().is_none_or(|(_, size)| *size < info.cbSize) {
                    let s = sample(self.plat).map_err(|e| err("output sample", e))?;
                    let b = memory_buffer(self.plat, info.cbSize).map_err(|e| err("output buffer", e))?;
                    unsafe { s.AddBuffer(&b) }.map_err(|e| err("output sample", e))?;
                    self.out_sample = Some((s, info.cbSize));
                }
                let (s, _) = self.out_sample.as_ref().unwrap();
                // Empty again: the decoder writes a whole picture into it.
                if let Ok(b) = unsafe { s.GetBufferByIndex(0) } {
                    let _ = unsafe { b.SetCurrentLength(0) };
                }
                Some(s.clone())
            };
            let mut out = [MFT_OUTPUT_DATA_BUFFER {
                dwStreamID: 0,
                pSample: ManuallyDrop::new(ours),
                dwStatus: 0,
                pEvents: ManuallyDrop::new(None),
            }];
            let mut status = 0u32;
            let r = unsafe { mft.ProcessOutput(0, &mut out, &mut status) };
            let [o] = out;
            let produced = ManuallyDrop::into_inner(o.pSample);
            drop(ManuallyDrop::into_inner(o.pEvents));
            match r {
                Ok(()) => {
                    if let Some(s) = produced {
                        last = Some(self.copy_planes(&s)?);
                    }
                }
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => self.choose_output()?,
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(last),
                Err(e) => return Err(err("output", e)),
            }
        }
        Ok(last)
    }

    fn copy_planes(&self, s: &IMFSample) -> DecoderResult<Planes> {
        let f = self.format.ok_or_else(|| DecoderError::msg("no output format"))?;
        let (Ok(width), Ok(height)) = (u16::try_from(f.width), u16::try_from(f.height)) else {
            return Err(DecoderError::msg("picture larger than 65535"));
        };
        // The software decoder writes into our plain (1D) buffer with the type's stride.
        let buffer = unsafe { s.ConvertToContiguousBuffer() }.map_err(|e| err("output buffer", e))?;
        let mut base = std::ptr::null_mut();
        let mut len = 0u32;
        unsafe { buffer.Lock(&mut base, None, Some(&mut len)) }.map_err(|e| err("lock", e))?;
        let unlock = || unsafe {
            let _ = buffer.Unlock();
        };
        let pitch = f.stride as i32;
        if pitch <= 0 {
            unlock();
            return Err(DecoderError::msg("bottom-up picture"));
        }
        let stride = pitch as usize;
        let rows = f.height as usize;
        let chroma_rows = rows.div_ceil(2);
        let luma = stride * rows;
        let need = if f.planar { luma + 2 * (stride / 2) * chroma_rows } else { luma + stride * chroma_rows };
        if (len as usize) < need || stride < f.width as usize {
            unlock();
            return Err(DecoderError::msg(format!(
                "picture buffer too small: {len} bytes for {}x{} at stride {stride}",
                f.width, f.height
            )));
        }
        // SAFETY: the buffer is locked and at least `need` bytes long.
        let all = unsafe { std::slice::from_raw_parts(base, need) };
        let y = all[..luma].to_vec();
        let (u, v, chroma_stride) = if f.planar {
            let c = (stride / 2) * chroma_rows;
            (all[luma..luma + c].to_vec(), all[luma + c..luma + 2 * c].to_vec(), stride / 2)
        } else {
            let cw = (f.width as usize).div_ceil(2);
            let mut u = vec![0u8; cw * chroma_rows];
            let mut v = vec![0u8; cw * chroma_rows];
            for r in 0..chroma_rows {
                let row = &all[luma + r * stride..luma + r * stride + 2 * cw];
                for (c, uv) in row.chunks_exact(2).enumerate() {
                    u[r * cw + c] = uv[0];
                    v[r * cw + c] = uv[1];
                }
            }
            (u, v, cw)
        };
        unlock();
        Ok(Planes { width, height, y, u, v, luma_stride: stride, chroma_stride })
    }
}

impl Drop for MfH264Decoder {
    fn drop(&mut self) {
        self.out_sample = None;
        if let Some(mft) = self.mft.take() {
            unsafe {
                let _ = mft.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            }
            drop(mft);
        }
        if self.mf_started {
            unsafe {
                let _ = (self.plat.shutdown)();
            }
        }
        if self.com == Some(std::thread::current().id()) {
            unsafe { CoUninitialize() };
        }
    }
}

impl H264Decoder for MfH264Decoder {
    fn decode(&mut self, data: &[u8]) -> DecoderResult<DecodedFrame> {
        let p = self.decode_planes(data)?;
        let started = Instant::now();
        let mut rgba = vec![0u8; usize::from(p.width) * usize::from(p.height) * 4];
        yuv420_to_rgba(&p, &mut rgba);
        let us = started.elapsed().as_micros() as u64;
        if let Some(h) = self.stats.held().h264.as_mut() {
            h.convert_us += us;
        }
        Ok(DecodedFrame::new(rgba, u32::from(p.width), u32::from(p.height)))
    }

    fn decode_yuv420(&mut self, data: &[u8]) -> DecoderResult<Yuv420Frame> {
        let p = self.decode_planes(data)?;
        Yuv420Frame::new(p.width, p.height, p.y, p.luma_stride, p.u, p.v, p.chroma_stride)
    }

    fn supports_yuv420(&self) -> bool {
        self.yuv420
    }

    fn reset(&mut self) {
        // A new stream (ResetGraphics, a channel reset): drop what the decoder holds; the next
        // access unit starts with its parameter sets and an IDR picture.
        if let Some(mft) = &self.mft {
            unsafe {
                let _ = mft.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            }
        }
    }
}

/// Annex B as it is, or 4-byte big-endian length-prefixed NAL units rewritten with start codes.
fn to_annex_b(data: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    if data.starts_with(&[0, 0, 0, 1]) || data.starts_with(&[0, 0, 1]) {
        return data.into();
    }
    let mut out = Vec::with_capacity(data.len() + 16);
    let mut at = 0;
    while at + 4 <= data.len() {
        let n = u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize;
        at += 4;
        let Some(nal) = data.get(at..at + n) else {
            // Not length-prefixed after all: hand it over as it came.
            return data.into();
        };
        out.extend_from_slice(&[0, 0, 0, 1]);
        out.extend_from_slice(nal);
        at += n;
    }
    if at != data.len() {
        return data.into();
    }
    out.into()
}

/// A channel of MS-RDPEGFX 3.3.8.3.1's reverse transform (full-range BT.709, in integers),
/// clamped to a byte exactly as ironrdp-egfx's pipeline does it, so both paths give the same
/// pixels.
#[inline(always)]
fn clamp(v: i32) -> u8 {
    v.clamp(0, 255) as u8
}

/// I420 planes to RGBA (opaque). For each chroma row, the three chroma terms are spread to one
/// per pixel once and serve both luma rows; the per-pixel loop is then straight arithmetic on
/// arrays. About 1.6 ms for 1280 x 800 and 3.2 ms for 1920 x 1088 here (release, `opt-level =
/// "s"`), against 4.2 and 8.6 ms for the pipeline's own conversion; explicit SIMD would go
/// further if it ever matters.
fn yuv420_to_rgba(p: &Planes, out: &mut [u8]) {
    let (w, h) = (usize::from(p.width), usize::from(p.height));
    let mut rv = vec![0i32; w];
    let mut guv = vec![0i32; w];
    let mut bu = vec![0i32; w];
    for pair in 0..h.div_ceil(2) {
        let c = pair * p.chroma_stride;
        let (u, v) = (&p.u[c..c + w.div_ceil(2)], &p.v[c..c + w.div_ceil(2)]);
        for x in 0..w {
            let (u, v) = (i32::from(u[x / 2]) - 128, i32::from(v[x / 2]) - 128);
            rv[x] = 403 * v;
            guv[x] = -48 * u - 120 * v;
            bu[x] = 475 * u;
        }
        for row in 2 * pair..(2 * pair + 2).min(h) {
            let y = &p.y[row * p.luma_stride..row * p.luma_stride + w];
            let dst = &mut out[row * w * 4..(row + 1) * w * 4];
            for ((((rgba, &luma), &rv), &guv), &bu) in dst.chunks_exact_mut(4).zip(y).zip(&rv).zip(&guv).zip(&bu) {
                let l = 256 * i32::from(luma);
                rgba[0] = clamp((l + rv) >> 8);
                rgba[1] = clamp((l + guv) >> 8);
                rgba[2] = clamp((l + bu) >> 8);
                rgba[3] = 0xff;
            }
        }
    }
}

#[cfg(test)]
mod tests;

//! The Media Foundation decoder against streams Windows' own encoder makes at test time
//! (`ffmpeg -c:v h264_mf`, the Microsoft H.264 encoder MFT; no x264), checked picture by picture
//! against ffmpeg's own decoding of the same stream: H.264 decoding is exact, so every plane must
//! match bit for bit. Without ffmpeg (or without its h264_mf encoder) these tests say so and pass;
//! nothing generated is committed.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

use ironrdp_dvc::DvcProcessor;
use ironrdp_egfx::decode::{H264Decoder, Yuv420Frame};
use ironrdp_egfx::pdu::{
    Avc420BitmapStream, CapabilitiesConfirmPdu, CapabilitiesV107Flags, CapabilitySet, Codec1Type, CreateSurfacePdu,
    EndFramePdu, GfxPdu, MapSurfaceToOutputPdu, PixelFormat, QuantQuality, ResetGraphicsPdu, StartFramePdu, Timestamp,
    WireToSurface1Pdu,
};
use ironrdp_pdu::geometry::ExclusiveRectangle;

use super::super::rdp_graphics::{Gfx, H264Mode, SharedStats, Stats};
use super::*;

fn stats() -> SharedStats {
    Arc::new(Mutex::new(Stats::new("gfx")))
}

/// A folder of its own under the system's temporary folder.
fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("zest-h264-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// An Annex B stream of `frames` pictures of ffmpeg's moving test pattern, encoded by Windows'
/// H.264 encoder MFT (software), and ffmpeg's decoding of it as raw I420 (cropped to the size).
/// None when ffmpeg or its h264_mf encoder is not there.
fn stream(dir: &Path, w: u32, h: u32, frames: u32) -> Option<(Vec<u8>, Vec<u8>)> {
    let h264 = dir.join("test.h264");
    let yuv = dir.join("test.yuv");
    let made = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i"])
        .arg(format!("testsrc2=size={w}x{h}:rate=30"))
        .args(["-frames:v", &frames.to_string(), "-pix_fmt", "nv12", "-c:v", "h264_mf", "-hw_encoding", "0"])
        .args(["-scenario", "display_remoting", "-f", "h264"])
        .arg(&h264)
        .status();
    if !made.is_ok_and(|s| s.success()) {
        eprintln!("SKIPPED: ffmpeg with the h264_mf encoder is not available");
        return None;
    }
    let decoded = Command::new("ffmpeg")
        .args(["-hide_banner", "-loglevel", "error", "-y", "-i"])
        .arg(&h264)
        .args(["-f", "rawvideo", "-pix_fmt", "yuv420p"])
        .arg(&yuv)
        .status()
        .unwrap();
    assert!(decoded.success());
    Some((std::fs::read(h264).unwrap(), std::fs::read(yuv).unwrap()))
}

/// Splits an Annex B stream into access units (one picture each): a new one starts at an access
/// unit delimiter, SEI, SPS or PPS after a slice, or at a slice whose first macroblock is 0.
fn access_units(stream: &[u8]) -> Vec<Vec<u8>> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i..i + 3] == [0, 0, 1] {
            let at = if i > 0 && stream[i - 1] == 0 { i - 1 } else { i };
            starts.push((at, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut units: Vec<Vec<u8>> = Vec::new();
    let mut current: Vec<u8> = Vec::new();
    let mut has_slice = false;
    for (k, &(at, nal)) in starts.iter().enumerate() {
        let end = starts.get(k + 1).map_or(stream.len(), |s| s.0);
        let kind = stream[nal] & 0x1f;
        let first_mb_zero = stream.get(nal + 1).is_some_and(|b| b & 0x80 != 0);
        let starts_unit = match kind {
            1 | 5 => has_slice && first_mb_zero,
            6..=9 => has_slice,
            _ => false,
        };
        if starts_unit {
            units.push(std::mem::take(&mut current));
            has_slice = false;
        }
        has_slice |= matches!(kind, 1 | 5);
        current.extend_from_slice(&stream[at..end]);
    }
    if !current.is_empty() {
        units.push(current);
    }
    units
}

/// Frame `n` of raw I420 (`w` x `h`) as planes.
fn reference(yuv: &[u8], w: usize, h: usize, n: usize) -> Yuv420Frame {
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let size = w * h + 2 * cw * ch;
    let f = &yuv[n * size..(n + 1) * size];
    Yuv420Frame::new(
        w as u16,
        h as u16,
        f[..w * h].to_vec(),
        w,
        f[w * h..w * h + cw * ch].to_vec(),
        f[w * h + cw * ch..].to_vec(),
        cw,
    )
    .unwrap()
}

fn same_picture(got: &Yuv420Frame, want: &Yuv420Frame) -> usize {
    let mut differ = 0;
    for r in 0..usize::from(want.height()) {
        let (a, b) = (got.luma_row(r).unwrap(), want.luma_row(r).unwrap());
        differ += a[..b.len()].iter().zip(b).filter(|(x, y)| x != y).count();
    }
    for r in 0..usize::from(want.height().div_ceil(2)) {
        let (a, b) = (got.u_row(r).unwrap(), want.u_row(r).unwrap());
        differ += a[..b.len()].iter().zip(b).filter(|(x, y)| x != y).count();
        let (a, b) = (got.v_row(r).unwrap(), want.v_row(r).unwrap());
        differ += a[..b.len()].iter().zip(b).filter(|(x, y)| x != y).count();
    }
    differ
}

#[test]
fn length_prefixed_nal_units_become_annex_b() {
    let annex_b = [0u8, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3];
    assert_eq!(&*to_annex_b(&annex_b), &annex_b);
    let prefixed = [0u8, 0, 0, 3, 0x67, 1, 2, 0, 0, 0, 2, 0x68, 3];
    assert_eq!(&*to_annex_b(&prefixed), &[0, 0, 0, 1, 0x67, 1, 2, 0, 0, 0, 1, 0x68, 3]);
    // A length running past the end: handed over as it came.
    let broken = [0u8, 0, 0, 9, 0x67];
    assert_eq!(&*to_annex_b(&broken), &broken);
}

#[test]
fn our_rgba_is_the_pipelines_bit_for_bit() {
    // Odd sizes and every chroma value against IronRDP's own conversion (MS-RDPEGFX 3.3.8.3.1).
    let (w, h) = (37usize, 19usize);
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let (ls, cs) = (w + 5, cw + 3);
    let byte = |i: usize, k: usize| ((i * 2654435761usize + k * 97) >> 7) as u8;
    let y: Vec<u8> = (0..ls * h).map(|i| byte(i, 1)).collect();
    let u: Vec<u8> = (0..cs * ch).map(|i| byte(i, 2)).collect();
    let v: Vec<u8> = (0..cs * ch).map(|i| byte(i, 3)).collect();
    let planes = Planes {
        width: w as u16,
        height: h as u16,
        y: y.clone(),
        u: u.clone(),
        v: v.clone(),
        luma_stride: ls,
        chroma_stride: cs,
    };
    let mut ours = vec![0u8; w * h * 4];
    yuv420_to_rgba(&planes, &mut ours);
    let theirs = Yuv420Frame::new(w as u16, h as u16, y, ls, u, v, cs).unwrap().to_rgba();
    assert_eq!(ours, theirs.data());
    // The extremes clamp the same way.
    for (yy, uu, vv) in [(0u8, 0u8, 0u8), (255, 255, 255), (0, 255, 0), (255, 0, 255), (16, 128, 128)] {
        let p = Planes { width: 2, height: 2, y: vec![yy; 4], u: vec![uu], v: vec![vv], luma_stride: 2, chroma_stride: 1 };
        let mut a = vec![0u8; 16];
        yuv420_to_rgba(&p, &mut a);
        let b = Yuv420Frame::new(2, 2, vec![yy; 4], 2, vec![uu], vec![vv], 1).unwrap().to_rgba();
        assert_eq!(a, b.data());
    }
}

#[test]
fn media_foundation_decodes_windows_own_h264_exactly() {
    // 200 x 120: neither side a multiple of 16, so the stream is cropped (coded 208 x 128).
    let dir = scratch("exact");
    let (w, h, frames) = (200usize, 120usize, 24u32);
    let Some((h264, yuv)) = stream(&dir, w as u32, h as u32, frames) else { return };
    let units = access_units(&h264);
    assert_eq!(units.len(), frames as usize, "one access unit per picture");
    let s = stats();
    s.lock().unwrap().h264 = Some(Default::default());
    let mut planes = MfH264Decoder::new(true, s.clone()).expect("Media Foundation's H.264 decoder");
    let mut rgba = MfH264Decoder::new(false, s.clone()).unwrap();
    assert!(planes.supports_yuv420() && !rgba.supports_yuv420());
    for (n, unit) in units.iter().enumerate() {
        // Each picture comes out of the call that carries it (low latency).
        let got = planes.decode_yuv420(unit).unwrap_or_else(|e| panic!("picture {n}: {e}"));
        assert!(usize::from(got.width()) >= w && usize::from(got.height()) >= h, "{}x{}", got.width(), got.height());
        let want = reference(&yuv, w, h, n);
        assert_eq!(same_picture(&got, &want), 0, "picture {n} differs from ffmpeg's decoding");
        // The RGBA way gives the pipeline's conversion of the same planes.
        let frame = rgba.decode(unit).unwrap();
        let fw = frame.width() as usize;
        let expected = want.to_rgba();
        for r in 0..h {
            assert_eq!(&frame.data()[r * fw * 4..(r * fw + w) * 4], &expected.data()[r * w * 4..(r + 1) * w * 4], "row {r}");
        }
    }
    // A stream from the start again after a reset (what ResetGraphics does).
    planes.reset();
    let got = planes.decode_yuv420(&units[0]).unwrap();
    assert_eq!(same_picture(&got, &reference(&yuv, w, h, 0)), 0);
    let st = s.lock().unwrap().h264.clone().unwrap();
    assert_eq!(st.pictures, 2 * frames as u64 + 1);
    eprintln!("output {}", st.output);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_pipeline_offers_avc_and_draws_an_avc420_frame() {
    let dir = scratch("gfx");
    let (w, h) = (200u16, 120u16);
    let Some((h264, yuv)) = stream(&dir, u32::from(w), u32::from(h), 2) else { return };
    let units = access_units(&h264);
    let s = stats();
    let mut g = Gfx::new(s.clone(), H264Mode::Avc444);
    let st = s.lock().unwrap().h264.clone().unwrap();
    assert_eq!((st.decoder.as_str(), st.error.as_deref(), st.mode.as_str()), (NAME, None, "avc444"));
    eprintln!("decoder started in {} us", st.init_us);
    assert_eq!(g.start(7).unwrap().len(), 1);
    let send = |g: &mut Gfx, pdu: GfxPdu| {
        let bytes = ironrdp_pdu::encode_vec(&pdu).unwrap();
        g.process(7, &ironrdp_graphics::zgfx::wrap_uncompressed(&bytes)).unwrap()
    };
    // The server picks 10.7 with AVC (AVC_DISABLED not set): only offered with a decoder.
    let caps = CapabilitySet::V10_7 { flags: CapabilitiesV107Flags::SMALL_CACHE };
    send(&mut g, GfxPdu::CapabilitiesConfirm(CapabilitiesConfirmPdu::from_typed(&caps)));
    send(&mut g, GfxPdu::ResetGraphics(ResetGraphicsPdu { width: w.into(), height: h.into(), monitors: vec![] }));
    send(&mut g, GfxPdu::CreateSurface(CreateSurfacePdu { surface_id: 1, width: w, height: h, pixel_format: PixelFormat::XRgb }));
    send(&mut g, GfxPdu::MapSurfaceToOutput(MapSurfaceToOutputPdu { surface_id: 1, output_origin_x: 0, output_origin_y: 0 }));
    let ts = Timestamp { milliseconds: 0, seconds: 0, minutes: 0, hours: 0 };
    send(&mut g, GfxPdu::StartFrame(StartFramePdu { timestamp: ts, frame_id: 1 }));
    let rect = ExclusiveRectangle { left: 0, top: 0, right: w, bottom: h };
    let stream = Avc420BitmapStream {
        rectangles: vec![rect.clone()],
        quant_qual_vals: vec![QuantQuality { quantization_parameter: 22, progressive: false, quality: 100 }],
        data: &units[0],
    };
    send(
        &mut g,
        GfxPdu::WireToSurface1(WireToSurface1Pdu {
            surface_id: 1,
            codec_id: Codec1Type::Avc420,
            pixel_format: PixelFormat::XRgb,
            destination_rectangle: rect,
            bitmap_data: ironrdp_pdu::encode_vec(&stream).unwrap(),
        }),
    );
    send(&mut g, GfxPdu::EndFrame(EndFramePdu { frame_id: 1 }));
    let out = g.drain();
    assert!(!out.is_empty());
    let mut f = super::super::framebuffer::Framebuffer::new(256);
    f.resize(w.into(), h.into());
    for u in &out {
        let r = &u.region;
        f.put(r.left.into(), r.top.into(), (r.right - r.left).into(), (r.bottom - r.top).into(), &u.data, 1);
    }
    let want = reference(&yuv, w.into(), h.into(), 0).to_rgba();
    let got = f.rgba();
    let differ = got.chunks_exact(4).zip(want.data().chunks_exact(4)).filter(|(a, b)| a[..3] != b[..3]).count();
    assert_eq!(differ, 0, "the AVC420 frame in the framebuffer");
    let st = s.lock().unwrap().clone();
    assert_eq!(st.gfx_codecs["avc420"].count, 1);
    assert_eq!(st.h264.unwrap().pictures, 1);
    let _ = std::fs::remove_dir_all(&dir);
}

/// What one picture costs (run: `cargo test --release --features rdp -- --ignored --nocapture
/// h264_cost`): Media Foundation's decode, our RGBA conversion and the pipeline's, per size.
#[test]
#[ignore]
fn h264_cost() {
    for (w, h) in [(1280usize, 800usize), (1920, 1080)] {
        let dir = scratch(&format!("cost{w}"));
        let Some((h264, _)) = stream(&dir, w as u32, h as u32, 60) else { return };
        let units = access_units(&h264);
        let s = stats();
        let started = Instant::now();
        let mut d = MfH264Decoder::new(true, s.clone()).unwrap();
        let init = started.elapsed();
        let mut pictures = Vec::new();
        let started = Instant::now();
        for u in &units {
            pictures.push(d.decode_planes(u).unwrap());
        }
        let decode = started.elapsed() / units.len() as u32;
        // The decoder's pictures are the coded size (1920 x 1088 for 1080p).
        let mut out = vec![0u8; usize::from(pictures[0].width) * usize::from(pictures[0].height) * 4];
        let started = Instant::now();
        for p in &pictures {
            yuv420_to_rgba(p, &mut out);
        }
        let ours = started.elapsed() / pictures.len() as u32;
        let frames: Vec<Yuv420Frame> = pictures
            .iter()
            .map(|p| Yuv420Frame::new(p.width, p.height, p.y.clone(), p.luma_stride, p.u.clone(), p.v.clone(), p.chroma_stride).unwrap())
            .collect();
        let started = Instant::now();
        for f in &frames {
            std::hint::black_box(f.to_rgba());
        }
        let theirs = started.elapsed() / frames.len() as u32;
        println!(
            "{w}x{h}: {} pictures, {} bytes; start {init:?}; decode {decode:?} a picture; RGBA: ours {ours:?}, the pipeline's {theirs:?}",
            units.len(),
            h264.len()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

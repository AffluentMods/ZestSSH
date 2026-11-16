//! RRE (2) and Hextile (5) decoders (RFC 6143, 7.7.3 and 7.7.4). Ours (ZestSSH), not from vnc-rs.
//! Pixels stay in the pixel format the client asked for, as Raw's do; each rectangle comes out as
//! one [VncEvent::RawImage].

use crate::vnc::engine::limits;
use crate::vnc::engine::{PixelFormat, Rect, VncError, VncEvent};
use std::future::Future;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt};

/// A rectangle's pixels, filled piece by piece.
struct Picture {
    width: usize,
    bpp: usize,
    data: Vec<u8>,
}

impl Picture {
    fn new(rect: &Rect, bpp: usize) -> Self {
        Self { width: rect.width as usize, bpp, data: vec![0; rect.width as usize * rect.height as usize * bpp] }
    }

    /// Fills x, y, w, h (inside the picture, checked by the caller) with one pixel.
    fn fill(&mut self, x: usize, y: usize, w: usize, h: usize, pixel: &[u8]) {
        for row in y..y + h {
            let start = (row * self.width + x) * self.bpp;
            for chunk in self.data[start..start + w * self.bpp].chunks_exact_mut(self.bpp) {
                chunk.copy_from_slice(pixel);
            }
        }
    }

    /// Copies a w x h block of pixels at x, y.
    fn put(&mut self, x: usize, y: usize, w: usize, h: usize, pixels: &[u8]) {
        for row in 0..h {
            let start = ((y + row) * self.width + x) * self.bpp;
            self.data[start..start + w * self.bpp].copy_from_slice(&pixels[row * w * self.bpp..(row + 1) * w * self.bpp]);
        }
    }
}

async fn read_pixel<S: AsyncRead + Unpin>(input: &mut S, bpp: usize) -> Result<[u8; 4], VncError> {
    let mut pixel = [0; 4];
    input.read_exact(&mut pixel[..bpp]).await?;
    Ok(pixel)
}

/// [VncError::Stopped] once [stop] is set.
fn check(stop: &AtomicBool) -> Result<(), VncError> {
    if stop.load(Ordering::Acquire) {
        return Err(VncError::Stopped);
    }
    Ok(())
}

pub struct RreDecoder {
    stop: Arc<AtomicBool>,
}

impl RreDecoder {
    #[cfg(test)]
    pub fn new() -> Self {
        Self::stopping(Arc::default())
    }

    /// Stops ([VncError::Stopped]) between subrectangles once [stop] is set.
    pub fn stopping(stop: Arc<AtomicBool>) -> Self {
        Self { stop }
    }

    pub async fn decode<S, F, Fut>(
        &mut self,
        format: &PixelFormat,
        rect: &Rect,
        input: &mut S,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        S: AsyncRead + Unpin,
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        crate::vnc::engine::limits::dimensions(rect.width, rect.height)?;
        format.validate()?;
        let bpp = format.bits_per_pixel as usize / 8;
        // number-of-subrectangles (U32), background-pixel-value, then each subrectangle: its
        // pixel, x, y, width, height (U16 each), relative to the rectangle.
        let count = input.read_u32().await? as usize;
        // Each subrectangle is at least 9 bytes on the wire; more than the pixels is nonsense.
        if count > rect.width as usize * rect.height as usize {
            return Err(VncError::InvalidImageData);
        }
        let background = read_pixel(input, bpp).await?;
        let mut picture = Picture::new(rect, bpp);
        picture.fill(0, 0, rect.width as usize, rect.height as usize, &background[..bpp]);
        // Ours: the subrectangles' pixels in all, against limits::MAX_SUBRECT_COVER.
        let area = rect.width as usize * rect.height as usize;
        let mut drawn = 0usize;
        for _ in 0..count {
            check(&self.stop)?;
            let pixel = read_pixel(input, bpp).await?;
            let x = input.read_u16().await? as usize;
            let y = input.read_u16().await? as usize;
            let w = input.read_u16().await? as usize;
            let h = input.read_u16().await? as usize;
            if x + w > rect.width as usize || y + h > rect.height as usize {
                return Err(VncError::InvalidImageData);
            }
            drawn += w * h;
            limits::subrects(drawn, area)?;
            picture.fill(x, y, w, h, &pixel[..bpp]);
        }
        output_func(VncEvent::RawImage(*rect, picture.data)).await
    }
}

const HEXTILE_RAW: u8 = 1;
const HEXTILE_BACKGROUND: u8 = 2;
const HEXTILE_FOREGROUND: u8 = 4;
const HEXTILE_ANY_SUBRECTS: u8 = 8;
const HEXTILE_SUBRECTS_COLOURED: u8 = 16;

pub struct HextileDecoder {
    stop: Arc<AtomicBool>,
}

impl HextileDecoder {
    #[cfg(test)]
    pub fn new() -> Self {
        Self::stopping(Arc::default())
    }

    /// Stops ([VncError::Stopped]) between tiles once [stop] is set.
    pub fn stopping(stop: Arc<AtomicBool>) -> Self {
        Self { stop }
    }

    pub async fn decode<S, F, Fut>(
        &mut self,
        format: &PixelFormat,
        rect: &Rect,
        input: &mut S,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        S: AsyncRead + Unpin,
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        crate::vnc::engine::limits::dimensions(rect.width, rect.height)?;
        format.validate()?;
        let bpp = format.bits_per_pixel as usize / 8;
        let (width, height) = (rect.width as usize, rect.height as usize);
        let mut picture = Picture::new(rect, bpp);
        // The background and foreground carry over from tile to tile within the rectangle.
        let mut background = [0u8; 4];
        let mut foreground = [0u8; 4];
        let mut raw = vec![0u8; 16 * 16 * 4];
        // Ours: the subrectangles' pixels in all, against limits::MAX_SUBRECT_COVER.
        let mut drawn = 0usize;
        for ty in (0..height).step_by(16) {
            for tx in (0..width).step_by(16) {
                check(&self.stop)?;
                let (tw, th) = ((width - tx).min(16), (height - ty).min(16));
                let mask = input.read_u8().await?;
                if mask & HEXTILE_RAW != 0 {
                    let raw = &mut raw[..tw * th * bpp];
                    input.read_exact(raw).await?;
                    picture.put(tx, ty, tw, th, raw);
                    continue;
                }
                if mask & HEXTILE_BACKGROUND != 0 {
                    background = read_pixel(input, bpp).await?;
                }
                picture.fill(tx, ty, tw, th, &background[..bpp]);
                if mask & HEXTILE_FOREGROUND != 0 {
                    foreground = read_pixel(input, bpp).await?;
                }
                if mask & HEXTILE_ANY_SUBRECTS == 0 {
                    continue;
                }
                let subrects = input.read_u8().await?;
                for _ in 0..subrects {
                    let colour = if mask & HEXTILE_SUBRECTS_COLOURED != 0 {
                        read_pixel(input, bpp).await?
                    } else {
                        foreground
                    };
                    // x in the high four bits, y in the low; width - 1 and height - 1 likewise.
                    let xy = input.read_u8().await?;
                    let wh = input.read_u8().await?;
                    let (sx, sy) = ((xy >> 4) as usize, (xy & 15) as usize);
                    let (sw, sh) = ((wh >> 4) as usize + 1, (wh & 15) as usize + 1);
                    if sx + sw > tw || sy + sh > th {
                        return Err(VncError::InvalidImageData);
                    }
                    drawn += sw * sh;
                    limits::subrects(drawn, width * height)?;
                    picture.fill(tx + sx, ty + sy, sw, sh, &colour[..bpp]);
                }
            }
        }
        output_func(VncEvent::RawImage(*rect, picture.data)).await
    }
}

/// Zlib (6): a U32 length and zlib data that inflates to Raw pixels; one zlib stream for the
/// whole connection.
pub struct ZlibRawDecoder {
    decompressor: Option<flate2::Decompress>,
}

impl ZlibRawDecoder {
    pub fn new() -> Self {
        Self { decompressor: Some(flate2::Decompress::new(true)) }
    }

    pub async fn decode<S, F, Fut>(
        &mut self,
        format: &PixelFormat,
        rect: &Rect,
        input: &mut S,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        S: AsyncRead + Unpin,
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        crate::vnc::engine::limits::dimensions(rect.width, rect.height)?;
        format.validate()?;
        let length = input.read_u32().await? as usize;
        if length > crate::vnc::engine::limits::MAX_COMPRESSED {
            return Err(VncError::InvalidImageData);
        }
        let mut compressed = vec![0; length];
        input.read_exact(&mut compressed).await?;
        let bpp = format.bits_per_pixel as usize / 8;
        let mut pixels = vec![0; rect.width as usize * rect.height as usize * bpp];
        let mut reader = super::zlib::ZlibReader::new(
            self.decompressor.take().ok_or(VncError::InvalidImageData)?,
            &compressed,
        );
        std::io::Read::read_exact(&mut reader, &mut pixels)?;
        self.decompressor = Some(reader.into_inner()?);
        output_func(VncEvent::RawImage(*rect, pixels)).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::sync::Mutex;

    fn rect(width: u16, height: u16) -> Rect {
        Rect { x: 0, y: 0, width, height }
    }

    /// Decodes with [decode] and returns the one picture it gave.
    macro_rules! picture {
        ($decoder:expr, $rect:expr, $bytes:expr) => {{
            let output = Mutex::new(Vec::new());
            let mut input: &[u8] = &$bytes;
            $decoder
                .decode(&PixelFormat::rgba(), &$rect, &mut input, &|event| {
                    output.lock().unwrap().push(event);
                    async { Ok(()) }
                })
                .await
                .map(|()| {
                    assert!(input.is_empty(), "bytes left over");
                    match output.into_inner().unwrap().pop() {
                        Some(VncEvent::RawImage(_, pixels)) => pixels,
                        other => panic!("{other:?}"),
                    }
                })
        }};
    }

    const A: [u8; 4] = [1, 1, 1, 255];
    const B: [u8; 4] = [2, 2, 2, 255];
    const C: [u8; 4] = [3, 3, 3, 255];

    fn pixels(of: &[[u8; 4]]) -> Vec<u8> {
        of.iter().flatten().copied().collect()
    }

    #[tokio::test]
    async fn rre_draws_subrectangles_over_the_background() {
        let mut b = 2u32.to_be_bytes().to_vec();
        b.extend(A);
        b.extend(B);
        b.extend([0, 1, 0, 0, 0, 2, 0, 1]); // x 1, y 0, 2 x 1
        b.extend(C);
        b.extend([0, 0, 0, 1, 0, 1, 0, 1]); // x 0, y 1, 1 x 1
        let got = picture!(RreDecoder::new(), rect(3, 2), b).unwrap();
        assert_eq!(got, pixels(&[A, B, B, C, A, A]));
        // A subrectangle outside the rectangle is refused.
        let mut b = 1u32.to_be_bytes().to_vec();
        b.extend(A);
        b.extend(B);
        b.extend([0, 2, 0, 0, 0, 2, 0, 1]);
        assert!(picture!(RreDecoder::new(), rect(3, 2), b).is_err());
    }

    #[tokio::test]
    async fn hextile_tiles_raw_background_foreground_and_coloured() {
        // 18 x 2: two tiles, 16 x 2 and 2 x 2.
        let mut b = vec![HEXTILE_BACKGROUND | HEXTILE_FOREGROUND | HEXTILE_ANY_SUBRECTS];
        b.extend(A); // background
        b.extend(B); // foreground
        b.push(1); // one subrectangle
        b.extend([0x21, 0x10]); // x 2, y 1, 2 x 1
        // Second tile: the background carries over, one coloured subrectangle.
        b.extend([HEXTILE_ANY_SUBRECTS | HEXTILE_SUBRECTS_COLOURED, 1]);
        b.extend(C);
        b.extend([0x10, 0x00]); // x 1, y 0, 1 x 1
        let got = picture!(HextileDecoder::new(), rect(18, 2), b).unwrap();
        let mut want = vec![A; 36];
        want[18 + 2] = B;
        want[18 + 3] = B;
        want[17] = C;
        assert_eq!(got, pixels(&want));

        // A raw tile.
        let mut b = vec![HEXTILE_RAW];
        b.extend(pixels(&[A, B, C, A]));
        assert_eq!(picture!(HextileDecoder::new(), rect(2, 2), b).unwrap(), pixels(&[A, B, C, A]));

        // A subrectangle beyond its tile is refused.
        let mut b = vec![HEXTILE_BACKGROUND | HEXTILE_ANY_SUBRECTS];
        b.extend(A);
        b.extend([1, 0x10, 0x10]); // x 1, 2 x 2 in a 2 x 2 tile
        b.extend(A); // (would-be foreground)
        assert!(picture!(HextileDecoder::new(), rect(2, 2), b).is_err());
    }

    #[tokio::test]
    async fn subrectangles_may_cover_their_rectangle_four_times_at_most() {
        // From a security review: 12 bytes of RRE could repaint a whole rectangle, again and again.
        let rre = |n: u32| {
            let mut b = n.to_be_bytes().to_vec();
            b.extend(A);
            for _ in 0..n {
                b.extend(B);
                b.extend([0, 0, 0, 0, 0, 4, 0, 4]); // the whole 4 x 4
            }
            b
        };
        assert_eq!(picture!(RreDecoder::new(), rect(4, 4), rre(4)).unwrap(), pixels(&[B; 16]));
        assert!(matches!(picture!(RreDecoder::new(), rect(4, 4), rre(5)), Err(VncError::Excessive(_))));
        // Hextile: one 2 x 2 tile, its subrectangles counted the same way.
        let hextile = |n: u8| {
            let mut b = vec![HEXTILE_BACKGROUND | HEXTILE_FOREGROUND | HEXTILE_ANY_SUBRECTS];
            b.extend(A);
            b.extend(B);
            b.push(n);
            for _ in 0..n {
                b.extend([0x00, 0x11]); // x 0, y 0, 2 x 2
            }
            b
        };
        assert_eq!(picture!(HextileDecoder::new(), rect(2, 2), hextile(4)).unwrap(), pixels(&[B; 4]));
        assert!(matches!(picture!(HextileDecoder::new(), rect(2, 2), hextile(5)), Err(VncError::Excessive(_))));
    }

    #[tokio::test]
    async fn a_stopped_decoder_stops_before_its_next_subrectangle_or_tile() {
        let stop = Arc::new(AtomicBool::new(true));
        let mut b = 1u32.to_be_bytes().to_vec();
        b.extend(A);
        b.extend(B);
        b.extend([0, 0, 0, 0, 0, 1, 0, 1]);
        assert!(matches!(picture!(RreDecoder::stopping(stop.clone()), rect(2, 2), b), Err(VncError::Stopped)));
        let mut b = vec![HEXTILE_BACKGROUND];
        b.extend(A);
        assert!(matches!(picture!(HextileDecoder::stopping(stop), rect(2, 2), b), Err(VncError::Stopped)));
    }

    #[tokio::test]
    async fn zlib_keeps_one_stream_across_rectangles() {
        // Two rectangles compressed as one stream, flushed between them, as servers do.
        let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
        z.write_all(&pixels(&[A, B])).unwrap();
        z.flush().unwrap();
        let first = z.get_ref().len();
        z.write_all(&pixels(&[C, C])).unwrap();
        z.flush().unwrap();
        let all = z.get_ref().clone();
        let mut decoder = ZlibRawDecoder::new();
        for (part, want) in [(&all[..first], pixels(&[A, B])), (&all[first..], pixels(&[C, C]))] {
            let mut b = (part.len() as u32).to_be_bytes().to_vec();
            b.extend_from_slice(part);
            assert_eq!(picture!(decoder, rect(2, 1), b).unwrap(), want);
        }
    }
}

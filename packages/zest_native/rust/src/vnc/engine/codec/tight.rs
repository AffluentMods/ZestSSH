use crate::vnc::engine::{PixelFormat, Rect, VncError, VncEvent};
use std::future::Future;
use std::io::Read;
use tokio::io::{AsyncRead, AsyncReadExt};

use super::{initialized_vec, zlib::ZlibReader};

const MAX_PALETTE: usize = 256;

/// A Tight JPEG rectangle as RGB, 3 bytes a pixel; it must be exactly the rectangle's size.
pub(crate) fn decode_jpeg(data: &[u8], rect: &Rect) -> Result<Vec<u8>, VncError> {
    use zune_core::{bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions};
    let options = DecoderOptions::default()
        .jpeg_set_out_colorspace(ColorSpace::RGB)
        .set_max_width(rect.width as usize)
        .set_max_height(rect.height as usize);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(data), options);
    let rgb = decoder.decode().map_err(|_| VncError::InvalidImageData)?;
    let info = decoder.info().ok_or(VncError::InvalidImageData)?;
    if (info.width as usize, info.height as usize) != (rect.width as usize, rect.height as usize)
        || rgb.len() != rect.width as usize * rect.height as usize * 3
    {
        return Err(VncError::InvalidImageData);
    }
    Ok(rgb)
}

#[derive(Default)]
pub struct Decoder {
    zlibs: [Option<flate2::Decompress>; 4],
    ctrl: u8,
    filter: u8,
    palette: Vec<u8>,
    alpha_shift: u32,
    /// Ours: a solid fill goes out as [VncEvent::Fill] (one colour) instead of a picture of it.
    pub fill_events: bool,
}

impl Decoder {
    pub fn new() -> Self {
        let mut new = Self {
            palette: Vec::with_capacity(MAX_PALETTE * 4),
            ..Default::default()
        };
        for i in 0..4 {
            let decompressor = flate2::Decompress::new(true);
            new.zlibs[i] = Some(decompressor);
        }
        new
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
        if format.bits_per_pixel != 32
            || format.true_color_flag == 0
            || [format.red_max, format.green_max, format.blue_max] != [255; 3]
        {
            return Err(VncError::WrongPixelFormat);
        }
        let pixel_mask = ((format.red_max as u32) << format.red_shift)
            | ((format.green_max as u32) << format.green_shift)
            | ((format.blue_max as u32) << format.blue_shift);

        self.alpha_shift = match pixel_mask {
            0xff_ff_ff_00 => 0,
            0xff_ff_00_ff => 8,
            0xff_00_ff_ff => 16,
            0x00_ff_ff_ff => 24,
            _ => return Err(VncError::WrongPixelFormat),
        };

        let ctrl = input.read_u8().await?;
        for i in 0..4 {
            if (ctrl >> i) & 1 == 1 {
                self.zlibs[i] = Some(flate2::Decompress::new(true));
            }
        }

        // Figure out filter
        self.ctrl = ctrl >> 4;

        match self.ctrl {
            8 => {
                // fill Rect
                self.fill_rect(format, rect, input, output_func).await
            }
            9 => {
                // jpeg Rect
                self.jpeg_rect(format, rect, input, output_func).await
            }
            10 => {
                // png Rect
                error!("PNG received in standard Tight rect");
                Err(VncError::InvalidImageData)
            }
            x if x & 0x8 == 0 => {
                // basic Rect
                self.basic_rect(format, rect, input, output_func).await
            }
            _ => {
                error!("Illegal tight compression received ({})", self.ctrl);
                Err(VncError::InvalidImageData)
            }
        }
    }

    async fn read_data<S>(&mut self, input: &mut S) -> Result<Vec<u8>, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let len = {
            let mut len;
            let mut byte = input.read_u8().await? as usize;
            len = byte & 0x7f;
            if byte & 0x80 == 0x80 {
                byte = input.read_u8().await? as usize;
                len |= (byte & 0x7f) << 7;

                if byte & 0x80 == 0x80 {
                    byte = input.read_u8().await? as usize;
                    len |= byte << 14;
                }
            }
            len
        };
        let mut data = initialized_vec(len);
        input.read_exact(&mut data).await?;
        Ok(data)
    }

    async fn fill_rect<S, F, Fut>(
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
        let mut color = [0; 3];
        input.read_exact(&mut color).await?;
        let true_color = self.to_true_color(format, &color);
        if self.fill_events {
            return output_func(VncEvent::Fill(*rect, true_color)).await;
        }
        let image = true_color.repeat(rect.width as usize * rect.height as usize);
        output_func(VncEvent::RawImage(*rect, image)).await?;
        Ok(())
    }

    async fn jpeg_rect<S, F, Fut>(
        &mut self,
        _format: &PixelFormat,
        rect: &Rect,
        input: &mut S,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        S: AsyncRead + Unpin,
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        let data = self.read_data(input).await?;
        // Ours: decoded here (vnc-rs handed the JPEG on), into the pixel format asked for.
        let rgb = decode_jpeg(&data, rect)?;
        let image = self.rgb_to_pixels(_format, &rgb);
        output_func(VncEvent::RawImage(*rect, image)).await?;
        Ok(())
    }

    async fn basic_rect<S, F, Fut>(
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
        self.filter = {
            if self.ctrl & 0x4 == 4 {
                input.read_u8().await?
            } else {
                0
            }
        };

        let stream_id = self.ctrl & 0x3;
        match self.filter {
            0 => {
                // copy filter
                self.copy_filter(stream_id, format, rect, input, output_func)
                    .await
            }
            1 => {
                // palette
                self.palette_filter(stream_id, format, rect, input, output_func)
                    .await
            }
            2 => {
                // gradient
                self.gradient_filter(stream_id, format, rect, input, output_func)
                    .await
            }
            _ => {
                error!("Illegal tight filter received (filter: {})", self.filter);
                Err(VncError::InvalidImageData)
            }
        }
    }

    async fn copy_filter<S, F, Fut>(
        &mut self,
        stream: u8,
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
        let uncompressed_size = rect.width as usize * rect.height as usize * 3;
        if uncompressed_size == 0 {
            return Ok(());
        };

        let data = self
            .read_tight_data(stream, input, uncompressed_size)
            .await?;
        let image = self.rgb_to_pixels(format, &data[..uncompressed_size]);

        output_func(VncEvent::RawImage(*rect, image)).await?;

        Ok(())
    }

    async fn palette_filter<S, F, Fut>(
        &mut self,
        stream: u8,
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
        let num_colors = input.read_u8().await? as usize + 1;
        if num_colors < 2 {
            return Err(VncError::InvalidImageData);
        }
        let palette_size = num_colors * 3;

        self.palette = initialized_vec(palette_size);
        input.read_exact(&mut self.palette).await?;

        let bpp = if num_colors <= 2 { 1 } else { 8 };
        let row_size = (rect.width as usize * bpp).div_ceil(8);
        let uncompressed_size = rect.height as usize * row_size;

        if uncompressed_size == 0 {
            return Ok(());
        }

        let data = self
            .read_tight_data(stream, input, uncompressed_size)
            .await?;

        if num_colors == 2 {
            self.mono_rect(data, rect, format, output_func).await?
        } else {
            self.palette_rect(data, rect, format, output_func).await?
        }

        Ok(())
    }

    async fn mono_rect<F, Fut>(
        &mut self,
        data: Vec<u8>,
        rect: &Rect,
        format: &PixelFormat,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        // Convert indexed (palette based) image data to RGB
        let total = rect.width as usize * rect.height as usize;
        let mut image = initialized_vec(total * 4);
        let mut offset = 8_usize;
        let mut index = -1_isize;
        let mut dp = 0;
        for i in 0..total {
            if offset == 0 || i % rect.width as usize == 0 {
                offset = 8;
                index += 1;
            }
            offset -= 1;
            let sp = ((data[index as usize] >> offset) & 0x01) as usize * 3;
            let color = self
                .palette
                .get(sp..sp + 3)
                .ok_or(VncError::InvalidImageData)?;
            let true_color = self.to_true_color(format, color);
            image[dp..dp + 4].copy_from_slice(&true_color);
            dp += 4;
        }
        output_func(VncEvent::RawImage(*rect, image)).await?;
        Ok(())
    }

    async fn palette_rect<F, Fut>(
        &mut self,
        data: Vec<u8>,
        rect: &Rect,
        format: &PixelFormat,
        output_func: &F,
    ) -> Result<(), VncError>
    where
        F: Fn(VncEvent) -> Fut,
        Fut: Future<Output = Result<(), VncError>>,
    {
        // Convert indexed (palette based) image data to RGB
        let total = rect.width as usize * rect.height as usize;
        let mut image = initialized_vec(total * 4);
        let mut i = 0;
        let mut dp = 0;
        while i < total {
            let sp = data[i] as usize * 3;
            let color = self
                .palette
                .get(sp..sp + 3)
                .ok_or(VncError::InvalidImageData)?;
            let true_color = self.to_true_color(format, color);
            image[dp..dp + 4].copy_from_slice(&true_color);
            dp += 4;
            i += 1;
        }
        output_func(VncEvent::RawImage(*rect, image)).await?;
        Ok(())
    }

    async fn gradient_filter<S, F, Fut>(
        &mut self,
        stream: u8,
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
        let uncompressed_size = rect.width as usize * rect.height as usize * 3;
        if uncompressed_size == 0 {
            return Ok(());
        };
        let data = self
            .read_tight_data(stream, input, uncompressed_size)
            .await?;
        let mut image = initialized_vec(rect.width as usize * rect.height as usize * 4);

        let row_len = rect.width as usize * 3 + 3;
        let mut row_0 = vec![0_u16; row_len];
        let mut row_1 = vec![0_u16; row_len];
        let max = [format.red_max, format.green_max, format.blue_max];
        let shift = [format.red_shift, format.green_shift, format.blue_shift];
        let mut sp = 0;
        let mut dp = 0;

        for y in 0..rect.height as usize {
            let (this_row, prev_row) = match y & 1 {
                0 => (&mut row_0, &mut row_1),
                1 => (&mut row_1, &mut row_0),
                _ => unreachable!(),
            };
            let mut x = 3;
            while x < row_len {
                let rgb = &data[sp..sp + 3];
                let mut color = 0;
                for index in 0..3 {
                    let d = prev_row[index + x] as i32 + this_row[index + x - 3] as i32
                        - prev_row[index + x - 3] as i32;
                    let converted = if d < 0 {
                        0
                    } else if d > max[index] as i32 {
                        max[index]
                    } else {
                        d as u16
                    };
                    this_row[index + x] = (converted + rgb[index] as u16) & max[index];
                    color |= (this_row[x + index] as u32 & max[index] as u32) << shift[index];
                }
                image[dp..dp + 4].copy_from_slice(&color.to_le_bytes());
                dp += 4;
                sp += 3;
                x += 3;
            }
        }

        output_func(VncEvent::RawImage(*rect, image)).await?;
        Ok(())
    }

    async fn read_tight_data<S>(
        &mut self,
        stream: u8,
        input: &mut S,
        uncompressed_size: usize,
    ) -> Result<Vec<u8>, VncError>
    where
        S: AsyncRead + Unpin,
    {
        let mut data;
        if uncompressed_size < 12 {
            data = initialized_vec(uncompressed_size);
            input.read_exact(&mut data).await?;
        } else {
            let d = self.read_data(input).await?;
            let mut reader = ZlibReader::new(
                self.zlibs[stream as usize]
                    .take()
                    .ok_or(VncError::InvalidImageData)?,
                &d,
            );
            data = initialized_vec(uncompressed_size);
            reader.read_exact(&mut data)?;
            self.zlibs[stream as usize] = Some(reader.into_inner()?);
        };
        Ok(data)
    }

    /// RGB triples to pixels in [format] (ours: one pass, with a straight path for RGBA and BGRA,
    /// the formats the app asks for).
    fn rgb_to_pixels(&self, format: &PixelFormat, rgb: &[u8]) -> Vec<u8> {
        let n = rgb.len() / 3;
        let mut image = vec![0u8; n * 4];
        let order = (format.red_shift, format.green_shift, format.blue_shift, self.alpha_shift, format.big_endian_flag);
        match order {
            (0, 8, 16, 24, 0) => {
                for (dst, src) in image.chunks_exact_mut(4).zip(rgb.chunks_exact(3)) {
                    dst.copy_from_slice(&[src[0], src[1], src[2], 255]);
                }
            }
            (16, 8, 0, 24, 0) => {
                for (dst, src) in image.chunks_exact_mut(4).zip(rgb.chunks_exact(3)) {
                    dst.copy_from_slice(&[src[2], src[1], src[0], 255]);
                }
            }
            _ => {
                for (dst, src) in image.chunks_exact_mut(4).zip(rgb.chunks_exact(3)) {
                    dst.copy_from_slice(&self.to_true_color(format, src));
                }
            }
        }
        image
    }

    fn to_true_color(&self, format: &PixelFormat, color: &[u8]) -> [u8; 4] {
        let alpha = 255;
        // always rgb
        (((color[0] as u32 & format.red_max as u32) << format.red_shift)
            | ((color[1] as u32 & format.green_max as u32) << format.green_shift)
            | ((color[2] as u32 & format.blue_max as u32) << format.blue_shift)
            | ((alpha as u32) << self.alpha_shift))
            .to_le_bytes()
    }
}

use super::*;
use crate::vnc::engine::{PixelFormat, Rect, VncError, VncEvent};
use std::sync::Mutex;

#[tokio::test]
async fn tight_fill_copy_and_palette_modes_preserve_pixels() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 2,
        height: 1,
    };
    for (bytes, expected) in [
        (vec![0x80, 1, 2, 3], vec![1, 2, 3, 255, 1, 2, 3, 255]),
        (vec![0, 1, 2, 3, 4, 5, 6], vec![1, 2, 3, 255, 4, 5, 6, 255]),
        (
            vec![0x40, 1, 1, 1, 2, 3, 4, 5, 6, 0x40],
            vec![1, 2, 3, 255, 4, 5, 6, 255],
        ),
        (
            vec![0x40, 1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 2],
            vec![1, 2, 3, 255, 7, 8, 9, 255],
        ),
    ] {
        let output = Mutex::new(Vec::new());
        TightDecoder::new()
            .decode(
                &PixelFormat::rgba(),
                &rect,
                &mut bytes.as_slice(),
                &|event| {
                    output.lock().unwrap().push(event);
                    async { Ok(()) }
                },
            )
            .await
            .unwrap();
        assert!(
            matches!(&output.into_inner().unwrap()[0], VncEvent::RawImage(_, pixels) if pixels == &expected)
        );
    }
}

#[tokio::test]
async fn tight_rejects_invalid_palette_indexes_and_unsupported_formats() {
    let rect = Rect {
        x: 0,
        y: 0,
        width: 2,
        height: 1,
    };
    for bytes in [
        vec![0x40, 1, 0], // a single color must use Fill
        vec![0x40, 1, 2, 1, 2, 3, 4, 5, 6, 7, 8, 9, 3, 0],
    ] {
        let result = TightDecoder::new()
            .decode(
                &PixelFormat::rgba(),
                &rect,
                &mut bytes.as_slice(),
                &|_| async { Ok(()) },
            )
            .await;
        assert!(matches!(result, Err(VncError::InvalidImageData)));
    }
    let mut format = PixelFormat::rgba();
    format.true_color_flag = 0;
    format.red_shift = 255; // ignored for indexed color, must never be shifted
    let result = TightDecoder::new()
        .decode(&format, &rect, &mut &[][..], &|_| async { Ok(()) })
        .await;
    assert!(matches!(result, Err(VncError::WrongPixelFormat)));
}

#[tokio::test]
async fn cursor_preserves_alpha_mask_and_accepts_empty_shapes() {
    for (width, bytes, expected) in [
        (1, vec![1, 2, 3, 0, 0x80], vec![1, 2, 3, 255]),
        (1, vec![1, 2, 3, 255, 0], vec![1, 2, 3, 0]),
        (0, vec![], vec![]),
    ] {
        let output = Mutex::new(Vec::new());
        CursorDecoder::new()
            .decode(
                &PixelFormat::rgba(),
                &Rect {
                    x: 0,
                    y: 0,
                    width,
                    height: 1,
                },
                &mut bytes.as_slice(),
                &|event| {
                    output.lock().unwrap().push(event);
                    async { Ok(()) }
                },
            )
            .await
            .unwrap();
        assert!(
            matches!(&output.into_inner().unwrap()[0], VncEvent::SetCursor(_, pixels) if pixels == &expected)
        );
    }
}

#[tokio::test]
async fn tight_rejects_component_widths_its_filters_cannot_decode() {
    let mut format = PixelFormat::rgba();
    format.red_max = 65535;
    format.red_shift = 0;
    format.green_max = 127;
    format.green_shift = 16;
    format.blue_max = 1;
    format.blue_shift = 23;
    assert!(format.validate().is_ok());
    let result = TightDecoder::new()
        .decode(
            &format,
            &Rect {
                x: 0,
                y: 0,
                width: 1,
                height: 1,
            },
            &mut &[0x40, 2, 255, 255, 255][..],
            &|_| async { Ok(()) },
        )
        .await;
    assert!(matches!(result, Err(VncError::WrongPixelFormat)));
}

/// Tight JPEG (ours): the rectangle's JPEG is decoded (zune-jpeg) into the pixel format asked
/// for. The test picture (made with Pillow, quality 95, no chroma subsampling) is 16 x 8: red on
/// the left half, blue on the right.
#[tokio::test]
async fn tight_jpeg_is_decoded_into_the_pixel_format() {
    let jpeg = include_bytes!("testdata/tight_test.jpg");
    let rect = Rect { x: 0, y: 0, width: 16, height: 8 };
    let mut bytes = vec![0x90]; // JPEG compression
    let n = jpeg.len();
    bytes.extend([(n & 0x7f) as u8 | 0x80, (n >> 7) as u8]);
    bytes.extend_from_slice(jpeg);
    for (format, red_at) in [(PixelFormat::rgba(), 0), (PixelFormat::bgra(), 2)] {
        let output = Mutex::new(Vec::new());
        TightDecoder::new()
            .decode(&format, &rect, &mut bytes.as_slice(), &|event| {
                output.lock().unwrap().push(event);
                async { Ok(()) }
            })
            .await
            .unwrap();
        let output = output.into_inner().unwrap();
        let VncEvent::RawImage(_, pixels) = &output[0] else { panic!("{output:?}") };
        assert_eq!(pixels.len(), 16 * 8 * 4);
        let near = |a: u8, b: u8| a.abs_diff(b) <= 12;
        for (i, px) in pixels.chunks_exact(4).enumerate() {
            let (r, b) = (px[red_at], px[2 - red_at]);
            let left = i % 16 < 8;
            // Away from the edge, where JPEG rings.
            if (i % 16) % 8 >= 2 && (i % 16) % 8 <= 5 {
                assert!(near(r, if left { 200 } else { 40 }) && near(b, if left { 40 } else { 200 }), "pixel {i}: {px:?}");
            }
            assert_eq!(px[3], 255);
        }
    }
    // A JPEG of another size than its rectangle is refused.
    let wrong = Rect { width: 8, ..rect };
    let result = TightDecoder::new()
        .decode(&PixelFormat::rgba(), &wrong, &mut bytes.as_slice(), &|_| async { Ok(()) })
        .await;
    assert!(result.is_err());
}

#[tokio::test]
async fn trle_tiles_follow_the_header_directly_sixteen_pixels_wide() {
    // RFC 6143 7.7.5: no length, no zlib; tiles of 16 x 16. A 20 x 1 rectangle is two solid
    // tiles (16 and 4 wide), each a palette of one 3-byte CPIXEL.
    let rect = Rect { x: 0, y: 0, width: 20, height: 1 };
    let bytes = [1u8, 10, 20, 30, 1, 40, 50, 60];
    let mut input = &bytes[..];
    let output = Mutex::new(Vec::new());
    TrleDecoder::new()
        .decode(&PixelFormat::rgba(), &rect, &mut input, &|event| {
            output.lock().unwrap().push(event);
            async { Ok(()) }
        })
        .await
        .unwrap();
    assert!(input.is_empty(), "{} bytes left", input.len());
    let mut pixels = vec![0u8; 20 * 4];
    for e in output.into_inner().unwrap() {
        if let VncEvent::RawImage(r, p) = e {
            for (i, px) in p.chunks_exact(4).enumerate() {
                let at = (r.x as usize + i) * 4;
                pixels[at..at + 3].copy_from_slice(&px[..3]);
            }
        }
    }
    assert_eq!(&pixels[..3], &[10, 20, 30]);
    assert_eq!(&pixels[15 * 4..15 * 4 + 3], &[10, 20, 30]);
    assert_eq!(&pixels[16 * 4..16 * 4 + 3], &[40, 50, 60]);
    assert_eq!(&pixels[19 * 4..19 * 4 + 3], &[40, 50, 60]);
}

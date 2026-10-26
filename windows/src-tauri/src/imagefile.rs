//! Image files: encoding captures with their DPI, reading size and scale cheaply from headers, and the
//! CF_DIB form for the clipboard. PNG captures carry `pHYs` = 96 × scale DPI, like the macOS app.

use std::{fs::File, io::Read, path::Path};

use image::{
    codecs::{
        jpeg::{JpegEncoder, PixelDensity},
        png::{CompressionType, FilterType, PngEncoder},
    },
    ExtendedColorType, ImageEncoder, ImageReader,
};

const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const INCH_IN_METRES: f64 = 0.0254;

/// One PNG chunk: type, data and the byte range of the whole chunk.
struct Chunk<'a> {
    kind: &'a [u8],
    data: &'a [u8],
    range: std::ops::Range<usize>,
}

/// Walks PNG chunks; stops at the first malformed one.
fn chunks(png: &[u8]) -> Option<impl Iterator<Item = Chunk<'_>>> {
    if png.len() < 8 || &png[..8] != PNG_SIGNATURE {
        return None;
    }
    let mut pos = 8;
    Some(std::iter::from_fn(move || {
        let header = png.get(pos..pos + 8)?;
        let len = u32::from_be_bytes(header[..4].try_into().ok()?) as usize;
        let start = pos;
        let end = pos.checked_add(12)?.checked_add(len)?;
        if end > png.len() {
            return None;
        }
        pos = end;
        Some(Chunk { kind: &png[start + 4..start + 8], data: &png[start + 8..start + 8 + len], range: start..end })
    }))
}

fn chunk_bytes(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 12);
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc = crc32fast::Hasher::new();
    crc.update(kind);
    crc.update(data);
    out.extend_from_slice(&crc.finalize().to_be_bytes());
    out
}

/// Pixel size from IHDR.
pub fn png_size(png: &[u8]) -> Option<(u32, u32)> {
    let ihdr = chunks(png)?.next().filter(|c| c.kind == b"IHDR" && c.data.len() >= 8)?;
    Some((u32::from_be_bytes(ihdr.data[..4].try_into().ok()?), u32::from_be_bytes(ihdr.data[4..8].try_into().ok()?)))
}

/// Horizontal DPI from `pHYs`, when the unit is metres.
pub fn png_dpi(png: &[u8]) -> Option<f64> {
    let phys = chunks(png)?.take_while(|c| c.kind != b"IDAT").find(|c| c.kind == b"pHYs")?;
    if phys.data.len() != 9 || phys.data[8] != 1 {
        return None;
    }
    let ppm = u32::from_be_bytes(phys.data[..4].try_into().ok()?);
    (ppm > 0).then_some(ppm as f64 * INCH_IN_METRES)
}

/// The same PNG with exactly one `pHYs` chunk for `dpi`, right after IHDR. None if it is not a PNG.
pub fn with_png_dpi(png: &[u8], dpi: f64) -> Option<Vec<u8>> {
    let ppm = (dpi / INCH_IN_METRES).round() as u32;
    let mut data = Vec::with_capacity(9);
    data.extend_from_slice(&ppm.to_be_bytes());
    data.extend_from_slice(&ppm.to_be_bytes());
    data.push(1);
    let mut out = Vec::with_capacity(png.len() + 21);
    out.extend_from_slice(PNG_SIGNATURE);
    let mut saw_ihdr = false;
    for chunk in chunks(png)? {
        if chunk.kind == b"pHYs" {
            continue;
        }
        out.extend_from_slice(&png[chunk.range.clone()]);
        if chunk.kind == b"IHDR" {
            saw_ihdr = true;
            out.extend_from_slice(&chunk_bytes(b"pHYs", &data));
        }
    }
    saw_ihdr.then_some(out)
}

/// DPI from a JPEG's JFIF header.
pub fn jpeg_dpi(jpeg: &[u8]) -> Option<f64> {
    if jpeg.len() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8 {
        return None;
    }
    let mut pos = 2;
    while pos + 4 <= jpeg.len() && jpeg[pos] == 0xFF {
        let marker = jpeg[pos + 1];
        let len = u16::from_be_bytes([jpeg[pos + 2], jpeg[pos + 3]]) as usize;
        let seg = jpeg.get(pos + 4..pos + 2 + len)?;
        if marker == 0xE0 && seg.len() >= 12 && &seg[..5] == b"JFIF\0" {
            let density = u16::from_be_bytes([seg[8], seg[9]]) as f64;
            return match seg[7] {
                1 if density > 0.0 => Some(density),
                2 if density > 0.0 => Some(density * 2.54),
                _ => None,
            };
        }
        if marker == 0xDA {
            break;
        }
        pos += 2 + len;
    }
    None
}

/// Pixels per point from DPI (96 DPI = 1). Captures are never smaller than their on-screen size.
pub fn scale_from_dpi(dpi: Option<f64>) -> f64 {
    match dpi {
        Some(d) if d.is_finite() && d > 0.0 => ((d / 96.0) * 100.0).round().max(100.0) / 100.0,
        _ => 1.0,
    }
}

pub fn dpi_for_scale(scale: f64) -> f64 {
    96.0 * if scale.is_finite() && scale > 0.0 { scale } else { 1.0 }
}

/// Size in pixels and the scale stored in the file. Reads only the header where it can.
pub fn info(path: &Path) -> Option<(u32, u32, f64)> {
    let mut head = Vec::with_capacity(64 * 1024);
    File::open(path).ok()?.take(64 * 1024).read_to_end(&mut head).ok()?;
    if let Some((w, h)) = png_size(&head) {
        return Some((w, h, scale_from_dpi(png_dpi(&head))));
    }
    let (w, h) = ImageReader::open(path).ok()?.with_guessed_format().ok()?.into_dimensions().ok()?;
    Some((w, h, scale_from_dpi(jpeg_dpi(&head))))
}

pub fn encode_png(rgba: &[u8], width: u32, height: u32, scale: f64) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    // Fast keeps the capture-to-shelf time short; screenshots still compress well.
    PngEncoder::new_with_quality(&mut out, CompressionType::Fast, FilterType::Adaptive)
        .write_image(rgba, width, height, ExtendedColorType::Rgba8)
        .map_err(|e| e.to_string())?;
    with_png_dpi(&out, dpi_for_scale(scale)).ok_or_else(|| "the PNG encoder wrote no IHDR".into())
}

pub fn encode_jpeg(rgba: &[u8], width: u32, height: u32, scale: f64, quality: f64) -> Result<Vec<u8>, String> {
    let rgb: Vec<u8> = rgba.chunks_exact(4).flat_map(|p| [p[0], p[1], p[2]]).collect();
    let mut out = Vec::new();
    let mut encoder = JpegEncoder::new_with_quality(&mut out, (quality * 100.0).round().clamp(1.0, 100.0) as u8);
    encoder.set_pixel_density(PixelDensity::dpi(dpi_for_scale(scale).round() as u16));
    encoder.write_image(&rgb, width, height, ExtendedColorType::Rgb8).map_err(|e| e.to_string())?;
    Ok(out)
}

/// Any supported image as RGBA pixels.
pub fn decode_rgba(bytes: &[u8]) -> Result<image::RgbaImage, String> {
    Ok(image::load_from_memory(bytes).map_err(|e| e.to_string())?.into_rgba8())
}

/// A packed CF_DIB: BITMAPINFOHEADER + bottom-up 32-bit BGRA rows. Colour is composited over white so
/// apps that ignore alpha show transparent corners as white instead of black.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn dib_from_rgba(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let row = width as usize * 4;
    let mut out = Vec::with_capacity(40 + row * height as usize);
    out.extend_from_slice(&40u32.to_le_bytes());
    out.extend_from_slice(&(width as i32).to_le_bytes());
    out.extend_from_slice(&(height as i32).to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&32u16.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    out.extend_from_slice(&((row * height as usize) as u32).to_le_bytes());
    out.extend_from_slice(&[0u8; 16]); // resolution and palette fields
    for y in (0..height as usize).rev() {
        for p in rgba[y * row..(y + 1) * row].chunks_exact(4) {
            let a = p[3] as u32;
            let over_white = |c: u8| ((c as u32 * a + 255 * (255 - a) + 127) / 255) as u8;
            out.extend_from_slice(&[over_white(p[2]), over_white(p[1]), over_white(p[0]), p[3]]);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(w: u32, h: u32) -> Vec<u8> {
        (0..w * h).flat_map(|i| [(i * 7) as u8, (i * 13) as u8, (i * 29) as u8, 255]).collect()
    }

    #[test]
    fn png_carries_96_times_scale_dpi() {
        for scale in [1.0, 1.25, 1.5, 1.75, 2.0, 3.0] {
            let png = encode_png(&sample(5, 3), 5, 3, scale).unwrap();
            assert_eq!(png_size(&png), Some((5, 3)));
            let dpi = png_dpi(&png).unwrap();
            assert!((dpi - 96.0 * scale).abs() < 0.05, "{scale}: {dpi}");
            assert_eq!(scale_from_dpi(Some(dpi)), scale);
            let decoded = decode_rgba(&png).unwrap();
            assert_eq!(decoded.as_raw(), &sample(5, 3));
        }
    }

    #[test]
    fn replacing_phys_keeps_one_chunk_and_valid_crcs() {
        let png = encode_png(&sample(4, 4), 4, 4, 2.0).unwrap();
        let again = with_png_dpi(&png, 120.0).unwrap();
        assert_eq!(chunks(&again).unwrap().filter(|c| c.kind == b"pHYs").count(), 1);
        assert_eq!(scale_from_dpi(png_dpi(&again)), 1.25);
        for c in chunks(&again).unwrap() {
            let stored = u32::from_be_bytes(again[c.range.end - 4..c.range.end].try_into().unwrap());
            let mut crc = crc32fast::Hasher::new();
            crc.update(c.kind);
            crc.update(c.data);
            assert_eq!(stored, crc.finalize());
        }
        assert!(decode_rgba(&again).is_ok());
    }

    #[test]
    fn not_a_png() {
        assert_eq!(with_png_dpi(b"GIF89a", 96.0), None);
        assert_eq!(png_dpi(b""), None);
        assert_eq!(png_size(b"\x89PNG\r\n\x1a\n\0\0"), None);
    }

    #[test]
    fn jpeg_density_round_trips() {
        let jpeg = encode_jpeg(&sample(8, 8), 8, 8, 1.5, 0.9).unwrap();
        assert_eq!(jpeg_dpi(&jpeg), Some(144.0));
        assert_eq!(scale_from_dpi(jpeg_dpi(&jpeg)), 1.5);
        assert_eq!(decode_rgba(&jpeg).unwrap().dimensions(), (8, 8));
    }

    #[test]
    fn scale_fallbacks() {
        assert_eq!(scale_from_dpi(None), 1.0);
        assert_eq!(scale_from_dpi(Some(72.0)), 1.0);
        assert_eq!(scale_from_dpi(Some(0.0)), 1.0);
        assert_eq!(scale_from_dpi(Some(192.0)), 2.0);
    }

    #[test]
    fn info_reads_png_and_jpeg_files() {
        let dir = std::env::temp_dir().join(format!("snipeshot-info-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = dir.join("a.png");
        std::fs::write(&png, encode_png(&sample(6, 2), 6, 2, 2.0).unwrap()).unwrap();
        assert_eq!(info(&png), Some((6, 2, 2.0)));
        let jpg = dir.join("b.jpg");
        std::fs::write(&jpg, encode_jpeg(&sample(3, 7), 3, 7, 1.25, 0.8).unwrap()).unwrap();
        assert_eq!(info(&jpg), Some((3, 7, 1.25)));
        assert_eq!(info(&dir.join("missing.png")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dib_is_bottom_up_bgra_over_white() {
        // Top row red opaque, bottom row fully transparent black.
        let rgba = [255, 0, 0, 255, 0, 0, 0, 0];
        let dib = dib_from_rgba(&rgba, 1, 2);
        assert_eq!(dib.len(), 40 + 8);
        assert_eq!(i32::from_le_bytes(dib[8..12].try_into().unwrap()), 2);
        assert_eq!(&dib[40..44], &[255, 255, 255, 0]);
        assert_eq!(&dib[44..48], &[0, 0, 255, 255]);
    }
}

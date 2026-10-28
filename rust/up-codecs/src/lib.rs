//! C API over oxipng and quantizr. All exported symbols are prefixed `up_`.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::slice;

/// Status codes returned by every `up_*` function.
#[allow(non_camel_case_types)]
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpStatus {
    UP_OK = 0,
    UP_INVALID_ARGUMENT = 1,
    UP_DECODE_FAILED = 2,
    UP_ENCODE_FAILED = 3,
    UP_QUANTIZE_FAILED = 4,
    UP_PANIC = 5,
}

use UpStatus::*;

const MAX_LEVEL: u8 = 6;

/// `fail` is the status reported when oxipng rejects the data: the input was
/// not a decodable PNG (public entry) or our own encoder output was (quantize).
/// `strip` is `None` for the public entry, whose caller already chose the
/// metadata to keep (§7.3), and `Safe` for quantizer output.
fn optimize(png: &[u8], level: u8, strip: oxipng::StripChunks, fail: UpStatus) -> Result<Vec<u8>, UpStatus> {
    let mut opts = oxipng::Options::from_preset(level);
    opts.strip = strip;
    oxipng::optimize_from_memory(png, &opts).map_err(|_| fail)
}

fn quantize_to_png(
    rgba: &[u8],
    width: usize,
    height: usize,
    stride: usize,
    max_colors: i32,
    dither: f32,
    level: u8,
) -> Result<Vec<u8>, UpStatus> {
    let row = width * 4;
    // Quantizr wants tightly packed rows.
    let packed;
    let pixels: &[u8] = if stride == row {
        &rgba[..row * height]
    } else {
        let mut v = Vec::with_capacity(row * height);
        for y in 0..height {
            v.extend_from_slice(&rgba[y * stride..y * stride + row]);
        }
        packed = v;
        &packed
    };
    let image = quantizr::Image::new(pixels, width, height).map_err(|_| UP_QUANTIZE_FAILED)?;
    let mut opts = quantizr::Options::default();
    opts.set_max_colors(max_colors).map_err(|_| UP_INVALID_ARGUMENT)?;
    let mut result = quantizr::QuantizeResult::quantize(&image, &opts);
    result.set_dithering_level(dither).map_err(|_| UP_INVALID_ARGUMENT)?;
    let mut idx = vec![0u8; width * height];
    result.remap_image(&image, &mut idx).map_err(|_| UP_QUANTIZE_FAILED)?;
    let pal = result.get_palette();
    let n = pal.count as usize;
    let rgb: Vec<u8> = pal.entries[..n].iter().flat_map(|e| [e.r, e.g, e.b]).collect();
    let alpha: Vec<u8> = pal.entries[..n].iter().map(|e| e.a).collect();

    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, width as u32, height as u32);
        enc.set_color(png::ColorType::Indexed);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_palette(rgb);
        if alpha.iter().any(|&a| a != 255) {
            enc.set_trns(alpha);
        }
        enc.write_header()
            .and_then(|mut w| w.write_image_data(&idx))
            .map_err(|_| UP_ENCODE_FAILED)?;
    }
    optimize(&out, level, oxipng::StripChunks::Safe, UP_ENCODE_FAILED)
}

/// Hands a Vec to the caller through the out-params.
///
/// # Safety
/// `out_data` and `out_len` must be valid for writes.
unsafe fn emit(v: Vec<u8>, out_data: *mut *mut u8, out_len: *mut usize) {
    let boxed = v.into_boxed_slice();
    *out_len = boxed.len();
    *out_data = Box::into_raw(boxed) as *mut u8;
}

fn guard(f: impl FnOnce() -> UpStatus) -> UpStatus {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(UP_PANIC)
}

/// Losslessly optimizes a PNG held in memory (oxipng). Keeps every ancillary chunk.
/// `level` is 0..=6. On `UP_OK` the caller owns `*out_data` and must release it
/// with `up_buffer_free(*out_data, *out_len)`. On error the out-params are
/// set to NULL / 0.
///
/// # Safety
/// `png_data` must point to `png_len` readable bytes; `out_data` and `out_len`
/// must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn up_png_optimize(
    png_data: *const u8,
    png_len: usize,
    level: u8,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> UpStatus {
    if out_data.is_null() || out_len.is_null() {
        return UP_INVALID_ARGUMENT;
    }
    *out_data = std::ptr::null_mut();
    *out_len = 0;
    guard(|| {
        if png_data.is_null() || png_len == 0 || level > MAX_LEVEL {
            return UP_INVALID_ARGUMENT;
        }
        let input = slice::from_raw_parts(png_data, png_len);
        match optimize(input, level, oxipng::StripChunks::None, UP_DECODE_FAILED) {
            Ok(v) => {
                emit(v, out_data, out_len);
                UP_OK
            }
            Err(s) => s,
        }
    })
}

/// Quantizes 8-bit RGBA pixels (non-premultiplied) to an indexed PNG
/// (PLTE, plus tRNS when any palette entry is not opaque), then runs oxipng
/// at `level` (0..=6). `stride` is the row pitch in bytes; pass 0 for tightly
/// packed rows (`width * 4`). `max_colors` is 2..=256, `dither` is 0.0..=1.0.
/// Output ownership is as for `up_png_optimize`.
///
/// # Safety
/// `rgba` must point to at least `stride * (height - 1) + width * 4` readable
/// bytes; `out_data` and `out_len` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn up_png_quantize(
    rgba: *const u8,
    width: u32,
    height: u32,
    stride: usize,
    max_colors: i32,
    dither: f32,
    level: u8,
    out_data: *mut *mut u8,
    out_len: *mut usize,
) -> UpStatus {
    if out_data.is_null() || out_len.is_null() {
        return UP_INVALID_ARGUMENT;
    }
    *out_data = std::ptr::null_mut();
    *out_len = 0;
    guard(|| {
        if rgba.is_null()
            || width == 0
            || height == 0
            || !(2..=256).contains(&max_colors)
            || !(0.0..=1.0).contains(&dither)
            || level > MAX_LEVEL
        {
            return UP_INVALID_ARGUMENT;
        }
        let (w, h) = (width as usize, height as usize);
        let Some(row) = w.checked_mul(4) else { return UP_INVALID_ARGUMENT };
        let stride = if stride == 0 { row } else { stride };
        if stride < row {
            return UP_INVALID_ARGUMENT;
        }
        let Some(total) = (h - 1).checked_mul(stride).and_then(|n| n.checked_add(row)) else {
            return UP_INVALID_ARGUMENT;
        };
        if w.checked_mul(h).is_none() {
            return UP_INVALID_ARGUMENT;
        }
        let input = slice::from_raw_parts(rgba, total);
        match quantize_to_png(input, w, h, stride, max_colors, dither, level) {
            Ok(v) => {
                emit(v, out_data, out_len);
                UP_OK
            }
            Err(s) => s,
        }
    })
}

/// Frees a buffer returned by `up_png_optimize` / `up_png_quantize`.
/// `data` may be NULL (no-op); `len` must be the length returned with it.
///
/// # Safety
/// `data`/`len` must be exactly a pair returned by this library, freed once.
#[no_mangle]
pub unsafe extern "C" fn up_buffer_free(data: *mut u8, len: usize) {
    if data.is_null() {
        return;
    }
    drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, len)));
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr::null_mut;

    fn gradient(w: u32, h: u32, alpha: bool) -> Vec<u8> {
        let mut v = Vec::new();
        for y in 0..h {
            for x in 0..w {
                let a = if alpha { (x * 255 / (w - 1)) as u8 } else { 255 };
                v.extend_from_slice(&[(x * 255 / (w - 1)) as u8, (y * 255 / (h - 1)) as u8, 128, a]);
            }
        }
        v
    }

    fn encode_rgba(w: u32, h: u32, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut e = png::Encoder::new(&mut out, w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(data).unwrap();
        out
    }

    fn decode_info(data: &[u8]) -> (png::ColorType, u32, u32, bool) {
        let r = png::Decoder::new(std::io::Cursor::new(data)).read_info().unwrap();
        let i = r.info();
        (i.color_type, i.width, i.height, i.trns.is_some())
    }

    unsafe fn take(data: *mut u8, len: usize) -> Vec<u8> {
        let v = slice::from_raw_parts(data, len).to_vec();
        up_buffer_free(data, len);
        v
    }

    #[test]
    fn optimize_returns_valid_smaller_or_equal_png() {
        let src = encode_rgba(64, 64, &gradient(64, 64, false));
        let (mut p, mut n) = (null_mut(), 0usize);
        let s = unsafe { up_png_optimize(src.as_ptr(), src.len(), 2, &mut p, &mut n) };
        assert_eq!(s, UP_OK);
        let out = unsafe { take(p, n) };
        assert!(out.len() <= src.len());
        let (_, w, h, _) = decode_info(&out);
        assert_eq!((w, h), (64, 64));
    }

    #[test]
    fn quantize_returns_indexed_png_with_trns() {
        let px = gradient(64, 64, true);
        let (mut p, mut n) = (null_mut(), 0usize);
        let s = unsafe { up_png_quantize(px.as_ptr(), 64, 64, 0, 32, 1.0, 2, &mut p, &mut n) };
        assert_eq!(s, UP_OK);
        let out = unsafe { take(p, n) };
        let (ct, w, h, trns) = decode_info(&out);
        assert_eq!(ct, png::ColorType::Indexed);
        assert_eq!((w, h), (64, 64));
        assert!(trns);
    }

    #[test]
    fn quantize_honors_stride() {
        let tight = gradient(64, 64, false);
        let mut padded = Vec::new();
        for row in tight.chunks(64 * 4) {
            padded.extend_from_slice(row);
            padded.extend_from_slice(&[0xEE; 16]);
        }
        let run = |buf: &[u8], stride| {
            let (mut p, mut n) = (null_mut(), 0usize);
            let s = unsafe { up_png_quantize(buf.as_ptr(), 64, 64, stride, 16, 0.0, 1, &mut p, &mut n) };
            assert_eq!(s, UP_OK);
            unsafe { take(p, n) }
        };
        assert_eq!(run(&tight, 0), run(&padded, 64 * 4 + 16));
    }

    #[test]
    fn invalid_arguments_are_rejected() {
        let px = gradient(4, 4, false);
        let (mut p, mut n) = (null_mut(), 0usize);
        unsafe {
            assert_eq!(up_png_optimize(std::ptr::null(), 10, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_optimize(px.as_ptr(), px.len(), 7, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_optimize(px.as_ptr(), px.len(), 2, std::ptr::null_mut(), &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_optimize(px.as_ptr(), px.len(), 2, &mut p, &mut n), UP_DECODE_FAILED);
            assert!(p.is_null() && n == 0);
            assert_eq!(up_png_quantize(px.as_ptr(), 4, 4, 0, 1, 1.0, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_quantize(px.as_ptr(), 4, 4, 0, 257, 1.0, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_quantize(px.as_ptr(), 4, 4, 0, 16, 1.5, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_quantize(px.as_ptr(), 4, 4, 8, 16, 1.0, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_quantize(px.as_ptr(), 0, 4, 0, 16, 1.0, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            assert_eq!(up_png_quantize(std::ptr::null(), 4, 4, 0, 16, 1.0, 2, &mut p, &mut n), UP_INVALID_ARGUMENT);
            up_buffer_free(std::ptr::null_mut(), 0);
        }
    }
}

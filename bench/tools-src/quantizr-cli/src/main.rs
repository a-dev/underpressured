// Usage: quantizr-cli in.png out.png --max-colors N --dither LEVEL
// LEVEL is 0.0..=1.0 (quantizr dithering level). Output is an 8-bit indexed PNG.
use std::{env, fs::File, io::BufWriter, process::exit};

type Res<T> = Result<T, Box<dyn std::error::Error>>;

fn load_rgba(path: &str) -> Res<(Vec<u8>, usize, usize)> {
    let mut dec = png::Decoder::new(std::io::BufReader::new(File::open(path)?));
    dec.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = dec.read_info()?;
    let mut buf = vec![0; reader.output_buffer_size().ok_or("image too large")?];
    let info = reader.next_frame(&mut buf)?;
    let data = &buf[..info.buffer_size()];
    let rgba = match info.color_type {
        png::ColorType::Rgba => data.to_vec(),
        png::ColorType::Rgb => data.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        png::ColorType::GrayscaleAlpha => data.chunks_exact(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        png::ColorType::Grayscale => data.iter().flat_map(|&g| [g, g, g, 255]).collect(),
        png::ColorType::Indexed => return Err("indexed not expanded".into()),
    };
    Ok((rgba, info.width as usize, info.height as usize))
}

fn run() -> Res<()> {
    let mut pos = Vec::new();
    let (mut colors, mut dither) = (256i32, 1.0f32);
    let mut it = env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--max-colors" => colors = it.next().ok_or("missing value")?.parse()?,
            "--dither" => dither = it.next().ok_or("missing value")?.parse()?,
            _ => pos.push(a),
        }
    }
    if pos.len() != 2 {
        return Err("usage: quantizr-cli in.png out.png --max-colors N --dither LEVEL".into());
    }
    let (rgba, w, h) = load_rgba(&pos[0])?;
    let image = quantizr::Image::new(&rgba, w, h)?;
    let mut opts = quantizr::Options::default();
    opts.set_max_colors(colors)?;
    let mut result = quantizr::QuantizeResult::quantize(&image, &opts);
    result.set_dithering_level(dither)?;
    let mut idx = vec![0u8; w * h];
    result.remap_image(&image, &mut idx)?;
    let pal = result.get_palette();
    let n = pal.count as usize;
    let rgb: Vec<u8> = pal.entries[..n].iter().flat_map(|e| [e.r, e.g, e.b]).collect();
    let trns: Vec<u8> = pal.entries[..n].iter().map(|e| e.a).collect();
    let mut enc = png::Encoder::new(BufWriter::new(File::create(&pos[1])?), w as u32, h as u32);
    enc.set_color(png::ColorType::Indexed);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_palette(rgb);
    enc.set_trns(trns);
    enc.write_header()?.write_image_data(&idx)?;
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("quantizr-cli: {e}");
        exit(1);
    }
}

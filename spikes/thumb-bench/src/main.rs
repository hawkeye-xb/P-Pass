use anyhow::{Context, Result};
use clap::Parser;
use rayon::prelude::*;
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

/// Thumbnail pipeline benchmark — M0 S-05 spike.
///
/// Walks an input directory, converts every JPEG / HEIC / MP4 to a
/// 256px‑longest‑edge JPEG, writes them to --output, and reports
/// timing and failure statistics as JSON on stdout.
#[derive(Parser)]
#[command(name = "thumb-bench")]
struct Args {
    /// Input directory (mixed JPEG / HEIC / MP4)
    #[arg(short, long)]
    input: PathBuf,

    /// Output directory (will be created)
    #[arg(short, long)]
    output: PathBuf,

    /// Longest‑edge pixel size (default 256)
    #[arg(short, long, default_value = "256")]
    size: u32,

    /// JPEG quality 1–100 (default 85)
    #[arg(short = 'q', long, default_value = "85")]
    quality: u8,

    /// Path to the mp4frame helper binary (optional; default helpers/mp4frame)
    #[arg(long, default_value = "helpers/mp4frame")]
    mp4frame: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
enum Kind {
    Jpeg,
    Heic,
    Mp4,
}

impl Kind {
    fn from_path(path: &Path) -> Option<Self> {
        match path.extension()?.to_str()?.to_lowercase().as_str() {
            "jpg" | "jpeg" => Some(Kind::Jpeg),
            "heic" => Some(Kind::Heic),
            "mp4" => Some(Kind::Mp4),
            _ => None,
        }
    }
}

#[derive(Debug, Serialize)]
struct Output {
    files: usize,
    ok: usize,
    failed: usize,
    failed_by_type: HashMap<Kind, usize>,
    total_s: f64,
    peak_rss_mb: f64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    fs::create_dir_all(&args.output)?;

    // Collect input files
    let files: Vec<PathBuf> = walkdir::WalkDir::new(&args.input)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .collect();

    if files.is_empty() {
        anyhow::bail!("No files in {}", args.input.display());
    }

    eprintln!("Found {} files", files.len());

    // Compile mp4frame if needed
    if files.iter().any(|f| Kind::from_path(f) == Some(Kind::Mp4)) {
        ensure_mp4frame(&args.mp4frame)?;
    }

    let started = Instant::now();
    let (results_by_type, _by_type_count): (Vec<(Kind, bool)>, HashMap<Kind, usize>) =
        files
            .par_iter()
            .flat_map(|path| {
                let kind = match Kind::from_path(path) {
                    Some(k) => k,
                    None => return None,
                };
                let out_name = output_name(path, kind);
                let out_path = args.output.join(&out_name);
                let ok = process_one(path, &out_path, args.size, args.quality, kind, &args.mp4frame);
                eprintln!("    {:?} {} → {}", kind, path.file_name().unwrap().to_string_lossy(), if ok { "✓" } else { "✗" });
                Some((kind, ok))
            })
            .fold(
                || (Vec::new(), HashMap::new()),
                |(mut v, mut m), (k, ok)| {
                    v.push((k, ok));
                    *m.entry(k).or_insert(0) += 1;
                    (v, m)
                },
            )
            .reduce(
                || (Vec::new(), HashMap::new()),
                |(mut va, mut ma), (vb, mb)| {
                    va.extend(vb);
                    for (k, v) in mb {
                        *ma.entry(k).or_insert(0) += v;
                    }
                    (va, ma)
                },
            );

    let elapsed = started.elapsed().as_secs_f64();
    let ok_count = results_by_type.iter().filter(|(_, ok)| *ok).count();
    let failed_count = results_by_type.len() - ok_count;

    // Estimate peak RSS (best-effort via `ps`)
    let peak_rss_mb = peak_rss();

    let out = Output {
        files: results_by_type.len(),
        ok: ok_count,
        failed: failed_count,
        failed_by_type: results_by_type
            .into_iter()
            .filter(|(_, ok)| !*ok)
            .fold(HashMap::new(), |mut acc, (k, _)| {
                *acc.entry(k).or_insert(0) += 1;
                acc
            }),
        total_s: elapsed,
        peak_rss_mb,
    };

    // Write JSON to stdout
    println!("{}", serde_json::to_string_pretty(&out)?);

    if failed_count > 0 {
        eprintln!("WARNING: {failed_count} failures");
    }
    Ok(())
}

// ── per‑file processing ────────────────────────────────────────────────

fn process_one(
    input: &Path,
    output: &Path,
    size: u32,
    quality: u8,
    kind: Kind,
    mp4frame: &Path,
) -> bool {
    match kind {
        Kind::Jpeg => process_jpeg(input, output, size, quality),
        Kind::Heic => process_heic(input, output, size, quality),
        Kind::Mp4 => process_mp4(input, output, size, quality, mp4frame),
    }
}

fn process_jpeg(input: &Path, output: &Path, size: u32, quality: u8) -> bool {
    let Ok(img) = image::open(input) else { return false };
    let thumb = img.thumbnail(size, size);
    thumb.save_with_format(output, image::ImageFormat::Jpeg).is_ok()
}

fn process_heic(input: &Path, output: &Path, size: u32, quality: u8) -> bool {
    // sips → JPEG temp file → resize
    let tmp = temp_path("heic", "jpg");
    let status = Command::new("sips")
        .args([
            "-s", "format", "jpeg",
            "-s", "formatOptions", &quality.to_string(),
            input.to_str().unwrap(),
            "--out", tmp.to_str().unwrap(),
        ])
        .status();
    if status.map_or(true, |s| !s.success()) {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    let ok = process_jpeg(&tmp, output, size, quality);
    let _ = fs::remove_file(&tmp);
    ok
}

fn process_mp4(input: &Path, output: &Path, size: u32, quality: u8, mp4frame: &Path) -> bool {
    let tmp = temp_path("mp4", "jpg");
    let status = Command::new(mp4frame)
        .arg(input)
        .arg(&tmp)
        .status();
    if status.map_or(true, |s| !s.success()) {
        let _ = fs::remove_file(&tmp);
        return false;
    }
    let ok = process_jpeg(&tmp, output, size, quality);
    let _ = fs::remove_file(&tmp);
    ok
}

// ── helpers ─────────────────────────────────────────────────────────────

fn output_name(input: &Path, kind: Kind) -> String {
    let stem = input.file_stem().unwrap_or_default().to_string_lossy();
    match kind {
        Kind::Mp4 => format!("{}.jpg", stem),
        _ => format!("{}.jpg", stem),
    }
}

fn temp_path(prefix: &str, ext: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("thumb-bench-{}-{}-{}.{}", prefix, std::process::id(), n, ext))
}

fn peak_rss() -> f64 {
    // macOS `ps` fallback: get RSS of current process in MB
    let pid = std::process::id();
    if let Ok(out) = Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output() {
        if let Ok(s) = String::from_utf8(out.stdout) {
            if let Ok(kb) = s.trim().parse::<f64>() {
                return kb / 1024.0;
            }
        }
    }
    f64::NAN
}

fn ensure_mp4frame(mp4frame: &Path) -> Result<()> {
    if mp4frame.exists() {
        return Ok(());
    }
    eprintln!("Compiling mp4frame helper…");
    let src = Path::new("helpers/mp4frame.swift");
    if !src.exists() {
        anyhow::bail!("mp4frame source not found at {}", src.display());
    }
    let status = Command::new("swiftc")
        .args(["-O", "-o"])
        .arg(mp4frame)
        .arg(src)
        .status()
        .context("swiftc failed to compile mp4frame")?;
    if !status.success() {
        anyhow::bail!("swiftc returned non-zero");
    }
    Ok(())
}

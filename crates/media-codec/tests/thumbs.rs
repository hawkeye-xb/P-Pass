//! T-013 acceptance: thumbnails for every product format, placeholder on
//! corruption (never a panic), pool completes everything submitted.

use std::fs;
use std::path::{Path, PathBuf};

use image::GenericImageView;
use media_codec::{make_thumbs, ThumbOutcome, ThumbPool};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

/// A real JPEG, generated in-test (no fixture needed).
fn write_jpeg(path: &Path, w: u32, h: u32) {
    let img = image::RgbImage::from_fn(w, h, |x, y| {
        image::Rgb([(x % 256) as u8, (y % 256) as u8, 100])
    });
    img.save_with_format(path, image::ImageFormat::Jpeg)
        .unwrap();
}

fn assert_valid_jpeg_max_edge(path: &Path, max_edge: u32) -> (u32, u32) {
    let img = image::open(path).unwrap_or_else(|e| panic!("{path:?} must decode: {e}"));
    let (w, h) = img.dimensions();
    assert!(
        w.max(h) <= max_edge,
        "{path:?} is {w}x{h}, longest edge over {max_edge}"
    );
    (w, h)
}

#[test]
fn jpeg_gets_both_sizes_aspect_preserved() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("photo.jpg");
    write_jpeg(&src, 2000, 1000);

    let r = make_thumbs(&[0x11; 32], &src, &dir.path().join("thumbs"));
    assert_eq!(r.outcome, ThumbOutcome::Generated);
    let (w, h) = assert_valid_jpeg_max_edge(&r.paths.t256, 256);
    assert_eq!((w, h), (256, 128), "2:1 aspect must survive");
    assert_valid_jpeg_max_edge(&r.paths.t1024, 1024);
}

#[test]
fn small_images_are_not_upscaled() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("tiny.png");
    image::RgbImage::from_pixel(40, 30, image::Rgb([1, 2, 3]))
        .save_with_format(&src, image::ImageFormat::Png)
        .unwrap();

    let r = make_thumbs(&[0x22; 32], &src, &dir.path().join("thumbs"));
    assert_eq!(r.outcome, ThumbOutcome::Generated);
    let img = image::open(&r.paths.t1024).unwrap();
    assert_eq!(img.dimensions(), (40, 30), "never upscale");
}

#[test]
fn heic_decodes_via_libheif() {
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x33; 32], &fixture("tiny.heic"), &dir.path().join("t"));
    assert_eq!(r.outcome, ThumbOutcome::Generated, "HEIC must decode");
    let (w, h) = assert_valid_jpeg_max_edge(&r.paths.t256, 256);
    assert_eq!((w, h), (64, 48), "fixture is 64x48, no upscale");
}

#[test]
fn video_first_frame_via_ffmpeg() {
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x44; 32], &fixture("tiny.mp4"), &dir.path().join("t"));
    assert_eq!(
        r.outcome,
        ThumbOutcome::Generated,
        "mp4 must thumbnail (ffmpeg required on dev/CI machines)"
    );
    assert_valid_jpeg_max_edge(&r.paths.t256, 256);
}

/// 契约: 损坏文件 → Placeholder 结果（thumb_state=2 由调用方记），
/// 不许 panic，不许 Err。
///
/// DESK-35 (#441)：最终路径上**不许**有文件。占位图一旦落在最终路径，
/// `thumb.get` 的读盘命中就会永远端出这张灰图、再也不重试。
#[test]
fn corrupt_file_yields_placeholder_not_panic() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("broken.jpg");
    fs::write(&src, b"this is not a jpeg at all").unwrap();

    let r = make_thumbs(&[0x55; 32], &src, &dir.path().join("thumbs"));
    let ThumbOutcome::Placeholder { reason } = &r.outcome else {
        panic!("corrupt input must yield Placeholder, got {:?}", r.outcome);
    };
    assert!(
        reason.contains("broken.jpg"),
        "reason names the file: {reason}"
    );
    assert!(
        !r.paths.t256.exists() && !r.paths.t1024.exists(),
        "a failed generation must leave the final thumb paths empty"
    );
    // What the caller serves instead is still a real, decodable JPEG.
    let bytes = media_codec::placeholder_jpeg(256);
    let img = image::load_from_memory(&bytes).expect("placeholder decodes");
    assert_eq!(img.dimensions(), (256, 256));
}

#[test]
fn missing_file_yields_placeholder_too() {
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(
        &[0x66; 32],
        &dir.path().join("never-existed.heic"),
        &dir.path().join("thumbs"),
    );
    assert!(matches!(r.outcome, ThumbOutcome::Placeholder { .. }));
    assert!(
        !r.paths.t256.exists() && !r.paths.t1024.exists(),
        "a failed generation must leave the final thumb paths empty"
    );
}

#[test]
fn pool_completes_every_job() {
    let dir = tempfile::tempdir().unwrap();
    let thumbs = dir.path().join("thumbs");
    let pool = ThumbPool::new(3, thumbs.clone());

    let mut pending = Vec::new();
    for i in 0..12u8 {
        let src = dir.path().join(format!("p{i}.jpg"));
        if i % 4 == 3 {
            fs::write(&src, b"corrupt").unwrap(); // every 4th is broken
        } else {
            write_jpeg(&src, 300 + u32::from(i) * 10, 200);
        }
        let mut hash = [0u8; 32];
        hash[0] = i;
        pending.push((i, pool.submit(hash, src)));
    }

    let mut generated = 0;
    let mut placeholder = 0;
    for (_, rx) in pending {
        match rx.recv().expect("pool must answer every job").outcome {
            ThumbOutcome::Generated => generated += 1,
            ThumbOutcome::Placeholder { .. } => placeholder += 1,
        }
    }
    assert_eq!((generated, placeholder), (9, 3));
    drop(pool); // join workers — no hang means clean shutdown
}

/// S-05 full-fixture sweep (验收: failed=0). Heavy and machine-local, so
/// it only runs when PPF_THUMB_FIXTURES points at the fixture directory;
/// CI covers formats via the small fixtures above.
#[test]
fn s05_fixture_sweep_failed_is_zero() {
    let Ok(dir) = std::env::var("PPF_THUMB_FIXTURES") else {
        eprintln!("PPF_THUMB_FIXTURES unset — sweep skipped");
        return;
    };
    let out = tempfile::tempdir().unwrap();
    let mut total = 0u32;
    let mut failed = Vec::new();
    for (i, entry) in fs::read_dir(&dir).unwrap().enumerate() {
        let path = entry.unwrap().path();
        if !path.is_file() {
            continue;
        }
        total += 1;
        let mut hash = [0u8; 32];
        hash[..8].copy_from_slice(&(i as u64).to_le_bytes());
        if let ThumbOutcome::Placeholder { reason } = make_thumbs(&hash, &path, out.path()).outcome
        {
            failed.push(format!("{path:?}: {reason}"));
        }
    }
    assert!(total > 0, "fixture dir {dir} is empty");
    assert!(
        failed.is_empty(),
        "S-05 sweep: {}/{} failed:\n{}",
        failed.len(),
        total,
        failed.join("\n")
    );
    eprintln!("S-05 sweep: {total} files, 0 failed");
}

/// 透明图：左半全透明（RGB 是黑的——PNG 导出器常见写法），右半不透明红。
fn transparent_rgba(w: u32, h: u32) -> image::RgbaImage {
    image::RgbaImage::from_fn(w, h, |x, _| {
        if x < w / 2 {
            image::Rgba([0, 0, 0, 0])
        } else {
            image::Rgba([220, 30, 30, 255])
        }
    })
}

fn assert_white_left_red_right(path: &Path) {
    let img = image::open(path).unwrap().to_rgb8();
    let (w, h) = img.dimensions();
    let left = img.get_pixel(w / 8, h / 2);
    let right = img.get_pixel(w - 1 - w / 8, h / 2);
    // JPEG 有损，留余量；改前透明区是黑块（≈0）。
    assert!(
        left.0.iter().all(|&c| c >= 240),
        "透明区必须垫白底，实际 {left:?}"
    );
    assert!(
        right.0[0] >= 190 && right.0[1] <= 70,
        "不透明区保持原色，实际 {right:?}"
    );
}

/// 统一回归：三星传来的透明 PNG 在照片墙上是黑块。行业做法是垫白底再出 JPEG。
/// 反证：去掉合成白底 → 左半是黑的，红。
#[test]
fn transparent_png_is_flattened_onto_white() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("sticker.png");
    transparent_rgba(600, 300)
        .save_with_format(&src, image::ImageFormat::Png)
        .unwrap();

    let r = make_thumbs(&[0x77; 32], &src, &dir.path().join("thumbs"));
    assert_eq!(r.outcome, ThumbOutcome::Generated);
    assert_white_left_red_right(&r.paths.t256);
    assert_white_left_red_right(&r.paths.t1024);
}

/// ICO 能出缩略图（程序现场生成样本），透明部分同样垫白底。
/// 反证：image 不开 `ico` feature → Placeholder，红。
#[test]
fn ico_gets_thumbnails_on_white() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("favicon.ico");
    let img = transparent_rgba(64, 64);
    let frame =
        image::codecs::ico::IcoFrame::as_png(img.as_raw(), 64, 64, image::ExtendedColorType::Rgba8)
            .unwrap();
    image::codecs::ico::IcoEncoder::new(fs::File::create(&src).unwrap())
        .encode_images(&[frame])
        .unwrap();

    let r = make_thumbs(&[0x78; 32], &src, &dir.path().join("thumbs"));
    assert_eq!(r.outcome, ThumbOutcome::Generated, "ICO 必须能解码");
    assert_white_left_red_right(&r.paths.t256);
}

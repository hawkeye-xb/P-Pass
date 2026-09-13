//! macOS system fallback for video first-frame extraction (MOB-74 B).
//!
//! The user decision (2026-09-13): 「能用系统的就先用系统的」 — before the
//! release pipeline bundles its own ffmpeg, thumbnails go through Apple's
//! built-in Quick Look (`/usr/bin/qlmanage`), a system binary we neither
//! ship nor license. Discovery order for video thumbs is now
//! ffmpeg (env/bundled/PATH) → qlmanage (macOS only).
//!
//! Probed on a real Mac (09-13): `qlmanage -t -s 1024 -o <existing dir> <f>`
//! exits 0 and writes `<dir>/<file-name>.png` — the directory must exist
//! first, the output keeps the source aspect ratio, and a 320×240 sample
//! yielded a 320×240 RGBA PNG (qlmanage treats `-s` as an upper bound).
//! A `qlmanage` failure says nothing on stdout, so an empty/missing PNG is
//! reported as such rather than passed downstream as success.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{CodecError, Result};

/// Whether this machine has the system thumbnailer. Fixed Apple path,
/// probed by existence — deliberately no platform switch in this crate
/// (arch rule B.2, same discipline as ffmpeg discovery in `ffmpeg.rs`):
/// off a Mac the file simply isn't there and the answer is `None`.
pub fn qlmanage_path() -> Option<PathBuf> {
    let p = Path::new("/usr/bin/qlmanage");
    p.is_file().then(|| p.to_path_buf())
}

/// Hard bound on one `qlmanage` invocation. 09-13 real-device finding: on
/// an undecodable file qlmanage **hangs forever** (it waits on the
/// QuickLook ThumbnailsAgent XPC reply that never comes) — `.status()` in
/// the first draft froze the test harness. The daemon's 5 s thumb budget
/// cannot help here: a blown `tokio::time::timeout` abandons the future,
/// not the spawned process. So the kill lives inside this function and the
/// budget stays honest: 4 s leaves room for the JPEG re-encode downstream.
pub const QL_DEADLINE: std::time::Duration = std::time::Duration::from_secs(4);

/// Extract the first frame of `video` into a PNG inside `out_dir` (which
/// must exist; the caller owns its lifetime — `tempfile` dirs are fine).
/// Returns the produced PNG path. Never returns while qlmanage is still
/// alive: success, non-zero exit, and deadline-expiry-kill are all
/// terminal answers.
pub fn extract_frame(qlmanage: &Path, video: &Path, out_dir: &Path) -> Result<PathBuf> {
    let out = out_dir.join(format!(
        "{}.png",
        video
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "frame".into())
    ));
    // qlmanage prints its own banner to stdout; keep the pipes quiet.
    let mut child = Command::new(qlmanage)
        .args(["-t", "-s", "1024"])
        .arg("-o")
        .arg(out_dir)
        .arg(video)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|source| CodecError::Io {
            path: qlmanage.to_path_buf(),
            source,
        })?;
    let deadline = std::time::Instant::now() + QL_DEADLINE;
    let status = loop {
        match child.try_wait().map_err(|source| CodecError::Io {
            path: qlmanage.to_path_buf(),
            source,
        })? {
            Some(status) => break status,
            None if std::time::Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CodecError::QuickLook {
                    path: video.to_path_buf(),
                    msg: format!("qlmanage timed out after {:?}", QL_DEADLINE),
                });
            }
            None => std::thread::sleep(std::time::Duration::from_millis(100)),
        }
    };
    if !status.success() {
        return Err(CodecError::QuickLook {
            path: video.to_path_buf(),
            msg: format!("qlmanage exited with {status}"),
        });
    }
    if out.is_file() && out.metadata().map(|m| m.len() > 0).unwrap_or(false) {
        Ok(out)
    } else {
        Err(CodecError::QuickLook {
            path: video.to_path_buf(),
            msg: "qlmanage produced no thumbnail".into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn qlmanage_resolves_only_where_the_system_binary_exists() {
        // Environment truth must match the file check — never a guess.
        assert_eq!(
            qlmanage_path().is_some(),
            Path::new("/usr/bin/qlmanage").is_file()
        );
    }

    #[test]
    fn system_first_frame_produces_a_decodable_png_for_a_real_video() {
        // The crate's committed fixture (same one the ffmpeg path uses).
        let Some(ql) = qlmanage_path() else { return };
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tiny.mp4");
        if !fixture.is_file() {
            return; // fixture missing — nothing to assert against
        }
        let dir = tempfile::tempdir().unwrap();
        let png = extract_frame(&ql, &fixture, dir.path()).unwrap();
        assert!(png.extension().unwrap() == "png");
        let img = image::open(&png).expect("qlmanage PNG must decode");
        assert!(img.width() > 0 && img.height() > 0);
    }

    #[test]
    fn garbage_video_reports_failure_within_the_deadline_instead_of_hanging() {
        let Some(ql) = qlmanage_path() else { return };
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("not-a-video.mp4");
        std::fs::write(&src, b"garbage").unwrap();
        // 09-13 real-device finding: qlmanage on undecodable input HANGS
        // (waits on the ThumbnailsAgent XPC reply forever) — this test is
        // simultaneously the fake-success guard and the counter-proof that
        // the internal deadline+kill actually works: without it, the test
        // process itself never returns.
        let out_dir = dir.path().join("thumbs");
        std::fs::create_dir_all(&out_dir).unwrap();
        let started = std::time::Instant::now();
        let r = extract_frame(&ql, &src, &out_dir);
        let elapsed = started.elapsed();
        assert!(r.is_err(), "garbage must never pass as a real frame: {r:?}");
        assert!(
            elapsed < QL_DEADLINE + std::time::Duration::from_secs(2),
            "must return by the internal deadline, took {elapsed:?}"
        );
    }
}

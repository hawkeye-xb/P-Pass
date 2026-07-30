//! ffmpeg discovery and first-frame extraction for video thumbnails.
//!
//! Discovery order: `PPF_FFMPEG` env → `<exe_dir>/tools/ffmpeg[.exe]` →
//! `ffmpeg` on PATH. Probing tries both binary names on every platform
//! instead of a `#[cfg]` — arch rule B.2 keeps platform switches out of
//! this crate.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{CodecError, Result};

/// Locate an ffmpeg binary, or `None` if the machine has none.
pub fn ffmpeg_path() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("PPF_FFMPEG") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in ["ffmpeg", "ffmpeg.exe"] {
                let candidate = dir.join("tools").join(name);
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    // PATH probe: cheap -version run; success means "ffmpeg" resolves.
    let on_path = Command::new("ffmpeg")
        .arg("-version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    on_path.then(|| PathBuf::from("ffmpeg"))
}

/// Extract the first video frame as a JPEG at `dst_jpg`.
pub fn extract_frame(ffmpeg: &Path, src: &Path, dst_jpg: &Path) -> Result<()> {
    let out = Command::new(ffmpeg)
        .args(["-y", "-loglevel", "error", "-i"])
        .arg(src)
        .args(["-frames:v", "1", "-q:v", "3"])
        .arg(dst_jpg)
        .output()
        .map_err(|source| CodecError::Io {
            path: ffmpeg.to_path_buf(),
            source,
        })?;
    if !out.status.success() || !dst_jpg.is_file() {
        return Err(CodecError::Ffmpeg {
            path: src.to_path_buf(),
            msg: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn env_override_wins_when_it_exists() {
        // Point PPF_FFMPEG at a file that certainly exists (this test
        // binary itself) — discovery must return exactly that path.
        let me = std::env::current_exe().unwrap();
        std::env::set_var("PPF_FFMPEG", &me);
        assert_eq!(ffmpeg_path(), Some(me));
        std::env::remove_var("PPF_FFMPEG");
    }

    #[test]
    fn extract_frame_reports_ffmpeg_stderr_on_garbage() {
        let Some(ffmpeg) = ffmpeg_path() else {
            eprintln!("no ffmpeg on this machine — skipping");
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("not-a-video.mp4");
        std::fs::write(&src, b"garbage").unwrap();
        let err = extract_frame(&ffmpeg, &src, &dir.path().join("out.jpg")).unwrap_err();
        assert!(matches!(err, CodecError::Ffmpeg { .. }));
    }
}

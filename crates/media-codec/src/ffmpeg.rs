//! ffmpeg discovery and first-frame extraction for video thumbnails.
//!
//! Discovery order: `PPF_FFMPEG` env → `<exe_dir>/tools/ffmpeg[.exe]` →
//! `ffmpeg` on PATH. Probing tries both binary names on every platform
//! instead of a `#[cfg]` — arch rule B.2 keeps platform switches out of
//! this crate.

use std::ffi::OsString;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

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
    // DESK-54 (#814)：daemon release 是 GUI 子系统，直接 Command::new 拉起
    // console 子系统的 ffmpeg 会闪黑窗；platform::command 在 Windows 上带
    // CREATE_NO_WINDOW。下面抽帧那处同理。
    let on_path = platform::command("ffmpeg")
        .arg("-version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    on_path.then(|| PathBuf::from("ffmpeg"))
}

/// Hard bound on one ffmpeg run, same reasoning as `quicklook::QL_DEADLINE`:
/// the daemon's 5 s thumb budget only stops *waiting*, so the process is
/// killed here. 4 s leaves room for the JPEG re-encode downstream.
pub const FFMPEG_DEADLINE: Duration = Duration::from_secs(4);

/// Input demuxer by file extension. ffmpeg is told the container instead of
/// probing the content, so a file is only ever parsed as what its name says.
/// `None`: not a container we take thumbnails from.
fn demuxer_for(src: &Path) -> Option<&'static str> {
    let ext = src.extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "mp4" | "m4v" | "mov" | "qt" | "3gp" | "3g2" => "mov",
        "mkv" | "webm" => "matroska",
        "avi" => "avi",
        _ => return None,
    })
}

/// The full argument list for one first-frame extraction. Input options
/// (`-f`, `-protocol_whitelist`) must precede `-i` to apply to the input.
fn frame_args(src: &Path, dst_jpg: &Path) -> Result<Vec<OsString>> {
    let demuxer = demuxer_for(src).ok_or_else(|| CodecError::Ffmpeg {
        path: src.to_path_buf(),
        msg: "unsupported video container".into(),
    })?;
    let mut args: Vec<OsString> = [
        "-nostdin",
        "-y",
        "-loglevel",
        "error",
        "-protocol_whitelist",
        "file,pipe",
        "-f",
        demuxer,
        "-i",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    args.push(src.as_os_str().to_owned());
    args.extend(["-frames:v", "1", "-q:v", "3"].map(OsString::from));
    args.push(dst_jpg.as_os_str().to_owned());
    Ok(args)
}

/// Extract the first video frame as a JPEG at `dst_jpg`. Never returns
/// while ffmpeg is still alive: past [`FFMPEG_DEADLINE`] it is killed.
pub fn extract_frame(ffmpeg: &Path, src: &Path, dst_jpg: &Path) -> Result<()> {
    extract_frame_within(ffmpeg, src, dst_jpg, FFMPEG_DEADLINE)
}

fn extract_frame_within(
    ffmpeg: &Path,
    src: &Path,
    dst_jpg: &Path,
    deadline: Duration,
) -> Result<()> {
    let io_err = |source| CodecError::Io {
        path: ffmpeg.to_path_buf(),
        source,
    };
    let args = frame_args(src, dst_jpg)?;
    // stderr goes to a file, not a pipe: nobody reads a pipe while we poll,
    // and a full pipe would block ffmpeg until the deadline.
    let mut stderr = tempfile::tempfile().map_err(io_err)?;
    let mut child = platform::command(ffmpeg)
        .args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(stderr.try_clone().map_err(io_err)?)
        .spawn()
        .map_err(io_err)?;
    let until = Instant::now() + deadline;
    let status = loop {
        match child.try_wait().map_err(io_err)? {
            Some(status) => break status,
            None if Instant::now() >= until => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(CodecError::Ffmpeg {
                    path: src.to_path_buf(),
                    msg: format!("ffmpeg timed out after {deadline:?}"),
                });
            }
            None => std::thread::sleep(Duration::from_millis(20)),
        }
    };
    if !status.success() || !dst_jpg.is_file() {
        let mut msg = String::new();
        let _ = stderr.seek(SeekFrom::Start(0));
        let _ = stderr.take(4096).read_to_string(&mut msg);
        return Err(CodecError::Ffmpeg {
            path: src.to_path_buf(),
            msg: msg.trim().to_string(),
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

    #[test]
    fn ffmpeg_args_whitelist_protocols_and_force_the_demuxer() {
        let args = frame_args(Path::new("/lib/clip.MP4"), Path::new("/t/out.jpg")).unwrap();
        let args: Vec<_> = args
            .iter()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        let at = |flag: &str| args.iter().position(|a| a == flag).unwrap();
        let input = at("-i");
        assert_eq!(args[at("-protocol_whitelist") + 1], "file,pipe");
        assert_eq!(args[at("-f") + 1], "mov");
        assert!(at("-protocol_whitelist") < input, "must apply to the input");
        assert!(at("-f") < input, "must apply to the input");
        assert_eq!(args[input + 1], "/lib/clip.MP4");
        assert!(args.contains(&"-nostdin".to_string()));
    }

    #[test]
    fn ffmpeg_demuxer_follows_the_extension_and_refuses_unknown() {
        assert_eq!(demuxer_for(Path::new("a.mov")), Some("mov"));
        assert_eq!(demuxer_for(Path::new("a.3gp")), Some("mov"));
        assert_eq!(demuxer_for(Path::new("a.webm")), Some("matroska"));
        assert_eq!(demuxer_for(Path::new("a.avi")), Some("avi"));
        assert_eq!(demuxer_for(Path::new("a.m3u8")), None);
        assert_eq!(demuxer_for(Path::new("noext")), None);
        let err = frame_args(Path::new("a.m3u8"), Path::new("o.jpg")).unwrap_err();
        assert!(matches!(err, CodecError::Ffmpeg { .. }));
    }

    #[test]
    fn ffmpeg_past_the_deadline_is_killed() {
        // A stand-in "ffmpeg" that would touch a marker after 3 s. With a
        // 1 s deadline the call must return in time, and the marker must
        // never appear: the process was killed, not merely abandoned.
        if !Path::new("/bin/sh").is_file() {
            eprintln!("no /bin/sh on this machine — skipping");
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let marker = dir.path().join("still-alive");
        let fake = dir.path().join("ffmpeg");
        std::fs::write(
            &fake,
            format!("#!/bin/sh\nsleep 3\ntouch '{}'\n", marker.display()),
        )
        .unwrap();
        let chmod = std::process::Command::new("chmod")
            .arg("+x")
            .arg(&fake)
            .status()
            .unwrap();
        assert!(chmod.success());

        let started = Instant::now();
        let err = extract_frame_within(
            &fake,
            &dir.path().join("clip.mp4"),
            &dir.path().join("out.jpg"),
            Duration::from_secs(1),
        )
        .unwrap_err();
        let took = started.elapsed();
        assert!(err.to_string().contains("timed out"), "{err}");
        assert!(
            took < Duration::from_millis(2500),
            "returned late: {took:?}"
        );
        std::thread::sleep(Duration::from_secs(4));
        assert!(!marker.exists(), "ffmpeg survived the deadline");
    }
}

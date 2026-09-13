//! MOB-74 B (user decision 2026-09-13: 「能用系统的就先用系统的」).
//!
//! End-to-end proof of the *fallback* branch: with no ffmpeg discoverable
//! at all (PATH scrubbed to system dirs, PPF_FFMPEG cleared, no bundled
//! `tools/ffmpeg` next to this test binary), a real video must STILL get
//! generated thumbnails — via the macOS system Quick Look path. This is
//! exactly the shipping-desktop situation: release builds never carried
//! ffmpeg, which is why every video thumb silently degraded to a gray
//! placeholder on the acceptance machine.
//!
//! Separate integration test on purpose: it mutates process env and must
//! not race the ffmpeg-preferring tests in the lib binary. No platform
//! switch (arch rule B.2): the test states its environment premises
//! explicitly and only exercises the branch when they hold — on a machine
//! where no ffmpeg can be hidden, or where `/usr/bin/qlmanage` doesn't
//! exist, the fallback is not the reachable path and the test says so by
//! returning early. Locally on a Mac (no ffmpeg in system dirs) it runs
//! for real; the lib unit tests pin the discovery/timeout contract on
//! every platform.

use std::path::Path;

use image::GenericImageView;
use media_codec::{make_thumbs, ThumbOutcome};

#[test]
fn video_thumbs_survive_a_machine_without_ffmpeg() {
    // System dirs only: Homebrew (/opt/homebrew/bin) and any user ffmpeg
    // are out of reach; /usr/bin/qlmanage is found by absolute path.
    std::env::remove_var("PPF_FFMPEG");
    std::env::set_var("PATH", "/usr/bin:/bin");
    if media_codec::ffmpeg_path().is_some() {
        eprintln!(
            "an ffmpeg still resolves on the scrubbed PATH — \
                   the fallback branch is not the reachable path here; skipping"
        );
        return;
    }
    if !Path::new("/usr/bin/qlmanage").is_file() {
        eprintln!("no system thumbnailer on this machine — skipping");
        return;
    }

    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/tiny.mp4");
    let dir = tempfile::tempdir().unwrap();
    let r = make_thumbs(&[0x77; 32], &fixture, &dir.path().join("t"));

    // The whole point of B: placeholder is NOT acceptable anymore on a Mac.
    assert_eq!(
        r.outcome,
        ThumbOutcome::Generated,
        "Quick Look must carry video thumbs when ffmpeg is absent"
    );
    for p in [&r.paths.t256, &r.paths.t1024] {
        let img = image::open(p).unwrap_or_else(|e| panic!("{p:?} must decode: {e}"));
        let (w, h) = img.dimensions();
        assert!(w > 0 && h > 0, "thumb must be real pixels");
    }
    let (w, h) = image::open(&r.paths.t256).unwrap().dimensions();
    assert!(w.max(h) <= 256, "256 slot must be downscaled, got {w}x{h}");
}

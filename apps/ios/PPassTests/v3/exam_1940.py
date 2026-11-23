import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1940LocalSourceFirstHardeningTest(unittest.TestCase):
    def test_live_timeline_cancellation_short_circuit_and_cache_generation_and_part_isolation(self) -> None:
        live_timeline = (
            REPO_ROOT / "apps/ios/PPass/Live/LiveTimeline.swift"
        ).read_text(encoding="utf-8")

        thumb_start = live_timeline.find("func thumbnail(")
        thumb_end = live_timeline.find("static var videoCacheDir", thumb_start)
        self.assertGreater(thumb_start, 0)
        self.assertGreater(thumb_end, thumb_start)
        thumb_body = live_timeline[thumb_start:thumb_end]

        remote_call_idx = thumb_body.find('logged("thumb.get')
        self.assertGreater(remote_call_idx, 0)
        before_remote = thumb_body[:remote_call_idx]
        self.assertIn(
            "checkCancellation()",
            before_remote,
            "LiveTimeline.thumbnail must check Task cancellation before falling back to remote thumb.get",
        )

        clear_idx = live_timeline.find("func clearMemoryCache()")
        self.assertGreater(clear_idx, 0)
        clear_slice = live_timeline[clear_idx : clear_idx + 350]
        self.assertTrue(
            "cacheGeneration" in clear_slice or "cacheGen" in clear_slice or "generation" in clear_slice,
            "LiveTimeline.clearMemoryCache must advance cache generation so in-flight thumbnails do not repopulate cleared NSCache",
        )

        self.assertNotIn(
            'appendingPathComponent("\\(item.id).\\(UUID().uuidString).part")',
            live_timeline,
            "In-flight .part staging file must not start with item.id where completeCached(hasPrefix:) would delete concurrent downloads",
        )
        self.assertNotIn(
            'appendingPathComponent(item.id + ".part")',
            live_timeline,
            "Remote in-flight .part staging file must not use shared <hash>.part prefix clobbered by concurrent requests",
        )

    def test_monotonic_reload_clock_and_uncached_resource_values_and_folder_privacy_test(self) -> None:
        local_idx = (
            REPO_ROOT / "apps/ios/PPass/Live/LocalSourceIndex.swift"
        ).read_text(encoding="utf-8")
        tests_swift = (
            REPO_ROOT / "apps/ios/PPassTests/LocalSourceFirstTests.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn(
            "Date().timeIntervalSince1970 * 1000",
            local_idx,
            "LocalFirstOriginals default clock must use a monotonic clock instead of wall-clock Date()",
        )
        self.assertIn(
            "removeAllCachedResourceValues()",
            local_idx,
            "IOSOriginalReader must clear cached URL resource values before post-copy version verification",
        )

        priv_start = tests_swift.find("func test_media_id_and_local_path_never_leak_to_uplink_or_logs")
        priv_end = tests_swift.find("func test_duplicate_hash_picks_lexicographically_largest_media_id", priv_start)
        self.assertGreater(priv_start, 0)
        self.assertGreater(priv_end, priv_start)
        priv_body = tests_swift[priv_start:priv_end]
        self.assertGreaterEqual(
            priv_body.count("videoHash"),
            2,
            "Privacy test must exercise fallback for the seeded folder videoHash entry in addition to seeding it",
        )


if __name__ == "__main__":
    unittest.main()

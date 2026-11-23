import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1937IOSFolderCountAndMediaReadHardeningTest(unittest.TestCase):
    def test_folder_in_scope_count_uses_single_pass_count_instead_of_paged_in_scope(self) -> None:
        backend = (REPO_ROOT / "apps/ios/PPass/Live/LiveBackend.swift").read_text(encoding="utf-8")
        folder_src = (REPO_ROOT / "apps/ios/PPass/Live/FolderMediaSource.swift").read_text(encoding="utf-8")
        idx = backend.find("static func folderInScopeCount(")
        self.assertGreater(idx, 0, "LiveBackend.folderInScopeCount must exist")
        fn_slice = backend[idx : idx + 1400]
        self.assertNotIn(
            "source.inScope(",
            fn_slice,
            "LiveBackend.folderInScopeCount must not page through source.inScope (causes repeated O(N^2/500) scans)",
        )
        self.assertIn(
            "inScopeCount(",
            fn_slice,
            "LiveBackend.folderInScopeCount must delegate to single-pass FolderMediaSource.inScopeCount",
        )
        self.assertIn(
            "func inScopeCount(",
            folder_src,
            "FolderMediaSource must expose single-pass inScopeCount()",
        )

    def test_photo_media_source_default_access_closure_is_injectable_and_tested(self) -> None:
        live_media = (REPO_ROOT / "apps/ios/PPass/Live/LiveMedia.swift").read_text(encoding="utf-8")
        access_tests = (
            REPO_ROOT / "apps/ios/PPassTests/PhotoMediaSourceAccessTests.swift"
        ).read_text(encoding="utf-8")
        pms_idx = live_media.find("final class PhotoMediaSource")
        self.assertGreater(pms_idx, 0)
        pms_head = live_media[pms_idx : pms_idx + 1800]
        self.assertIn(
            "PhotoKitAuthorizing",
            pms_head,
            "PhotoMediaSource.init should accept PhotoKitAuthorizing so default accessDecided can be tested without overriding it",
        )
        self.assertIn(
            "auth: FakeAuthorization(",
            access_tests,
            "PhotoMediaSourceAccessTests must exercise PhotoMediaSource with injected FakeAuthorization and default accessDecided",
        )

    def test_live_timeline_thumbnail_checks_cancellation_before_remote_rpc(self) -> None:
        timeline = (REPO_ROOT / "apps/ios/PPass/Live/LiveTimeline.swift").read_text(encoding="utf-8")
        t_idx = timeline.find("func thumbnail(")
        r_idx = timeline.find('logged("thumb.get', t_idx)
        self.assertGreater(t_idx, 0)
        self.assertGreater(r_idx, t_idx)
        between = timeline[t_idx:r_idx]
        self.assertIn(
            "Task.checkCancellation()",
            between,
            "LiveTimeline.thumbnail must check Task.checkCancellation() before falling back to remote thumb.get",
        )

    def test_folder_copy_clears_cached_resource_values_before_verification(self) -> None:
        local_idx = (REPO_ROOT / "apps/ios/PPass/Live/LocalSourceIndex.swift").read_text(encoding="utf-8")
        self.assertIn(
            "removeAllCachedResourceValues()",
            local_idx,
            "IOSOriginalReader must clear URL cached resource values before post-copy folderFileVersion verification",
        )


if __name__ == "__main__":
    unittest.main()

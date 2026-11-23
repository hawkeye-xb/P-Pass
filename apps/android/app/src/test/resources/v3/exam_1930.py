import pathlib
import re
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/android").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1930ViewerSyncAndPPScreenWiringTest(unittest.TestCase):
    def test_photos_screen_does_not_defer_viewer_open_via_launched_effect(self) -> None:
        photos_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt"
        ).read_text(encoding="utf-8")
        deferred = re.search(
            r"LaunchedEffect\s*\([^)]*\)\s*\{[^}]*onViewerOpenChange",
            photos_kt,
            re.DOTALL,
        )
        self.assertIsNone(
            deferred,
            "PhotosScreen must not defer onViewerOpenChange via LaunchedEffect (causes a 1-frame background/status-bar flash)",
        )

    def test_ppscreen_wiring_test_guards_missing_signature_full_file_and_viewer_chain(self) -> None:
        wiring_kt = (
            REPO_ROOT / "apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/PPScreenWiringTest.kt"
        ).read_text(encoding="utf-8")
        self.assertNotIn(
            'substringAfter(funSig, "")',
            wiring_kt,
            "topLevelBody must fail fast when funSig is missing instead of silently returning an empty string",
        )
        self.assertIn(
            "onViewerOpenChange",
            wiring_kt,
            "PPScreenWiringTest must lock the onViewerOpenChange -> photoViewerOpen -> twoTabsBackground wiring chain",
        )


if __name__ == "__main__":
    unittest.main()

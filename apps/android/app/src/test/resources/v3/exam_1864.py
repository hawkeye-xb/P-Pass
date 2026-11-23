import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/android").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1864SingleTransferEnqueueFailureFeedbackTest(unittest.TestCase):
    def test_single_transfer_pick_callbacks_surface_enqueue_failure_to_user(self) -> None:
        main_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt"
        ).read_text(encoding="utf-8")

        p_idx = main_kt.find("val pickPhotosLauncher")
        f_idx = main_kt.find("val filePickLauncher")
        l_idx = main_kt.find("androidx.compose.runtime.LaunchedEffect", f_idx)
        d_idx = main_kt.find("val decisionPickLauncherResult:")
        lf_idx = main_kt.find("val launchDecisionFile:", d_idx)

        self.assertGreater(p_idx, 0, "pickPhotosLauncher must exist")
        self.assertGreater(f_idx, p_idx, "filePickLauncher must follow pickPhotosLauncher")
        self.assertGreater(l_idx, f_idx, "polling LaunchedEffect must follow filePickLauncher")
        self.assertGreater(d_idx, 0, "decisionPickLauncherResult must exist")
        self.assertGreater(lf_idx, d_idx, "launchDecisionFile must follow decisionPickLauncherResult")

        photos_block = main_kt[p_idx:f_idx]
        files_block = main_kt[f_idx:l_idx]
        decision_block = main_kt[d_idx:lf_idx]

        def has_failure_feedback(block: str) -> bool:
            return any(
                token in block
                for token in (
                    "showSnackbar",
                    "command_failed",
                    "notifyEnqueueFailure",
                    "runPickedEnqueue",
                    "onEnqueueFailure",
                )
            )

        self.assertTrue(
            has_failure_feedback(photos_block),
            "pickPhotosLauncher must surface user-visible feedback when PickedUploads.enqueue fails instead of silently logging only",
        )
        self.assertTrue(
            has_failure_feedback(files_block),
            "filePickLauncher must surface user-visible feedback when PickedUploads.enqueue fails instead of silently logging only",
        )
        self.assertTrue(
            has_failure_feedback(decision_block),
            "decisionPickLauncherResult must surface user-visible feedback when PickedUploads.enqueue fails instead of silently logging only",
        )

    def test_unit_test_covers_picked_enqueue_failure_feedback_and_no_wake(self) -> None:
        status_test = (
            REPO_ROOT
            / "apps/android/app/src/test/java/com/hawkeyexb/ppass/ui/SingleTransferStatusTest.kt"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "R.string.command_failed",
            status_test,
            "SingleTransferStatusTest must assert R.string.command_failed feedback on single-transfer enqueue failure",
        )


if __name__ == "__main__":
    unittest.main()

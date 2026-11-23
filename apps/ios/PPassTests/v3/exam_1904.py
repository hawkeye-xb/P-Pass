import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1904IOSConnectionStateConsistencyTest(unittest.TestCase):
    def test_ppass_core_defines_unified_connection_state_matching_android_1883(self) -> None:
        live_swift = (
            REPO_ROOT / "apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/TimelineLive.swift"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "struct ConnectionState",
            live_swift,
            "TimelineLive.swift must define unified ConnectionState matching Android #1883",
        )
        self.assertIn(
            "func connectionStateOf(",
            live_swift,
            "TimelineLive.swift must expose connectionStateOf(pairingLost:state:daysUnreachable:)",
        )

    def test_storage_detail_and_photos_screen_share_single_connection_state(self) -> None:
        diag_swift = (
            REPO_ROOT / "apps/ios/PPass/Diagnostics/DiagnosticsScreen.swift"
        ).read_text(encoding="utf-8")
        photos_swift = (
            REPO_ROOT / "apps/ios/PPass/Photos/PhotosScreen.swift"
        ).read_text(encoding="utf-8")
        timeline_model = (
            REPO_ROOT / "apps/ios/PPass/Photos/TimelineModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "storage_detail_offline",
            diag_swift,
            "StorageDetailScreen must use storage_detail_offline when not actively connected instead of claiming connected whenever !pairingLost",
        )
        self.assertNotIn(
            "app.pairingLost ? PPColor.act : PPColor.safe",
            diag_swift,
            "StorageDetailScreen status dot must reflect ConnectionState.Status rather than binary pairingLost",
        )
        self.assertIn(
            "app.connection",
            diag_swift,
            "StorageDetailScreen must read unified app.connection",
        )
        self.assertIn(
            "app.connection",
            photos_swift,
            "PhotosScreen must read unified app.connection",
        )
        attach_idx = timeline_model.find("func attach(")
        detach_idx = timeline_model.find("func detach(", attach_idx)
        self.assertGreater(attach_idx, 0)
        self.assertGreater(detach_idx, attach_idx)
        attach_slice = timeline_model[attach_idx:detach_idx]
        self.assertIn(
            "refreshFromSignal",
            attach_slice,
            "TimelineModel.attach must refresh full page on connected when stale error != nil (matching Android #1883)",
        )


if __name__ == "__main__":
    unittest.main()

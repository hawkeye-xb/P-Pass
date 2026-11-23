import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1964PairingOnboardingAlignmentTest(unittest.TestCase):
    def test_ios_pairing_removed_notice_and_camera_routing_and_centering(self) -> None:
        manifest_swift = (
            REPO_ROOT / "apps/ios/Packages/PPassCore/Sources/PPassCore/Storage/DisconnectManifest.swift"
        ).read_text(encoding="utf-8")
        onboarding_swift = (
            REPO_ROOT / "apps/ios/PPass/Pairing/OnboardingFlow.swift"
        ).read_text(encoding="utf-8")
        scan_swift = (
            REPO_ROOT / "apps/ios/PPass/Pairing/ScanScreen.swift"
        ).read_text(encoding="utf-8")
        app_model_swift = (
            REPO_ROOT / "apps/ios/PPass/App/AppModel.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "PairingRemovedNoticeStore",
            manifest_swift,
            "iOS DisconnectManifest must register PairingRemovedNoticeStore so notice survives cleanup",
        )
        self.assertIn("pairing_lost_title", onboarding_swift)
        self.assertIn("pairing_lost_body", onboarding_swift)
        self.assertIn(".alert(", onboarding_swift)

        ps_idx = onboarding_swift.find("struct PairStatusScreen: View")
        self.assertGreater(ps_idx, 0)
        ps_slice = onboarding_swift[ps_idx : ps_idx + 1800]
        self.assertIn("GeometryReader", ps_slice)
        self.assertIn("minHeight: geo.size.height", ps_slice)

        so_idx = app_model_swift.find("func startOver()")
        self.assertGreater(so_idx, 0)
        so_slice = app_model_swift[so_idx : so_idx + 500]
        self.assertTrue(
            "scan" in so_slice.lower() or "camera" in so_slice.lower(),
            "AppModel.startOver() must route directly to scan when camera access is already authorized",
        )

        self.assertIn(
            "onManual()",
            scan_swift,
            "ScanScreen must auto-navigate via onManual() when first-time camera prompt is denied",
        )

    def test_android_pair_status_spinner_and_welcome_scroll(self) -> None:
        onboarding_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/Onboarding.kt"
        ).read_text(encoding="utf-8")
        main_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "CircularProgressIndicator",
            onboarding_kt,
            "Android PairStatusScreen must render a CircularProgressIndicator while waiting",
        )
        self.assertIn(
            "verticalScroll",
            onboarding_kt,
            "Android WelcomeScreen must support verticalScroll under large font scale",
        )
        ask_idx = main_kt.find("PairPhase.Asking -> PairStatusScreen(")
        self.assertGreater(ask_idx, 0)
        ask_slice = main_kt[ask_idx : ask_idx + 400]
        self.assertIn(
            "loading = true",
            ask_slice,
            "MainActivity PairPhase.Asking must pass loading = true to PairStatusScreen",
        )


if __name__ == "__main__":
    unittest.main()

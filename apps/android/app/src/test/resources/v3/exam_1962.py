import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1962HomeAndPhotosGuideAlignmentTest(unittest.TestCase):
    def test_ios_first_choice_guard_hero_today_empty_and_secondary_tabbar_hidden(self) -> None:
        app_model_swift = (
            REPO_ROOT / "apps/ios/PPass/App/AppModel.swift"
        ).read_text(encoding="utf-8")
        hero_swift = (
            REPO_ROOT / "apps/ios/PPass/Home/HeroCard.swift"
        ).read_text(encoding="utf-8")
        settings_swift = (
            REPO_ROOT / "apps/ios/PPass/Home/SettingsScreen.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "firstChoicePending",
            app_model_swift,
            "iOS GuideFacts / photosGuideOf must guard enableScope with firstChoicePending like Android",
        )
        sg_idx = app_model_swift.find("var scopeGuideActionKey: String")
        self.assertGreater(sg_idx, 0)
        sg_slice = app_model_swift[sg_idx : sg_idx + 400]
        self.assertNotIn(
            "photos_first_run_enable",
            sg_slice,
            "scopeGuideActionKey must unify to photos_guide_enable / auto_backup_blocked_action",
        )

        self.assertIn(
            "auto_backup_from_today_empty",
            hero_swift,
            "iOS HeroCard must render auto_backup_from_today_empty when 0/0 and scope has start date",
        )

        nav_idx = settings_swift.find(".navigationDestination(for: Route.self)")
        self.assertGreater(nav_idx, 0)
        nav_slice = settings_swift[nav_idx : nav_idx + 800]
        self.assertIn(
            ".toolbar(.hidden, for: .tabBar)",
            nav_slice,
            "iOS SettingsScreen secondary routes (storage / diagnostics / more) must hide bottom tabBar",
        )

    def test_android_notice_only_on_settings_and_hero_idle_line_color(self) -> None:
        two_tabs_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/TwoTabs.kt"
        ).read_text(encoding="utf-8")
        home_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt"
        ).read_text(encoding="utf-8")

        fn_idx = two_tabs_kt.find("fun TwoTabs(")
        self.assertGreater(fn_idx, 0)
        two_tabs_body = two_tabs_kt[fn_idx:]
        self.assertNotIn(
            "if (notice != null)",
            two_tabs_body,
            "TwoTabs must not mount notice banner above both Photos and Settings tabs",
        )

        idle_idx = home_kt.find("val idleLine: String? = when")
        self.assertGreater(idle_idx, 0)
        idle_slice = home_kt[idle_idx : idle_idx + 2200]
        self.assertNotIn(
            "color = PPColor.Ink60,\n                                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }",
            idle_slice,
            "Android HomeScreen idleLine must use semantic status color (Safe / Waiting / Ink60), not hardcoded Ink60",
        )


if __name__ == "__main__":
    unittest.main()

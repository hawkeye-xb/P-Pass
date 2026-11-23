import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


class TestIssue1888AndroidA11yFollowups(unittest.TestCase):
    def test_headings_liveregion_scale_readback_and_fixtures_readme(self) -> None:
        home = pathlib.Path(
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt"
        ).read_text(encoding="utf-8")

        more_match = re.search(r"private\s+fun\s+MorePage\s*\(.*?\n\}\n", home, re.S)
        self.assertIsNotNone(more_match, "MorePage not found in HomeScreen.kt")
        self.assertIn(
            "heading()",
            more_match.group(0),
            "MorePage title must mark heading() semantics",
        )

        storage_match = re.search(r"private\s+fun\s+StorageComputerDetail\s*\(.*?\n\}\n", home, re.S)
        self.assertIsNotNone(storage_match, "StorageComputerDetail not found in HomeScreen.kt")
        self.assertIn(
            "heading()",
            storage_match.group(0),
            "StorageComputerDetail title must mark heading() semantics",
        )

        idle_match = re.search(r"if\s*\(\s*idleLine\s*!=\s*null\s*\)\s*\{(.*?)\}", home, re.S)
        self.assertIsNotNone(idle_match, "idleLine Text block not found in HomeScreen.kt")
        self.assertIn(
            "LiveRegionMode.Polite",
            idle_match.group(1),
            "Hero idleLine Text must expose LiveRegionMode.Polite semantics",
        )

        fix_root = pathlib.Path("tools/e3/fixtures/android-a11y-bigfont")
        actual_dirs = sorted(d.name for d in fix_root.iterdir() if d.is_dir())
        self.assertIn(
            "fail-scale-readback",
            actual_dirs,
            "fixtures/android-a11y-bigfont must include fail-scale-readback counter-fixture",
        )

        readme = (fix_root / "README.md").read_text(encoding="utf-8")
        self.assertNotIn(
            "fail-manual-truncation",
            readme,
            "README.md still references non-existent fail-manual-truncation/",
        )
        self.assertNotIn(
            "zh-CN 与 en-US 各一套",
            readme,
            "README.md still claims pass/ has both zh-CN and en-US",
        )
        for dname in actual_dirs:
            self.assertIn(
                f"`{dname}/`",
                readme,
                f"README.md must document fixture directory `{dname}/`",
            )

        # Verify scale readback in a11y-bigfont.sh act() and judge()
        scn = pathlib.Path("tools/e3/scenarios/android/a11y-bigfont.sh").read_text(encoding="utf-8")
        self.assertIn("scales.txt", scn, "a11y-bigfont.sh should record and judge scales.txt readback")

        # Run judge on pass/ -> must exit 0; tamper font_scale -> must fail; tamper anim scale -> must fail
        pass_res = subprocess.run(
            ["tools/e3/run", "judge", "android/a11y-bigfont", str(fix_root / "pass")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(pass_res.returncode, 0, pass_res.stderr or pass_res.stdout)

        with tempfile.TemporaryDirectory() as tmp:
            bad_font = pathlib.Path(tmp) / "bad_font"
            shutil.copytree(fix_root / "pass", bad_font)
            scales_file = bad_font / "zh-CN" / "scales.txt"
            self.assertTrue(scales_file.is_file(), "pass/zh-CN/scales.txt must exist")
            orig = scales_file.read_text(encoding="utf-8")
            scales_file.write_text(re.sub(r"font_scale=.*", "font_scale=1.0", orig), encoding="utf-8")
            r1 = subprocess.run(
                ["tools/e3/run", "judge", "android/a11y-bigfont", str(bad_font)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(r1.returncode, 0, "judge must fail when font_scale readback is 1.0")

            bad_anim = pathlib.Path(tmp) / "bad_anim"
            shutil.copytree(fix_root / "pass", bad_anim)
            (bad_anim / "zh-CN" / "scales.txt").write_text(
                re.sub(r"animator_duration_scale=.*", "animator_duration_scale=1.0", orig),
                encoding="utf-8",
            )
            r2 = subprocess.run(
                ["tools/e3/run", "judge", "android/a11y-bigfont", str(bad_anim)],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(r2.returncode, 0, "judge must fail when animation scale readback is non-zero")


if __name__ == "__main__":
    unittest.main()

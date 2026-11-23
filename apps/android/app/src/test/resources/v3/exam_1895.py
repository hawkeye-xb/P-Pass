import pathlib
import subprocess
import sys
import unittest


class TestIssue1895DeadPickFilesLabel(unittest.TestCase):
    TARGETS = (
        "apps/android/app/src/main/res/values/strings.xml",
        "apps/android/app/src/main/res/values-zh/strings.xml",
        "apps/ios/PPass/Resources/en.lproj/Localizable.strings",
        "apps/ios/PPass/Resources/zh-Hans.lproj/Localizable.strings",
    )

    def test_pick_files_label_removed_and_ios_strings_synced(self) -> None:
        for rel in self.TARGETS:
            text = pathlib.Path(rel).read_text(encoding="utf-8")
            self.assertNotIn("pick_files_label", text, f"dead key still present in {rel}")
        chk = subprocess.run(
            [sys.executable, "tools/ios/gen-strings.py", "--check"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(chk.returncode, 0, chk.stderr or chk.stdout)


if __name__ == "__main__":
    unittest.main()

import json
import pathlib
import re
import subprocess
import sys
import unittest


class TestIssue1434PhotosPageGutterToken(unittest.TestCase):
    def test_photos_page_gutter_registered_and_hardcoded_20_removed(self) -> None:
        tokens = json.loads(pathlib.Path("assets/design/tokens.json").read_text(encoding="utf-8"))
        ios_overrides = tokens.get("platforms", {}).get("ios", {})
        mui = tokens.get("mobile-ui", {})

        for full_key, spec in ios_overrides.items():
            if full_key.startswith("$"):
                continue
            parts = full_key.split(".")
            self.assertEqual(len(parts), 3, f"invalid override key {full_key}")
            base_val = mui[parts[1]][parts[2]]["value"]
            self.assertNotEqual(base_val, spec.get("value"), f"{full_key} equals Android base {base_val}")
            self.assertTrue((spec.get("why") or "").strip(), f"{full_key} missing why")

        ios_dump = json.dumps(ios_overrides, ensure_ascii=False)
        self.assertIn("照片页", ios_dump, "platforms.ios must document why PhotosScreen uses 20pt gutter")

        chk_ios = subprocess.run(
            [sys.executable, "tools/ios/gen-tokens.py", "--check"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(chk_ios.returncode, 0, chk_ios.stderr or chk_ios.stdout)

        chk_css = subprocess.run(
            [sys.executable, "tools/check-token-drift.py"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(chk_css.returncode, 0, chk_css.stderr or chk_css.stdout)

        ios_photos = pathlib.Path("apps/ios/PPass/Photos/PhotosScreen.swift").read_text(encoding="utf-8")
        self.assertNotRegex(
            ios_photos,
            r"\.padding\(\.horizontal,\s*20(?:\.0)?\)",
            "PhotosScreen.swift still has hardcoded .padding(.horizontal, 20)",
        )
        token_uses = re.findall(r"\.padding\(\.horizontal,\s*PPUI\.Layout\.([A-Za-z0-9_]+)\)", ios_photos)
        self.assertGreaterEqual(len(token_uses), 7, f"expected >=7 PPUI.Layout gutter uses, got {token_uses}")

        generated = pathlib.Path("apps/ios/PPass/Design/Tokens.generated.swift").read_text(encoding="utf-8")
        for name in set(token_uses):
            self.assertRegex(
                generated,
                rf"static let {re.escape(name)}:\s*CGFloat\s*=\s*20\b",
                f"PPUI.Layout.{name} = 20 not found in Tokens.generated.swift",
            )

        and_photos = pathlib.Path(
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt"
        ).read_text(encoding="utf-8")
        self.assertNotRegex(
            and_photos,
            r"padding\(\s*20\.dp\s*,\s*0\.dp\s*,\s*20\.dp",
            "PhotosScreen.kt still has hardcoded padding(20.dp, 0.dp, 20.dp, ...)",
        )
        self.assertGreaterEqual(
            and_photos.count("PPSize.PageGutter"),
            10,
            "PhotosScreen.kt should replace hardcoded 20.dp horizontal paddings with PPSize.PageGutter",
        )


if __name__ == "__main__":
    unittest.main()

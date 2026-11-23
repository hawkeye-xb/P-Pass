import pathlib
import re
import unittest


class TestIssue1868AddSourceCardEnabled(unittest.TestCase):
    def test_add_source_card_exposes_enabled_and_bucket_screen_passes_not_saving(self) -> None:
        cards = pathlib.Path(
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/components/SourceCards.kt"
        ).read_text(encoding="utf-8")

        add_fn_match = re.search(r"fun\s+AddSourceCard\s*\((.*?)\)\s*\{", cards, re.S)
        self.assertIsNotNone(add_fn_match, "AddSourceCard signature not found in SourceCards.kt")
        add_params = add_fn_match.group(1)
        self.assertRegex(
            add_params,
            r"\benabled\s*:\s*Boolean\s*=\s*true\b",
            "AddSourceCard must expose `enabled: Boolean = true` parameter",
        )

        frame_fn_match = re.search(r"private\s+fun\s+SourceCellFrame\s*\((.*?)\)\s*\{(.*?)\n\}", cards, re.S)
        self.assertIsNotNone(frame_fn_match, "SourceCellFrame not found in SourceCards.kt")
        self.assertRegex(
            frame_fn_match.group(1),
            r"\benabled\s*:\s*Boolean\b",
            "SourceCellFrame must accept `enabled: Boolean`",
        )
        self.assertRegex(
            frame_fn_match.group(2),
            r"Card\s*\([^)]*\benabled\s*=\s*enabled\b",
            "SourceCellFrame must forward `enabled = enabled` to Material3 Card",
        )

        bucket = pathlib.Path(
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt"
        ).read_text(encoding="utf-8")
        add_call_match = re.search(r'item\(\s*key\s*=\s*"add-folder"\s*\)\s*\{(.*?)\n\s*\}', bucket, re.S)
        self.assertIsNotNone(add_call_match, 'item(key = "add-folder") block not found in BucketScreen.kt')
        add_call = add_call_match.group(1)
        self.assertRegex(
            add_call,
            r"\benabled\s*=\s*!\s*saving\b",
            "BucketScreen AddSourceCard must pass `enabled = !saving`",
        )
        self.assertNotIn(
            "if (!saving) onAddFolder()",
            add_call,
            "BucketScreen AddSourceCard should not silently swallow clicks via `if (!saving)` while leaving semantics enabled",
        )

        sem_tests = ""
        for p in [
            pathlib.Path("apps/android/app/src/androidTest/java/com/hawkeyexb/ppass/ui/accessibility/SourceCardSemanticsTest.kt"),
            pathlib.Path("apps/android/app/src/androidTest/java/com/hawkeyexb/ppass/ui/components/SourceCardsTest.kt"),
        ]:
            if p.is_file():
                sem_tests += p.read_text(encoding="utf-8") + "\n"
        self.assertIn(
            "assertIsNotEnabled",
            sem_tests,
            "Compose semantics tests must assert disabled semantics (`assertIsNotEnabled`) when AddSourceCard enabled = false",
        )


if __name__ == "__main__":
    unittest.main()

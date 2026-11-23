import pathlib
import shutil
import subprocess
import tempfile
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "tools/e3/run").is_file():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


def extract_first_flow_row_header(source: str) -> str:
    idx = source.find("FlowRow(")
    if idx < 0:
        return ""
    brace = source.find("{", idx)
    if brace < 0:
        return ""
    return source[idx:brace]


class Exam1882ChipTouchTargetAndE3JudgeTest(unittest.TestCase):
    def test_a11y_bigfont_judge_passes_48dp_and_fails_32dp_time_chip(self) -> None:
        pass_dir = REPO_ROOT / "tools/e3/fixtures/android-a11y-bigfont/pass"
        run_bin = REPO_ROOT / "tools/e3/run"

        ok_proc = subprocess.run(
            ["bash", str(run_bin), "judge", "android/a11y-bigfont", str(pass_dir)],
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            ok_proc.returncode,
            0,
            f"48dp pass fixture must continue to pass judge: {ok_proc.stdout}\n{ok_proc.stderr}",
        )

        with tempfile.TemporaryDirectory() as tmp:
            shrunk_dir = pathlib.Path(tmp) / "shrunk-chip"
            shutil.copytree(pass_dir, shrunk_dir)
            scope_xml = shrunk_dir / "zh-CN/scope-open.xml"
            xml_text = scope_xml.read_text(encoding="utf-8")
            self.assertIn('[68,317][515,452]', xml_text)
            scope_xml.write_text(
                xml_text.replace('[68,317][515,452]', '[68,317][515,407]', 1),
                encoding="utf-8",
            )
            bad_proc = subprocess.run(
                ["bash", str(run_bin), "judge", "android/a11y-bigfont", str(shrunk_dir)],
                cwd=str(REPO_ROOT),
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(
                bad_proc.returncode,
                0,
                "32dp (90px @450dpi) time filter chip must fail android/a11y-bigfont judge once #1882 exemption is removed",
            )

    def test_filter_chip_rows_stay_above_scrollable_grid_occlusion(self) -> None:
        bucket_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt"
        ).read_text(encoding="utf-8")
        photos_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/PhotosScreen.kt"
        ).read_text(encoding="utf-8")

        bucket_header = extract_first_flow_row_header(bucket_kt)
        photos_header = extract_first_flow_row_header(photos_kt)
        self.assertIn(
            "zIndex(",
            bucket_header,
            "BucketScreen time filter FlowRow must set zIndex above LazyVerticalGrid so scrolled card touchBounds do not clip chip touch targets to 32dp",
        )
        self.assertIn(
            "zIndex(",
            photos_header,
            "PhotosScreen filter FlowRow must also set zIndex above LazyVerticalGrid for same-class occlusion safety",
        )
        self.assertIn(
            "heightIn(min = 36.dp)",
            photos_kt,
            "PhotoFilterChip must preserve heightIn(min = 36.dp) for multi-line 1.5x text growth",
        )


if __name__ == "__main__":
    unittest.main()

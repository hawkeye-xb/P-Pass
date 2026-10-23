#!/usr/bin/env python3
"""Tests for tools/a11y-contrast.py (#1127): the WCAG maths and the pair table."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "a11y-contrast.py"
spec = importlib.util.spec_from_file_location("a11y_contrast", SCRIPT)
ac = importlib.util.module_from_spec(spec)
sys.modules["a11y_contrast"] = ac
spec.loader.exec_module(ac)

PALETTE = {k: v["value"] for k, v in json.loads(ac.TOKENS_JSON.read_text())["color"].items()}


class Maths(unittest.TestCase):
    def ratio(self, fg: str, bg: str) -> float:
        return ac.contrast_ratio(ac.parse_color(fg), ac.parse_color(bg))

    def test_black_on_white_is_21(self):
        self.assertAlmostEqual(self.ratio("#000000", "#FFFFFF"), 21.0, places=6)

    def test_same_colour_is_1(self):
        self.assertAlmostEqual(self.ratio("#FBF8F2", "#FBF8F2"), 1.0, places=6)

    def test_known_reference_values(self):
        # WebAIM contrast checker reference values.
        self.assertAlmostEqual(self.ratio("#777777", "#FFFFFF"), 4.48, places=2)
        self.assertAlmostEqual(self.ratio("#767676", "#FFFFFF"), 4.54, places=2)

    def test_symmetric(self):
        self.assertAlmostEqual(self.ratio("#2E6B4F", "#E4F1E8"), self.ratio("#E4F1E8", "#2E6B4F"))

    def test_alpha_is_composited_onto_background(self):
        # 50% black over white = #808080 (rounded), ratio about 3.95.
        half = ac.parse_color("rgba(0,0,0,.5)")
        white = ac.parse_color("#FFFFFF")
        self.assertEqual(ac.to_hex(ac.composite(half, white)), "#808080")
        self.assertAlmostEqual(ac.contrast_ratio(half, white), self.ratio("#7F7F7F", "#FFFFFF"), places=1)

    def test_android_argb_hex_alpha(self):
        # #RRGGBBAA form used for derived colours.
        self.assertEqual(ac.parse_color("#FBF8F29E")[3], 0x9E / 255)

    def test_translucent_background_rejected(self):
        with self.assertRaises(ValueError):
            ac.composite(ac.parse_color("#000000"), ac.parse_color("rgba(0,0,0,.5)"))


class PairTable(unittest.TestCase):
    def test_every_pair_resolves_and_has_known_kind(self):
        self.assertTrue(ac.PAIRS, "pair table is empty")
        rows = ac.evaluate(ac.PAIRS, PALETTE)
        self.assertEqual(len(rows), len(ac.PAIRS))

    def test_backgrounds_are_opaque_tokens(self):
        for p in ac.PAIRS:
            self.assertNotIn("@", p.bg, f"{p}: background must be an opaque token")
            self.assertEqual(ac.parse_color(PALETTE[p.bg])[3], 1.0, f"{p}: background not opaque")

    def test_every_pair_has_reference_and_family(self):
        for p in ac.PAIRS:
            self.assertIn(p.family, ("light", "dark"))
            self.assertTrue(p.refs.strip(), f"{p.fg} on {p.bg}: missing code reference")

    def test_no_duplicate_pairs(self):
        seen = [(p.fg, p.bg, p.kind, p.family) for p in ac.PAIRS]
        self.assertEqual(len(seen), len(set(seen)))

    def test_dark_family_sits_on_dark_surfaces(self):
        for p in ac.PAIRS:
            if p.family == "dark":
                self.assertIn(p.bg, ("surface-dark", "ink-hover"), str(p))
            else:
                self.assertNotEqual(p.bg, "surface-dark", str(p))

    def test_both_families_covered(self):
        self.assertEqual({p.family for p in ac.PAIRS}, {"light", "dark"})


class Cli(unittest.TestCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)

    def test_report_mode_exits_zero(self):
        self.assertEqual(self.run_cli().returncode, 0)

    def test_strict_mode_fails_iff_any_failure(self):
        report = json.loads(self.run_cli("--json").stdout)
        expected = 1 if report["failures"] else 0
        self.assertEqual(self.run_cli("--strict").returncode, expected)


if __name__ == "__main__":
    unittest.main()

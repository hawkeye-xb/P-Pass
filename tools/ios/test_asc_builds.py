#!/usr/bin/env python3
"""#940：asc-builds.py 防过期守护的判定逻辑（纯函数，不联网）。

    python3 -m unittest tools/ios/test_asc_builds.py     （或直接 python3 tools/ios/test_asc_builds.py）
"""
import importlib.util
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

spec = importlib.util.spec_from_file_location("asc_builds", Path(__file__).with_name("asc-builds.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

NOW = datetime(2026, 10, 13, 12, 0, tzinfo=timezone.utc)


def ago(days, extra_hours=0):
    return NOW - timedelta(days=days, hours=extra_hours)


class Staleness(unittest.TestCase):
    def test_fresh(self):
        s = m.staleness(ago(10), NOW)
        self.assertEqual((s["age_days"], s["remaining_days"], s["stale"]), (10, 80, False))

    def test_boundary_75_days_not_stale(self):
        self.assertFalse(m.staleness(ago(75), NOW)["stale"])

    def test_just_over_75_days_floors_to_75_not_stale(self):
        self.assertFalse(m.staleness(ago(75, 23), NOW)["stale"])

    def test_76_days_stale(self):
        s = m.staleness(ago(76), NOW)
        self.assertEqual((s["remaining_days"], s["stale"]), (14, True))

    def test_expired(self):
        s = m.staleness(ago(95), NOW)
        self.assertEqual((s["remaining_days"], s["stale"]), (-5, True))

    def test_no_valid_build_is_stale(self):
        s = m.staleness(None, NOW)
        self.assertTrue(s["stale"])
        self.assertEqual(s["remaining_days"], 0)

    def test_custom_threshold(self):
        self.assertTrue(m.staleness(ago(31), NOW, stale_days=30)["stale"])


class ParseIso(unittest.TestCase):
    def test_offset(self):
        self.assertEqual(m.parse_iso("2026-10-01T05:00:00-07:00"), datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc))

    def test_zulu_and_fraction(self):
        self.assertEqual(m.parse_iso("2026-10-01T12:00:00.000Z"), datetime(2026, 10, 1, 12, 0, tzinfo=timezone.utc))

    def test_naive_rejected(self):
        with self.assertRaises(ValueError):
            m.parse_iso("2026-10-01T12:00:00")


class Dedup(unittest.TestCase):
    stale = {"age_days": 80, "remaining_days": 10, "stale": True}
    fresh = {"age_days": 5, "remaining_days": 85, "stale": False}

    def test_opens_when_stale_and_none_open(self):
        self.assertTrue(m.need_issue(self.stale, [{"number": 1, "title": "别的 issue"}]))

    def test_no_duplicate_when_same_title_open(self):
        self.assertFalse(m.need_issue(self.stale, [{"number": 7, "title": m.ISSUE_TITLE}]))

    def test_nothing_when_fresh(self):
        self.assertFalse(m.need_issue(self.fresh, []))


class Body(unittest.TestCase):
    def test_contains_remaining_days_and_entrypoint(self):
        b = m.issue_body({"age_days": 80, "remaining_days": 10, "stale": True}, "2026-07-25T00:00:00Z")
        self.assertIn("剩余 10 天", b)
        self.assertIn("testflight_version", b)
        self.assertIn("ci-ios.yml", b)

    def test_expired_and_missing_wording(self):
        self.assertIn("已过期", m.issue_body({"age_days": 95, "remaining_days": -5, "stale": True}, "x"))
        self.assertIn("没有任何 VALID build", m.issue_body({"age_days": None, "remaining_days": 0, "stale": True}, None))


if __name__ == "__main__":
    unittest.main()

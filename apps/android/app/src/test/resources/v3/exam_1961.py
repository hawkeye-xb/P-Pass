import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/android").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1961BucketScreenAlignmentTest(unittest.TestCase):
    def test_android_partial_access_and_empty_initial_selection_and_remove_error(self) -> None:
        bucket_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/BucketScreen.kt"
        ).read_text(encoding="utf-8")
        scope_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupScopeTime.kt"
        ).read_text(encoding="utf-8")
        main_kt = (
            REPO_ROOT / "apps/android/app/src/main/java/com/hawkeyexb/ppass/MainActivity.kt"
        ).read_text(encoding="utf-8")

        self.assertNotIn(
            "fun bucketScreenOffersAlbumChoices(access: MediaAccess): Boolean = access != MediaAccess.NONE",
            bucket_kt,
            "PARTIAL photo access must not offer incomplete album choices on BucketScreen",
        )
        self.assertIn(
            "access == MediaAccess.FULL",
            bucket_kt,
            "bucketScreenOffersAlbumChoices must require MediaAccess.FULL",
        )

        init_idx = scope_kt.find("fun initialSelection(")
        self.assertGreater(init_idx, 0)
        init_slice = scope_kt[init_idx : init_idx + 260]
        self.assertNotIn(
            "firstTime -> cameraBucketIds",
            init_slice,
            "initialSelection must not auto-preselect cameraBucketIds when saved == null (#1811)",
        )

        rm_idx = main_kt.find("onRemoveFolder =")
        self.assertGreater(rm_idx, 0)
        rm_slice = main_kt[rm_idx : rm_idx + 600]
        self.assertNotIn(
            "R.string.folder_add_failed",
            rm_slice,
            "onRemoveFolder failure must not report folder_add_failed",
        )

    def test_ios_bucket_screen_shared_notice_source_card_and_error_copy(self) -> None:
        bucket_swift = (
            REPO_ROOT / "apps/ios/PPass/Home/BucketScreen.swift"
        ).read_text(encoding="utf-8")
        ios_zh = (
            REPO_ROOT / "apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings"
        ).read_text(encoding="utf-8")
        ios_en = (
            REPO_ROOT / "apps/ios/PPass/Resources/en.lproj/IOS.strings"
        ).read_text(encoding="utf-8")

        for legacy_key in (
            "bucket_no_access_title",
            "bucket_no_access_body",
            "bucket_no_access_action",
            "bucket_request_access_action",
        ):
            self.assertNotIn(legacy_key, bucket_swift)
            self.assertNotIn(f'"{legacy_key}"', ios_zh)
            self.assertNotIn(f'"{legacy_key}"', ios_en)

        for shared_key in (
            "scope_album_no_access_title",
            "scope_album_no_access_body",
            "scope_album_no_access_action",
            "auto_backup_blocked_action",
            "source_kind_album",
            "source_kind_folder",
        ):
            self.assertIn(shared_key, bucket_swift)

        self.assertIn("PPColor.actBg", bucket_swift)
        self.assertNotIn(".confirmationDialog(", bucket_swift)
        self.assertIn(".alert(", bucket_swift)
        self.assertIn("Menu", bucket_swift)
        self.assertNotIn("self.error = String(describing: error)", bucket_swift)
        self.assertTrue(
            "folder_sources_reauth_failed" in bucket_swift
            and "folder_sources_remove_failed" in bucket_swift,
            "iOS BucketScreen must distinguish reauthorize and remove failure messages from add failure",
        )


if __name__ == "__main__":
    unittest.main()

import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/android").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1771AndroidFolderSourcePresenceTest(unittest.TestCase):
    def test_flow_engine_removes_global_album_gate_and_guards_remote_presence(self) -> None:
        engine_kt = (
            REPO_ROOT
            / "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowEngine.kt"
        ).read_text(encoding="utf-8")
        self.assertNotIn(
            "mediaAbsenceTrusted",
            engine_kt,
            "FlowEngine must not gate all sources on global album permission mediaAbsenceTrusted",
        )
        self.assertIn(
            "sourcePresenceTrusted",
            engine_kt,
            "FlowEngine must thread sourcePresenceTrusted into Round/presence gating so untrusted absence cannot trigger REUPLOAD or UNRECOVERABLE",
        )

    def test_mediastore_and_composite_partition_existing_ids_trust_per_source(self) -> None:
        media_kt = (
            REPO_ROOT
            / "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/order/MediaSnapshotSource.kt"
        ).read_text(encoding="utf-8")
        composite_kt = (
            REPO_ROOT
            / "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/folder/CompositeMediaSource.kt"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "absenceTrusted",
            media_kt,
            "ContentResolverMediaSnapshotSource.existingIds must guard MediaStore absence with absenceTrusted",
        )
        ex_idx = composite_kt.find("override fun existingIds(")
        self.assertGreater(ex_idx, 0)
        ex_body = composite_kt[ex_idx : ex_idx + 900]
        self.assertTrue(
            "partition" in ex_body or "isEmpty()" in ex_body or "isNotEmpty()" in ex_body,
            "CompositeMediaSnapshotSource.existingIds must avoid querying primary when no non-folder IDs are requested so folder-only reconciliation works without album access",
        )


if __name__ == "__main__":
    unittest.main()

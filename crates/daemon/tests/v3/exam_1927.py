import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[4]


class Exam1927RemoteReparseAndNetworkVolumeTest(unittest.TestCase):
    def test_platform_exposes_pre_canonicalize_reparse_and_network_checks(self) -> None:
        lib_rs = (REPO_ROOT / "crates/platform/src/lib.rs").read_text(encoding="utf-8")
        peer_rs = (REPO_ROOT / "crates/platform/src/local_peer.rs").read_text(encoding="utf-8")
        self.assertIn(
            "pub fn contains_remote_reparse_point(",
            lib_rs,
            "crates/platform must expose contains_remote_reparse_point before canonicalize()",
        )
        self.assertIn(
            "pub fn is_network_volume_or_ancestor(",
            lib_rs,
            "crates/platform must expose is_network_volume_or_ancestor for non-existent target subdirs and mapped drives",
        )
        self.assertIn(
            "contains_remote_reparse_point(",
            peer_rs,
            "UserDirFacts validation must block remote reparse points before real_path/canonicalize",
        )
        self.assertIn(
            "is_network_volume_or_ancestor(",
            peer_rs,
            "UserDirFacts validation must block mapped/network drives",
        )

    def test_daemon_check_library_path_blocks_remote_reparse_and_network_volume(self) -> None:
        loc_rs = (REPO_ROOT / "crates/daemon/src/library_location.rs").read_text(encoding="utf-8")
        reparse_pos = loc_rs.find("contains_remote_reparse_point(")
        resolve_call_pos = loc_rs.find("let Some(real) = resolve_components(target)")
        self.assertGreater(
            reparse_pos,
            0,
            "check_library_path must invoke platform::contains_remote_reparse_point before resolve_components",
        )
        self.assertGreater(
            resolve_call_pos,
            reparse_pos,
            "contains_remote_reparse_point must run strictly before resolve_components(target) calls canonicalize()",
        )
        self.assertIn(
            "ui.err_relocate_network_volume",
            loc_rs,
            "check_library_path must reject network volumes with ui.err_relocate_network_volume on initial setup too",
        )


if __name__ == "__main__":
    unittest.main()

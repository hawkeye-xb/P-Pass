import pathlib
import unittest


def find_repo_root() -> pathlib.Path:
    cur = pathlib.Path(__file__).resolve().parent
    for candidate in (cur, *cur.parents):
        if (candidate / "AGENTS.md").is_file() and (candidate / "apps/ios").is_dir():
            return candidate
    raise RuntimeError(f"cannot locate repo root from {__file__}")


REPO_ROOT = find_repo_root()


class Exam1770FolderLocalizedDisplayNameTest(unittest.TestCase):
    def test_folder_source_resolves_localized_name_inside_security_scope(self) -> None:
        registry_swift = (
            REPO_ROOT / "apps/ios/PPass/Live/FolderRegistry.swift"
        ).read_text(encoding="utf-8")
        backend_swift = (
            REPO_ROOT / "apps/ios/PPass/Live/LiveBackend.swift"
        ).read_text(encoding="utf-8")
        combined = registry_swift + "\n" + backend_swift

        self.assertIn(
            "localizedNameKey",
            combined,
            "Folder source registration must query URLResourceValues.localizedName (.localizedNameKey) for shared app Documents roots",
        )
        self.assertIn(
            "FolderDisplayName",
            combined,
            "Expected dedicated FolderDisplayName resolver used inside security scope",
        )

        add_idx = backend_swift.find("func addFolderSource(at url: URL, displayName: String) throws")
        self.assertGreater(add_idx, 0)
        add_slice = backend_swift[add_idx : add_idx + 700]
        scope_pos = add_slice.find("startAccessingSecurityScopedResource()")
        resolve_pos = add_slice.find("FolderDisplayName")
        self.assertGreater(scope_pos, 0)
        self.assertGreater(
            resolve_pos,
            scope_pos,
            "FolderDisplayName resolution must happen after startAccessingSecurityScopedResource()",
        )

    def test_unit_test_covers_documents_container_display_name(self) -> None:
        tests_dir = REPO_ROOT / "apps/ios/PPassTests"
        matched = False
        for p in tests_dir.glob("*Folder*Tests.swift"):
            txt = p.read_text(encoding="utf-8")
            if "Documents" in txt and "FolderDisplayName" in txt:
                matched = True
                break
        self.assertTrue(
            matched,
            "Expected unit tests covering Documents container localized display name resolution via FolderDisplayName",
        )


if __name__ == "__main__":
    unittest.main()

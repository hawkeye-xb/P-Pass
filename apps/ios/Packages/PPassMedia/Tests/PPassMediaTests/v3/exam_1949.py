import pathlib
import re
import unittest


class TestIssue1949PhotoKitAlbumCatalogBatching(unittest.TestCase):
    def test_batch_collection_summaries_and_count_of_assets_without_redundant_fetches(self) -> None:
        proto = pathlib.Path(
            "apps/ios/Packages/PPassMedia/Sources/PPassMedia/Library/PhotoLibraryReading.swift"
        ).read_text(encoding="utf-8")
        lib = pathlib.Path(
            "apps/ios/Packages/PPassMedia/Sources/PPassMedia/Library/PhotoKitLibrary.swift"
        ).read_text(encoding="utf-8")
        catalog = pathlib.Path(
            "apps/ios/Packages/PPassMedia/Sources/PPassMedia/Albums/AlbumCatalog.swift"
        ).read_text(encoding="utf-8")
        tests = pathlib.Path(
            "apps/ios/Packages/PPassMedia/Tests/PPassMediaTests/AlbumCatalogTests.swift"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "collectionSummaries",
            proto,
            "PhotoLibraryReading must expose batch collectionSummaries API to avoid per-album PHAssetCollection re-fetch",
        )
        self.assertIn(
            "collectionSummaries",
            catalog,
            "AlbumCatalog.listAlbums() must use batch collectionSummaries instead of N per-id summary(ofCollection:) lookups",
        )
        self.assertIn(
            "countOfAssets(with: .image)",
            lib,
            "PhotoKitLibrary must use PHFetchResult.countOfAssets(with: .image) instead of a separate image fetchAssets query",
        )
        self.assertIn(
            "countOfAssets(with: .video)",
            lib,
            "PhotoKitLibrary must use PHFetchResult.countOfAssets(with: .video) instead of a separate video fetchAssets query",
        )
        self.assertNotIn(
            "mediaOptions(only: .image)",
            lib,
            "PhotoKitLibrary summary should no longer issue a separate fetchAssets(options: mediaOptions(only: .image))",
        )
        self.assertNotIn(
            "mediaOptions(only: .video)",
            lib,
            "PhotoKitLibrary summary should no longer issue a separate fetchAssets(options: mediaOptions(only: .video))",
        )

        # Ensure batch implementation in PhotoKitLibrary reuses PHAssetCollection directly without collection(id) re-fetch
        m = re.search(r"public\s+func\s+collectionSummaries\b.*?\n    \}", lib, re.S)
        self.assertIsNotNone(m, "PhotoKitLibrary must implement public func collectionSummaries(...)")
        batch_body = m.group(0)
        self.assertNotIn(
            "Self.collection(",
            batch_body,
            "PhotoKitLibrary.collectionSummaries must reuse enumerated PHAssetCollection instances without Self.collection(id)",
        )
        self.assertNotIn(
            "withLocalIdentifiers",
            batch_body,
            "PhotoKitLibrary.collectionSummaries must not re-fetch collections by localIdentifier",
        )

        self.assertRegex(
            tests,
            r"80|collectionSummaries",
            "AlbumCatalogTests.swift must include regression test covering 80-album batch enumeration without per-id summary fallback",
        )


if __name__ == "__main__":
    unittest.main()

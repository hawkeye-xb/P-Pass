// #1152：「保存到相册」去重记录在存储根里（不进备份、断开清掉），旧 UserDefaults 键启动时删。
import Foundation
import XCTest
@testable import PPassCore

final class SavedToGalleryStoreTests: XCTestCase {
    func testRoundTripAndOverwrite() throws {
        let tmp = TempDir()
        let store = SavedToGalleryStore(directory: tmp.url)
        XCTAssertNil(store.localIdentifier(for: "h1"))
        try store.remember(hash: "h1", localIdentifier: "L1")
        try store.remember(hash: "h2", localIdentifier: "L2")
        XCTAssertEqual(SavedToGalleryStore(directory: tmp.url).localIdentifier(for: "h1"), "L1")
        XCTAssertEqual(store.localIdentifier(for: "h2"), "L2")
    }

    func testTheFileLivesInsideTheStorageRootWhichIsExcludedFromBackup() throws {
        let tmp = TempDir()
        let root = try StorageRoot.resolve(appPrivateDirectory: tmp.url, logger: NoopLogger())
        try SavedToGalleryStore(directory: root.url).remember(hash: "h", localIdentifier: "L")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(SavedToGalleryStore.fileName).path))
        XCTAssertEqual(try root.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testLegacyUserDefaultsKeyIsRemoved() {
        let suite = "saved-to-gallery-legacy-test"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["h": "L"], forKey: SavedToGalleryStore.legacyDefaultsKey)
        SavedToGalleryStore.removeLegacyDefaults(defaults)
        XCTAssertNil(defaults.object(forKey: SavedToGalleryStore.legacyDefaultsKey))
    }
}

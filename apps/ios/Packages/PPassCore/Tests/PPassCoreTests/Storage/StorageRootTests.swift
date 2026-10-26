// #338 / #1172：存储根落在 App 私有目录下的 PPass/（不是 App Group 共享容器），建好目录、整个不进备份。
import Foundation
import XCTest
@testable import PPassCore

final class StorageRootTests: XCTestCase {

    func testRootIsUnderTheAppPrivateDirectory() throws {
        let tmp = TempDir()
        let logger = RecordingLogger()
        let root = try StorageRoot.resolve(appPrivateDirectory: tmp.file("private"), logger: logger)
        XCTAssertEqual(root.url.path, tmp.file("private/PPass").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.url.path))
        XCTAssertTrue(logger.contains("storage: using app container"), "\(logger.lines)")
    }

    /// 目录位置被普通文件占住：建不出存储根就抛出，不换别处凑合。
    func testUnwritableDirectoryThrows() throws {
        let tmp = TempDir()
        tmp.write("private", "not a directory")
        XCTAssertThrowsError(try StorageRoot.resolve(appPrivateDirectory: tmp.file("private"), logger: RecordingLogger()))
    }

    /// 存储根整个不进备份：配对与本次安装的标记跟着这台设备走。
    /// 反证：去掉 resolve 里的 excludeFromBackup，断言变红。
    func testRootIsExcludedFromBackup() throws {
        let tmp = TempDir()
        let root = try StorageRoot.resolve(appPrivateDirectory: tmp.file("private"), logger: RecordingLogger())
        XCTAssertEqual(try root.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, root.url.path)
    }
}

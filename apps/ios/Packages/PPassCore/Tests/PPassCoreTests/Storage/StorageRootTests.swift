// #338 验收 2：取不到 App Group 容器时退回 App 私有目录，**必须说实话**——日志里写明，返回值里带着降级原因。
import Foundation
import XCTest
@testable import PPassCore

final class StorageRootTests: XCTestCase {

    func testAppGroupContainerIsUsedWhenAvailable() throws {
        let tmp = TempDir()
        let logger = RecordingLogger()
        let root = try StorageRoot.resolve(
            appGroupContainer: tmp.file("group"), groupIdentifier: "group.com.hawkeyexb.ppass",
            appPrivateDirectory: tmp.file("private"), logger: logger
        )
        XCTAssertEqual(root.kind, .appGroup)
        XCTAssertFalse(root.isDegraded)
        XCTAssertEqual(root.url.path, tmp.file("group/PPass").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.url.path))
        XCTAssertFalse(logger.contains("DEGRADED"))
    }

    /// 反证：把降级分支改成「静默用私有目录、kind 仍报 appGroup」，这里三条断言全红。
    func testMissingContainerFallsBackAndSaysSo() throws {
        let tmp = TempDir()
        let logger = RecordingLogger()
        let root = try StorageRoot.resolve(
            appGroupContainer: nil, groupIdentifier: "group.com.hawkeyexb.ppass",
            appPrivateDirectory: tmp.file("private"), logger: logger
        )
        XCTAssertTrue(root.isDegraded)
        guard case let .appPrivateFallback(reason) = root.kind else { return XCTFail("expected fallback") }
        XCTAssertTrue(reason.contains("group.com.hawkeyexb.ppass"), reason)
        XCTAssertEqual(root.url.path, tmp.file("private/PPass").path)
        XCTAssertTrue(logger.contains("storage: DEGRADED"), "\(logger.lines)")
    }

    /// 容器路径在、但写不进去（这里用一个普通文件占住目录位置来构造）：同样降级并说明原因。
    func testUnwritableContainerFallsBack() throws {
        let tmp = TempDir()
        tmp.write("group", "not a directory")
        let logger = RecordingLogger()
        let root = try StorageRoot.resolve(
            appGroupContainer: tmp.file("group"), groupIdentifier: "group.x",
            appPrivateDirectory: tmp.file("private"), logger: logger
        )
        XCTAssertTrue(root.isDegraded)
        XCTAssertTrue(logger.contains("不可写"), "\(logger.lines)")
    }

    /// 存储根整个不进备份（两种根都是）：配对与本次安装的标记跟着这台设备走。
    /// 反证：去掉 resolve 里的 excludeFromBackup，两条断言都红。
    func testRootIsExcludedFromBackupInBothKinds() throws {
        let tmp = TempDir()
        let group = try StorageRoot.resolve(appGroupContainer: tmp.file("group"), groupIdentifier: "g",
                                            appPrivateDirectory: tmp.file("private"), logger: RecordingLogger())
        let fallback = try StorageRoot.resolve(appGroupContainer: nil, groupIdentifier: "g",
                                               appPrivateDirectory: tmp.file("private2"), logger: RecordingLogger())
        for root in [group, fallback] {
            XCTAssertEqual(try root.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, root.url.path)
        }
    }
}

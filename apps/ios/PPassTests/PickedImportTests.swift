import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PPass

final class PickedImportTests: XCTestCase {
    /// #1840（产品口径 2026-11-17）：单次入口只允许图片与视频，不允许文件夹。
    /// 视频被选中后走哪条链路由 `testPhotoPickerPayloadAcceptsVideo` 覆盖，这里钉住两件事：
    /// 选择器真的用 `mediaFilter`（不是另写一份），且 `mediaFilter` 就是图片 + 视频。
    /// 反证：`configuration()` 的 filter 改回 `.images` → 第一条红；`mediaFilter` 改成 `.images`
    /// 或 `.livePhotos`（只筛实况照片，普通视频选不到）→ 第二条红。
    func testPickerDoesNotLimitSelectionToImages() {
        let config = PhotoPickerSheet.configuration()
        XCTAssertEqual(config.filter, PhotoPickerSheet.mediaFilter, "选择器必须用 App 定义的那一份过滤条件")
        XCTAssertEqual(PhotoPickerSheet.mediaFilter, .any(of: [.images, .videos]), "允许的类型必须是图片 + 视频")
    }

    func testPhotoPickerPayloadAcceptsVideo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("clip.mov")
        try Data([0, 1, 2, 3]).write(to: url)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: url))

        let described = PHPickedPayload.describe(provider, index: 0)

        XCTAssertTrue(described?.name.hasSuffix(".mov") == true)
        XCTAssertEqual(described?.mime, "video/quicktime")
    }

    func testFilePayloadCopiesSelectedOriginalBytes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        let bytes = Data((0..<256).map { UInt8($0) })
        try bytes.write(to: source)
        let payload = FilePickedPayload(url: source, type: .movie)

        let copied = try await payload.copy(into: dir, fileName: "clip.mov")

        XCTAssertEqual(try Data(contentsOf: copied), bytes)
        XCTAssertEqual(copied.lastPathComponent, "clip.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFilePayloadCopiesTheCoordinatedAccessorURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let placeholder = dir.appendingPathComponent("placeholder.mov")
        let prepared = dir.appendingPathComponent("prepared.mov")
        try Data([0]).write(to: placeholder)
        let preparedBytes = Data([1, 2, 3, 4])
        try preparedBytes.write(to: prepared)
        let payload = FilePickedPayload(url: placeholder, type: .movie, coordinateRead: { _, accessor in
            accessor(prepared)
            return nil
        })

        let copied = try await payload.copy(into: dir, fileName: "clip.mov")

        XCTAssertEqual(try Data(contentsOf: copied), preparedBytes, "必须复制协调回调提供的实体内容，不能复制原占位 URL")
    }

    func testFilePayloadPropagatesCoordinationFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.mov")
        try Data([0]).write(to: source)
        let expected = NSError(domain: "PickedImportTests", code: 41)
        let payload = FilePickedPayload(url: source, type: .movie, coordinateRead: { _, _ in expected })

        do {
            _ = try await payload.copy(into: dir, fileName: "clip.mov")
            XCTFail("协调失败不能复制原 URL")
        } catch {
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["source.mov"], "失败目录必须清理")
    }
}


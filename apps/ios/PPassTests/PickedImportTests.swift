import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import PPass

final class PickedImportTests: XCTestCase {
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


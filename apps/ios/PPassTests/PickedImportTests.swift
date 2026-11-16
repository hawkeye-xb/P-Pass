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
}


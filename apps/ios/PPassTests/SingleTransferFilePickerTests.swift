import Foundation
import XCTest
@testable import PPass

final class SingleTransferFilePickerTests: XCTestCase {
    func testSelectionAcceptsImageAndVideoButSkipsOtherFiles() {
        let urls = [
            URL(fileURLWithPath: "/tmp/photo.jpg"),
            URL(fileURLWithPath: "/tmp/clip.mov"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
        ]

        let items = SingleTransferFilePicker.items(from: urls)

        XCTAssertEqual(items.map(\.fileName), ["photo.jpg", "clip.mov"])
        XCTAssertEqual(items.map(\.mimeType), ["image/jpeg", "video/quicktime"])
    }

    func testSelectionDoesNotTruncateOverOneHundredFiles() {
        let urls = (0..<130).map { URL(fileURLWithPath: "/tmp/clip\($0).mp4") }

        let items = SingleTransferFilePicker.items(from: urls)

        XCTAssertEqual(items.count, 130)
        XCTAssertEqual(items.last?.fileName, "clip129.mp4")
    }

    func testEmptySelectionProducesNoItems() {
        XCTAssertTrue(SingleTransferFilePicker.items(from: []).isEmpty)
    }
}

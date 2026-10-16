import XCTest
import Photos
import UIKit
import PPassMedia

/// #968 真 PhotoKit：收藏不换版本（旧口径 modificationDate 会变，反证），编辑换版本，再编辑再换。
final class ContentVersionIT: XCTestCase {
    private func asset(_ id: String) -> PHAsset { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject! }
    private func content(_ id: String) -> OriginalContent {
        let a = asset(id)
        return readOriginalContent(of: a, resources: PHAssetResource.assetResources(for: a))
    }

    private func edit(_ id: String, tag: String) throws {
        let exp = expectation(description: "edit \(tag)")
        var ok = false
        asset(id).requestContentEditingInput(with: nil) { input, _ in
            guard let input else { exp.fulfill(); return }
            let out = PHContentEditingOutput(contentEditingInput: input)
            out.adjustmentData = PHAdjustmentData(formatIdentifier: "ppass.it", formatVersion: "1", data: Data(tag.utf8))
            let img = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { c in
                UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                (String(repeating: tag, count: tag.count * 40) as NSString).draw(at: .zero, withAttributes: nil)
            }
            try? img.jpegData(compressionQuality: 0.8)!.write(to: out.renderedContentURL)
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest(for: self.asset(id)).contentEditingOutput = out }) { success, _ in
                ok = success; exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
        XCTAssertTrue(ok, "edit \(tag) should commit")
    }

    func testFavoriteKeepsTheVersionAndEditsChangeIt() throws {
        try IT.requireFullAccess()
        let id = try IT.createPhoto(label: "cv-\(IT.nonce)")
        let created = content(id)
        XCTAssertFalse(created.degraded, "模拟器上 fileSize 必须读得到：\(created)")
        let modBefore = try XCTUnwrap(asset(id).modificationDate)

        Thread.sleep(forTimeInterval: 1.2)
        try IT.perform { PHAssetChangeRequest(for: self.asset(id)).isFavorite = true }
        let modAfter = try XCTUnwrap(asset(id).modificationDate)
        XCTAssertGreaterThan(modAfter, modBefore, "前提：收藏推进了 modificationDate（旧口径会因此判成新版本）")
        XCTAssertEqual(content(id).version, created.version, "收藏不换内容版本")

        try edit(id, tag: "a")
        let e1 = content(id)
        XCTAssertNotEqual(e1.version, created.version, "编辑换版本")
        XCTAssertEqual(PHAssetResource.assetResources(for: asset(id))[try XCTUnwrap(e1.resourceIndex)].type, .fullSizePhoto)
        try edit(id, tag: "bb")
        XCTAssertNotEqual(content(id).version, e1.version, "再次编辑再换版本")
    }
}

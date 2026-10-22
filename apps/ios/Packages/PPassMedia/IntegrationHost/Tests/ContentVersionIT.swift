import XCTest
import Photos
import UIKit
import PPassMedia

/// #968 / #1016 真 PhotoKit：收藏、加进相册不换版本（修改时间口径会变，反证），编辑换版本，再编辑再换，还原回到原值。
final class ContentVersionIT: XCTestCase {
    private func asset(_ id: String) -> PHAsset { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject! }
    private let reader = OriginalContentReader()
    /// 同步包一层：测试体里还有 `wait(for:)`（编辑提交），不能整体改成 async。
    private func content(_ id: String) -> OriginalContent {
        let a = asset(id)
        let exp = expectation(description: "read version")
        let box = ContentBox()
        let reader = self.reader
        Task.detached {
            box.value = await reader.read(a, resources: PHAssetResource.assetResources(for: a))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 30)
        return box.value!
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
        XCTAssertFalse(created.degraded, "\(created)")
        let modBefore = try XCTUnwrap(asset(id).modificationDate)

        Thread.sleep(forTimeInterval: 1.2)
        try IT.perform { PHAssetChangeRequest(for: self.asset(id)).isFavorite = true }
        let modAfter = try XCTUnwrap(asset(id).modificationDate)
        XCTAssertGreaterThan(modAfter, modBefore, "前提：收藏推进了 modificationDate（修改时间口径会因此判成新版本）")
        let afterFavorite = content(id)
        XCTAssertEqual(afterFavorite.version, created.version, "收藏不换内容版本")

        try edit(id, tag: "a")
        let e1 = content(id)
        XCTAssertFalse(e1.degraded, "编辑记录读得到：\(e1)")
        XCTAssertNotEqual(e1.version, created.version, "编辑换版本")
        XCTAssertEqual(PHAssetResource.assetResources(for: asset(id))[try XCTUnwrap(e1.resourceIndex)].type, .fullSizePhoto)

        Thread.sleep(forTimeInterval: 1.2)
        try IT.perform { PHAssetChangeRequest(for: self.asset(id)).isFavorite = false }
        let e1Unfavorited = content(id)
        XCTAssertEqual(e1Unfavorited.version, e1.version, "编辑过的照片：取消收藏不换版本（缓存键随修改时间变，重读编辑记录后摘要相同）")

        try edit(id, tag: "bb")
        let e2 = content(id)
        XCTAssertNotEqual(e2.version, e1.version, "再次编辑再换版本")

        try IT.perform { PHAssetChangeRequest(for: self.asset(id)).revertAssetContentToOriginal() }
        let reverted = content(id)
        XCTAssertEqual(reverted.version, created.version, "还原编辑：回到原值")
    }
}

private final class ContentBox: @unchecked Sendable {
    var value: OriginalContent?
}

import XCTest
import Photos
@testable import PPassMedia

/// PhotoKit 变更历史的错误分类与 token 解码：收件箱靠它区分「令牌失效（重置令牌）」与「其他错误（原样上抛）」。
final class ChangeHistoryTests: XCTestCase {
    func testOnlyExpiryLikeErrorsInvalidateTheToken() {
        for e in [ChangeHistoryError.tokenExpired, .detailsUnavailable, .undecodableToken] {
            XCTAssertTrue(e.invalidatesToken)
        }
        XCTAssertFalse(ChangeHistoryError.other(code: 3311, domain: PHPhotosErrorDomain).invalidatesToken,
                       "授权被拒不是「token 过期」，不许悄悄重置")
    }

    func testPhotoKitErrorClassification() {
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3105)), .tokenExpired)
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3210)), .detailsUnavailable)
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: PHPhotosErrorDomain, code: 3311)),
                       .other(code: 3311, domain: PHPhotosErrorDomain))
        XCTAssertEqual(PhotoKitChangeHistory.classify(NSError(domain: NSCocoaErrorDomain, code: 3105)),
                       .other(code: 3105, domain: NSCocoaErrorDomain), "只认 PHPhotosErrorDomain 的 3105")
    }

    func testGarbageBytesAreUndecodable() {
        XCTAssertThrowsError(try PhotoKitChangeHistory().changes(since: ChangeToken(archived: Data("not a token".utf8)))) {
            XCTAssertEqual($0 as? ChangeHistoryError, .undecodableToken)
        }
    }
}

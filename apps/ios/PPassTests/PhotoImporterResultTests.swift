import PPassCore
import PPassMedia
import XCTest
@testable import PPass

/// #337 / #311 D4：取原图失败 → 引擎导入结果。只有「资源确实不可得」抛错计次，其余都不扣失败预算。
/// 反证：`localStorageFull` 曾落进 `default: throw`，手机空间不足被当成这张照片失败、扣预算。
final class PhotoImporterResultTests: XCTestCase {
    func testOnlyUnavailableIsCountedAsFailure() {
        XCTAssertEqual(PhotoImporter.result(for: .sourceMissing), .sourceMissing)
        XCTAssertEqual(PhotoImporter.result(for: .network(reason: "NSURLErrorDomain#-1009")),
                       .originalUnavailable(reason: "NSURLErrorDomain#-1009"))
        XCTAssertEqual(PhotoImporter.result(for: .localStorageFull(reason: "PHPhotosErrorDomain#3305")),
                       .localStorageFull(reason: "PHPhotosErrorDomain#3305"))
        XCTAssertNil(PhotoImporter.result(for: .unavailable(reason: "no original resource")))
    }

    func testProgressCountsCallbacks() {
        let p = OriginalProgress()
        XCTAssertEqual(p.snapshot().count, 0)
        p.record(0.25); p.record(1.0)
        XCTAssertEqual(p.snapshot().count, 2)
        XCTAssertEqual(p.snapshot().last, 1.0)
    }
}

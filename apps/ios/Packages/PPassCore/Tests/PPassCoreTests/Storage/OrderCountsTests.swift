// #973：首页计数读库失败要抛出去，不许落成 0。
import Foundation
import XCTest
@testable import PPassCore

final class OrderCountsTests: XCTestCase {
    private struct Boom: Error {}

    /// 按读口逐个让它失败的账本替身。
    private final class Stub: OrderCountReading, @unchecked Sendable {
        var failing: Set<String> = []
        func countCurrentByState(bucketIds: Set<String>?) throws -> [OrderState: Int64] {
            if failing.contains("byState") { throw Boom() }
            return [.failed: 2, .pending: 3]
        }
        func countConfirmedPresent(bucketIds: Set<String>?) throws -> Int64 {
            if failing.contains("confirmed") { throw Boom() }
            return 10
        }
        func lastConfirmedAtMs() throws -> Int64 {
            if failing.contains("last") { throw Boom() }
            return 777
        }
        func countSourceMissingSkipped(afterMs: Int64, upToMs: Int64) throws -> Int64 {
            if failing.contains("missing") { throw Boom() }
            return afterMs == 0 ? 4 : 1
        }
    }

    func testReadsAllFiveFigures() throws {
        let c = try OrderCounts.read(from: Stub(), missingSourceAckAt: 50, nowMs: 100)
        XCTAssertEqual(c.byState[.failed], 2)
        XCTAssertEqual(c.confirmed, 10)
        XCTAssertEqual(c.lastSuccessAt, 777)
        XCTAssertEqual(c.missingSourceUnacknowledged, 1)
        XCTAssertEqual(c.missingSourceAcknowledged, 4)
    }

    func testAnySingleReadFailureThrowsInsteadOfZero() {
        for which in ["byState", "confirmed", "last", "missing"] {
            let s = Stub(); s.failing = [which]
            XCTAssertThrowsError(try OrderCounts.read(from: s, missingSourceAckAt: 50, nowMs: 100), which)
        }
    }

    func testNoAckSkipsAcknowledgedRead() throws {
        let s = Stub()
        let c = try OrderCounts.read(from: s, missingSourceAckAt: 0, nowMs: 100)
        XCTAssertEqual(c.missingSourceAcknowledged, 0)
    }
}

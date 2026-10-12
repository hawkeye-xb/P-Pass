// #338 验收 4：暂停（PAUSED_BY_USER）跨重启不被解除；等待原因持久化；写盘失败不崩、内存值照样生效。
import Foundation
import XCTest
@testable import PPassCore

final class FlowControlStoreTests: XCTestCase {

    /// 反证：把 paused 只放内存（不写盘），新实例读回 false，红。
    func testPauseSurvivesRestart() {
        let tmp = TempDir()
        FlowControlStore(directory: tmp.url).setPaused(true)
        XCTAssertTrue(FlowControlStore(directory: tmp.url).paused())
        FlowControlStore(directory: tmp.url).setPaused(false)
        XCTAssertFalse(FlowControlStore(directory: tmp.url).paused())
    }

    func testWaitReasonSurvivesRestartAndUnknownValuesReadAsNone() {
        let tmp = TempDir()
        FlowControlStore(directory: tmp.url).setWaitReason(.originalUnavailable)
        XCTAssertEqual(FlowControlStore(directory: tmp.url).waitReason(), .originalUnavailable)
        FlowControlStore(directory: tmp.url).setWaitReason(nil)
        XCTAssertNil(FlowControlStore(directory: tmp.url).waitReason())
        tmp.write(FlowControlStore.fileName, #"{"paused":true,"waitReason":"FGS_BLOCKED"}"#)
        let s = FlowControlStore(directory: tmp.url)
        XCTAssertTrue(s.paused())
        XCTAssertNil(s.waitReason(), "Android 才有的原因名在 iOS 上不认识 → 没在等")
    }

    func testLeaseBlockKeepsTheFirstReasonUntilCleared() {
        let tmp = TempDir()
        let s = FlowControlStore(directory: tmp.url, clock: { 7 })
        s.recordLeaseBlock(.expired)
        s.recordLeaseBlock(.refused)
        XCTAssertEqual(FlowControlStore(directory: tmp.url).leaseBlock(), .expired)
        s.clearLeaseBlock()
        XCTAssertNil(FlowControlStore(directory: tmp.url).leaseBlock())
    }

    func testRetryLadderAndAckWatermarkRoundTrip() {
        let tmp = TempDir()
        FlowControlStore(directory: tmp.url).setRetryLadderSpent(true)
        FlowControlStore(directory: tmp.url).setMissingSourceAckAt(123)
        let s = FlowControlStore(directory: tmp.url)
        XCTAssertTrue(s.retryLadderSpent())
        XCTAssertEqual(s.missingSourceAckAt(), 123)
    }

    func testCorruptFileReadsAsDefaults() {
        let tmp = TempDir()
        tmp.write(FlowControlStore.fileName, "\u{0}\u{1}")
        let logger = RecordingLogger()
        let s = FlowControlStore(directory: tmp.url, logger: logger)
        XCTAssertFalse(s.paused())
        XCTAssertNil(s.waitReason())
        XCTAssertTrue(logger.contains("flow-control.json unreadable"))
    }

    /// 写盘失败（这里用一个同名目录占住文件位置）：不抛、不崩，内存里的值生效，并记一行日志。
    func testWriteFailureKeepsTheInMemoryValue() throws {
        let tmp = TempDir()
        try FileManager.default.createDirectory(at: tmp.file(FlowControlStore.fileName), withIntermediateDirectories: true)
        let logger = RecordingLogger()
        let s = FlowControlStore(directory: tmp.url, logger: logger)
        s.setPaused(true)
        XCTAssertTrue(s.paused())
        XCTAssertTrue(logger.contains("flow-control: write failed"), "\(logger.lines)")
    }
}

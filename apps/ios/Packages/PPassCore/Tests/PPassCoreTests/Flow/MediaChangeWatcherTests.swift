// #978：前台相册变化监听。对位 Android BackupUiStateHolder 的 MediaStore ContentObserver →
// `gateway.onMediaChanged()`（FOREGROUND_MEDIA_CHANGE，人在场）+ 重算首页计数。
import Foundation
import XCTest
@testable import PPassCore

private final class FakeSource: MediaChangeSource, @unchecked Sendable {
    var starts = 0
    var stops = 0
    var handler: (@Sendable () -> Void)?
    func start(_ onChange: @escaping @Sendable () -> Void) { starts += 1; handler = onChange }
    func stop() { stops += 1; handler = nil }
}

private final class WatcherLogLines: CoreLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func log(_ message: String) { lock.lock(); lines.append(message); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class MediaChangeWatcherTests: XCTestCase {
    private final class Box: @unchecked Sendable { var reason: String?; var fired = 0 }

    private func makeWatcher(_ source: FakeSource, _ box: Box, _ logger: CoreLogger = NoopLogger()) -> MediaChangeWatcher {
        MediaChangeWatcher(source: source, unavailableReason: { box.reason }, onChange: { box.fired += 1 }, logger: logger)
    }

    func testStartRegistersOnceAndIsIdempotent() {
        let source = FakeSource(), box = Box()
        let watcher = makeWatcher(source, box)
        XCTAssertTrue(watcher.start())
        XCTAssertTrue(watcher.start())
        XCTAssertEqual(source.starts, 1, "重复 start（每次回前台都会调）不重复注册")
        source.handler?()
        XCTAssertEqual(box.fired, 1)
    }

    /// 没条件（未配对 / 相册没授权）不注册，且要有日志（不静默吞）；同一原因只记一次；条件满足后再 start 才注册。
    func testUnavailableDoesNotRegisterLogsOnceAndRecovers() {
        let source = FakeSource(), box = Box(), logger = WatcherLogLines()
        let watcher = makeWatcher(source, box, logger)
        box.reason = "photo access denied"
        XCTAssertFalse(watcher.start())
        XCTAssertFalse(watcher.start())
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(logger.all.filter { $0.contains("photo access denied") }.count, 1, "同一原因只记一次，别刷屏")
        box.reason = nil
        XCTAssertTrue(watcher.start())
        XCTAssertEqual(source.starts, 1)
    }

    /// 断开：注销；没注册时 stop 不碰 source；重新配对后可以再注册（#974 的 stopMediaChangeObserver 对位）。
    func testStopUnregistersAndRestartRegistersAgain() {
        let source = FakeSource(), box = Box()
        let watcher = makeWatcher(source, box)
        watcher.stop()
        XCTAssertEqual(source.stops, 0)
        _ = watcher.start()
        watcher.stop()
        XCTAssertEqual(source.stops, 1)
        XCTAssertFalse(watcher.isRegistered)
        XCTAssertTrue(watcher.start())
        XCTAssertEqual(source.starts, 2)
    }

    /// 注销之后到达的旧回调（系统线程上的在途通知）不能再往引擎里灌。
    func testACallbackFromAStaleRegistrationIsIgnored() {
        let source = FakeSource(), box = Box()
        let watcher = makeWatcher(source, box)
        _ = watcher.start()
        let stale = source.handler
        watcher.stop()
        stale?()
        XCTAssertEqual(box.fired, 0)
        _ = watcher.start()
        stale?()
        XCTAssertEqual(box.fired, 0, "重新注册之后，旧注册的回调仍然作废")
        source.handler?()
        XCTAssertEqual(box.fired, 1)
    }
}

final class ForegroundMediaChangeTests: XCTestCase {
    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// 前台：先重算首页计数，再以 FOREGROUND_MEDIA_CHANGE 叫醒引擎（人在场，不查后台开关）。
    func testForegroundRecountsThenTriggersTheForegroundReason() async {
        let trace = Trace()
        let change = ForegroundMediaChange(isForeground: { true }, recount: { trace.add("recount") },
                                           trigger: { trace.add("trigger:\($0.rawValue)") })
        await change.handle()
        XCTAssertEqual(trace.all, ["recount", "trigger:FOREGROUND_MEDIA_CHANGE"])
    }

    /// 不在前台（后台任务窗口里进程活着时收到通知）：只重算计数，不叫醒引擎——后台由 BGTask 管（对位 Android isAppVisible 判断）。
    func testNotForegroundOnlyRecounts() async {
        let trace = Trace()
        let change = ForegroundMediaChange(isForeground: { false }, recount: { trace.add("recount") },
                                           trigger: { trace.add("trigger:\($0.rawValue)") })
        await change.handle()
        XCTAssertEqual(trace.all, ["recount"])
    }

    /// 引擎侧的两条前提（分发只管触发，这两条决定触发后的行为）：人在场不查后台开关；在跑时合并并重算待办。
    func testTheReasonIsUserPresentAndRecountedWhileRunning() {
        XCTAssertTrue(TriggerReason.foregroundMediaChange.userPresent)
        XCTAssertTrue(FlowEngine.recountWhileRunning.contains(.foregroundMediaChange))
    }
}

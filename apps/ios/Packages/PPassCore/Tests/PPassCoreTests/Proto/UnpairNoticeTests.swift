// #956 关闭裁决（2026-10-22）：主动断开时尽力通知电脑一次，收到就收到，没收到就算了；之后不再有任何动作。#1239：不等通知——立刻清本地，通知在后台发。
import Foundation
import XCTest
@testable import PPassCore

final class UnpairNoticeTests: XCTestCase {
    private struct Unreachable: Error {}

    /// 反证：把 sendOnce 改回「失败就再试」或在里面循环 → 调用次数不是 1 → 红。
    func testAnUnreachableDesktopIsTriedExactlyOnceWithThePairingIdAndAShortTimeout() async {
        let transport = ScriptedTransport { _, _ in throw Unreachable() }
        let logger = RecordingLogger()
        await UnpairNotice.sendOnce(transport, daemonNodeId: "desk-A", pairingId: "e1", logger: logger)
        XCTAssertEqual(transport.calls.map(\.method), [Methods.deviceUnpair])
        XCTAssertEqual(transport.calls.first?.params, .object(["pairing_id": .string("e1")]))
        XCTAssertEqual(transport.calls.first?.timeoutMs, 5_000, "对位 Android：5 秒")
        XCTAssertTrue(logger.contains("unreachable"))
        XCTAssertTrue(logger.contains("not retried"))
    }

    /// 电脑接了连接却不回（或建端点卡住）：到截止就不等了，不卡住断开。
    /// 反证：去掉 firstWithin、直接 await 调用 → 永远等不到，expectation 超时 → 红。
    func testASilentDesktopIsGivenUpAtTheDeadline() async {
        let gate = UnpairTestGate() // 永不放行
        let logger = RecordingLogger()
        let returned = expectation(description: "sendOnce returns at the deadline")
        Task {
            await UnpairNotice.sendOnce(GatedTransport(gate: gate), daemonNodeId: "d", pairingId: "e1",
                                        logger: logger, deadlineMs: 50)
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertTrue(logger.contains("no reply within 50 ms"))
        XCTAssertEqual(UnpairNotice.timeoutMs, 5_000, "生产截止对位 Android：5 秒")
    }

    func testALegacyPairingWithoutAnPairingIdSendsNoPairingId() async {
        let transport = ScriptedTransport { _, _ in Resp(id: "1", ok: true, result: .object([:])) }
        await UnpairNotice.sendOnce(transport, daemonNodeId: "desk-A", pairingId: "", logger: NoopLogger())
        XCTAssertEqual(transport.calls.first?.params, .object([:]))
    }

    /// 反证：把实现改回「先 await 通知再清本地」→ 通知挂住时清理永远不发生，expectation 超时 → 红。
    func testLocalStateIsClearedWhileTheNoticeIsStillHanging() async {
        let gate = UnpairTestGate() // 永不放行
        let events = UnpairEvents()
        await UnpairNotice.disconnect(
            notify: { events.add("notify-start"); await gate.state.enter(); events.add("notify-end") },
            clearLocal: { events.add("clear") })
        // disconnect 已经返回：清理发生在通知完成之前
        XCTAssertTrue(events.snapshot.contains("clear"))
        XCTAssertFalse(events.snapshot.contains("notify-end"))
        await gate.waitUntilEntered() // 通知确实已在后台开始（并挂在门上）
        gate.open() // 放行后后台通知才结束，不泄漏
    }

    /// 通知只发一次；不可达（抛错）不影响清理。反证：把 clearLocal 挪进「通知成功」分支 → 红。
    func testAnUnreachableNoticeIsSentOnceAndLocalStateIsStillCleared() async {
        let transport = ScriptedTransport { _, _ in throw Unreachable() }
        let cleared = UnpairCounter()
        let sent = expectation(description: "notice attempted")
        await UnpairNotice.disconnect(
            notify: {
                await UnpairNotice.sendOnce(transport, daemonNodeId: "d", pairingId: "e1", logger: NoopLogger())
                sent.fulfill()
            },
            clearLocal: { cleared.add() })
        XCTAssertEqual(cleared.value, 1)
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(transport.calls.count, 1)
    }

    /// 断开所在的任务被取消（界面被关掉）：清理照样执行，后台通知不受影响（不是子任务）。
    func testCleanupAndNoticeSurviveTheDisconnectTaskBeingCancelled() async {
        let cleared = UnpairCounter()
        let noticed = expectation(description: "notice ran despite cancellation")
        let task = Task {
            await UnpairNotice.disconnect(
                notify: { XCTAssertFalse(Task.isCancelled); noticed.fulfill() },
                clearLocal: { cleared.add() })
        }
        task.cancel()
        await task.value
        XCTAssertEqual(cleared.value, 1)
        await fulfillment(of: [noticed], timeout: 5)
    }

    /// 老版本的发件箱存着旧电脑的 peerToken：启动删掉，伴生临时文件一起；别的文件不碰。
    func testTheLegacyOutboxIsRemovedAtStartup() {
        let dir = TempDir()
        dir.write("pending_unpair.json", #"{"entries":[{"peerToken":"SECRET"}]}"#)
        dir.write("pending_unpair.json.tmp", "SECRET")
        dir.write("onboarded_desktops.json", "{}")
        let logger = RecordingLogger()
        UnpairNotice.removeLegacyOutbox(root: dir.url, logger: logger)
        XCTAssertNil(dir.read("pending_unpair.json"))
        XCTAssertNil(dir.read("pending_unpair.json.tmp"))
        XCTAssertEqual(dir.read("onboarded_desktops.json"), "{}")
        XCTAssertTrue(logger.contains("removed legacy outbox"))
    }

    /// 没升级前就断开过、启动清理又失败的那份：断开清单也清它（CLEAR，不是 KEEP）。
    func testTheDisconnectManifestClearsTheLegacyOutbox() throws {
        let dir = TempDir()
        dir.write("pending_unpair.json", "SECRET")
        XCTAssertEqual(unregisteredStatePaths(root: dir.url), [], "旧文件必须登记在断开清单里")
        XCTAssertEqual(DisconnectState.legacyUnpairOutbox.disposition, .clear)
        try applyDisconnectManifest(root: dir.url, runtime: NoRuntime(), manifest: [.legacyUnpairOutbox])
        XCTAssertNil(dir.read("pending_unpair.json"))
    }

    /// 「之后回前台 / 网络恢复 / 重启都不再发」的结构门禁：生产代码里 `device.unpair` 只有一个发送点
    /// （UnpairNotice.sendOnce），它只有一个调用点（LivePairing.disconnect）。
    /// 反证：在 PPassApp 的 `.active` 分支或 LiveBackend.start 里加一行 sendOnce / deviceUnpair → 红。
    func testTheOnlyUnpairSenderIsTheDisconnectAction() throws {
        let ios = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ios.appendingPathComponent("project.yml").path), "定位 apps/ios 失败: \(ios.path)")
        var senders: [String] = [], callers: [String] = []
        let files = FileManager.default.enumerator(at: ios, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let rel = String(url.path.dropFirst(ios.path.count + 1))
            if rel.split(separator: "/").contains(where: { $0.hasSuffix("Tests") || $0 == "build" || $0 == ".build" }) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("Methods.deviceUnpair") || text.contains("\"device.unpair\"") { senders.append(rel) }
            if text.contains("UnpairNotice.sendOnce(") { callers.append(rel) }
        }
        XCTAssertEqual(senders.sorted(), ["Packages/PPassCore/Sources/PPassCore/Proto/Messages.swift",
                                          "Packages/PPassCore/Sources/PPassCore/Proto/UnpairNotice.swift"])
        XCTAssertEqual(callers, ["PPass/Live/LivePairing.swift"])
    }
}

private struct NoRuntime: DisconnectRuntime {
    func stopFlowRuntime() {}
    func cancelScheduledWakes() {}
    func stopMediaChangeObserver() {}
    func clearThumbnailMemoryCache() {}
}

private final class UnpairEvents: @unchecked Sendable {
    private let lock = NSLock(); private var e: [String] = []
    func add(_ s: String) { lock.lock(); e.append(s); lock.unlock() }
    var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return e }
}

private final class UnpairCounter: @unchecked Sendable {
    private let lock = NSLock(); private var v = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
    func add() { lock.lock(); v += 1; lock.unlock() }
}

private actor UnpairTestGateState {
    var entered = false, opened = false
    var enteredWaiters: [CheckedContinuation<Void, Never>] = [], openWaiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }; enteredWaiters = []
        if !opened { await withCheckedContinuation { openWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }
    func open() { opened = true; openWaiters.forEach { $0.resume() }; openWaiters = [] }
}

private struct UnpairTestGate: Sendable {
    let state = UnpairTestGateState()
    func waitUntilEntered() async { await state.waitUntilEntered() }
    func open() { Task { await state.open() } }
}

/// 进来后挂住，放行后按「连不上」失败。
private struct GatedTransport: CtrlTransport {
    let gate: UnpairTestGate
    struct Unreachable: Error {}
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        await gate.state.enter()
        throw Unreachable()
    }
}

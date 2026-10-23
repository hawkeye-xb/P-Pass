// #1119：被拒即清理，从「应答」到「配对记录没了 / 后台任务取消 / 缓存清空 / 回欢迎页」的整条链。
// 用真实的 PairingStore、PlannedWakeScheduler、断开清单与 RejectedPairingCleanup；传输用脚本化的假传输，BGTask 提交器可注入。
import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

private final class CountingSubmitter: BackgroundTaskSubmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var longs = 0, shorts = 0, cancelCount = 0
    var submitted: Int { lock.lock(); defer { lock.unlock() }; return longs + shorts }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancelCount }
    func submit(_ spec: BackgroundTaskRequestSpec) throws { lock.lock(); longs += 1; lock.unlock() }
    func submitShort(earliestBeginDate: Date) throws { lock.lock(); shorts += 1; lock.unlock() }
    func cancelAll() { lock.lock(); cancelCount += 1; lock.unlock() }
}

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private struct ScriptedHello: CtrlTransport {
    enum Behavior { case reject(String), helloWithoutPairingId, helloWithPairingId(String), unreachable }
    let behavior: Behavior
    struct Down: Error {}
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        switch behavior {
        case .unreachable: throw Down()
        case .reject(let reason):
            return try ProtoJSON.encode(Resp(ok: false, error: RespError(code: "x", reason: reason)))
        case .helloWithoutPairingId:
            return try ProtoJSON.encode(Resp(ok: true, result: .object(["capabilities": .array([])])))
        case .helloWithPairingId(let id):
            return try ProtoJSON.encode(Resp(ok: true, result: .object(["capabilities": .array([]), "pairing_id": .string(id)])))
        }
    }
}

final class RejectedPairingCleanupWiringTests: XCTestCase {
    private var base: URL!
    private var root: URL { base.appendingPathComponent("root") }
    private var caches: URL { base.appendingPathComponent("caches") }
    private var tmp: URL { base.appendingPathComponent("tmp") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rejected-cleanup-\(UUID().uuidString)")
        for d in [root, caches, tmp] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private final class Rig: @unchecked Sendable {
        let store: PairingStore
        let submitter = CountingSubmitter()
        let loss = PairingLoss()
        let announced = Count()
        let cleared = Count()
        let scheduler: PlannedWakeScheduler
        var cleanup: RejectedPairingCleanup!
        let probe: ControlPlaneProbe

        init(root: URL, caches: URL, tmp: URL, behavior: ScriptedHello.Behavior) throws {
            let store = PairingStore(root: root)
            self.store = store
            try store.save(PairingRecord(daemonNodeId: "d", peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
            let submitter = self.submitter
            scheduler = PlannedWakeScheduler(directory: root, submitter: submitter, logger: NoopLogger(), isPaired: { store.load() != nil })
            let scheduler = self.scheduler
            let pairingId: @Sendable () -> String? = { store.load()?.pairingId }
            let desktop = ControlPlaneDesktop(client: ProtoClient(transport: ScriptedHello(behavior: behavior)), localPairingId: pairingId)
            probe = ControlPlaneProbe(currentPairingId: pairingId, desktop: desktop, logger: NoopLogger(), pairingLoss: loss, timeoutMs: 2_000)
            let announced = self.announced, cleared = self.cleared
            let external = DisconnectExternalRoots(caches: caches, tmp: tmp)
            cleanup = RejectedPairingCleanup(
                localPairingId: pairingId,
                announce: { _ in announced.bump() },
                clear: {
                    cleared.bump()
                    let actions = DisconnectActions(stopFlow: {}, cancelWakes: { scheduler.stop() }, stopMedia: {}, clearThumbs: {})
                    try? applyDisconnectManifest(root: root, runtime: actions, external: external)
                },
                logger: NoopLogger())
            let cleanup = self.cleanup!
            loss.setOnLost { id in Task { await cleanup.handle(rejectedPairingId: id) } }
        }
    }

    private func fillCaches() throws {
        let fm = FileManager.default
        for dir in [caches.appendingPathComponent("ppass-videos"), tmp.appendingPathComponent("ppass-share")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([1]).write(to: dir.appendingPathComponent("a.bin"))
            try Data([1]).write(to: dir.appendingPathComponent("b.part"))
        }
        try Data([1]).write(to: caches.appendingPathComponent("video-1.mp4.part")) // 不属于清单的文件：不碰（Android 的文件名，这里只是占位）
    }

    private func isEmpty(_ dir: URL) -> Bool { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out: \(what)")
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    /// 明确的「未配对」信号（not_paired / pairing_mismatch / hello 无 pairing_id / hello 带的代号与本地不同）：
    /// 配对记录被删、后台任务取消、缓存清空；再收到一次拒绝是空操作（只清一次）。
    /// 反证：把任一信号从触发面里拿掉（例如 `ControlPlaneDesktop.hello` 不再核对 pairing_id，或 reasonClass 把 not_paired 归成单张失败），
    /// 对应那一轮的 `cleared == 1` 红；去掉 RejectedPairingCleanup 里的 claim / 代号比较，第二次探测会再清一次，红。
    func testAnUnpairedSignalDeletesThePairingCancelsTasksClearsCachesAndOnlyOnce() async throws {
        let behaviors: [(String, ScriptedHello.Behavior)] = [
            ("not_paired", .reject("not_paired")), ("pairing_mismatch", .reject("pairing_mismatch")),
            ("hello 无 pairing_id", .helloWithoutPairingId), ("hello 代号不一致", .helloWithPairingId("e2")),
        ]
        for (name, behavior) in behaviors {
            try? FileManager.default.removeItem(at: base)
            try setUpWithError()
            try fillCaches()
            let rig = try Rig(root: root, caches: caches, tmp: tmp, behavior: behavior)
            let first = await rig.probe.probe()
            XCTAssertEqual(first, .pairingLost, name)
            await waitUntil("\(name): 清理完成") { rig.store.load() == nil && rig.submitter.cancels >= 1 }
            XCTAssertNil(rig.store.load(), "\(name): 配对记录被删")
            XCTAssertEqual(rig.submitter.cancels, 1, "\(name): 后台任务取消（长 + 短由提交器一次取消）")
            XCTAssertTrue(isEmpty(caches.appendingPathComponent("ppass-videos")) || !FileManager.default.fileExists(atPath: caches.appendingPathComponent("ppass-videos").path), "\(name): 视频缓存清空")
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ppass-share").path), "\(name): 照片临时目录清空")
            XCTAssertEqual(rig.announced.value, 1, "\(name): 提示一次")

            // 清完之后再收到拒绝（迟到的应答 / 另一条路径）：空操作。
            rig.loss.markLost(pairingId: "e1")
            await settle()
            XCTAssertEqual(rig.cleared.value, 1, "\(name): 只清一次")
            XCTAssertEqual(rig.submitter.cancels, 1, "\(name): 没有第二次取消")
            XCTAssertEqual(rig.announced.value, 1)
        }
    }

    /// role_forbidden / 超时 / 连不上 / 版本不匹配 / 其它拒绝：不清。
    /// 反证：把 role_forbidden 归回 `.pairingLost`（或把超时、不可达也按未配对处理），对应那一轮配对记录被删，红。
    func testOtherFailuresLeaveEverythingInPlace() async throws {
        let behaviors: [(String, ScriptedHello.Behavior)] = [
            ("role_forbidden", .reject("role_forbidden")), ("phone_outdated", .reject("phone_outdated")), ("desktop_outdated", .reject("desktop_outdated")),
            ("unsupported_method", .reject("unsupported_method")), ("internal", .reject("internal")), ("未登记的 reason", .reject("from_the_future")),
            ("连不上", .unreachable), ("hello 代号一致", .helloWithPairingId("e1")),
        ]
        for (name, behavior) in behaviors {
            try? FileManager.default.removeItem(at: base)
            try setUpWithError()
            try fillCaches()
            let rig = try Rig(root: root, caches: caches, tmp: tmp, behavior: behavior)
            let result = await rig.probe.probe()
            XCTAssertNotEqual(result, .pairingLost, name)
            await settle()
            XCTAssertNotNil(rig.store.load(), "\(name): 配对记录还在")
            XCTAssertEqual(rig.submitter.cancels, 0, "\(name): 不取消后台任务")
            XCTAssertFalse(isEmpty(caches.appendingPathComponent("ppass-videos")), "\(name): 缓存不动")
            XCTAssertEqual(rig.cleared.value, 0, name)
        }
    }

    /// 超时（hello 永不返回）：不是拒绝，不清。
    func testAHelloTimeoutDoesNotClean() async throws {
        struct Hang: CtrlTransport {
            func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CancellationError()
            }
        }
        try fillCaches()
        let store = PairingStore(root: root)
        try store.save(PairingRecord(daemonNodeId: "d", peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
        let loss = PairingLoss()
        let fired = Count()
        loss.setOnLost { _ in fired.bump() }
        let pairingId: @Sendable () -> String? = { store.load()?.pairingId }
        let desktop = ControlPlaneDesktop(client: ProtoClient(transport: Hang()), localPairingId: pairingId)
        let result = await ControlPlaneProbe(currentPairingId: pairingId, desktop: desktop, logger: NoopLogger(), pairingLoss: loss, timeoutMs: 50).probe()
        XCTAssertEqual(result, .unreachable)
        await settle()
        XCTAssertEqual(fired.value, 0)
        XCTAssertNotNil(store.load())
    }

    /// 手动断开 / 被拒即清理走同一份清单：断开之后所有后台任务已取消，缓存目录没了；之后（已无配对）启动 / 回前台的重排不再提交。
    /// 反证：清单里去掉缓存行或 cancelWakes 不调 `scheduler.stop()`，对应断言红；去掉 scheduler 的 isPaired 门禁，最后两条红。
    func testManualDisconnectEmptiesCachesCancelsEverythingAndNothingIsResubmittedWhileUnpaired() throws {
        try fillCaches()
        let store = PairingStore(root: root)
        try store.save(PairingRecord(daemonNodeId: "d", peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
        let submitter = CountingSubmitter()
        let scheduler = PlannedWakeScheduler(directory: root, submitter: submitter, logger: NoopLogger(), isPaired: { store.load() != nil })
        scheduler.ensureScheduled()
        scheduler.ensureShortScheduled()
        XCTAssertEqual(submitter.submitted, 2, "已配对：长任务和短任务都挂着")

        let actions = DisconnectActions(stopFlow: {}, cancelWakes: { scheduler.stop() }, stopMedia: {}, clearThumbs: {})
        try applyDisconnectManifest(root: root, runtime: actions, external: DisconnectExternalRoots(caches: caches, tmp: tmp))
        XCTAssertNil(store.load())
        XCTAssertEqual(submitter.cancels, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: caches.appendingPathComponent("ppass-videos").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("ppass-share").path))

        scheduler.ensureScheduled() // 回前台 / 起进程
        scheduler.ensureShortScheduled()
        scheduler.scheduleUnreachableProbes()
        XCTAssertEqual(submitter.submitted, 2, "未配对：不再提交")
    }

    /// 缩略图内存缓存：清单的 thumbnailMemoryCache 行调到 `clearThumbs`。反证：该行改成 keep，calls 为空，红。
    func testTheManifestClearsTheThumbnailMemoryCache() throws {
        let count = Count()
        let actions = DisconnectActions(stopFlow: {}, cancelWakes: {}, stopMedia: {}, clearThumbs: { count.bump() })
        try applyDisconnectManifest(root: root, runtime: actions)
        XCTAssertEqual(count.value, 1)
    }

    // MARK: 回欢迎页

    /// 配对被清掉：配对之后的任何页面都回欢迎页；欢迎页本身与仍有配对（含失效卡）的状态不动。
    /// 反证：把规则改成永远返回原 phase，前三条红；改成无条件回欢迎页，后几条红。
    func testPairingClearedSendsEveryLaterPhaseBackToOnboarding() {
        for phase in [AppModel.Phase.main, .chooseAlbums, .backupStarted(count: 3)] {
            XCTAssertEqual(AppModel.phase(phase, whenPairing: .notPaired), .onboarding)
            XCTAssertEqual(AppModel.phase(phase, whenPairing: .paired(desktopName: "Mac")), phase)
            XCTAssertEqual(AppModel.phase(phase, whenPairing: .lost(desktopName: "Mac")), phase)
        }
        XCTAssertEqual(AppModel.phase(.onboarding, whenPairing: .notPaired), .onboarding)
    }
}

// #891：传输端口（对位 Android `C413DeliveryPortTest` / `ARCH13DeliveryPortTest` / `NET06` / `NET14` / `NET29` /
// `MOB117` / `ARCH01RemotePresenceProbeTest` / `AuditOutboxDispatcherTest`）。
// 真实的 FlowDeliveryPort 等待循环；原生 provider、桌面控制面、推送订阅是假的。时间参数整体缩小到毫秒级、真跑。
//
// 工具链缺陷登记（#938）：Swift 6.3.3（swiftlang-6.3.3.1.3）/ Xcode 26.6（17F113）/ ld-1267。
// - 现象：只改本文件的测试代码（如把读 Rust 常量的测试改成 NSRegularExpression 写法），两条取消类测试
//   （testCancellingADelivery… / testADesktopThatNeverAnswersFlowSuspend…）就稳定崩溃，
//   运行时报 `freed pointer was not the last allocation`（swift_task_dealloc，栈在 waitForCompletion 的 sleep 处）。
// - 机制：公共 init 的默认参数若是 async 闭包字面量，-Onone 下定义模块（PPassCore）和调用方模块（本测试 /
//   App 的 LiveBackend）各生成一份同名 weak 符号，两份记录的 async context 大小不同（80 vs 64 字节）。
//   链接器分别挑函数体和 async 函数指针，可能拼出「80 字节的函数体 + 64 字节的 context」，运行时越界写坏
//   任务分配器。挑哪一份取决于目标文件布局，所以改一段无关的测试代码就能翻转结果。Release（-O）未见此问题。
// - 规避：公共 API 的默认参数里不写 async 闭包字面量；默认值写 `nil`，在函数体里补上（见 DeliveryPort.swift
//   的 `taskSleepMs`）。
// - 复现对布局敏感：改完测试不崩不代表隐患消失。核对办法是在 .build/<config>/PPassCore.build 与
//   PPassCoreTests.build 的全部 .o 上列出在两个以上目标文件里出现的 weak `…Tu` 符号，比较 context 大小，应当全部一致。
import Foundation
import XCTest
@testable import PPassCore

final class FakeProvider: BlobProvider, @unchecked Sendable {
    let status = Locked<() -> TransferStatus>({ .inProgress(connected: false, idleForMs: nil, bytesSent: nil, byteIdleForMs: nil, source: nil) })
    let events = Locked<[String]>([])
    let serveFailure = Locked<Error?>(nil)
    let serveHold = Locked(false)
    let serveGate = Gate()

    func serve(_ lease: ProviderLease) async throws -> String {
        events.update { $0.append("serve:\(lease.orderId)") }
        if serveHold.get() { try? await serveGate.wait() }
        if let f = serveFailure.get() { throw f }
        return "ticket-\(lease.orderId)"
    }

    func transferStatus() -> TransferStatus { status.get()() }
    func pause(_ lease: ProviderLease) { events.update { $0.append("pause:\(lease.orderId)") } }
    func releaseRetention(_ lease: ProviderLease) { events.update { $0.append("release:\(lease.orderId)") } }
}

final class FakeDesktop: FlowDesktop, @unchecked Sendable {
    let offerReply = Locked<FlowStatusReply>(FlowStatusReply(state: "active"))
    let offerError = Locked<Error?>(nil)
    let statusReply = Locked<() throws -> FlowStatusReply>({ FlowStatusReply(state: "active") })
    let statusHang = Locked(false)
    let suspendHang = Locked(false)
    let offers = Locked<[FlowFetchRequest]>([])
    let offerTimes = Locked<[Int64]>([])
    let statusCalls = Locked(0)
    let suspends = Locked<[FlowTupleRef]>([])
    let cancels = Locked<[FlowTupleRef]>([])
    let helloResult = Locked<Result<Hello, Error>>(.success(Hello(capabilities: [], deviceName: "PC", pairingEpoch: "e1")))
    let submitted = Locked<[[String]]>([])
    let accept = Locked<(Set<String>) -> Set<String>>({ $0 })
    let submitFails = Locked(false)
    let missing = Locked<Set<String>>([])
    let helloCalls = Locked(0)
    let helloHang = Locked(false)
    private let never = Gate()

    func releaseHello() { never.open() }

    func hello() async throws -> Hello {
        helloCalls.update { $0 += 1 }
        if helloHang.get() { try await never.wait() }
        return try helloResult.get().get()
    }

    func offer(_ request: FlowFetchRequest) async throws -> FlowStatusReply {
        offers.update { $0.append(request) }
        offerTimes.update { $0.append(Int64(ProcessInfo.processInfo.systemUptime * 1000)) }
        if let e = offerError.get() { throw e }
        return offerReply.get()
    }

    func status(_ tuple: FlowTupleRef) async throws -> FlowStatusReply {
        statusCalls.update { $0 += 1 }
        if statusHang.get() { try await never.wait() }
        return try statusReply.get()()
    }

    func suspendFetch(_ tuple: FlowTupleRef) async throws {
        suspends.update { $0.append(tuple) }
        // 模拟一次阻塞的 FFI 调用：**不响应取消**，永远不回。
        if suspendHang.get() { await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in } }
    }

    func cancelTuple(_ tuple: FlowTupleRef) async throws { cancels.update { $0.append(tuple) } }

    func auditSubmit(_ events: [FlowAuditEvent]) async throws -> FlowAuditAccepted {
        submitted.update { $0.append(events.map(\.eventId)) }
        if submitFails.get() { throw URLError(.notConnectedToInternet) }
        return FlowAuditAccepted(eventIds: Array(accept.get()(Set(events.map(\.eventId)))).sorted())
    }

    func presence(_ query: BackupPresenceQuery) async throws -> BackupMissing {
        BackupMissing(hashes: query.hashes.filter(missing.get().contains))
    }
}

/// 假推送：每次 subscribe 调一次 [impl]（第几次、onConnected、onEvent）；默认立刻连上、挂到被取消为止。
final class FakePush: FlowPushSource, @unchecked Sendable {
    let calls = Locked(0)
    let live = Locked<((String, JSONValue) -> Void)?>(nil)
    let impl = Locked<(Int, @escaping @Sendable () -> Void, @escaping @Sendable (String, JSONValue) -> Void) async throws -> Void>({ _, connected, _ in
        connected()
        try await Gate().wait()
    })

    func subscribe(onConnected: @escaping @Sendable () -> Void, onEvent: @escaping @Sendable (String, JSONValue) -> Void) async throws {
        let n = calls.update { c -> Int in c += 1; return c - 1 }
        live.set(onEvent)
        defer { live.set(nil) }
        try await impl.get()(n, onConnected, onEvent)
    }

    /// 推给当前活着的那条订阅；没有活着的 = 丢了。
    func emit(_ kind: String, _ fields: [String: JSONValue]) {
        live.get()?(kind, .object(fields))
    }
}

final class PortHarness: @unchecked Sendable {
    let provider = FakeProvider()
    let desktop = FakeDesktop()
    let push = FakePush()
    let logger = RecordingLogger()
    let epoch = Locked<String?>("e1")
    let loss = PairingLoss()
    let progress = Locked<[Int64]>([])
    let hash = String(repeating: "ab", count: 32)
    let orderId: Int64 = 1_790_000_000_123
    var timings = DeliveryTimings()
    private(set) lazy var port = FlowDeliveryPort(
        provider: provider, currentEpoch: { [epoch] in epoch.get() }, desktop: desktop, push: push, logger: logger,
        timings: timings, pairingLoss: loss
    )

    init() {
        timings.idleStallThresholdMs = 40
        timings.byteStallThresholdMs = 400
        timings.subscriptionRetryDelaysMs = [10]
        timings.localStatusRecheckMs = 3
        timings.subscriptionReadyTimeoutMs = 300
        timings.stallStatusTimeoutMs = 60
        timings.controlCallTimeoutMs = 60
        timings.statusPollDelayScale = 0.003
    }

    var request: DeliveryRequest {
        DeliveryRequest(
            orderId: orderId, pairingEpoch: "e1", contentHash: hash,
            details: MediaDetails(snapshot: MediaSnapshot(mediaId: "A1/L0/001", sourceVersion: "1:1", bucketId: "B7"), fileName: "IMG_9.HEIC", mimeType: "image/heic", sizeBytes: 1_000_000, captureAtMs: 1_690_000_000_000)
        )
    }

    var tuple: FlowTupleRef { FlowTupleRef(queueSequence: UInt64(orderId), pairingEpoch: "e1", leaseToken: leaseTokenFor(orderId)) }

    func receipt(hash: String? = nil) -> FlowCompletionReceipt {
        FlowCompletionReceipt(queueSequence: UInt64(orderId), receiptId: "r1", pairingEpoch: "e1", leaseToken: leaseTokenFor(orderId), contentHash: hash ?? self.hash)
    }

    func tupleFields() -> [String: JSONValue] {
        ["queue_sequence": .int(orderId), "pairing_epoch": .string("e1"), "lease_token": .string(leaseTokenFor(orderId))]
    }

    func deliver() async throws -> DeliveryOutcome {
        try await port.deliver(request) { [progress] b in progress.update { $0.append(b) } }
    }

    func start() -> Task<DeliveryOutcome, Error> {
        Task { try await self.deliver() }
    }
}

/// 看门狗：[op] 在 [seconds] 内没有结束就判这条测试失败（反证时「永远等下去」也要显形为红，而不是挂死）。
func within<T: Sendable>(_ seconds: Double, _ what: String = "operation", file: StaticString = #filePath, line: UInt = #line, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    let result = await boundedWait(Int64(seconds * 1000), sleep: { try await Task.sleep(nanoseconds: UInt64($0) * 1_000_000) }, op)
    switch result {
    case let .success(v)?: return v
    case let .failure(e)?: throw e
    case nil:
        XCTFail("\(what) did not finish within \(seconds)s", file: file, line: line)
        throw CancellationError()
    }
}

final class DeliveryPortTests: XCTestCase {

    // MARK: 取消 = flow.suspend，不是 flow.cancel（C-01）

    /// 反证：取消时发 flow.cancel（或什么都不发）→ suspends 为空 / cancels 非空，红。
    func testCancellingADeliverySuspendsTheDesktopFetchInsteadOfCancellingIt() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 0, source: nil) }
        let task = h.start()
        await eventually("offer sent") { h.desktop.offers.get().count == 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(h.desktop.suspends.get(), [h.tuple])
        XCTAssertEqual(h.desktop.cancels.get(), [], "取消绝不丢桌面半截")
        XCTAssertTrue(h.provider.events.get().contains("pause:\(h.orderId)"))
    }

    /// 桌面不回 flow.suspend：暂停最多被拖住一个有界时长（控制面超时），不会挂死。
    func testADesktopThatNeverAnswersFlowSuspendCannotHoldThePauseLongerThanTheBound() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 0, source: nil) }
        h.desktop.suspendHang.set(true)
        let task = h.start()
        await eventually("offer sent") { h.desktop.offers.get().count == 1 }
        let before = Date()
        task.cancel()
        _ = try? await within(2, "pause with a silent desktop") { _ = try? await task.value }
        let took = Date().timeIntervalSince(before)
        XCTAssertLessThan(took, 1.0, "bounded by controlCallTimeoutMs (60ms) + slack")
        XCTAssertEqual(h.desktop.suspends.get().count, 1)
    }

    /// 供数阻塞很久期间被暂停：不会走到 offer。
    func testAPauseDuringALongServeNeverReachesOffer() async throws {
        let h = PortHarness()
        h.provider.serveHold.set(true)
        let task = h.start()
        await eventually("serve started") { h.provider.events.get().contains("serve:\(h.orderId)") }
        task.cancel()
        h.provider.serveGate.open()
        _ = try? await task.value
        XCTAssertEqual(h.desktop.offers.get().count, 0)
        XCTAssertTrue(h.provider.events.get().contains("pause:\(h.orderId)"))
    }

    // MARK: 订阅

    /// 一整轮共用一条推送订阅；首张 offer 等订阅就绪之后才发。
    func testOnePushSubscriptionServesAWholeRoundAndTheFirstOfferWaitsForIt() async throws {
        let h = PortHarness()
        let connectedAt = Locked<Int64>(0)
        h.push.impl.set { _, connected, _ in
            try await Task.sleep(nanoseconds: 40_000_000)
            connectedAt.set(Int64(ProcessInfo.processInfo.systemUptime * 1000))
            connected()
            try await Gate().wait()
        }
        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: h.receipt()))
        let outcomes = try await h.port.session { () -> [DeliveryOutcome] in
            [try await h.deliver(), try await h.deliver()]
        }
        XCTAssertEqual(h.push.calls.get(), 1)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertGreaterThanOrEqual(h.desktop.offerTimes.get()[0], connectedAt.get())
    }

    /// 订阅断了会重建；重建后的推送照样结掉这一张。
    func testADroppedPushSubscriptionIsRebuiltAndTheDeliveredPushStillResolves() async throws {
        let h = PortHarness()
        h.push.impl.set { n, connected, _ in
            connected()
            if n == 0 { return } // 第一条马上断
            try await Gate().wait()
        }
        let task = h.start()
        await eventually("rebuilt") { h.push.calls.get() >= 2 && h.push.live.get() != nil }
        var fields = h.tupleFields()
        fields["receipt"] = try JSONValue.from(h.receipt())
        h.push.emit("flow.delivered", fields)
        let outcome = try await task.value
        guard case .confirmed = outcome else { return XCTFail("\(outcome)") }
    }

    /// 订阅循环随这一张结束而停，不在后台一直重连。
    func testTheSubscriptionLoopStopsWithTheItem() async throws {
        let h = PortHarness()
        h.push.impl.set { _, connected, _ in connected() } // 每次都马上断
        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: h.receipt()))
        _ = try await h.deliver()
        let calls = h.push.calls.get()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(h.push.calls.get(), calls)
    }

    /// 订阅丢了、重建也没连上：马上问一次桌面；桌面不回 → 路径失败。
    func testALostPushSubscriptionWhoseRebuildFailsTriggersAStatusCheck() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 1, byteIdleForMs: 0, source: nil) }
        h.push.impl.set { n, connected, _ in
            if n == 0 { connected(); return }
            throw URLError(.cannotConnectToHost)
        }
        h.desktop.statusHang.set(true)
        let outcome = try await h.deliver()
        XCTAssertEqual(outcome, .pathFailure("desktop_unreachable:subscription_lost"))
    }

    // MARK: offer

    /// 线上 tuple 就是 order id；offer 回终态（桌面按 hash 判重已有）不等待直接确认（O-03 的端口一半：传输字节 0）。
    func testTheWireTupleIsTheOrderIdAndATerminalOfferReplyConfirmsWithoutWaiting() async throws {
        let h = PortHarness()
        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: h.receipt()))
        let outcome = try await h.deliver()
        XCTAssertEqual(outcome, .confirmed(CompletionReceipt(queueSequence: h.orderId, receiptId: "r1", pairingEpoch: "e1", contentHash: h.hash, leaseToken: leaseTokenFor(h.orderId))))
        let offer = try XCTUnwrap(h.desktop.offers.get().first)
        XCTAssertEqual(offer.queueSequence, UInt64(h.orderId))
        XCTAssertEqual(offer.leaseToken, "lease-\(h.orderId)")
        XCTAssertEqual(offer.provider, "ticket-\(h.orderId)")
        XCTAssertEqual(h.desktop.statusCalls.get(), 0)
        XCTAssertTrue(h.provider.events.get().contains("release:\(h.orderId)"), "核对通过才放掉供数占用")
    }

    /// H-03 的手机一半：offer 带这张的字节数（桌面按它预检空间）、拍摄时刻、类型、文件名。
    func testTheOfferCarriesTheItemSizeAndMetadata() async throws {
        let h = PortHarness()
        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: h.receipt()))
        _ = try await h.deliver()
        let offer = try XCTUnwrap(h.desktop.offers.get().first)
        XCTAssertEqual(offer.sizeBytes, 1_000_000)
        XCTAssertEqual(offer.captureAtMs, 1_690_000_000_000)
        XCTAssertEqual(offer.mediaType, "image/heic")
        XCTAssertEqual(offer.fileName, "IMG_9.HEIC")
        XCTAssertEqual(offer.contentHash, h.hash)
    }

    /// H-03 / C-12：offer 因空间被拒 = 对端失败（不计次）。
    func testAnOfferRefusedForSpaceIsAPeerFailure() async throws {
        let h = PortHarness()
        h.desktop.offerError.set(DesktopRejected(msgKey: "storage_full", method: "flow.offer"))
        let outcome = try await h.deliver()
        XCTAssertEqual(outcome, .peerFailure(.storageFull, code: "storage_full"))
    }

    /// 回执四个字段任何一个对不上：不确认（单张失败），也不放掉供数占用。
    func testAMismatchedReceiptIsNeverAccepted() async throws {
        let h = PortHarness()
        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: h.receipt(hash: String(repeating: "cd", count: 32))))
        let outcome = try await h.deliver()
        guard case let .itemFailure(reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("ReceiptMismatch"), reason)
        XCTAssertFalse(h.provider.events.get().contains("release:\(h.orderId)"))
    }

    /// 配对代号变了（换了一次配对）：这一张不跨进新代号，路径失败。
    func testAnEpochChangeIsAPathFailure() async throws {
        let h = PortHarness()
        h.epoch.set("e2")
        let outcome = try await h.deliver()
        XCTAssertEqual(outcome, .pathFailure("epoch_changed"))
        h.epoch.set(nil)
        let unpaired = try await h.deliver()
        XCTAssertEqual(unpaired, .pairingLost)
    }

    // MARK: 等待循环（C-10 / C-11 / R-05 / #250）

    /// C-10：连着、但太久没有新的文件字节 → 主动断开，路径失败（不计次）。
    func testConnectedButNoNewFileBytesIsAPathFailureAndDisconnects() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 500, source: nil) }
        let outcome = try await within(3, "stall detection") { try await h.deliver() }
        XCTAssertEqual(outcome, .pathFailure("byte_stall"))
        XCTAssertTrue(h.provider.events.get().contains("pause:\(h.orderId)"))
    }

    /// 字节一直在走就永远不是停滞（连接类事件不刷新字节计时，这里只看字节）。
    func testBytesThatKeepMovingAreNeverMistakenForAStall() async throws {
        let h = PortHarness()
        let sent = Locked<Int64>(0)
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: sent.update { $0 += 1000; return $0 }, byteIdleForMs: 0, source: nil) }
        let task = h.start()
        try await Task.sleep(nanoseconds: 600_000_000) // 比 byteStall（400ms）长
        var fields = h.tupleFields()
        fields["receipt"] = try JSONValue.from(h.receipt())
        await eventually("subscribed") { h.push.live.get() != nil }
        h.push.emit("flow.delivered", fields)
        let outcome = try await task.value
        guard case .confirmed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(h.progress.get().count, 3)
    }

    /// #250：本地传输已完成 → 等回执之前先报一次满。
    func testALocallyCompletedTransferReportsFullBytesBeforeTheReceipt() async throws {
        let h = PortHarness()
        h.provider.status.set { .completed(hash: "x") }
        h.desktop.statusReply.set { FlowStatusReply(state: "completed", receipt: h.receipt()) }
        let outcome = try await h.deliver()
        guard case .confirmed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(h.progress.get().last, 1_000_000)
    }

    /// C-11：没人来连超过阈值 → 问桌面；回 active 就继续等，不判失败；之后完成照常确认。
    func testNobodyConnectedAsksTheDesktopAndKeepsWaitingWhileItSaysActive() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: false, idleForMs: 100, bytesSent: nil, byteIdleForMs: 0, source: nil) }
        let polls = Locked(0)
        h.desktop.statusReply.set {
            if polls.update({ p -> Int in p += 1; return p }) < 4 { return FlowStatusReply(state: "active") }
            return FlowStatusReply(state: "completed", receipt: h.receipt())
        }
        let outcome = try await h.deliver()
        guard case .confirmed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThanOrEqual(h.desktop.statusCalls.get(), 4)
    }

    /// NET-06：连着 N 次状态往返都失败 → 放弃这次尝试，路径失败（不是单张失败）。
    func testRepeatedStatusFailuresGiveUpAsAPathFailure() async throws {
        let h = PortHarness()
        h.provider.status.set { .noLease }
        h.desktop.statusReply.set { throw URLError(.timedOut) }
        let outcome = try await h.deliver()
        guard case let .pathFailure(reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.hasPrefix("network:"), reason)
        XCTAssertEqual(h.desktop.statusCalls.get(), 5)
    }

    /// `not_found`：桌面没有我们自己的 grant——真正的不一致，单张失败（计次、有上限），不当路径失败无限续。
    func testANotFoundStatusIsAnItemFailure() async throws {
        let h = PortHarness()
        h.provider.status.set { .noLease }
        h.desktop.statusReply.set { FlowStatusReply(state: "not_found") }
        let outcome = try await h.deliver()
        guard case .itemFailure = outcome else { return XCTFail("\(outcome)") }
    }

    /// 本地中止 + 桌面不吭声：短超时内判路径失败（不沿着退避一直等）。
    func testALocalAbortWithASilentDesktopIsAPathFailureWithinTheShortTimeout() async throws {
        let h = PortHarness()
        h.provider.status.set { .aborted(hash: "x", source: nil) }
        h.desktop.statusHang.set(true)
        let before = Date()
        let outcome = try await h.deliver()
        XCTAssertEqual(outcome, .pathFailure("desktop_unreachable:local_aborted"))
        XCTAssertLessThan(Date().timeIntervalSince(before), 1.0)
    }

    /// 本地中止 + 桌面还在且已经完成：照常确认。
    func testALocalAbortWithALiveDesktopKeepsTheExistingOutcomes() async throws {
        let h = PortHarness()
        h.provider.status.set { .aborted(hash: "x", source: nil) }
        h.desktop.statusReply.set { FlowStatusReply(state: "completed", receipt: h.receipt()) }
        let outcome = try await h.deliver()
        guard case .confirmed = outcome else { return XCTFail("\(outcome)") }
    }

    /// R-05：供数途中原文件被改 / 删 → 源已删（不计失败），不把残缺内容确认为完成；桌面已经回了完整回执的除外。
    func testASourceFaultWhileServingIsSourceMissing() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 0, source: .changed) }
        let outcome = try await within(3, "source fault detection") { try await h.deliver() }
        XCTAssertEqual(outcome, .sourceMissing)
        XCTAssertTrue(h.provider.events.get().contains("pause:\(h.orderId)"))
    }

    // MARK: 分类（纯函数）

    func testDesktopCodesMapToTheContract() {
        XCTAssertEqual(classifyDesktopCode("storage_full"), .peerFailure(.storageFull, code: "storage_full"))
        XCTAssertEqual(classifyDesktopCode("library_unavailable"), .peerFailure(.libraryUnavailable, code: "library_unavailable"))
        XCTAssertEqual(classifyDesktopCode("storage_failed"), .peerFailure(.storageError, code: "storage_failed"))
        XCTAssertEqual(classifyDesktopCode("fetch_failed"), .pathFailure("fetch_failed"))
        XCTAssertNil(classifyDesktopCode("materialize_io"))
        XCTAssertEqual(classifyPushedFailure("materialize_io"), .itemFailure("pushed:materialize_io"))
    }

    /// 桌面可达但拒绝不是路径问题；配对失效单独一类；网络错误是路径失败。
    func testExceptionsAreClassified() {
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(msgKey: "err.not_authorized", method: "flow.offer")), .pairingLost)
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(msgKey: "err.bad_request", method: "flow.offer")), .itemFailure("rejected:err.bad_request"))
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(msgKey: "storage_full", method: "flow.offer")), .peerFailure(.storageFull, code: "storage_full"))
        guard case let .pathFailure(reason) = classifyDeliveryFailure(URLError(.timedOut)) else { return XCTFail("network error must be a path failure") }
        XCTAssertTrue(reason.hasPrefix("network:"), reason)
        XCTAssertEqual(classifyDeliveryFailure(ReceiptMismatch(field: "content_hash")), .itemFailure("invalid:ReceiptMismatch"))
    }

    /// 供数失败：源已删 / 已变不是失败；provider 上线超时是路径失败；其它是单张失败（NET-29：不会把离线当成照片坏了）。
    func testProviderFailuresAreClassified() {
        XCTAssertEqual(classifyProviderFailure(ProviderFailure.sourceChanged), .sourceMissing)
        XCTAssertEqual(classifyProviderFailure(ProviderFailure.sourceMissing), .sourceMissing)
        XCTAssertEqual(classifyProviderFailure(ProviderFailure.offline("wait_online timed out")), .pathFailure("provider_offline"))
        // NET-29：原生库的诊断文案（不是类型）也认得出「端点没上线」。
        XCTAssertEqual(classifyProviderFailure(NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "endpoint did not become online in 30s"])), .pathFailure("provider_offline"))
        XCTAssertEqual(classifyProviderFailure(NSError(domain: "x", code: 2, userInfo: [NSLocalizedDescriptionKey: "blob does not match its declared content hash"])), .sourceMissing)
        XCTAssertEqual(classifyProviderFailure(NSError(domain: "x", code: 3)), .itemFailure("provider:NSError"))
        XCTAssertEqual(classifyProviderFailure(InconsistentReply(detail: "x")), .itemFailure("provider:InconsistentReply"))
    }

    func testTransferStatusDecodesByteProgressAndToleratesOlderNativeBuilds() {
        XCTAssertEqual(TransferStatus.parse(Data(#"{"state":"in_progress","connected":true,"idle_for_ms":5,"bytes_sent":100,"byte_idle_for_ms":7}"#.utf8)),
                       .inProgress(connected: true, idleForMs: 5, bytesSent: 100, byteIdleForMs: 7, source: nil))
        XCTAssertEqual(TransferStatus.parse(Data(#"{"state":"in_progress","connected":false}"#.utf8)),
                       .inProgress(connected: false, idleForMs: nil, bytesSent: nil, byteIdleForMs: nil, source: nil))
        XCTAssertEqual(TransferStatus.parse(Data(#"{"state":"aborted","hash":"h","source":"missing"}"#.utf8)), .aborted(hash: "h", source: .missing))
        XCTAssertEqual(TransferStatus.parse(Data(#"{"state":"completed","hash":"h"}"#.utf8)), .completed(hash: "h"))
        XCTAssertEqual(TransferStatus.parse(Data(#"{"state":"weird"}"#.utf8)), .noLease)
        XCTAssertEqual(TransferStatus.parse(Data("not json".utf8)), .noLease)
    }

    func testWaitStepThresholds() {
        let quiet = TransferStatus.inProgress(connected: false, idleForMs: 14_999, bytesSent: nil, byteIdleForMs: nil, source: nil)
        XCTAssertEqual(flowWaitStep(pushed: nil, local: quiet, idleStallThresholdMs: 15_000, byteStallThresholdMs: 180_000, attemptElapsedMs: 1), .keepWaitingForPush)
        let idle = TransferStatus.inProgress(connected: false, idleForMs: 15_000, bytesSent: nil, byteIdleForMs: nil, source: nil)
        XCTAssertEqual(flowWaitStep(pushed: nil, local: idle, idleStallThresholdMs: 15_000, byteStallThresholdMs: 180_000, attemptElapsedMs: 1), .checkStatusNow)
        let stuck = TransferStatus.inProgress(connected: true, idleForMs: 0, bytesSent: 1, byteIdleForMs: 180_000, source: nil)
        XCTAssertEqual(flowWaitStep(pushed: nil, local: stuck, idleStallThresholdMs: 15_000, byteStallThresholdMs: 180_000, attemptElapsedMs: 1), .stalled)
        XCTAssertEqual(flowWaitStep(pushed: .failed("fetch_failed"), local: stuck, idleStallThresholdMs: 15_000, byteStallThresholdMs: 180_000, attemptElapsedMs: 1), .failed("fetch_failed"))
        XCTAssertEqual(flowWaitStep(pushed: nil, local: .noLease, idleStallThresholdMs: 15_000, byteStallThresholdMs: 180_000, attemptElapsedMs: 1), .checkStatusNow)
        XCTAssertEqual(DeliveryTimings().idleStallThresholdMs, 15_000, "#410：15 秒")
        XCTAssertEqual(DeliveryTimings().byteStallThresholdMs, 180_000, "#410：3 分钟")
        XCTAssertEqual((0...7).map(nextStatusPollDelayMs), [1_000, 2_000, 3_000, 5_000, 8_000, 8_000, 8_000, 8_000])
    }

    func testPushesAreMatchedOnTheExactTuple() throws {
        let h = PortHarness()
        var other = h.tupleFields()
        other["lease_token"] = .string("lease-1")
        XCTAssertNil(parseFlowPushOutcome(kind: "flow.failed", data: .object(other), tuple: h.tuple))
        var mine = h.tupleFields()
        mine["code"] = .string("storage_full")
        XCTAssertEqual(parseFlowPushOutcome(kind: "flow.failed", data: .object(mine), tuple: h.tuple), .failed("storage_full"))
        mine["receipt"] = try JSONValue.from(h.receipt())
        XCTAssertEqual(parseFlowPushOutcome(kind: "flow.delivered", data: .object(mine), tuple: h.tuple), .delivered(h.receipt()))
        XCTAssertNil(parseFlowPushOutcome(kind: "timeline.invalidated", data: .object(mine), tuple: h.tuple))
    }

    // MARK: 桌面健康（H-01 / H-02 / #555）

    /// hello 的 health 按契约字段名解析；没有 health = 健康（H-02）。
    func testHelloHealthIsParsedAndAbsentMeansHealthy() async throws {
        let h = PortHarness()
        let probe = ControlPlaneProbe(currentEpoch: { "e1" }, desktop: h.desktop, logger: h.logger, pairingLoss: h.loss)
        let old = await probe.probe()
        XCTAssertEqual(old, .reachable(advertisedEpoch: "e1", health: nil, capabilities: []))
        XCTAssertNil(waitReasonOf(nil as DesktopHealth?))
        let wire = try ProtoJSON.decode(Hello.self, from: Data(#"{"proto_ver":1,"capabilities":["flow.supersede.v1"],"device_name":"PC","pairing_epoch":"e1","health":{"free_bytes":1024,"library_writable":true,"index_ok":false}}"#.utf8))
        h.desktop.helloResult.set(.success(wire))
        let unhealthy = await probe.probe()
        XCTAssertEqual(unhealthy, .reachable(advertisedEpoch: "e1", health: DesktopHealth(freeBytes: 1024, libraryWritable: true, indexOk: false), capabilities: ["flow.supersede.v1"]))
        XCTAssertEqual(waitReasonOf(DesktopHealth(freeBytes: 1024, libraryWritable: true, indexOk: false)), .desktopStorageError)
    }

    /// #555：照片库不可写 + 剩余空间低于保留余量 = 空间不足，不是「文件夹打不开」。
    func testAnUnwritableLibraryOnAFullDiskReadsAsStorageFull() {
        XCTAssertEqual(waitReasonOf(DesktopHealth(freeBytes: 10 * 1024 * 1024, libraryWritable: false)), .desktopStorageFull)
        XCTAssertEqual(waitReasonOf(DesktopHealth(freeBytes: 100 * 1024 * 1024 * 1024, libraryWritable: false)), .desktopLibraryUnavailable)
        XCTAssertEqual(waitReasonOf(DesktopHealth(freeBytes: nil, libraryWritable: false)), .desktopLibraryUnavailable)
        XCTAssertTrue(DesktopHealth(freeBytes: 4 * 1024 * 1024 * 1024).lowSpace, "H-04：< 5 GiB 预警")
        XCTAssertNil(waitReasonOf(DesktopHealth(freeBytes: 4 * 1024 * 1024 * 1024)), "低空间只是预警，不挡")
    }

    /// 盘满线与 daemon 的 SPACE_RESERVE_BYTES 同值（读 Rust 源里的常量，改一边另一边红）。
    func testTheCriticallyLowLineMatchesTheDaemonSpaceReserve() throws {
        let source = try String(contentsOf: RepoFixtures.repoRoot().appendingPathComponent("crates/daemon/src/flow_delivery.rs"), encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #"SPACE_RESERVE_BYTES: u64 = (\d+) \* 1024 \* 1024"#)
        guard let m = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let r = Range(m.range(at: 1), in: source), let mib = Int64(source[r]) else {
            return XCTFail("daemon 的 SPACE_RESERVE_BYTES 没找到（形状变了就更新本断言）")
        }
        XCTAssertEqual(DesktopHealth.criticallyLowBytes, mib * 1024 * 1024)
    }

    // MARK: 探测与配对失效（MOB-117 / #466）

    func testAProbeRejectedAsNotAuthorizedReportsPairingLostForThatEpoch() async {
        let h = PortHarness()
        h.desktop.helloResult.set(.failure(DesktopRejected(msgKey: "err.not_authorized", method: "hello")))
        let probe = ControlPlaneProbe(currentEpoch: { "e1" }, desktop: h.desktop, logger: h.logger, pairingLoss: h.loss)
        let result = await probe.probe()
        XCTAssertEqual(result, .pairingLost)
        XCTAssertTrue(h.loss.isLost(epoch: "e1"))
        XCTAssertFalse(h.loss.isLost(epoch: "e2"), "失效属于被拒的那一代，不属于之后重新配对的")
    }

    func testAnOrdinaryRejectionOrTimeoutIsUnreachableNotLost() async {
        let h = PortHarness()
        h.desktop.helloResult.set(.failure(DesktopRejected(msgKey: "err.busy", method: "hello")))
        let probe = ControlPlaneProbe(currentEpoch: { "e1" }, desktop: h.desktop, logger: h.logger, pairingLoss: h.loss)
        let rejected = await probe.probe()
        XCTAssertEqual(rejected, .unreachable)
        XCTAssertFalse(h.loss.isLost(epoch: "e1"))
        let unpaired = await ControlPlaneProbe(currentEpoch: { nil }, desktop: h.desktop, logger: h.logger, pairingLoss: h.loss).probe()
        XCTAssertEqual(unpaired, .pairingLost)
    }

    // MARK: presence（ARCH-08）

    func testAPresencePageIsValidated() async throws {
        let h = PortHarness()
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        h.desktop.missing.set([b])
        let missing = try await ControlPlanePresence(desktop: h.desktop).missing([a, b])
        XCTAssertEqual(missing, [b])
        XCTAssertThrowsError(try presenceQueryFor([]))
        XCTAssertThrowsError(try presenceQueryFor(["not-hex"]))
        XCTAssertThrowsError(try presenceQueryFor(Array(repeating: a, count: 501)))
    }

    // MARK: 审计 outbox 投递（AUDIT-01 / AUDIT-06）

    /// 按 seq 分页走完整个 outbox；只删桌面确认的；被永久拒收的留着但挡不住后面的；离线时停下、一条不删。
    func testTheAuditOutboxIsDrainedBySeqAndOnlyAcknowledgedEventsAreDropped() async throws {
        let dir = TempDir()
        let store = try SQLiteOrderStore(directory: dir.url)
        for i in 0..<450 { try store.appendAudit(AuditRecord(eventId: String(format: "ev%03d", i), kind: "k", roundId: nil, occurredAtMs: Int64(i), payload: [:])) }
        let desktop = FakeDesktop()
        desktop.accept.set { ids in ids.subtracting(["ev000", "ev250"]) } // 两条被永久拒收
        let dispatcher = AuditOutboxDispatcher(store: store, desktop: { desktop }, acknowledge: { ids in try? store.acknowledgeAudit(ids) })
        await dispatcher.flush()
        XCTAssertEqual(desktop.submitted.get().map(\.count), [200, 200, 50])
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 1_000).map(\.record.eventId), ["ev000", "ev250"])

        desktop.submitFails.set(true)
        try store.appendAudit(AuditRecord(eventId: "late", kind: "k", roundId: nil, occurredAtMs: 1, payload: [:]))
        await dispatcher.flush()
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 1_000).count, 3, "离线：一条不删")
        let unpaired = AuditOutboxDispatcher(store: store, desktop: { nil }, acknowledge: { _ in })
        await unpaired.flush()
        XCTAssertEqual(try store.pendingAuditAfter(0, limit: 1_000).count, 3)
    }

    // MARK: discardPartial

    func testDiscardingAPartialSendsCancelTupleBounded() async {
        let h = PortHarness()
        await h.port.discardPartial(orderId: 42, pairingEpoch: "e1")
        XCTAssertEqual(h.desktop.cancels.get(), [FlowTupleRef(queueSequence: 42, pairingEpoch: "e1", leaseToken: "lease-42")])
        XCTAssertEqual(h.desktop.suspends.get(), [])
    }
}

/// 引擎 + 真实传输端口端到端（假的只有原生 provider、桌面控制面、推送）：C-01 / X-05 / E-01 在两层之间的接缝。
final class EngineWithPortTests: XCTestCase {

    /// C-01 + X-05：传输中暂停 → 端口发 `flow.suspend`（一次）、绝不发 `flow.cancel_tuple`；继续 → 同一个 tuple 续传、确认。
    func testPauseSuspendsTheDesktopFetchAndResumeContinuesTheSameTuple() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 0, source: nil) }
        let rig = try Rig(port: h.port)
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("offer sent") { h.desktop.offers.get().count == 1 }
        let order = try XCTUnwrap(rig.current(1))
        let paused = await rig.engine.pause()
        XCTAssertTrue(paused)
        XCTAssertEqual(h.desktop.suspends.get().map(\.queueSequence), [UInt64(order.id)])
        XCTAssertEqual(h.desktop.cancels.get(), [])
        XCTAssertEqual(try rig.state(1), .transferring)

        h.desktop.offerReply.set(FlowStatusReply(state: "completed", receipt: FlowCompletionReceipt(
            queueSequence: UInt64(order.id), receiptId: "r", pairingEpoch: "e1", leaseToken: leaseTokenFor(order.id), contentHash: order.contentHash ?? ""
        )))
        await rig.engine.resume()
        await rig.engine.awaitIdle()
        XCTAssertEqual(h.desktop.offers.get().map(\.queueSequence), [UInt64(order.id), UInt64(order.id)], "续传同一个 tuple")
        XCTAssertEqual(try rig.state(1), .confirmed)
    }

    /// X-01：取消剩余时在飞的那张——端口发 `flow.cancel_tuple` 丢掉桌面半截。
    func testCancelRemainingDiscardsTheDesktopPartial() async throws {
        let h = PortHarness()
        h.provider.status.set { .inProgress(connected: true, idleForMs: 0, bytesSent: 10, byteIdleForMs: 0, source: nil) }
        let rig = try Rig(port: h.port)
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.engine.trigger(.mediaChange)
        await eventually("offer sent") { h.desktop.offers.get().count == 1 }
        let order = try XCTUnwrap(rig.current(1))
        await rig.engine.pause()
        let written = try await rig.engine.cancelRemaining(rig.engine.remainingSnapshot())
        XCTAssertEqual(written, 1)
        XCTAssertEqual(h.desktop.cancels.get().map(\.queueSequence), [UInt64(order.id)])
        XCTAssertEqual(try rig.state(1), .skippedByUser)
    }
}

// #891：逐张循环契约测试用的假端口（对位 Android `FlowTestKit.kt` + `FakeMedia.kt`）。
// 存储用**真实的 SQLiteOrderStore**（临时目录，真跑 IO）；导入、传输、租约、调度、桌面探测是计数的假端口。
import Foundation
import XCTest
@testable import PPassCore

/// 线程安全的小盒子（假端口在 actor 之外被调用）。
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    @discardableResult
    func update<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

/// 照片的测试 id：补零，让字节序与数字序一致（"m002" < "m010"）。
func mid(_ n: Int) -> String { String(format: "m%03d", n) }

/// 照片库里的一张：快照字段 + 字节内容（假 hash = "blake3:" + 内容）。
struct FakePhoto: Equatable {
    var n: Int
    var modified: Int64
    var size: Int64
    var content: String
    /// 发现顺序（Android 的 generation）。
    var generation: Int64
    var bucket: String = "B7"
    /// 直接指定 id（字节序 / 规范等价测试用）；nil = mid(n)。
    var idOverride: String? = nil
    /// true = 视频（mimeType video/quicktime）。
    var video = false

    var mediaId: String { idOverride ?? mid(n) }
    var sourceVersion: String { sourceVersionOf(modifiedAtMs: modified, size: size) }
    var hash: String { "blake3:\(content)" }
}

/// 假的发现位置：(token 代, generation, id)。id 为 nil = 这个 generation 整个过去了。
struct FakePosition: Codable, Equatable {
    var epoch: Int
    var generation: Int64
    var id: String?

    var encoded: DiscoveryPosition { DiscoveryPosition(raw: try! JSONEncoder().encode(self)) }
    static func decode(_ p: DiscoveryPosition) -> FakePosition { try! JSONDecoder().decode(FakePosition.self, from: p.raw) }

    /// (generation, id) 字典序：p 是否排在这个位置之后。
    func isBefore(_ photo: FakePhoto) -> Bool {
        if photo.generation != generation { return photo.generation > generation }
        guard let id else { return false }
        return MediaOrder.precedes(id, photo.mediaId)
    }
}

/// 假照片库。语义与 PhotoKit 适配层的契约相同：inScope 按 id 字节序；changes 按 (generation, id) 升序、每张带位置。
final class FakeMedia: MediaSource, @unchecked Sendable {
    private let state = Locked<(photos: [FakePhoto], scope: Set<String>?, epoch: Int, identity: String?, duplicate: Set<String>, existingUnreadable: Bool)>(([], ["B7"], 1, "lib-1", [], false))
    let metadataReads = Locked(0)
    /// iOS（#1016）：lookup 给不出字节数（0），只有导入后才知道。
    let sizeUnknownBeforeImport = Locked(false)
    /// 默认 true：大部分测试关心的是 G 本身的语义；#904 的测试显式置 false。
    let precise = Locked(true)
    var preciseDiscovery: Bool { precise.get() }
    let existingIdsCalls = Locked(0)

    var photos: [FakePhoto] { state.get().photos }
    var scope: Set<String>? {
        get { state.get().scope }
        set { state.update { $0.scope = newValue } }
    }
    var identity: String? {
        get { state.get().identity }
        set { state.update { $0.identity = newValue } }
    }
    var duplicateInScope: Set<String> {
        get { state.get().duplicate }
        set { state.update { $0.duplicate = newValue } }
    }
    var existingIdsUnreadable: Bool {
        get { state.get().existingUnreadable }
        set { state.update { $0.existingUnreadable = newValue } }
    }

    func put(_ p: FakePhoto) { state.update { s in s.photos.removeAll { $0.n == p.n }; s.photos.append(p) } }
    func remove(_ n: Int) { state.update { s in s.photos.removeAll { $0.n == n } } }
    /// F3 / 3105：之前发出去的位置全部失效。
    func expireTokens() { state.update { $0.epoch += 1 } }

    func isInScope(_ bucket: String) -> Bool { state.get().scope?.contains(bucket) == true }

    func snapshot(_ p: FakePhoto, position: DiscoveryPosition? = nil) -> MediaSnapshot {
        MediaSnapshot(mediaId: p.mediaId, sourceVersion: p.sourceVersion, bucketId: p.bucket, position: position)
    }

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] {
        metadataReads.update { $0 += 1 }
        let s = state.get()
        let rows = s.photos
            .filter { p in (after.map { MediaOrder.precedes($0, p.mediaId) } ?? true) && (s.scope?.contains(p.bucket) == true) }
            .sorted { MediaOrder.precedes($0.mediaId, $1.mediaId) }
            .flatMap { s.duplicate.contains($0.mediaId) ? [$0, $0] : [$0] }
        return Array(rows.prefix(limit)).map { snapshot($0) }
    }

    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        metadataReads.update { $0 += 1 }
        let s = state.get()
        let from = FakePosition.decode(position)
        if from.epoch != s.epoch { throw DiscoveryCursorExpired() }
        return s.photos
            .filter { from.isBefore($0) && s.scope?.contains($0.bucket) == true }
            .sorted { $0.generation != $1.generation ? $0.generation < $1.generation : MediaOrder.precedes($0.mediaId, $1.mediaId) }
            .prefix(limit)
            .map { snapshot($0, position: FakePosition(epoch: s.epoch, generation: $0.generation, id: $0.mediaId).encoded) }
    }

    func currentPosition() async throws -> DiscoveryPosition {
        let s = state.get()
        return FakePosition(epoch: s.epoch, generation: s.photos.map(\.generation).max() ?? 0, id: nil).encoded
    }

    func libraryIdentity() async throws -> String? { state.get().identity }

    func lookup(_ mediaId: String) async throws -> MediaDetails? {
        guard let p = state.get().photos.first(where: { MediaOrder.same($0.mediaId, mediaId) }) else { return nil }
        return MediaDetails(snapshot: snapshot(p), fileName: "IMG_\(p.n).HEIC", mimeType: p.video ? "video/quicktime" : "image/heic", sizeBytes: sizeUnknownBeforeImport.get() ? 0 : p.size, captureAtMs: 0)
    }

    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? {
        existingIdsCalls.update { $0 += 1 }
        let s = state.get()
        if s.existingUnreadable { return nil }
        return Set(mediaIds.filter { id in s.photos.contains { MediaOrder.same($0.mediaId, id) } })
    }
}

struct FakeImportError: Error {}

/// 假导入：导入 = 读 FakeMedia 的内容（假 hash）；每次导入就是一次「读文件 / 拉 iCloud」。
final class FakeImporter: MediaImporter, @unchecked Sendable {
    let media: FakeMedia
    let imported = Locked<[String]>([])
    let released = Locked<[String]>([])
    let failures = Locked<[Error]>([])
    /// 照片库还列着、文件读不到。
    let unreadable = Locked<Set<String>>([])
    /// D4：原图在 iCloud、因网络拉不下来。
    let iCloudOffline = Locked<Set<String>>([])
    /// #911：手机空间不足，临时文件写不下。
    let phoneStorageFull = Locked(false)
    let hashOverride = Locked<[String: String]>([:])
    /// 导入期间挂起（模拟一次很长的 iCloud 下载），直到被放行。
    let hold = Locked(false)
    private let gate = Gate()

    init(media: FakeMedia) { self.media = media }

    func releaseHold() { hold.set(false); holdIds.set([]); gate.open() }

    /// 只挂起这几张的导入（其余照常），直到 releaseHold。
    let holdIds = Locked<Set<String>>([])
    /// 模拟 iCloud 下载：导入时按这些进度依次回报（`fromICloud = true`）。
    let iCloudProgress = Locked<[String: [Double]]>([:])

    func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        let id = details.snapshot.mediaId
        imported.update { $0.append(id) }
        if let steps = iCloudProgress.get()[id] {
            onFetch(OriginalFetchUpdate(fromICloud: true, fraction: nil))
            for f in steps { onFetch(OriginalFetchUpdate(fromICloud: true, fraction: f)) }
        }
        if hold.get() || holdIds.get().contains(id) { try await gate.wait() }
        if let failure = failures.update({ $0.isEmpty ? nil : $0.removeFirst() }) { throw failure }
        if unreadable.get().contains(id) { return .sourceMissing }
        if iCloudOffline.get().contains(id) { return .originalUnavailable(reason: "NSURLErrorNotConnectedToInternet") }
        if phoneStorageFull.get() { return .localStorageFull(reason: "PHPhotosErrorDomain#3305") }
        guard let p = media.photos.first(where: { MediaOrder.same($0.mediaId, id) }) else { return .sourceMissing }
        return .imported(contentHash: hashOverride.get()[id] ?? p.hash, sizeBytes: p.size)
    }

    func release(_ contentHash: String) { released.update { $0.append(contentHash) } }
}

/// 一个可以反复用的闸门：wait 挂起直到 open，或在被取消时抛 CancellationError。
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = c
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let c = waiters.removeValue(forKey: id)
            lock.unlock()
            c?.resume(throwing: CancellationError())
        }
    }

    func open() {
        lock.lock()
        let all = waiters
        waiters.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume() }
    }
}

/// 传输脚本：按顺序给结局；[hold] 为 true 时挂起直到被放行或被取消（取消时记下 orderId 再抛）。
final class FakeDelivery: ItemDelivery, @unchecked Sendable {
    let requests = Locked<[DeliveryRequest]>([])
    let discarded = Locked<[Int64]>([])
    let cancelled = Locked<[Int64]>([])
    let sessions = Locked(0)
    /// 下一次（及之后每次）传输的结局；为空时默认 Confirmed。
    let script = Locked<[(DeliveryRequest) -> DeliveryOutcome]>([])
    let hold = Locked(false)
    let onStart = Locked<(DeliveryRequest) -> Void>({ _ in })
    /// 结局之前的进度回调脚本。
    let progress = Locked<(DeliveryRequest, (Int64) -> Void) async -> Void>({ _, _ in })
    /// 被取消、退出之前调（#1007：在「引擎停循环、等在飞的那张退出」这个窗口里插事件）。
    let onCancel = Locked<(DeliveryRequest) async -> Void>({ _ in })
    private let gate = Gate()

    var deliveredIds: [Int] { requests.get().map { Int($0.details.snapshot.mediaId.dropFirst())! } }

    func release() {
        hold.set(false)
        gate.open()
    }

    func session<T>(_ body: () async throws -> T) async throws -> T {
        sessions.update { $0 += 1 }
        return try await body()
    }

    func deliver(_ request: DeliveryRequest, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> DeliveryOutcome {
        requests.update { $0.append(request) }
        onStart.get()(request)
        if hold.get() {
            do {
                try await gate.wait()
            } catch {
                cancelled.update { $0.append(request.orderId) }
                await onCancel.get()(request)
                throw error
            }
        }
        await progress.get()(request, onProgress)
        onProgress(request.details.sizeBytes)
        let next = script.update { $0.isEmpty ? nil : $0.removeFirst() }
        return (next ?? Self.confirmed)(request)
    }

    func discardPartial(orderId: Int64, pairingEpoch: String) async {
        discarded.update { $0.append(orderId) }
    }

    static func confirmed(_ r: DeliveryRequest) -> DeliveryOutcome {
        .confirmed(CompletionReceipt(queueSequence: r.orderId, receiptId: "receipt-\(r.orderId)", pairingEpoch: r.pairingEpoch, contentHash: r.contentHash, leaseToken: r.leaseToken))
    }
}

final class FakeLease: ExecutionLease, @unchecked Sendable {
    let acquires = Locked(0)
    let releases = Locked(0)
    let grant = Locked(true)
    let held = Locked(false)
    let updates = Locked<[LoopStatus]>([])
    let photosOnlyFlag = Locked(false)
    var photosOnly: Bool { photosOnlyFlag.get() }

    func acquire() async -> Bool {
        acquires.update { $0 += 1 }
        let g = grant.get()
        held.set(g)
        return g
    }

    func isHeld() -> Bool { held.get() }
    var hasExecutionTime: Bool { held.get() }
    func renew() {}
    func update(_ status: LoopStatus) { updates.update { $0.append(status) } }

    func release() {
        releases.update { $0 += 1 }
        held.set(false)
    }
}

final class FakeScheduler: WakeScheduler, @unchecked Sendable {
    let unreachableProbes = Locked(0)
    let probesCancelled = Locked(0)
    let constraintWakes = Locked<[WaitReason]>([])

    func scheduleUnreachableProbes() { unreachableProbes.update { $0 += 1 } }
    func cancelUnreachableProbes() { probesCancelled.update { $0 += 1 } }
    func scheduleWhenConditionsMet(_ reason: WaitReason) { constraintWakes.update { $0.append(reason) } }
}

final class FakeProbe: DesktopProbe, @unchecked Sendable {
    let result = Locked<ProbeResult>(.reachable(advertisedEpoch: "e1", health: nil, capabilities: []))
    let calls = Locked(0)
    let hold = Locked(false)
    private let gate = Gate()

    func releaseHold() { hold.set(false); gate.open() }

    func probe() async -> ProbeResult {
        calls.update { $0 += 1 }
        if hold.get() { try? await gate.wait() }
        return result.get()
    }
}

final class FakePresence: RemotePresence, @unchecked Sendable {
    let missingOnDesktop = Locked<Set<String>>([])
    let calls = Locked(0)
    let unreachable = Locked(false)

    func missing(_ hashes: [String]) async throws -> Set<String> {
        calls.update { $0 += 1 }
        if unreachable.get() { throw URLError(.cannotConnectToHost) }
        let m = missingOnDesktop.get()
        return Set(hashes.filter(m.contains))
    }
}

/// 内存里的 FlowControl（引擎的「重启」测试改用真实的 FlowControlStore）。
final class FakeControl: FlowControl, @unchecked Sendable {
    let state = Locked<(paused: Bool, wait: WaitReason?, block: LeaseBlockReason?, ladder: Bool, ack: Int64)>((false, nil, nil, false, 0))

    var pausedFlag: Bool {
        get { state.get().paused }
        set { state.update { $0.paused = newValue } }
    }
    var wait: WaitReason? { state.get().wait }
    var block: LeaseBlockReason? { state.get().block }
    var ladderSpent: Bool { state.get().ladder }

    func paused() -> Bool { state.get().paused }
    func setPaused(_ p: Bool) { state.update { $0.paused = p } }
    func waitReason() -> WaitReason? { state.get().wait }
    func setWaitReason(_ r: WaitReason?) { state.update { $0.wait = r } }
    func leaseBlock() -> LeaseBlockReason? { state.get().block }
    func recordLeaseBlock(_ r: LeaseBlockReason) { state.update { if $0.block == nil { $0.block = r } } }
    func clearLeaseBlock() { state.update { $0.block = nil } }
    func retryLadderSpent() -> Bool { state.get().ladder }
    func setRetryLadderSpent(_ s: Bool) { state.update { $0.ladder = s } }
    func missingSourceAckAt() -> Int64 { state.get().ack }
    func setMissingSourceAckAt(_ a: Int64) { state.update { $0.ack = a } }
}

/// 一套装好的引擎。范围默认是 B7；[cursors] 为 true（默认）时预置 G = 第 0 代之后、库身份不变——
/// 视为「装好之后一直在跑」，只有显式置脏才扫描。
final class Rig: @unchecked Sendable {
    let dir: TempDir
    let clock = ManualClock(1_000)
    let store: SQLiteOrderStore
    let media = FakeMedia()
    let importer: FakeImporter
    let delivery = FakeDelivery()
    let lease = FakeLease()
    let scheduler = FakeScheduler()
    let probe = FakeProbe()
    let presence = FakePresence()
    let control: FlowControl
    let fakeControl: FakeControl?
    let logger = RecordingLogger()
    let conditions = Locked(Conditions())
    let epoch = Locked<String?>("e1")
    let fullMediaAccess = Locked(true)
    let afterCycles = Locked(0)
    /// 收尾（审计冲刷）挂起，直到放行。
    let afterCycleHold = Locked(false)
    let afterCycleGate = Gate()
    let views = Locked<[EngineView]>([])
    let advertised = Locked<[String]>([])
    let conditionsHook = Locked<(() throws -> Conditions)?>(nil)
    private(set) var engine: FlowEngine!

    /// 非 nil 时引擎用它（真实的 FlowDeliveryPort）而不是 [delivery] 这个假端口。
    let portOverride: ItemDelivery?
    let leaseOverride: ExecutionLease?
    let schedulerOverride: WakeScheduler?
    /// 引擎看到的媒体源：默认就是 [media]；收件箱测试（#958）换成按 seq 取件的包装。
    private(set) var source: MediaSource!

    init(_ name: String = #function, cursors: Bool = true, openRound: String? = nil, control: FlowControl? = nil, directory: TempDir? = nil, port: ItemDelivery? = nil, lease: ExecutionLease? = nil, scheduler: WakeScheduler? = nil, source: ((FakeMedia) -> MediaSource)? = nil) throws {
        portOverride = port
        leaseOverride = lease
        schedulerOverride = scheduler
        dir = directory ?? TempDir(name)
        store = try SQLiteOrderStore(directory: dir.url, logger: logger, clock: clock.function)
        importer = FakeImporter(media: media)
        if let control {
            self.control = control
            fakeControl = nil
        } else {
            let f = FakeControl()
            self.control = f
            fakeControl = f
        }
        if cursors {
            try store.saveDiscoveryState(DiscoveryState(position: FakePosition(epoch: 1, generation: 0, id: "").encoded, libraryIdentity: "lib-1"))
        }
        if let openRound { try store.openRound(openRound) }
        self.source = source?(media) ?? media
        engine = makeEngine()
    }

    func makeEngine() -> FlowEngine {
        FlowEngine(
            store: store, media: source, importer: importer, delivery: portOverride ?? delivery, probe: probe, presence: presence,
            lease: leaseOverride ?? lease, scheduler: schedulerOverride ?? scheduler, control: control,
            conditions: { [conditions, conditionsHook] in (try? conditionsHook.get()?()) ?? conditions.get() },
            inScope: { [media] in media.isInScope($0) },
            mediaAbsenceTrusted: { [fullMediaAccess] in fullMediaAccess.get() },
            pairingEpoch: { [epoch] in epoch.get() },
            logger: logger,
            clock: clock.function,
            monotonic: { 0 },
            afterCycle: { [afterCycles, afterCycleHold, afterCycleGate] in
                if afterCycleHold.get() { try? await afterCycleGate.wait() }
                afterCycles.update { $0 += 1 }
            },
            onEpochAdvertised: { [advertised] e in advertised.update { $0.append(e) } },
            onView: { [views] v in views.update { $0.append(v) } }
        )
    }

    @discardableResult
    func photo(_ n: Int, generation: Int64, content: String? = nil, bucket: String = "B7", video: Bool = false) -> FakePhoto {
        let p = FakePhoto(n: n, modified: 100 + Int64(n), size: 10 + Int64(n), content: content ?? "c\(n)", generation: generation, bucket: bucket, video: video)
        media.put(p)
        return p
    }

    @discardableResult
    func order(_ p: FakePhoto, _ state: OrderState) throws -> Order {
        try store.insert(NewOrder(mediaId: p.mediaId, sourceVersion: p.sourceVersion, bucketId: p.bucket, contentHash: p.hash, state: state, pairingEpoch: "e1"))
    }

    func state(_ n: Int) throws -> OrderState? { try store.currentForMedia(mid(n))?.state }

    func current(_ n: Int) throws -> Order? { try store.currentForMedia(mid(n)) }

    /// G 的 generation 部分（Android 测试里的 `generation()`）。
    func generation() throws -> Int64 { FakePosition.decode(try store.discoveryState()!.position).generation }

    func advanceG(_ generation: Int64) throws {
        try store.advanceDiscovery(FakePosition(epoch: 1, generation: generation, id: nil).encoded)
    }

    func start() async { await engine.start() }

    /// 触发并等这一轮（含合并进来的触发）跑完。
    func trigger(_ reason: TriggerReason = .mediaChange) async {
        await engine.trigger(reason)
        await engine.awaitIdle()
    }

    func pending() async -> Int { await engine.view.pending }

    func cancelRemainingNow() async throws -> Int {
        fakeControl?.pausedFlag = true
        return try await engine.cancelRemaining(engine.remainingSnapshot()) ?? 0
    }
}

/// 轮询等待一个条件成立（用于「传输已经开始 / 挂在闸门上」这类跨任务的观察点）。
func eventually(_ what: String = "condition", timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    XCTFail("timed out waiting for \(what)", file: file, line: line)
}

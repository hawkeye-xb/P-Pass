// #891：传输端口的真实实现（对位 Android `NativeFlowDeliveryPort` / `DaemonDesktopProbe` / `RemotePresenceProbe` /
// `AuditOutboxDispatcher`）。字节走原生 iroh-blobs（FFI，#313），这里只管控制面与等待循环：
//   serve → offer（带 size_bytes）→ 等结局（推送优先 → 本地信号 → 有界 status 兜底）→ 四字段核对回执。
// 取消（暂停 / 执行时间被收回 / 断网）时：停原生传输 → 同步、不继承取消、有界（约 3 秒）地发 `flow.suspend` → 再抛取消。
// **取消绝不发 `flow.cancel`**；丢弃半截只走 `discardPartial`（`flow.cancel_tuple`）。
import Foundation

/// 一次供数占用 provider 的凭据：queue_sequence = order 行 id，lease_token = `lease-<id>`。
public struct ProviderLease: Equatable, Sendable {
    public let orderId: Int64
    public let leaseToken: String
    public let contentHash: String

    public init(orderId: Int64, leaseToken: String, contentHash: String) {
        self.orderId = orderId
        self.leaseToken = leaseToken
        self.contentHash = contentHash
    }
}

/// 原生 iroh-blobs provider（FFI，#313 / IOS-05）中传输端口用到的那一部分。
public protocol BlobProvider: Sendable {
    /// 让已导入的内容成为当前 lease 并返回 ticket。原图已删 / 已变、端点没上线时抛 [ProviderFailure]。
    func serve(_ lease: ProviderLease) async throws -> String
    /// 当前 lease 的本地传输状态（读本地字段，不走网络）。
    func transferStatus() -> TransferStatus
    /// 停掉这个 lease 的原生传输（不丢 provider 里的内容）。
    func pause(_ lease: ProviderLease)
    /// 已确认：放掉供数占用与导入。不许抛。
    func releaseRetention(_ lease: ProviderLease)
}

/// 一轮的推送订阅（`timeline.subscribe` 上的 `flow.delivered` / `flow.failed`）。
public protocol FlowPushSource: Sendable {
    /// 订阅一次：确认帧到达时调 [onConnected]，之后每条推送调 [onEvent]；流结束时返回，出错时抛；必须响应取消。
    func subscribe(onConnected: @escaping @Sendable () -> Void, onEvent: @escaping @Sendable (String, JSONValue) -> Void) async throws
}

/// 传输端口需要的桌面控制面（对位 Android `FlowReceiptClient`）。对端可达但拒绝时抛 [DesktopRejected]。
public protocol FlowDesktop: Sendable {
    func hello() async throws -> Hello
    /// NET-24：offer 的回复与此刻 status 的回复同形；终态（桌面按 hash 判重已有 / rebind）可能直接随 offer 回来。
    func offer(_ request: FlowFetchRequest) async throws -> FlowStatusReply
    func status(_ tuple: FlowTupleRef) async throws -> FlowStatusReply
    /// `flow.suspend`：打断桌面的拉取任务，grant 保持 active（半截受保护，续传只补缺的）。
    func suspendFetch(_ tuple: FlowTupleRef) async throws
    /// `flow.cancel_tuple`：丢掉桌面半截。
    func cancelTuple(_ tuple: FlowTupleRef) async throws
    func auditSubmit(_ events: [FlowAuditEvent]) async throws -> FlowAuditAccepted
    func presence(_ query: BackupPresenceQuery) async throws -> BackupMissing
}

/// [FlowDesktop] 的控制面实现：一切经 [ProtoClient]（FFI 的 `call(method, params_json)`）。
public struct ControlPlaneDesktop: FlowDesktop {
    public let client: ProtoClient

    public init(client: ProtoClient) { self.client = client }

    private func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type) async throws -> R {
        do {
            return try await client.call(method, params, as: R.self)
        } catch let rejection as ProtoRejection {
            throw DesktopRejected(msgKey: rejection.error?.msgKey, method: method)
        }
    }

    private func callOk<P: Encodable>(_ method: String, _ params: P) async throws {
        let resp = try await client.callRaw(method, params)
        guard resp.ok else { throw DesktopRejected(msgKey: resp.error?.msgKey, method: method) }
    }

    public func hello() async throws -> Hello { try await call(Methods.hello, JSONValue.object([:]), as: Hello.self) }
    public func offer(_ request: FlowFetchRequest) async throws -> FlowStatusReply { try await call(Methods.flowOffer, request, as: FlowStatusReply.self) }
    public func status(_ tuple: FlowTupleRef) async throws -> FlowStatusReply { try await call(Methods.flowStatus, tuple, as: FlowStatusReply.self) }
    public func suspendFetch(_ tuple: FlowTupleRef) async throws { try await callOk(Methods.flowSuspend, tuple) }
    public func cancelTuple(_ tuple: FlowTupleRef) async throws { try await callOk(Methods.flowCancelTuple, tuple) }
    public func auditSubmit(_ events: [FlowAuditEvent]) async throws -> FlowAuditAccepted {
        try await call(Methods.flowAuditSubmit, FlowAuditSubmit(events: events), as: FlowAuditAccepted.self)
    }
    public func presence(_ query: BackupPresenceQuery) async throws -> BackupMissing {
        try await call(Methods.backupPresence, query, as: BackupMissing.self)
    }
}

/// 进程内的「配对已失效」事实（某个配对代号被桌面以 not_authorized / not_paired 拒绝过）。UI 的红卡读它。
public final class PairingLoss: @unchecked Sendable {
    private let lock = NSLock()
    private var lostEpoch: String?
    private var changes: Int64 = 0

    public init() {}

    public func record(epoch: String, failure: Error) {
        guard let rejected = failure as? DesktopRejected, let key = rejected.msgKey, isPairingLostText(key) else { return }
        lock.lock(); defer { lock.unlock() }
        lostEpoch = epoch
        changes += 1
    }

    public func isLost(epoch: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return lostEpoch == epoch
    }

    public var changeCount: Int64 {
        lock.lock(); defer { lock.unlock() }
        return changes
    }
}

/// 只有界地等一个异步操作：操作本身跑在不继承取消的非结构化 Task 里（调用方已被取消时也照样发出去），
/// 超时就不等了（操作自己跑完或失败）。返回 nil = 超时。
func boundedWait<T: Sendable>(_ timeoutMs: Int64, sleep: @escaping @Sendable (Int64) async throws -> Void, _ op: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
    let once = OnceFlag()
    return await withCheckedContinuation { (cont: CheckedContinuation<Result<T, Error>?, Never>) in
        Task {
            let result: Result<T, Error>
            do { result = .success(try await op()) } catch { result = .failure(error) }
            if once.claim() { cont.resume(returning: result) }
        }
        Task {
            try? await sleep(timeoutMs)
            if once.claim() { cont.resume(returning: nil) }
        }
    }
}

/// 传输端口（对位 Android `NativeFlowDeliveryPort`）。
public final class FlowDeliveryPort: ItemDelivery, @unchecked Sendable {
    private let provider: BlobProvider
    private let currentEpoch: @Sendable () -> String?
    private let desktop: FlowDesktop
    private let push: FlowPushSource
    private let logger: CoreLogger
    /// 单调时钟（ms）。
    private let clock: @Sendable () -> Int64
    private let sleep: @Sendable (Int64) async throws -> Void
    private let timings: DeliveryTimings
    private let pairingLoss: PairingLoss

    private let lock = NSLock()
    private var round: Round?

    public init(
        provider: BlobProvider,
        currentEpoch: @escaping @Sendable () -> String?,
        desktop: FlowDesktop,
        push: FlowPushSource,
        logger: CoreLogger,
        clock: @escaping @Sendable () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
        timings: DeliveryTimings = DeliveryTimings(),
        pairingLoss: PairingLoss = PairingLoss()
    ) {
        self.provider = provider
        self.currentEpoch = currentEpoch
        self.desktop = desktop
        self.push = push
        self.logger = logger
        self.clock = clock
        self.sleep = sleep
        self.timings = timings
        self.pairingLoss = pairingLoss
    }

    /// 一轮的推送订阅：缓冲无界（整轮共用，旧 tuple 的推送不许把要等的那条挤掉），按 tuple 过滤。
    final class Round: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, JSONValue)] = []
        private var connectedFlag = false
        private var readyWaiters: [CheckedContinuation<Void, Never>] = []
        var readyAwaited = false
        private var lostFlag = false

        func append(_ kind: String, _ data: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            events.append((kind, data))
        }

        func popEvent() -> (String, JSONValue)? {
            lock.lock(); defer { lock.unlock() }
            return events.isEmpty ? nil : events.removeFirst()
        }

        func clearEvents() {
            lock.lock(); defer { lock.unlock() }
            events.removeAll()
        }

        /// 会话结束：还在等订阅就绪的一律放行（否则那个等待任务和它捕获的这一轮永远挂着）。
        func close() {
            lock.lock()
            let waiters = readyWaiters
            readyWaiters.removeAll()
            closed = true
            lock.unlock()
            waiters.forEach { $0.resume() }
        }

        private var closed = false

        func markConnected() {
            lock.lock()
            connectedFlag = true
            lostFlag = false
            let waiters = readyWaiters
            readyWaiters.removeAll()
            lock.unlock()
            waiters.forEach { $0.resume() }
        }

        var subscriptionLost: Bool {
            get { lock.lock(); defer { lock.unlock() }; return lostFlag }
            set { lock.lock(); lostFlag = newValue; lock.unlock() }
        }

        /// 等订阅就绪，最多 [timeoutMs]；返回是否就绪。
        func awaitConnected(_ timeoutMs: Int64, sleep: @escaping @Sendable (Int64) async throws -> Void) async -> Bool {
            let ready = await boundedWait(timeoutMs, sleep: sleep) { [self] in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if connectedFlag || closed {
                        lock.unlock()
                        c.resume()
                    } else {
                        readyWaiters.append(c)
                        lock.unlock()
                    }
                }
            }
            return ready != nil
        }
    }

    private func log(_ m: String) { logger.log(m) }

    private func setRound(_ r: Round) {
        lock.lock(); defer { lock.unlock() }
        round = r
    }

    private func clearRound(_ r: Round) {
        lock.lock(); defer { lock.unlock() }
        if round === r { round = nil }
    }

    private func currentRound() -> Round? {
        lock.lock(); defer { lock.unlock() }
        return round
    }

    public func session<T>(_ body: () async throws -> T) async throws -> T {
        guard currentEpoch() != nil else { return try await body() }
        let r = Round()
        // 推送只是加速，不是唯一路径：订阅失败不致命，本地信号 + status() 兜底。断了按退避重建。
        let subscription = Task { await self.keepSubscribed(r) }
        setRound(r)
        defer {
            clearRound(r)
            subscription.cancel()
            r.close()
        }
        return try await body()
    }

    public func deliver(_ request: DeliveryRequest, onProgress: @escaping @Sendable (Int64) -> Void) async throws -> DeliveryOutcome {
        if let r = currentRound() { return try await deliverIn(r, request, onProgress) }
        // 没有外层会话（调用方没开轮）：这一张自己开一条订阅。未配对时没有会话可开。
        guard currentEpoch() != nil else { return .pairingLost }
        return try await session { [self] in
            guard let r = currentRound() else { return .pairingLost }
            return try await deliverIn(r, request, onProgress)
        }
    }

    private func deliverIn(_ r: Round, _ request: DeliveryRequest, _ onProgress: @escaping @Sendable (Int64) -> Void) async throws -> DeliveryOutcome {
        guard let epoch = currentEpoch() else { return .pairingLost }
        if epoch != request.pairingEpoch { return .pathFailure("epoch_changed") }
        let lease = ProviderLease(orderId: request.orderId, leaseToken: request.leaseToken, contentHash: request.contentHash)
        let ticket: String
        do {
            ticket = try await provider.serve(lease)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            let outcome = classifyProviderFailure(error)
            log("order \(request.orderId): provider serve failed -> \(outcome) (\(error))")
            return outcome
        }
        // 供数可能阻塞很久：返回之后、offer 之前再看一眼是不是已经被暂停 / 取消了。
        if Task.isCancelled {
            provider.pause(lease)
            throw CancellationError()
        }
        let details = request.details
        let fetch = FlowFetchRequest(
            queueSequence: UInt64(request.orderId), pairingEpoch: request.pairingEpoch, leaseToken: request.leaseToken,
            contentHash: request.contentHash, fileName: details.fileName, mediaType: details.mimeType, provider: ticket,
            captureAtMs: details.captureAtMs, sizeBytes: max(0, details.sizeBytes)
        )
        let tuple = FlowTupleRef(queueSequence: fetch.queueSequence, pairingEpoch: fetch.pairingEpoch, leaseToken: fetch.leaseToken)
        do {
            if !r.readyAwaited {
                // 推送可能早于订阅建立，桌面的 broadcast 不重放：首张 offer 之前限时等订阅就绪（超时照样继续，status 兜底）。
                r.readyAwaited = true
                if !(await r.awaitConnected(timings.subscriptionReadyTimeoutMs, sleep: sleep)) {
                    log("Flow push subscription not ready within \(timings.subscriptionReadyTimeoutMs)ms; offering anyway")
                }
            }
            // 整轮共用一条订阅：offer 之前积压的都是别的 tuple / 上一次尝试的，丢掉。
            r.clearEvents()
            try Task.checkCancellation()
            let offerReply = try await desktop.offer(fetch)
            try Task.checkCancellation()
            switch try flowStatusPollOutcome(offerReply) {
            case let .completed(receipt):
                log("Flow resolved by=offer_reply seq=\(fetch.queueSequence)")
                return try accept(receipt, fetch, lease)
            case .cancelled:
                provider.pause(lease)
                return .pathFailure("offer_cancelled")
            case .keepPolling:
                break
            }
            return try await waitForCompletion(r, fetch, tuple, lease, request.pairingEpoch, onProgress)
        } catch {
            if error is CancellationError || Task.isCancelled {
                // 暂停 / 执行时间被收回 / 断网：停掉原生传输，再同步、有界地告诉桌面「先停，别丢」（flow.suspend）。
                provider.pause(lease)
                await boundedControlCall("flow.suspend", fetch.queueSequence) { [desktop] in try await desktop.suspendFetch(tuple) }
                throw CancellationError()
            }
            provider.pause(lease)
            if currentEpoch() != request.pairingEpoch { return .pathFailure("epoch_changed") }
            pairingLoss.record(epoch: request.pairingEpoch, failure: error)
            let outcome = classifyDeliveryFailure(error)
            log("order \(request.orderId): delivery ended with \(outcome) (\(error))")
            return outcome
        }
    }

    private func boundedControlCall(_ label: String, _ seq: UInt64, _ call: @escaping @Sendable () async throws -> Void) async {
        let result = await boundedWait(timings.controlCallTimeoutMs, sleep: sleep, call)
        switch result {
        case nil: log("\(label) seq=\(seq): no reply within \(timings.controlCallTimeoutMs)ms; not waiting")
        case let .failure(e)?: log("\(label) seq=\(seq) failed: \(e)")
        case .success?: log("\(label) seq=\(seq) sent")
        }
    }

    /// 短超时的一次 `flow.status`（本地中止 / 订阅丢了之后用）。超时或网络错误 → nil（调用方判路径失败）；
    /// 桌面可达但拒绝照常抛出，由外层分类。
    private func quickStatus(_ tuple: FlowTupleRef) async throws -> FlowStatusReply? {
        let result = await boundedWait(timings.stallStatusTimeoutMs, sleep: sleep) { [desktop] in try await desktop.status(tuple) }
        switch result {
        case nil: return nil
        case let .success(reply)?: return reply
        case let .failure(e)?:
            if e is DesktopRejected { throw e }
            return nil
        }
    }

    private func waitForCompletion(_ r: Round, _ fetch: FlowFetchRequest, _ tuple: FlowTupleRef, _ lease: ProviderLease, _ epoch: String, _ onProgress: @escaping @Sendable (Int64) -> Void) async throws -> DeliveryOutcome {
        // NET-06 / NET-14：优先级——推送，然后本地 iroh-blobs 信号，然后有界的 status() 兜底。
        let seq = fetch.queueSequence
        var pollIndex = 0
        var consecutiveStatusFailures = 0
        var lastBytes: Int64 = -1
        let startedAt = clock()
        var abortChecked = false
        while true {
            try Task.checkCancellation()
            if currentEpoch() != epoch {
                provider.pause(lease)
                return .pathFailure("epoch_changed")
            }
            // 按 tuple 过滤：不是这一张的推送直接丢（整轮共用一条订阅）。
            var pushed: FlowPushOutcome?
            while pushed == nil, let (kind, data) = r.popEvent() {
                pushed = parseFlowPushOutcome(kind: kind, data: data, tuple: tuple)
            }
            let local = provider.transferStatus()
            // 引用的原图在供数期间被删 / 被改：桌面那边只会报 fetch_failed，所以先看这里（R-05）。桌面已经回了完整回执的除外。
            var fault: SourceFault?
            switch local {
            case let .aborted(_, source): fault = source
            case let .inProgress(_, _, _, _, source): fault = source
            default: fault = nil
            }
            if let fault, !{ if case .delivered? = pushed { return true }; return false }() {
                log("order \(seq): source \(fault.rawValue) while serving; abandoning as source missing")
                provider.pause(lease)
                return .sourceMissing
            }
            // 本地传输中止（不是源文件的问题）或推送订阅断了且重建失败：立即、短超时问一次桌面；问不到就判路径失败。
            var suspect: String?
            if case .aborted = local, !abortChecked { suspect = "local_aborted" } else if r.subscriptionLost { suspect = "subscription_lost" }
            if let suspect, pushed == nil {
                if case .aborted = local { abortChecked = true }
                r.subscriptionLost = false
                guard let reply = try await quickStatus(tuple) else {
                    log("order \(seq): \(suspect) and the desktop did not answer flow.status within \(timings.stallStatusTimeoutMs)ms; path failure")
                    provider.pause(lease)
                    return .pathFailure("desktop_unreachable:\(suspect)")
                }
                switch try flowStatusPollOutcome(reply) {
                case let .completed(receipt): return try accept(receipt, fetch, lease)
                case .cancelled:
                    provider.pause(lease)
                    return .pathFailure("cancelled")
                case .keepPolling:
                    log("order \(seq): \(suspect) but the desktop still reports \(reply.state); waiting")
                }
            }
            if case let .inProgress(_, _, sent?, _, _) = local, sent != lastBytes {
                lastBytes = sent
                onProgress(sent)
            }
            // 本地传输已完成 → 字节全部发出了，报一次满（#250：否则等回执那段时间停在 99%）。
            if case .completed = local, fetch.sizeBytes > 0, lastBytes < fetch.sizeBytes {
                lastBytes = fetch.sizeBytes
                onProgress(fetch.sizeBytes)
            }
            let elapsed = clock() - startedAt
            switch flowWaitStep(pushed: pushed, local: local, idleStallThresholdMs: timings.idleStallThresholdMs, byteStallThresholdMs: timings.byteStallThresholdMs, attemptElapsedMs: elapsed) {
            case let .resolved(outcome):
                switch outcome {
                case let .completed(receipt):
                    log("Flow resolved by=push seq=\(seq)")
                    return try accept(receipt, fetch, lease)
                case .cancelled:
                    provider.pause(lease)
                    return .pathFailure("cancelled")
                case .keepPolling:
                    continue
                }
            case let .failed(code):
                provider.pause(lease)
                return classifyPushedFailure(code)
            case .stalled:
                // C-10：连接还在、很久没有新的文件字节 → 主动断开，路径失败。
                log("order \(seq): no new file bytes for \(timings.byteStallThresholdMs)ms; disconnecting")
                provider.pause(lease)
                return .pathFailure("byte_stall")
            case .keepWaitingForPush:
                try await sleep(timings.localStatusRecheckMs)
            case .checkStatusNow:
                let reply: FlowStatusReply
                do {
                    reply = try await desktop.status(tuple)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let rejected as DesktopRejected {
                    throw rejected
                } catch {
                    consecutiveStatusFailures += 1
                    log("Flow status poll failed seq=\(seq) #\(consecutiveStatusFailures) (\(error))")
                    if consecutiveStatusFailures >= timings.statusPollMaxConsecutiveFailures { throw error }
                    try await sleep(pollDelay(pollIndex))
                    pollIndex += 1
                    continue
                }
                consecutiveStatusFailures = 0
                switch try flowStatusPollOutcome(reply) {
                case let .completed(receipt):
                    log("Flow resolved by=status seq=\(seq)")
                    return try accept(receipt, fetch, lease)
                case .cancelled:
                    provider.pause(lease)
                    return .pathFailure("cancelled")
                case .keepPolling:
                    // C-11：桌面回 active 就继续等，不判失败（字节停滞由 stalled 兜底）。
                    try await sleep(pollDelay(pollIndex))
                    pollIndex += 1
                }
            }
        }
    }

    private func pollDelay(_ index: Int) -> Int64 {
        Int64(Double(nextStatusPollDelayMs(index)) * timings.statusPollDelayScale)
    }

    private func accept(_ receipt: FlowCompletionReceipt, _ fetch: FlowFetchRequest, _ lease: ProviderLease) throws -> DeliveryOutcome {
        let completed = try relayFlowCompletion(receipt, fetch)
        // BLOB-03：只在核对通过之后放掉供数占用。
        provider.releaseRetention(lease)
        return .confirmed(completed)
    }

    /// 保持这一轮的推送订阅一直在：流结束（正常或抛错）就按退避重建，直到会话结束取消它。取消必须让它退出。
    private func keepSubscribed(_ r: Round) async {
        var attempt = 0
        while !Task.isCancelled {
            if attempt > 0 { log("Flow push subscription rebuild #\(attempt)") }
            let connectedThisAttempt = LockedFlag()
            var reason = "stream_ended"
            do {
                try await push.subscribe(onConnected: {
                    connectedThisAttempt.set()
                    r.markConnected()
                }, onEvent: { kind, data in r.append(kind, data) })
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                reason = "\(error)"
            }
            if Task.isCancelled { return }
            // 断开之后的重建也没连上：告诉等待循环去问一次桌面（桌面多半不在了）。
            if attempt >= 1 && !connectedThisAttempt.value { r.subscriptionLost = true }
            let delays = timings.subscriptionRetryDelaysMs
            let retryIn = delays[min(attempt, delays.count - 1)]
            log("Flow push subscription closed attempt=\(attempt) reason=\(reason); retry in \(retryIn)ms")
            do { try await sleep(retryIn) } catch { return }
            attempt += 1
        }
    }

    public func discardPartial(orderId: Int64, pairingEpoch: String) async {
        guard currentEpoch() != nil else { return }
        let tuple = FlowTupleRef(queueSequence: UInt64(orderId), pairingEpoch: pairingEpoch, leaseToken: leaseTokenFor(orderId))
        await boundedControlCall("flow.cancel_tuple", tuple.queueSequence) { [desktop] in try await desktop.cancelTuple(tuple) }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// `hello` 探测（有超时）：桌面可达吗、它现在的配对代号是什么、它健不健康（#413 契约 §5）。
public struct ControlPlaneProbe: DesktopProbe {
    let currentEpoch: @Sendable () -> String?
    let desktop: FlowDesktop
    let timeoutMs: Int64
    let logger: CoreLogger
    let pairingLoss: PairingLoss
    let sleep: @Sendable (Int64) async throws -> Void

    public init(currentEpoch: @escaping @Sendable () -> String?, desktop: FlowDesktop, logger: CoreLogger, pairingLoss: PairingLoss, timeoutMs: Int64 = 20_000,
                sleep: @escaping @Sendable (Int64) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) }) {
        self.currentEpoch = currentEpoch
        self.desktop = desktop
        self.timeoutMs = timeoutMs
        self.logger = logger
        self.pairingLoss = pairingLoss
        self.sleep = sleep
    }

    public func probe() async -> ProbeResult {
        guard let epoch = currentEpoch() else { return .pairingLost }
        let result = await boundedWait(timeoutMs, sleep: sleep) { [desktop] in try await desktop.hello() }
        switch result {
        case nil:
            logger.log("Flow probe result=unreachable:probe_timeout_\(timeoutMs)ms")
            return .unreachable
        case let .success(hello)?:
            logger.log("Flow probe result=reachable")
            return .reachable(advertisedEpoch: hello.pairingEpoch, health: hello.health.map(DesktopHealth.init(wire:)), capabilities: Set(hello.capabilities))
        case let .failure(error)?:
            if let rejected = error as? DesktopRejected {
                logger.log("Flow probe result=rejected:\(rejected.msgKey ?? "nil")")
                // #466：每轮先探测，桌面移除这台手机时走不到投递——探测这里也要记，红卡才会亮。
                pairingLoss.record(epoch: epoch, failure: rejected)
                if let key = rejected.msgKey, isPairingLostText(key) { return .pairingLost }
                return .unreachable
            }
            logger.log("Flow probe result=unreachable error=\(error)")
            return .unreachable
        }
    }
}

/// ARCH-08：一页「这些 hash 你还在吗」最多这么多条。
public let remotePresencePageSize = 500

/// 一页 presence 查询的校验：非空、不超过一页、全是 64 位十六进制 BLAKE3。
public func presenceQueryFor(_ hashes: [String]) throws -> BackupPresenceQuery {
    guard !hashes.isEmpty else { throw InconsistentReply(detail: "presence page must not be empty") }
    guard hashes.count <= remotePresencePageSize else { throw InconsistentReply(detail: "presence page exceeds \(remotePresencePageSize) hashes") }
    let hex = Set("0123456789abcdefABCDEF")
    guard hashes.allSatisfy({ $0.count == 64 && $0.allSatisfy(hex.contains) }) else { throw InconsistentReply(detail: "presence page contains an invalid hash") }
    return BackupPresenceQuery(hashes: hashes)
}

/// 对账：分页问桌面「这些 hash 你还在吗」。不可达 / 拒绝时抛（引擎这一轮放弃对账，下一轮再问）。
public struct ControlPlanePresence: RemotePresence {
    let desktop: FlowDesktop

    public init(desktop: FlowDesktop) { self.desktop = desktop }

    public func missing(_ hashes: [String]) async throws -> Set<String> {
        let query = try presenceQueryFor(hashes)
        return Set(try await desktop.presence(query).hashes)
    }
}

/// AUDIT-01：把 order 库的持久审计 outbox 冲到桌面（`flow.audit.submit`），只删桌面确认落库的那些。
/// AUDIT-06：一次冲刷按 seq 分页走完整个 outbox（不是每次都从最旧的读）：被桌面永久拒收的留在原地，但挡不住后面的。
public struct AuditOutboxDispatcher: Sendable {
    public static let batch = 200
    let store: OrderStore
    let desktop: @Sendable () -> FlowDesktop?
    /// 删已确认事件这一步回到单写者上执行（生产：`engine.acknowledgeAudit`）。
    let acknowledge: @Sendable (Set<String>) async -> Void

    public init(store: OrderStore, desktop: @escaping @Sendable () -> FlowDesktop?, acknowledge: @escaping @Sendable (Set<String>) async -> Void) {
        self.store = store
        self.desktop = desktop
        self.acknowledge = acknowledge
    }

    /// 尽力而为：任何失败（离线、未配对、IO）都停下这次冲刷，outbox 其余原样留着。
    public func flush() async {
        var cursor: Int64 = 0
        while true {
            guard let page = try? store.pendingAuditAfter(cursor, limit: Self.batch), let last = page.last else { return }
            guard let desktop = desktop() else { return }
            guard let accepted = try? await desktop.auditSubmit(page.map(\.record.wire)) else { return }
            if !accepted.eventIds.isEmpty { await acknowledge(Set(accepted.eventIds)) }
            if page.count < Self.batch { return }
            cursor = last.seq
        }
    }
}

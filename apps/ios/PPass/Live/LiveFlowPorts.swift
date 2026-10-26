import Foundation
import PPassCore
import PPassMedia
import PPassTransport
import UIKit

/// FFI 的原生 provider（一个进程一个；provider store 放在存储根目录下的 `blobs/`）。同步调用，放后台线程。
final class NativeProvider: @unchecked Sendable {
    let ffi: Provider
    /// 当前占用 provider 的 lease（对位 Android `IrohBlobsProviderBridge.active`）：serve 成功后记下，pause 时据此核对。
    private let activeLock = NSLock()
    private var activeLease: ProviderLease?

    func setActive(_ lease: ProviderLease?) {
        activeLock.lock(); defer { activeLock.unlock() }
        activeLease = lease
    }

    /// 取出并清空 active；传入的 lease 与 active 不是同一份（orderId / leaseToken）时返回 nil、不动。
    func takeActive(matching lease: ProviderLease) -> ProviderLease? {
        activeLock.lock(); defer { activeLock.unlock() }
        guard let current = activeLease, current.orderId == lease.orderId, current.leaseToken == lease.leaseToken else { return nil }
        activeLease = nil
        return current
    }

    /// 设置允许拉原图的对端（#547；#1015）。Android 在建运行时时直接调、失败抛出并记 error；这里启动与配对两处共用：
    /// 原生侧在 node id 格式非法时已「拒绝所有人」（fail-closed），所以这里只把失败写进日志、不中断启动或配对。
    /// 返回 false = 没设上（此时没有任何电脑能拉原图）。
    @discardableResult
    func applyAllowedPeer(_ nodeId: String?, context: String, logger: CoreLogger) -> Bool {
        do { try ffi.setAllowedPeer(nodeId: nodeId); return true } catch {
            logger.log("\(context): setAllowedPeer failed, no desktop can pull originals: \(error)")
            return false
        }
    }

    /// 断开（#974，对位 Android `clearFlowRuntime`）：旧桌面不许再拉——清允许的对端（在飞的连接在原生侧关掉）、
    /// 掐掉在飞传输并 revoke（拿掉当前 handler 与全部导入，同 `FfiBlobProvider.pause` 的 #958 语义：只 stop 不 revoke
    /// 会让同进程里重新配对后所有取原图都被拒）。清不掉的只记日志、不中断后面的步骤。
    /// 引擎这一轮在清单之前已由 `engine.stopForDisconnect` 停好；Android 在此还关 scope / writer / SQLite，
    /// iOS 的账本与引擎活过断开（06-ios-variants：同一台重连账本仍有效），所以不关。
    func teardownForDisconnect(logger: CoreLogger) {
        setActive(nil)
        do { try ffi.setAllowedPeer(nodeId: nil) } catch { logger.log("disconnect: clearing allowed peer failed: \(error)") }
        ffi.stopActiveFetch()
        ffi.revoke()
        logger.log("disconnect: provider revoked, allowed peer cleared")
    }

    /// #1126：provider 的入站连接被已配对电脑用应用关闭码关掉（电脑删了这台设备 = 410）时的监听。
    /// 回调在 Rust 自起的独立线程上，可直接调 provider 接口；本地 revoke / 关闭不会触发。
    let peerCloseListener: PeerCloseListener?

    init(root: URL, onPeerClosed: (@Sendable (String, UInt64) -> Void)? = nil) throws {
        let dir = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ffi = try Provider(root: dir.path)
        if let onPeerClosed {
            let listener = PeerCloseBridge(onPeerClosed)
            ffi.setPeerCloseListener(listener: listener)
            peerCloseListener = listener
        } else {
            peerCloseListener = nil
        }
    }

    func run<T>(_ body: @escaping @Sendable (Provider) throws -> T) async throws -> T {
        let ffi = self.ffi
        return try await Task.detached(priority: .userInitiated) { try body(ffi) }.value
    }
}

/// 导入：PhotoKit 取原图到临时文件（PPassMedia `OriginalFetcher`，D4 分类）→ provider 导入（BLAKE3 由 Rust 侧算，
/// 与 daemon 校验的是同一个值）。provider 是**按引用**导入的，所以临时文件要留到这张照片 `release` 为止。
final class PhotoImporter: MediaImporter, @unchecked Sendable {
    private let provider: NativeProvider
    private let fetcher: OriginalFetcher
    private let lock = NSLock()
    private var held: [String: FetchedOriginal] = [:]

    init(provider: NativeProvider, tempRoot: URL) {
        self.provider = provider
        fetcher = OriginalFetcher(tempRoot: tempRoot)
        fetcher.purgeLeftovers()
    }

    func importMedia(_ details: MediaDetails, onFetch: @escaping @Sendable (OriginalFetchUpdate) -> Void) async throws -> ImportResult {
        let assetId = details.snapshot.mediaId
        let progress = OriginalProgress()
        let started = Date()
        let original: FetchedOriginal
        do {
            // #1092：读之前判定一次原图在不在本机（公开 API、不下载）；要从 iCloud 下载时把下载进度报给引擎，首页据此显示。
            original = try await fetcher.fetch(assetId: assetId, progress: { p in
                progress.record(p)
                if progress.fromICloud == true { onFetch(OriginalFetchUpdate(fromICloud: true, fraction: p)) }
            }, onLocality: { local in
                progress.setFromICloud(!local)
                if !local { onFetch(OriginalFetchUpdate(fromICloud: true, fraction: nil)) }
            })
        } catch let failure as OriginalFetchFailure {
            guard let result = Self.result(for: failure) else { throw failure }
            return result
        }
        try Task.checkCancellation()
        let path = original.fileURL.path
        let imported = try await provider.run { try $0.importFile(path: path) }
        lock.lock()
        held[imported.hash]?.discard()
        held[imported.hash] = original
        lock.unlock()
        // 成功路径的判据行（#337）：原图取之前在不在本机（local=）、资源类型（rawValue：photo=1 video=2，编辑过为 fullSizePhoto=5 / fullSizeVideo=6）、字节数、系统进度回调次数
        // （真机实测本机原图也会回调，不能据此判断走了网络；在不在本机看调试包的 local=）、耗时、BLAKE3 前缀（与桌面库对账）。
        let (callbacks, last) = progress.snapshot()
        let locality = progress.fromICloud.map { $0 ? " local=no" : " local=yes" } ?? " local=unknown"
        AppLog.log("original fetched \(LogRedact.id(assetId)) type=\(original.info.resourceType.rawValue) bytes=\(original.sizeBytes) "
            + "progress_callbacks=\(callbacks) last_progress=\(String(format: "%.2f", last)) "
            + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) hash=\(imported.hash.prefix(16))\(locality)")
        return .imported(contentHash: imported.hash, sizeBytes: Int64(imported.size))
    }

    /// D4 分类 → 引擎的导入结果。nil = 资源确实不可得，抛错由引擎按单张失败计次；其余都不计失败预算。
    static func result(for failure: OriginalFetchFailure) -> ImportResult? {
        switch failure {
        case .sourceMissing: return .sourceMissing
        case .network(let reason): return .originalUnavailable(reason: reason)
        case .localStorageFull(let reason): return .localStorageFull(reason: reason)
        case .unavailable: return nil
        }
    }

    func release(_ contentHash: String) {
        try? provider.ffi.release(hash: contentHash)
        lock.lock()
        held.removeValue(forKey: contentHash)?.discard()
        lock.unlock()
    }
}

/// 取原图时系统回调的进度（跨线程）。真机实测本机原图也会回调，只作参考。
final class OriginalProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var last = 0.0
    private var _fromICloud: Bool?

    /// 读之前判定的结果：true = 要从 iCloud 下载；nil = 没判定出来。
    var fromICloud: Bool? { lock.lock(); defer { lock.unlock() }; return _fromICloud }
    func setFromICloud(_ value: Bool) { lock.lock(); _fromICloud = value; lock.unlock() }

    func record(_ value: Double) {
        lock.lock(); count += 1; last = value; lock.unlock()
    }

    func snapshot() -> (count: Int, last: Double) {
        lock.lock(); defer { lock.unlock() }
        return (count, last)
    }
}

/// PPassCore `BlobProvider` 端口。
struct FfiBlobProvider: BlobProvider {
    let provider: NativeProvider

    func serve(_ lease: ProviderLease) async throws -> String {
        do {
            let ticket = try await provider.run { try $0.serve(hash: lease.contentHash) }
            provider.setActive(lease)
            return ticket
        } catch let error as FfiError {
            switch error {
            case .SourceFault(let fault): throw fault == "changed" ? ProviderFailure.sourceChanged : ProviderFailure.sourceMissing
            case .Timeout(let msg): throw ProviderFailure.offline(msg)
            default: throw error
            }
        }
    }

    func transferStatus() -> PPassCore.TransferStatus {
        let source = provider.ffi.sourceFault().flatMap(SourceFault.init(rawValue:))
        switch provider.ffi.transferStatus() {
        case .noLease: return .noLease
        case .completed(let hash): return .completed(hash: hash)
        case .aborted(let hash): return .aborted(hash: hash, source: source)
        case .inProgress(let connected, let idle, let sent, let byteIdle):
            return .inProgress(connected: connected, idleForMs: idle.map(Int64.init(clamping:)),
                               bytesSent: sent.map(Int64.init(clamping:)),
                               byteIdleForMs: byteIdle.map(Int64.init(clamping:)), source: source)
        }
    }

    /// 暂停 / 中止：先关掉在飞的原生连接，再 revoke（Rust 侧拿掉当前 handler 与全部导入，下次 serve 新建 handler）。
    /// 只 stop 不 revoke 会让 handler 的 `accepting` 永远是 false：同进程里之后所有取原图连接都被立即关闭（#958）。
    /// 接收端的半截文件不动，续传从缺的区间接着拉。与 Android 一致：lease 不是当前 active 的就不动。
    func pause(_ lease: ProviderLease) {
        guard provider.takeActive(matching: lease) != nil else { return }
        provider.ffi.stopActiveFetch()
        provider.ffi.revoke()
    }
    func releaseRetention(_ lease: ProviderLease) { provider.ffi.releaseRetention() }
}

struct OSLogger: CoreLogger {
    func log(_ message: String) { AppLog.log(message) }
}

/// 探测前预热 provider（#979，对位 Android #434 `DesktopProbe { native.prewarm(); hello.probe() }`）：引擎只在「有东西要传」时
/// 才探测桌面，此刻先把 endpoint 绑上，它和 hello 并行去连 relay；否则第一张 serve 才从零绑定，短任务窗口（20 秒）里这段开销占比很高。
/// 预热失败不挡探测：serve 时照常自己绑。
struct PrewarmingProbe: DesktopProbe {
    let provider: NativeProvider
    let inner: DesktopProbe
    let logger: CoreLogger

    func probe() async -> ProbeResult {
        let started = Date()
        do {
            try await provider.run { try $0.prewarm() }
            logger.log("provider prewarm: endpoint bound in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        } catch {
            logger.log("provider prewarm failed; serve binds instead: \(error)")
        }
        return await inner.probe()
    }
}

/// 空闲回收 provider 的 endpoint（#979，对位 Android #434 `NetworkIdleReaper`）：不在前台、且引擎这一轮已结束，就关掉 endpoint
/// （store 不关），下次 serve / 预热时再懒绑定。provider 回 false（桌面还连着这一张）就隔一会儿再试，直到不再空闲。
/// 与 Android 的差别（06-ios-variants 登记）：Android 等 30 秒宽限期再关；iOS 退到后台后进程很快被挂起，等不到 30 秒，
/// 所以条件一成立就关——挂起前把 endpoint 放掉，而不是带着它挂起。控制面那条 endpoint 的 FFI 没有 park，不在本处。
final class ProviderIdleParker: @unchecked Sendable {
    static let retryMs: UInt64 = 2_000

    private let provider: NativeProvider
    private let logger: CoreLogger
    private let lock = NSLock()
    /// 起始按「不在前台」：后台任务拉起的进程不会收到 scenePhase 变化；前台启动时 `.active` 马上会把它翻成 true。
    private var foreground = false
    private var engineBusy = false
    /// 每次「空闲 ↔ 不空闲」变化加一；回收任务只在自己那一代仍然空闲时动手。
    private var generation = 0
    private var reaping = false

    init(provider: NativeProvider, logger: CoreLogger) {
        self.provider = provider
        self.logger = logger
    }

    func setForeground(_ visible: Bool) { update { $0.foreground = visible } }
    func setEngineBusy(_ busy: Bool) { update { $0.engineBusy = busy } }

    private var idle: Bool { !foreground && !engineBusy }

    private func update(_ change: (ProviderIdleParker) -> Void) {
        lock.lock()
        let wasIdle = idle
        change(self)
        let nowIdle = idle
        if wasIdle != nowIdle { generation += 1 }
        let start = nowIdle && !reaping
        if start { reaping = true }
        let gen = generation
        lock.unlock()
        if start { Task.detached(priority: .utility) { [weak self] in await self?.reap(from: gen) } }
    }

    private func stillIdle(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return idle && generation == gen
    }

    private func reap(from gen: Int) async {
        var gen = gen
        while true {
            if stillIdle(gen) {
                if provider.ffi.park() {
                    logger.log("provider: park ok (background, engine idle; endpoint closed if it was bound)")
                    break
                }
                logger.log("provider: idle but desktop still connected; retrying in \(Self.retryMs)ms")
                try? await Task.sleep(nanoseconds: Self.retryMs * 1_000_000)
                continue
            }
            // 这一代已经不空闲；若中途又回到空闲（新的一代），接着按新的一代回收，否则收工。
            lock.lock()
            let again = idle
            if again { gen = generation } else { reaping = false }
            lock.unlock()
            if !again { return }
        }
        lock.lock(); reaping = false; lock.unlock()
    }
}

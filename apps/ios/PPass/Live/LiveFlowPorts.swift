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

    init(root: URL) throws {
        let dir = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ffi = try Provider(root: dir.path)
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

    func importMedia(_ details: MediaDetails) async throws -> ImportResult {
        let original: FetchedOriginal
        do {
            original = try await fetcher.fetch(assetId: details.snapshot.mediaId)
        } catch let failure as OriginalFetchFailure {
            switch failure {
            case .sourceMissing: return .sourceMissing
            case .network(let reason): return .originalUnavailable(reason: reason)
            default: throw failure
            }
        }
        try Task.checkCancellation()
        let path = original.fileURL.path
        let imported = try await provider.run { try $0.importFile(path: path) }
        lock.lock()
        held[imported.hash]?.discard()
        held[imported.hash] = original
        lock.unlock()
        return .imported(contentHash: imported.hash, sizeBytes: Int64(imported.size))
    }

    func release(_ contentHash: String) {
        try? provider.ffi.release(hash: contentHash)
        lock.lock()
        held.removeValue(forKey: contentHash)?.discard()
        lock.unlock()
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

import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

/// #974：断开时 provider 清理（对位 Android `clearFlowRuntime`：`setAllowedPeer(null)` + `revoke("")`）。
/// 走真实的原生 provider + 控制端点（离线回环）：断开之后旧 ticket 拉不到、导入被放掉；重新配对（同一进程）之后
/// 重新导入 → 供数 → 取原图正常——与 #958 暂停同一套语义（stop + revoke 之后 handler 重建）。
final class DisconnectProviderTests: XCTestCase {
    private var dir: URL!
    private var client: CtrlClient!
    private var native: NativeProvider!
    private var ports: FfiBlobProvider!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("disconnect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        native = try NativeProvider(root: dir)
        try native.ffi.setAllowedPeer(nodeId: try client.nodeId())
        ports = FfiBlobProvider(provider: native)
    }

    override func tearDown() {
        client?.shutdown()
        native?.ffi.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, count: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return url
    }

    private func importFile(_ url: URL) async throws -> String {
        try await native.run { try $0.importFile(path: url.path) }.hash
    }

    private func pull(_ ticket: String) async throws -> String {
        let client = self.client!
        let scratch = dir.appendingPathComponent("scratch").path
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("pulled-\(UUID().uuidString)").path
        return try await Task.detached {
            try client.fetchBlob(ticket: ticket, scratchDir: scratch, destPath: dest, stallMs: 3_000, progress: nil, cancel: nil)
        }.value
    }

    private final class LogLines: CoreLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func log(_ message: String) { lock.lock(); lines.append(message); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    /// 断开后：旧对端（桌面若仍持有旧 ticket）拉不到；导入被放掉（不重新导入不能供数）；active lease 清空。
    /// 反证：teardown 去掉 revoke → 末尾的「不重新导入不能供数」红；去掉 setAllowedPeer(nil) → 旧 ticket 仍拉得到，红。
    func testTeardownRefusesTheOldPeerAndDropsTheImports() async throws {
        let hash = try await importFile(try makeFile("a.bin", count: 256 * 1024))
        let lease = ProviderLease(orderId: 1, leaseToken: "lease-1", contentHash: hash)
        let ticket = try await ports.serve(lease)
        let baseline = try await pull(ticket)
        XCTAssertEqual(baseline, hash, "断开之前取得到（基线）")

        native.teardownForDisconnect(logger: LogLines())

        do {
            _ = try await pull(ticket)
            XCTFail("断开之后旧 ticket 不应还能拉到")
        } catch {}
        XCTAssertNil(native.takeActive(matching: lease), "断开清掉 active lease")
        do {
            _ = try await ports.serve(lease)
            XCTFail("revoke 之后不重新导入不应还能供数")
        } catch {}
    }

    /// 重新配对（同一进程）：允许新对端 → 重新导入 → 供数 → 取原图正常。
    func testAfterTeardownAReconnectedPeerCanFetchOriginalsAgain() async throws {
        let file = try makeFile("a.bin", count: 256 * 1024)
        let hash = try await importFile(file)
        _ = try await ports.serve(ProviderLease(orderId: 1, leaseToken: "lease-1", contentHash: hash))

        native.teardownForDisconnect(logger: LogLines())
        // 断开期间没有允许的对端：同一个对端此刻也拉不到。
        let reimported = try await importFile(file)
        let during = try await ports.serve(ProviderLease(orderId: 1, leaseToken: "lease-2", contentHash: reimported))
        do {
            _ = try await pull(during)
            XCTFail("断开期间（允许对端为空）不应有人拉得到")
        } catch {}

        // 重新配对：paired() 里 setAllowedPeer(新对端)。
        try native.ffi.setAllowedPeer(nodeId: try client.nodeId())
        let again = try await importFile(file)
        let ticket = try await ports.serve(ProviderLease(orderId: 1, leaseToken: "lease-3", contentHash: again))
        let pulled = try await pull(ticket)
        XCTAssertEqual(pulled, hash, "重新配对后同进程取原图正常")
    }

    /// 断开清单驱动：`stopFlowRuntime` 不再是空函数——走 manifest 之后 provider 已撤销，且三个运行时都被调到。
    func testTheManifestDrivesTheProviderTeardown() async throws {
        let hash = try await importFile(try makeFile("a.bin", count: 64 * 1024))
        let lease = ProviderLease(orderId: 1, leaseToken: "lease-1", contentHash: hash)
        let ticket = try await ports.serve(lease)
        _ = try await pull(ticket)

        var calls: [String] = []
        let logger = LogLines()
        let actions = DisconnectActions(
            stopFlow: { [native] in native!.teardownForDisconnect(logger: logger); calls.append("flow") },
            cancelWakes: { calls.append("wakes") },
            stopMedia: { calls.append("media") },
            clearThumbs: { calls.append("thumbs") })
        let root = dir.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try applyDisconnectManifest(root: root, runtime: actions, logger: logger)

        XCTAssertEqual(Set(calls), ["flow", "wakes", "media", "thumbs"])
        do {
            _ = try await ports.serve(lease)
            XCTFail("断开清单执行后 provider 应已 revoke")
        } catch {}
    }
}

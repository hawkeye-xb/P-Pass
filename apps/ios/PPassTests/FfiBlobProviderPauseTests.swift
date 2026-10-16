import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

/// #958：暂停（`FfiBlobProvider.pause`）之后，同一进程里再供数 / 再取原图必须还能成功。
/// 走真实的原生 provider + 控制端点（离线回环，不需要 daemon）：Rust 侧 `stop_active_fetch` 会把当前 handler 的
/// `accepting` 置 false，只有 `revoke` 拿掉 handler 才能恢复，所以这里是端到端地验证「stop + revoke」。
final class FfiBlobProviderPauseTests: XCTestCase {
    private var dir: URL!
    private var client: CtrlClient!
    private var native: NativeProvider!
    private var ports: FfiBlobProvider!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        native = try NativeProvider(root: dir)
        try native.ffi.setAllowedPeer(nodeId: try client.nodeId())
        ports = FfiBlobProvider(provider: native)
    }

    override func tearDown() {
        client?.close()
        native?.ffi.close()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String, count: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: url)
        return url
    }

    private func importFile(_ url: URL) async throws -> (hash: String, size: Int) {
        let imported = try await native.run { try $0.importFile(path: url.path) }
        return (imported.hash, Int(imported.size))
    }

    /// 经控制端点（带配对身份）拉 ticket；返回内容哈希，失败抛错。
    private func pull(_ ticket: String) async throws -> String {
        let client = self.client!
        let scratch = dir.appendingPathComponent("scratch").path
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("pulled-\(UUID().uuidString)").path
        return try await Task.detached {
            try client.fetchBlob(ticket: ticket, scratchDir: scratch, destPath: dest, stallMs: 8_000, progress: nil, cancel: nil)
        }.value
    }

    func testServeAndPullWorksAfterPause() async throws {
        let file = try makeFile("a.bin", count: 256 * 1024)
        let first = try await importFile(file)
        let lease1 = ProviderLease(orderId: 1, leaseToken: "lease-1", contentHash: first.hash)
        let ticket1 = try await ports.serve(lease1)
        let baseline = try await pull(ticket1)
        XCTAssertEqual(baseline, first.hash, "暂停之前取得到（基线）")

        // 在飞时暂停：stop + revoke。之后的下一轮：重新导入 → 供数 → 取。
        ports.pause(lease1)
        let again = try await importFile(file)
        XCTAssertEqual(again.hash, first.hash)
        let lease2 = ProviderLease(orderId: 1, leaseToken: "lease-2", contentHash: again.hash)
        let ticket2 = try await ports.serve(lease2)
        let resumed = try await pull(ticket2)
        XCTAssertEqual(resumed, first.hash, "暂停之后同一张续传必须取得到（revoke 重建 handler）")

        // 排在后面的另一张也不被挡住。
        let other = try await importFile(try makeFile("b.bin", count: 128 * 1024))
        let ticket3 = try await ports.serve(ProviderLease(orderId: 2, leaseToken: "lease-3", contentHash: other.hash))
        let next = try await pull(ticket3)
        XCTAssertEqual(next, other.hash)
    }

    func testPauseOfAStaleLeaseLeavesTheActiveOneAlone() async throws {
        let file = try makeFile("a.bin", count: 64 * 1024)
        let imported = try await importFile(file)
        let current = ProviderLease(orderId: 1, leaseToken: "lease-1", contentHash: imported.hash)
        _ = try await ports.serve(current)

        // orderId / leaseToken 对不上 = 别人的 lease：不 stop 也不 revoke（与 Android 一致）。
        ports.pause(ProviderLease(orderId: 2, leaseToken: "lease-1", contentHash: imported.hash))
        ports.pause(ProviderLease(orderId: 1, leaseToken: "lease-OLD", contentHash: imported.hash))
        let ticket = try await ports.serve(current)  // 导入还在：没被 revoke 清掉
        let pulled = try await pull(ticket)
        XCTAssertEqual(pulled, imported.hash)

        // 对得上的才撤：导入被放掉，不重新导入就不能供数。
        ports.pause(current)
        do {
            _ = try await ports.serve(current)
            XCTFail("revoke 之后不重新导入不应还能供数")
        } catch {
            // 预期：NotImported
        }
    }
}

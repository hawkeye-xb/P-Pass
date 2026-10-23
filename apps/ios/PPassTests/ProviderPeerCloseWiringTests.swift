// #1126：电脑删掉这台设备时，除控制面连接外，上传 provider 的入站连接也被它以 410 关掉。
// 这里验接线：provider 的关闭监听 → 与控制面同一个处理（`desktopCloseHandler` → `recordDesktopClose`）→ 记配对失效。
// 用真实的 PairingStore / PairingLoss / NativeProvider（真实 uniffi Provider）；410 的真实来源（桌面关连接）由 Rust 侧测试覆盖，
// 这里直接以 provider 注册的那个监听对象回调，等同 Rust 线程的回调。
import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

private final class Lost: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
}

final class ProviderPeerCloseWiringTests: XCTestCase {
    private let daemon = String(repeating: "ab", count: 32)
    private let stranger = String(repeating: "cd", count: 32)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("provider-close-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func rig() throws -> (NativeProvider, Lost) {
        let store = PairingStore(root: dir)
        try store.save(PairingRecord(daemonNodeId: daemon, peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
        let loss = PairingLoss()
        let lost = Lost()
        loss.setOnLost { lost.add($0) }
        let handler = desktopCloseHandler(pairingStore: store, loss: loss, logger: NoopLogger())
        let provider = try NativeProvider(root: dir, onPeerClosed: handler)
        return (provider, lost)
    }

    /// 记录的电脑以 410（及 401）关了 provider 的连接 ⇒ 记成配对失效；别的关闭方、码 0、blobs 的 403 ⇒ 不动。
    /// 反证：NativeProvider 不注册监听（listener 为 nil）→ 第一条红；handler 里把判据换成自写的「任何码都算」→ 后三条红；
    /// 去掉 recordDesktopClose 里的关闭方核对 → 「别的 NodeId」红。
    func testProviderCloseListenerSharesTheDesktopCloseJudgement() throws {
        let (provider, lost) = try rig()
        defer { provider.ffi.shutdown() }
        let listener = try XCTUnwrap(provider.peerCloseListener, "provider 必须注册关闭监听")

        listener.onPeerClosed(nodeId: stranger, code: 410)
        listener.onPeerClosed(nodeId: daemon, code: 0)
        listener.onPeerClosed(nodeId: daemon, code: 403)
        XCTAssertEqual(lost.all, [], "别的 NodeId / 码 0 / 403 都不算配对失效")

        listener.onPeerClosed(nodeId: daemon, code: 410)
        XCTAssertEqual(lost.all, ["e1"], "记录的电脑 + 410 ⇒ 配对失效")
        listener.onPeerClosed(nodeId: daemon.uppercased(), code: 401)
        XCTAssertEqual(lost.all, ["e1", "e1"], "401 同样；NodeId 大小写不敏感")
    }

    /// 未配对（没有记录）时回调不记任何失效。
    func testNoPairingRecordMeansNothingToLose() throws {
        let store = PairingStore(root: dir)
        let loss = PairingLoss()
        let lost = Lost()
        loss.setOnLost { lost.add($0) }
        let handler = desktopCloseHandler(pairingStore: store, loss: loss, logger: NoopLogger())
        handler(daemon, 410)
        XCTAssertEqual(lost.all, [])
    }

    /// 本地关闭不触发监听：电脑（这里是一个控制端点）拉完一张图之后，本机 teardown（清允许的对端、停传输、revoke）
    /// 把在飞连接关掉——这是本地关闭，监听一次都不许响（否则每次断开都会误判成被电脑删除）。
    /// 反证：teardown / revoke 若改成以非 0 应用码关连接并上报，计数大于 0，红。
    func testLocalRevokeDoesNotFireTheListener() async throws {
        let counter = Lost()
        let client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.shutdown() }
        let native = try NativeProvider(root: dir, onPeerClosed: { node, code in counter.add("\(node):\(code)") })
        defer { native.ffi.shutdown() }
        try native.ffi.setAllowedPeer(nodeId: try client.nodeId())
        let file = dir.appendingPathComponent("a.bin")
        try Data((0..<(64 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: file)
        let imported = try await native.run { try $0.importFile(path: file.path) }
        let ticket = try native.ffi.serve(hash: imported.hash)
        let scratch = dir.appendingPathComponent("scratch").path
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("pulled").path
        let pulled = try await Task.detached {
            try client.fetchBlob(ticket: ticket, scratchDir: scratch, destPath: dest, stallMs: 3_000, progress: nil, cancel: nil)
        }.value
        XCTAssertEqual(pulled, imported.hash)

        native.teardownForDisconnect(logger: NoopLogger())
        native.ffi.stopActiveFetch()
        native.ffi.revoke()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(counter.all, [], "本地 revoke / 断开不触发关闭监听")
    }
}

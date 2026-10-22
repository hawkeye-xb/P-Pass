// #1122：桌面在接受连接时就以 401 关掉未配对的手机、删配对时以 410 关掉已有连接。
// 这里验：控制面调用因「记录里的那台电脑」以 401 / 410 关闭而失败 → 与 `not_paired` 应答同一条被拒即清理路径
// （配对记录被删、只清一次、不发 device.unpair）；其它一切（别的关闭码、别的关闭方、超时、网络断、本地取消）不清。
// 用真实的 PairingStore / CurrentPeerTransport / ControlPlaneDesktop / ControlPlaneProbe / RejectedPairingCleanup；底座（FFI）用脚本化假实现。
import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

private final class Count: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

private final class ScriptedPlane: PeerCallPlane, @unchecked Sendable {
    enum Script { case fail(Error), hang }
    let script: Script
    private let lock = NSLock()
    private var seen: [String] = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    init(_ script: Script) { self.script = script }

    func call(peerToken: String, method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        lock.lock(); seen.append(method); lock.unlock()
        switch script {
        case let .fail(error): throw error
        case .hang:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
    }

    func stream(peerToken: String, method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
        throw CancellationError()
    }
}

final class PeerClosedPairingLossTests: XCTestCase {
    private let daemon = String(repeating: "ab", count: 32)
    private let stranger = String(repeating: "cd", count: 32)
    private var base: URL!
    private var root: URL { base.appendingPathComponent("root") }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("peer-closed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private final class Rig: @unchecked Sendable {
        let store: PairingStore
        let plane: ScriptedPlane
        let loss = PairingLoss()
        let announced = Count()
        let cleared = Count()
        var cleanup: RejectedPairingCleanup!
        let probe: ControlPlaneProbe

        init(root: URL, daemon: String, script: ScriptedPlane.Script, timeoutMs: Int64 = 2_000) throws {
            let store = PairingStore(root: root)
            self.store = store
            try store.save(PairingRecord(daemonNodeId: daemon, peerToken: "t", storageDeviceName: "Mac", pairedAt: 1, pairingId: "e1"))
            plane = ScriptedPlane(script)
            let pairingId: @Sendable () -> String? = { store.load()?.pairingId }
            let desktop = ControlPlaneDesktop(client: ProtoClient(transport: CurrentPeerTransport(plane: plane, store: store)), localPairingId: pairingId)
            probe = ControlPlaneProbe(currentPairingId: pairingId, desktop: desktop, logger: NoopLogger(), pairingLoss: loss, timeoutMs: timeoutMs)
            let announced = self.announced, cleared = self.cleared
            cleanup = RejectedPairingCleanup(
                localPairingId: pairingId,
                announce: { _ in announced.bump() },
                clear: {
                    cleared.bump()
                    let actions = DisconnectActions(stopFlow: {}, cancelWakes: {}, stopMedia: {}, clearThumbs: {})
                    try? applyDisconnectManifest(root: root, runtime: actions, external: DisconnectExternalRoots(caches: root.appendingPathComponent("c"), tmp: root.appendingPathComponent("t")))
                },
                logger: NoopLogger())
            let cleanup = self.cleanup!
            loss.setOnLost { id in Task { await cleanup.handle(rejectedPairingId: id) } }
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out: \(what)")
    }

    private func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }

    /// 记录的那台电脑以 401 / 410 关闭 → 配对记录被删、提示一次、清一次，迟到的再来一次是空操作；全程只调了 hello（没有 device.unpair）。
    /// 反证：去掉 `translateDesktopClose`（或 CurrentPeerTransport 不调它），probe 结果变 unreachable、记录还在，红；
    /// 去掉 RejectedPairingCleanup 的 claim，二次 markLost 会再清一次，红。
    func testRecordedDesktopClosingWith401Or410CleansUpOnce() async throws {
        for code in [UInt64(401), 410] {
            try? FileManager.default.removeItem(at: base)
            try setUpWithError()
            let rig = try Rig(root: root, daemon: daemon, script: .fail(FfiError.PeerClosed(nodeId: daemon, code: code)))
            let result = await rig.probe.probe()
            XCTAssertEqual(result, .pairingLost, "\(code)")
            await waitUntil("\(code): 清理完成") { rig.store.load() == nil }
            XCTAssertNil(rig.store.load(), "\(code): 配对记录被删")
            XCTAssertEqual(rig.announced.value, 1, "\(code)")
            XCTAssertEqual(rig.cleared.value, 1, "\(code)")
            XCTAssertEqual(rig.plane.methods, [Methods.hello], "\(code): 不发 device.unpair")

            rig.loss.markLost(pairingId: "e1")
            await settle()
            XCTAssertEqual(rig.cleared.value, 1, "\(code): 只清一次")
            XCTAssertEqual(rig.announced.value, 1, "\(code)")
        }
    }

    /// 其它一律按「连不上」：关闭方不是记录的电脑、未知关闭码（含 blobs 的 403）、超时、网络断、本地取消、hello 永不返回。
    /// 反证：把关闭方核对去掉（任何节点的 401 都清），第一行红；把 meansNotPaired 放宽（如 >= 400），403 / 500 两行红；
    /// 把超时 / 网络错误也当未配对，对应行红。
    func testEverythingElseIsUnreachableAndCleansNothing() async throws {
        let cases: [(String, ScriptedPlane.Script, Int64)] = [
            ("别的电脑 401", .fail(FfiError.PeerClosed(nodeId: stranger, code: 401)), 2_000),
            ("别的电脑 410", .fail(FfiError.PeerClosed(nodeId: stranger, code: 410)), 2_000),
            ("blobs 403", .fail(FfiError.PeerClosed(nodeId: daemon, code: 403)), 2_000),
            ("未知码 500", .fail(FfiError.PeerClosed(nodeId: daemon, code: 500)), 2_000),
            ("码 0", .fail(FfiError.PeerClosed(nodeId: daemon, code: 0)), 2_000),
            ("超时", .fail(FfiError.Timeout(msg: "deadline")), 2_000),
            ("网络断", .fail(FfiError.Transport(msg: "connection lost")), 2_000),
            ("本地取消", .fail(CancellationError()), 2_000),
            ("hello 永不返回", .hang, 50),
        ]
        for (name, script, timeoutMs) in cases {
            try? FileManager.default.removeItem(at: base)
            try setUpWithError()
            let rig = try Rig(root: root, daemon: daemon, script: script, timeoutMs: timeoutMs)
            let result = await rig.probe.probe()
            XCTAssertEqual(result, .unreachable, name)
            await settle()
            XCTAssertNotNil(rig.store.load(), "\(name): 配对记录还在")
            XCTAssertEqual(rig.announced.value, 0, name)
            XCTAssertEqual(rig.cleared.value, 0, name)
        }
    }

    /// 翻译函数本身：只翻「记录的电脑 + 未配对码」；其余（含非 PeerClosed 的任何错误）原样返回。
    func testTranslateOnlyMapsTheRecordedDesktopWithNotPairedCodes() {
        let translated = translateDesktopClose(FfiError.PeerClosed(nodeId: daemon, code: 401), recordedDaemonNodeId: daemon, method: "hello")
        XCTAssertEqual((translated as? DesktopRejected)?.reason, .registered(.notPaired))
        XCTAssertTrue(translateDesktopClose(FfiError.PeerClosed(nodeId: stranger, code: 401), recordedDaemonNodeId: daemon, method: "hello") is FfiError)
        XCTAssertTrue(translateDesktopClose(FfiError.PeerClosed(nodeId: daemon, code: 403), recordedDaemonNodeId: daemon, method: "hello") is FfiError)
        XCTAssertTrue(translateDesktopClose(CancellationError(), recordedDaemonNodeId: daemon, method: "hello") is CancellationError)
    }

    /// 契约：FFI 导出的判据 `closeCodeMeansNotPaired(code:)` 与 Rust 注册表快照、与 PPassCore 的常量一致（快照里的码为真，其余为假）。
    func testFfiPredicateAndCoreConstantsAgreeWithTheRustSnapshot() throws {
        let rust = try ProtoJSON.decode([CloseCodeRow].self, from: snapshotBody("snapshots__close_codes_registry"))
        XCTAssertEqual(DesktopCloseCodes.registry.map { CloseCodeRow(code: $0.code, reason: $0.reason) }, rust)
        let codes = Set(rust.map(\.code))
        for code in codes {
            XCTAssertTrue(closeCodeMeansNotPaired(code: code), "FFI: \(code)")
            XCTAssertTrue(DesktopCloseCodes.meansNotPaired(code), "Core: \(code)")
        }
        for code in [UInt64(0), 400, 402, 403, 409, 411, 500] where !codes.contains(code) {
            XCTAssertFalse(closeCodeMeansNotPaired(code: code), "FFI: \(code)")
            XCTAssertFalse(DesktopCloseCodes.meansNotPaired(code), "Core: \(code)")
        }
    }

    private struct CloseCodeRow: Codable, Equatable {
        var code: UInt64
        var reason: String
    }

    /// insta 的 `.snap`：`---` 包起来的 YAML 头，之后是 pretty JSON（与 PPassCore 测试里的 `RepoFixtures.goldenBody` 同一解析）。
    private func snapshotBody(_ name: String, file: String = #filePath) throws -> Data {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/", !FileManager.default.fileExists(atPath: dir.appendingPathComponent("crates/proto/tests/snapshots").path) {
            dir = dir.deletingLastPathComponent()
        }
        let text = try String(contentsOf: dir.appendingPathComponent("crates/proto/tests/snapshots/\(name).snap"), encoding: .utf8)
        let parts = text.components(separatedBy: "---")
        return Data(parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}

// #1119：被拒即清理的触发判据。只有经过认证的控制面应答里「明确的未配对」才触发：
// `not_paired` / `pairing_mismatch`，或 hello 成功但 pairing_id 缺失 / 为空 / 与本地不一致。
// 超时、连不上、版本不匹配、role_forbidden 等一律不触发。
import Foundation
import XCTest
@testable import PPassCore

final class PairingRejectionTests: XCTestCase {
    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
    }

    private func loss(_ fired: Fired) -> PairingLoss {
        let loss = PairingLoss()
        loss.setOnLost { fired.add($0) }
        return loss
    }

    // MARK: hello 成功但电脑不认这台手机

    /// 反证：把 `isBlank` 判断去掉，"  " 会被当成有代号，红；把「不一致」判成认得，pairing_mismatch 那行红。
    func testHelloWithoutAMatchingPairingIdIsTheSameFactAsARejection() {
        for advertised in [nil, "", "  "] as [String?] {
            XCTAssertEqual(helloUnpairedRejection(advertised: advertised, local: "e1")?.reason, .registered(.notPaired), "\(String(describing: advertised))")
        }
        XCTAssertEqual(helloUnpairedRejection(advertised: "e2", local: "e1")?.reason, .registered(.pairingMismatch))
        XCTAssertNil(helloUnpairedRejection(advertised: "e1", local: "e1"))
        for advertised in [nil, "", "e2"] as [String?] {
            XCTAssertTrue(helloUnpairedRejection(advertised: advertised, local: "e1")!.isPairingLost)
        }
    }

    private struct HelloTransport: CtrlTransport {
        let result: String
        func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
            Data(#"{"id":"1","ok":true,"result":\#(result),"ver":\#(ProtoVersion.current),"min_ver":\#(ProtoVersion.minSupported)}"#.utf8)
        }
    }

    private func desktop(_ result: String, local: String?) -> ControlPlaneDesktop {
        ControlPlaneDesktop(client: ProtoClient(transport: HelloTransport(result: result)), localPairingId: { local })
    }

    /// 真实的控制面实现：hello 成功但没有 pairing_id → 抛 not_paired；不一致 → pairing_mismatch；一致 → 正常返回；本地没有代号 → 不核对。
    /// 反证：去掉 `ControlPlaneDesktop.hello` 里的核对，前三条都不抛，红。
    func testControlPlaneHelloIsCheckedAgainstTheLocalPairingId() async throws {
        for (body, reason) in [(#"{"capabilities":[]}"#, ProtoReason.notPaired), (#"{"capabilities":[],"pairing_id":null}"#, .notPaired),
                               (#"{"capabilities":[],"pairing_id":""}"#, .notPaired), (#"{"capabilities":[],"pairing_id":"e2"}"#, .pairingMismatch)] {
            do {
                _ = try await desktop(body, local: "e1").hello()
                XCTFail("\(body) 必须被拒")
            } catch let rejected as DesktopRejected {
                XCTAssertEqual(rejected.reason, .registered(reason), body)
                XCTAssertEqual(rejected.method, "hello")
            }
        }
        let ok = try await desktop(#"{"capabilities":[],"pairing_id":"e1"}"#, local: "e1").hello()
        XCTAssertEqual(ok.pairingId, "e1")
        let unchecked = try await desktop(#"{"capabilities":[]}"#, local: nil).hello()
        XCTAssertNil(unchecked.pairingId, "本地没有代号：没有可比的对象，不核对")
    }

    // MARK: PairingLoss 的触发面

    /// 只有 not_paired / pairing_mismatch 触发；其余登记过的和没登记的 reason 都不触发。
    /// 反证：把 role_forbidden 放回 `.pairingLost`（或把别的 reason 也归进去），对应一行触发，红。
    func testOnlyAnExplicitUnpairedRejectionFires() {
        let fired = Fired()
        let loss = loss(fired)
        for wire in ["role_forbidden", "phone_outdated", "desktop_outdated", "unsupported_method", "bad_request", "not_found", "internal",
                     "backup_failed", "storage_full", "library_unavailable", "storage_failed", "fetch_failed", "pair_token_invalid",
                     "grant_not_found", "grant_conflict", "cancelled", "from_the_future", ""] {
            loss.record(pairingId: "e1", failure: DesktopRejected(reason: DesktopReason(wire: wire), method: "flow.offer"))
        }
        XCTAssertEqual(fired.all, [], "这些都不是「未配对」")
        XCTAssertFalse(loss.isLost(pairingId: "e1"))
        for wire in ["not_paired", "pairing_mismatch"] {
            loss.record(pairingId: "e1", failure: DesktopRejected(reason: DesktopReason(wire: wire), method: "flow.offer"))
        }
        XCTAssertEqual(fired.all, ["e1", "e1"])
    }

    /// 超时 / 连不上不是拒绝：不触发。
    func testNetworkFailuresAndTimeoutsDoNotFire() async {
        let fired = Fired()
        let loss = loss(fired)
        loss.record(pairingId: "e1", failure: URLError(.cannotConnectToHost))
        loss.record(pairingId: "e1", failure: InconsistentReply(detail: "x"))
        let desktop = FakeDesktop()
        desktop.helloResult.set(.failure(URLError(.timedOut)))
        let probe = ControlPlaneProbe(currentPairingId: { "e1" }, desktop: desktop, logger: NoopLogger(), pairingLoss: loss)
        let unreachable = await probe.probe()
        XCTAssertEqual(unreachable, .unreachable)
        desktop.helloResult.set(.success(Hello(pairingId: "e1")))
        desktop.helloHang.set(true)
        let timedOut = await ControlPlaneProbe(currentPairingId: { "e1" }, desktop: desktop, logger: NoopLogger(), pairingLoss: loss, timeoutMs: 30).probe()
        XCTAssertEqual(timedOut, .unreachable)
        desktop.releaseHello()
        XCTAssertEqual(fired.all, [])
    }

    /// 探测路径：hello 被拒 not_paired / pairing_mismatch → 触发一次并判配对失效；role_forbidden / 版本不匹配 → 不触发。
    /// 反证：探测里不再 `pairingLoss.record`，前两行红；role_forbidden 归回 pairingLost，第三行红。
    func testTheProbePathFiresOnlyForUnpairedRejections() async {
        for (wire, expectFire) in [("not_paired", true), ("pairing_mismatch", true), ("role_forbidden", false), ("phone_outdated", false), ("desktop_outdated", false)] {
            let fired = Fired()
            let desktop = FakeDesktop()
            desktop.helloResult.set(.failure(DesktopRejected(reason: DesktopReason(wire: wire), method: "hello")))
            let result = await ControlPlaneProbe(currentPairingId: { "e1" }, desktop: desktop, logger: NoopLogger(), pairingLoss: loss(fired)).probe()
            XCTAssertEqual(fired.all, expectFire ? ["e1"] : [], wire)
            if expectFire { XCTAssertEqual(result, .pairingLost) } else { XCTAssertNotEqual(result, .pairingLost, wire) }
        }
    }

    /// 前台心跳路径：同上；hello 成功但没有 pairing_id（走真实的 ControlPlaneDesktop 核对）也触发。
    /// 反证：去掉心跳的 `isPairingLost` 分支或 hello 核对，对应行红。
    func testTheHeartbeatPathFiresForRejectionsAndForAHelloWithoutPairingId() async {
        let cases: [(Result<Hello, Error>, Bool)] = [
            (.failure(DesktopRejected(reason: DesktopReason(wire: "not_paired"), method: "hello")), true),
            (.failure(DesktopRejected(reason: DesktopReason(wire: "pairing_mismatch"), method: "hello")), true),
            (.failure(DesktopRejected(reason: DesktopReason(wire: "role_forbidden"), method: "hello")), false),
            (.failure(URLError(.cannotConnectToHost)), false),
            (.success(Hello(pairingId: "e1")), false),
        ]
        for (result, expectFire) in cases {
            let fired = Fired()
            let desktop = FakeDesktop()
            desktop.helloResult.set(result)
            let tmp = TempDir()
            let loss = loss(fired)
            let hb = ForegroundHeartbeat(desktop: desktop, currentPairingId: { "e1" }, ledger: SentinelStore(directory: tmp.url), now: { 1 },
                                         onReachable: {}, onPairingLost: { id, failure in loss.record(pairingId: id, failure: failure) }, logger: NoopLogger())
            hb.start()
            await eventually("心跳拍完") { desktop.helloCalls.get() >= 1 }
            try? await Task.sleep(nanoseconds: 60_000_000)
            hb.stop()
            XCTAssertEqual(fired.all, expectFire ? ["e1"] : [], "\(result)")
        }

        let fired = Fired()
        let loss = loss(fired)
        let tmp = TempDir()
        let hb = ForegroundHeartbeat(desktop: desktop(#"{"capabilities":[]}"#, local: "e1"), currentPairingId: { "e1" }, ledger: SentinelStore(directory: tmp.url), now: { 1 },
                                     onReachable: {}, onPairingLost: { id, failure in loss.record(pairingId: id, failure: failure) }, logger: NoopLogger())
        hb.start()
        await eventually("hello 没有 pairing_id 触发") { fired.all == ["e1"] }
        hb.stop()
    }
}

import PPassCore
import XCTest
@testable import PPass

/// #1073 配对通道：被拒的说明按 `reason` 本端挑（线上不再带文案 key），版本不兼容不算「电脑主人拒绝」。
final class PairReasonTests: XCTestCase {
    private func loop(_ replies: [String: Resp]) -> PairVerdictLoop {
        var l = PairVerdictLoop(rpc: { method, _ in
            guard let r = replies[method] else { throw URLError(.cannotConnectToHost) }
            return r
        })
        l.pollIntervalNs = 1_000_000
        return l
    }

    private func hello() throws -> Resp {
        Resp(ok: true, result: try JSONValue.from(Hello(capabilities: [PairVerdictLoop.statusCapability])))
    }

    private func rejected(_ code: String, _ reason: String) -> Resp { Resp(ok: false, error: RespError(code: code, reason: reason)) }

    /// 令牌无效：与 v1 同一句「没有访问权限」，算电脑那边说不。
    func test_bad_token_is_a_refusal_with_the_same_note_as_v1() async throws {
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected(Codes.notAuthorized, "pair_token_invalid")]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .denied(.notAuthorized))
        XCTAssertEqual(v.outcome, .refused(note: .notAuthorized, ownerSaidNo: true))
    }

    /// 版本不兼容：不是电脑主人拒绝的（ownerSaidNo=false），说明是「可能有一端需要更新版本」。
    func test_version_mismatch_is_not_the_owner_saying_no() async throws {
        for (reason, side) in [("phone_outdated", OutdatedSide.phone), ("desktop_outdated", .desktop)] {
            let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected("VERSION_MISMATCH", reason)]).run(token: "t", deviceName: "d")
            XCTAssertEqual(v, .versionMismatch(side), reason)
            XCTAssertEqual(v.outcome, .refused(note: .versionMismatch, ownerSaidNo: false), reason)
        }
    }

    /// 不认识的 reason：只显示通用文案（note=nil），绝不显示原始代码。
    func test_unknown_reason_shows_only_the_generic_text() async throws {
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected("SOMETHING_NEW", "from_the_future")]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v.outcome, .refused(note: nil, ownerSaidNo: true))
    }

    /// v2 的 pair.status denied 不带说明：本端给 v1 时代同一句。
    func test_denied_status_uses_the_local_note() async throws {
        let submitted = Resp(ok: true, result: try JSONValue.from(PairSubmitted(accepted: true, requestId: "r1", ttlMs: 60_000)))
        let denied = Resp(ok: true, result: try JSONValue.from(PairStatusReply(state: "denied")))
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: submitted, Methods.pairStatus: denied]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v.outcome, .refused(note: .notAuthorized, ownerSaidNo: true))
    }

    /// 每条说明都能在本机字典里解析出人话（缺了就会退回只显示通用文案）。
    func test_every_note_resolves_to_text() {
        for note in [PairNote.notAuthorized, .notPaired, .versionMismatch, .expired, .desktopRestarted] {
            for lang in ["en", "zh-Hans"] {
                XCTAssertNotNil(DiagText.resolve(note.diagKey, language: lang), "\(note) / \(lang)")
            }
        }
    }

    /// 穷举：登记表里每个 reason 在配对通道都有显式说明或显式「通用文案」（switch 无 default，编译期兜住新值）。
    func test_pair_note_for_every_registered_reason() {
        let expected: [ProtoReason: PairNote?] = [
            .pairTokenInvalid: .notAuthorized, .revoked: .notAuthorized, .roleForbidden: .notAuthorized, .notPaired: .notPaired,
            .phoneOutdated: .versionMismatch, .desktopOutdated: .versionMismatch, .unsupportedMethod: .versionMismatch, .badRequest: .versionMismatch,
        ]
        for r in ProtoReason.allCases where r != .unknown {
            XCTAssertEqual(PairNote(rejection: .registered(r)), expected[r] ?? nil, r.rawValue)
        }
    }
}

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

    /// 令牌无效：本端文案「配对码无效或已被使用」，算电脑那边说不（#1072 §5）。
    func test_bad_token_is_a_refusal_with_its_own_note() async throws {
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected(Codes.notAuthorized, "pair_token_invalid")]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .denied(.tokenInvalid))
        XCTAssertEqual(v.outcome, .refused(note: .tokenInvalid, ownerSaidNo: true))
    }

    /// 版本在握手（hello）时判定：不兼容就不发 pair.request，直接「需要更新」（#1069）。
    func test_version_mismatch_at_hello_never_sends_the_pair_request() async throws {
        for (reason, side) in [("phone_outdated", OutdatedSide.phone), ("desktop_outdated", .desktop)] {
            var calls: [String] = []
            var l = PairVerdictLoop(rpc: { method, _ in
                calls.append(method)
                return Resp(ok: false, error: RespError(code: Codes.versionMismatch, reason: reason))
            })
            l.pollIntervalNs = 1_000_000
            let v = try await l.run(token: "t", deviceName: "d")
            XCTAssertEqual(v, .versionMismatch(side), reason)
            XCTAssertEqual(v.outcome, .needsUpdate(side), reason)
            XCTAssertEqual(calls, [Methods.hello], "不发起配对请求")
        }
    }

    /// pair.request 上才收到版本拒绝（兜底）：同样是「需要更新」。电脑不认识方法 = 电脑太旧。
    func test_version_rejection_on_the_request_is_needs_update() async throws {
        for (reason, side) in [("phone_outdated", OutdatedSide.phone), ("unsupported_method", .desktop)] {
            let code = reason == "unsupported_method" ? Codes.invalidRequest : Codes.versionMismatch
            let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected(code, reason)]).run(token: "t", deviceName: "d")
            XCTAssertEqual(v.outcome, .needsUpdate(side), reason)
        }
    }

    /// 不认识的 reason：通用提示，绝不显示原始代码。
    func test_unknown_reason_shows_the_generic_note() async throws {
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: rejected("SOMETHING_NEW", "from_the_future")]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v.outcome, .refused(note: .generic, ownerSaidNo: true))
    }

    /// v2 的 pair.status denied 不带说明：本端「电脑上拒绝了这次加入」。
    func test_denied_status_uses_the_local_note() async throws {
        let submitted = Resp(ok: true, result: try JSONValue.from(PairSubmitted(accepted: true, requestId: "r1", ttlMs: 60_000)))
        let denied = Resp(ok: true, result: try JSONValue.from(PairStatusReply(state: "denied")))
        let v = try await loop([Methods.hello: try hello(), Methods.pairRequest: submitted, Methods.pairStatus: denied]).run(token: "t", deviceName: "d")
        XCTAssertEqual(v.outcome, .refused(note: .denied, ownerSaidNo: true))
    }

    /// 每条说明的 key 都在打包的文案表里（en / zh-Hans）。
    func test_every_note_key_is_bundled() {
        for note in PairNote.allCases {
            for lang in ["en", "zh-Hans"] {
                let path = Bundle.main.path(forResource: lang, ofType: "lproj").flatMap(Bundle.init(path:))
                let text = path?.localizedString(forKey: note.key, value: "\u{1}", table: nil)
                XCTAssertNotEqual(text, "\u{1}", "\(note.key) / \(lang)")
            }
        }
    }
}

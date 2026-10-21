import Foundation
import XCTest
@testable import PPassCore

/// #1073：协议 v2 `reason` 的控制流归类。与 Android #1072 是同一张表（两端逐条一致，改一端必须改另一端）。
final class ReasonClassificationTests: XCTestCase {
    /// reason → 应答通道 / 推送通道的归类（#1069 拍板 https://github.com/hawkeye-xb/P-Pass/issues/1069#issuecomment-6306902273）。
    /// 行序与 `reasons_registry` 金样一致。两列只在待拍板的 `grant_*` 上不同（维持今天）。
    /// 应答通道 = offer / status / hello 探测 / 前台心跳 / 配对失效红卡；推送通道 = `flow.failed`。
    static let table: [(reason: String, reply: String, push: String)] = [
        ("not_paired", "pairing_lost", "pairing_lost"),
        ("revoked", "pairing_lost", "pairing_lost"),
        ("role_forbidden", "pairing_lost", "pairing_lost"),
        ("pair_token_invalid", "request_rejected", "request_rejected"),
        ("phone_outdated", "version_mismatch:phone", "version_mismatch:phone"),
        ("desktop_outdated", "version_mismatch:desktop", "version_mismatch:desktop"),
        ("unsupported_method", "version_mismatch:desktop", "version_mismatch:desktop"),
        ("bad_request", "request_rejected", "request_rejected"),
        ("not_found", "request_rejected", "request_rejected"),
        ("internal", "peer_failure:DESKTOP_INTERNAL", "peer_failure:DESKTOP_INTERNAL"),
        ("backup_failed", "request_rejected", "request_rejected"),
        ("storage_full", "peer_failure:STORAGE_FULL", "peer_failure:STORAGE_FULL"),
        ("library_unavailable", "peer_failure:LIBRARY_UNAVAILABLE", "peer_failure:LIBRARY_UNAVAILABLE"),
        ("storage_failed", "peer_failure:STORAGE_ERROR", "peer_failure:STORAGE_ERROR"),
        ("fetch_failed", "path_failure", "path_failure"),
        ("epoch_mismatch", "pairing_lost", "pairing_lost"),
        ("grant_not_found", "pairing_lost", "item_failure"), // 待 #1072 拍板，维持今天
        ("grant_conflict", "pairing_lost", "item_failure"), // 待 #1072 拍板，维持今天
        ("cancelled", "request_rejected", "request_rejected"),
    ]

    static func label(_ c: ReasonClass) -> String {
        switch c {
        case .pairingLost: return "pairing_lost"
        case let .versionMismatch(side): return "version_mismatch:\(side.rawValue)"
        case let .peerFailure(kind): return "peer_failure:\(kind.rawValue)"
        case .pathFailure: return "path_failure"
        case .requestRejected: return "request_rejected"
        case .itemFailure: return "item_failure"
        }
    }

    /// 穷举：金样里的每个 reason 在表里有且只有一行，且实现给出的归类与表一致；表里不许有金样外的行。
    func testEveryRegisteredReasonHasAnExplicitClassOnBothChannels() throws {
        let rust = try ProtoJSON.decode([RespError].self, from: RepoFixtures.goldenBody("snapshots__reasons_registry"))
        XCTAssertEqual(Self.table.map(\.reason), rust.map(\.reason), "表的行必须与 reasons_registry 金样逐行对应")
        for row in Self.table {
            let reason = DesktopReason(wire: row.reason)
            XCTAssertEqual(Self.label(reasonClass(reason, channel: .reply)), row.reply, "应答通道 \(row.reason)")
            XCTAssertEqual(Self.label(reasonClass(reason, channel: .push)), row.push, "推送通道 \(row.reason)")
        }
    }

    /// 不认识的 reason（更新的桌面）与缺 reason：不算照片失败，退出本轮、退避；原值只进日志。
    func testUnknownReasonsFallBackOnBothChannels() {
        for raw in ["from_the_future", ""] {
            let reason = DesktopReason(wire: raw)
            XCTAssertEqual(reason, .unknown(raw))
            XCTAssertEqual(reasonClass(reason, channel: .reply), .requestRejected)
            XCTAssertEqual(reasonClass(reason, channel: .push), .requestRejected)
        }
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .unknown("from_the_future"), method: "flow.offer")),
                       .desktopRejected("unknown:from_the_future"))
        XCTAssertEqual(classifyPushedFailure(.unknown("from_the_future")), .desktopRejected("unknown:from_the_future"))
    }

    // MARK: 行为基线（v1 桌面发什么、今天的 iOS 怎么判）

    /// 冻结的 v1 判据（`f1b70a58` 的 `isPairingLostText` + `classifyDesktopCode`），只当基线用。
    private static func v1Reply(_ msgKey: String) -> String {
        if msgKey.contains("err.not_paired") || msgKey.contains("err.not_authorized") { return "pairing_lost" }
        return v1Code(msgKey)
    }

    private static func v1Code(_ code: String) -> String {
        switch code {
        case "storage_full": return "peer_failure:STORAGE_FULL"
        case "library_unavailable": return "peer_failure:LIBRARY_UNAVAILABLE"
        case "storage_failed": return "peer_failure:STORAGE_ERROR"
        case "fetch_failed": return "path_failure"
        default: return "item_failure"
        }
    }

    /// v1 桌面在同一情形下的应答 msg_key（`f1b70a58` 的 authz.rs / router.rs）。版本两项是 v2 新增，不在基线里。
    static let v1ReplyKey: [String: String] = [
        "not_paired": "err.not_paired",
        "revoked": "err.not_authorized",
        "role_forbidden": "err.not_authorized",
        "pair_token_invalid": "err.not_authorized",
        "unsupported_method": "err.unsupported",
        "bad_request": "err.unsupported",
        "not_found": "err.not_found",
        "internal": "err.unsupported",
        "backup_failed": "err.backup_failed",
        "storage_full": "storage_full",
        "library_unavailable": "library_unavailable",
        "storage_failed": "storage_failed",
        "fetch_failed": "fetch_failed",
        "epoch_mismatch": "err.not_authorized",
        "grant_not_found": "err.not_authorized",
        "grant_conflict": "err.not_authorized",
        "cancelled": "err.not_authorized",
    ]

    /// v1 桌面 `flow.failed` 推送的 code（`DeliveryError::wire_code`）。
    static let v1PushCode: [String: String] = [
        "storage_full": "storage_full",
        "library_unavailable": "library_unavailable",
        "storage_failed": "storage_failed",
        "fetch_failed": "fetch_failed",
        "epoch_mismatch": "guard_mismatch",
        "grant_not_found": "guard_mismatch",
        "grant_conflict": "guard_mismatch",
        "cancelled": "cancelled",
        "bad_request": "invalid_request",
        "internal": "internal",
    ]

    /// 相对 v1 有意改变的格子（#1069 拍板）。其余格子 v2 与 v1 结论必须相同。
    static let approvedReplyChanges: Set = [
        "pair_token_invalid", // 配对失效 → 发错请求（只出现在配对通道，那里另有文案）
        "unsupported_method", // 单张失败 → 需要更新（电脑太旧）
        "bad_request", "not_found", "backup_failed", // 单张失败 → 发错请求：不算照片失败，退避
        "internal", // 单张失败 → 对端失败（电脑上的 P-Pass 出错了）
        "cancelled", // 配对失效 → 发错请求
    ]
    static let approvedPushChanges: Set = [
        "epoch_mismatch", "cancelled", "bad_request", "internal", // 推送也走同一张表
    ]

    /// 应答通道：v2 与 v1 不同的格子必须恰好是拍板过的那些（多一个、少一个都红）。
    func testReplyChangesAgainstV1AreExactlyTheApprovedOnes() {
        var changed = Set<String>()
        for (reason, key) in Self.v1ReplyKey where Self.label(reasonClass(DesktopReason(wire: reason), channel: .reply)) != Self.v1Reply(key) {
            changed.insert(reason)
        }
        XCTAssertEqual(changed, Self.approvedReplyChanges)
    }

    /// 推送通道：同上。
    func testPushChangesAgainstV1AreExactlyTheApprovedOnes() {
        var changed = Set<String>()
        for (reason, code) in Self.v1PushCode where Self.label(reasonClass(DesktopReason(wire: reason), channel: .push)) != Self.v1Code(code) {
            changed.insert(reason)
        }
        XCTAssertEqual(changed, Self.approvedPushChanges)
    }

    /// 端到端：应答拒绝 → 传输结局；配对失效红卡只认应答通道的配对失效。
    func testRejectionsDriveTheDeliveryOutcomeAndThePairingLossFact() {
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.epochMismatch), method: "flow.offer")), .pairingLost)
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.libraryUnavailable), method: "flow.offer")),
                       .peerFailure(.libraryUnavailable, code: "library_unavailable"))
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.fetchFailed), method: "flow.offer")), .pathFailure("fetch_failed"))
        XCTAssertEqual(classifyPushedFailure(.registered(.epochMismatch)), .pairingLost)
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.internal), method: "flow.offer")),
                       .peerFailure(.desktopInternal, code: "internal"))
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.badRequest), method: "flow.offer")), .desktopRejected("bad_request"))
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.phoneOutdated), method: "flow.offer")), .versionMismatch(.phone))
        XCTAssertEqual(classifyDeliveryFailure(DesktopRejected(reason: .registered(.unsupportedMethod), method: "flow.offer")), .versionMismatch(.desktop))

        let loss = PairingLoss()
        loss.record(epoch: "e1", failure: DesktopRejected(reason: .registered(.notFound), method: "flow.status"))
        XCTAssertFalse(loss.isLost(epoch: "e1"))
        loss.record(epoch: "e1", failure: DesktopRejected(reason: .registered(.revoked), method: "hello"))
        XCTAssertTrue(loss.isLost(epoch: "e1"))
    }

    /// `flow.failed` 推送载荷读 `reason`（#1070 改名）；缺键 → 不认识。
    func testPushedFailureReadsTheReasonField() {
        let tuple = FlowTupleRef(queueSequence: 3, pairingEpoch: "e", leaseToken: "l")
        let base: [String: JSONValue] = ["queue_sequence": .int(3), "pairing_epoch": .string("e"), "lease_token": .string("l")]
        var withReason = base
        withReason["reason"] = .string("library_unavailable")
        XCTAssertEqual(parseFlowPushOutcome(kind: "flow.failed", data: .object(withReason), tuple: tuple), .failed(.registered(.libraryUnavailable)))
        var legacy = base
        legacy["code"] = .string("library_unavailable")
        XCTAssertEqual(parseFlowPushOutcome(kind: "flow.failed", data: .object(legacy), tuple: tuple), .failed(.unknown("")))
    }
}

// #890 契约测试：解码 Rust 侧 `cargo test -p proto` 断言的同一批 insta 样本（crates/proto/tests/snapshots），
// 重新编码后要求与样本 **JSON 值全等**。任何一边改了形状，两边之一当场变红。
//
// 比 Android 的 GoldenDriftTest（golden ⊆ 编码，null 等于缺键）更严：Rust 写 `null` 的字段这里也必须写 `null`，
// Rust 省略的这里也必须省略，多一个键也算漂移。
import Foundation
import XCTest
@testable import PPassCore

final class GoldenContractTests: XCTestCase {

    /// 一个样本 → 「按哪个类型 decode → encode」。新增 Rust 样本不在这里登记，[testEverySnapshotIsCovered] 红。
    private static let registry: [String: (Data) throws -> (decoded: JSONValue, again: Bool)] = [
        "snapshots__hello": roundtrip(Hello.self),
        "snapshots__hello_json": roundtrip(Hello.self),
        "snapshots__hello_paired_with_health": roundtrip(Hello.self),
        "snapshots__hello_health_free_bytes_unknown": roundtrip(Hello.self),
        "snapshots__pair_request": roundtrip(PairRequest.self),
        "snapshots__pair_request_ack_then_poll": roundtrip(PairRequest.self),
        "snapshots__pair_accepted": roundtrip(PairAccepted.self),
        "snapshots__pair_submitted": roundtrip(PairSubmitted.self),
        "snapshots__pair_status_request": roundtrip(PairStatusRequest.self),
        "snapshots__pair_status_reply_accepted": roundtrip(PairStatusReply.self),
        "snapshots__pair_status_reply_denied": roundtrip(PairStatusReply.self),
        // #1118 配对验证码（proto v3）
        "snapshots__pair_request_pake": roundtrip(PairRequest.self),
        "snapshots__pair_status_reply_pake_b": roundtrip(PairStatusReply.self),
        "snapshots__pair_confirm_request": roundtrip(PairConfirmRequest.self),
        "snapshots__pair_status_reply_confirmed": roundtrip(PairStatusReply.self),
        "snapshots__pair_status_reply_failed": roundtrip(PairStatusReply.self),
        "snapshots__req_envelope": roundtrip(Req.self),
        "snapshots__req_envelope_json": roundtrip(Req.self),
        "snapshots__resp_ok_envelope": roundtrip(Resp.self),
        "snapshots__resp_ok_envelope_json": roundtrip(Resp.self),
        "snapshots__resp_err_envelope": roundtrip(Resp.self),
        "snapshots__resp_err_envelope_json": roundtrip(Resp.self),
        "snapshots__timeline_query": roundtrip(TimelineQuery.self),
        "snapshots__timeline_page": roundtrip(TimelinePage.self),
        "snapshots__thumb_get_256": roundtrip(ThumbGet.self),
        "snapshots__thumb_get_1024": roundtrip(ThumbGet.self),
        "snapshots__thumb_data_real": roundtrip(ThumbData.self),
        "snapshots__thumb_data_placeholder": roundtrip(ThumbData.self),
        "snapshots__blob_ticket_request": roundtrip(BlobTicketRequest.self),
        "snapshots__blob_ticket_response": roundtrip(BlobTicketResponse.self),
        "snapshots__backup_begin": roundtrip(BackupBegin.self),
        "snapshots__backup_manifest": roundtrip(BackupManifest.self),
        "snapshots__backup_manifest_with_items": roundtrip(BackupManifest.self),
        "snapshots__backup_missing": roundtrip(BackupMissing.self),
        "snapshots__backup_presence_query": roundtrip(BackupPresenceQuery.self),
        "snapshots__backup_commit": roundtrip(BackupCommit.self),
        "snapshots__backup_commit_with_generation": roundtrip(BackupCommit.self),
        "snapshots__diag_status": roundtrip(DiagStatus.self),
        "snapshots__flow_supersede_request": roundtrip(FlowSupersedeRequest.self),
        "snapshots__flow_supersede_reply_replaced": roundtrip(FlowSupersedeReply.self),
        "snapshots__flow_supersede_reply_refused": roundtrip(FlowSupersedeReply.self),
        "snapshots__flow_fetch_request": roundtrip(FlowFetchRequest.self),
        "snapshots__flow_tuple_ref": roundtrip(FlowTupleRef.self),
        "snapshots__flow_completion_receipt": roundtrip(FlowCompletionReceipt.self),
        "snapshots__flow_status_reply_completed": roundtrip(FlowStatusReply.self),
        "snapshots__flow_status_reply_active": roundtrip(FlowStatusReply.self),
        "snapshots__flow_audit_submit": roundtrip(FlowAuditSubmit.self),
        "snapshots__flow_audit_accepted": roundtrip(FlowAuditAccepted.self),
        // #1070 协议 v2
        "snapshots__resp_err_with_params": roundtrip(Resp.self),
        "snapshots__resp_err_v1_shim_flow": roundtrip(Resp.self),
        "snapshots__resp_err_v1_shim_pair": roundtrip(Resp.self),
        "snapshots__flow_failed_push": roundtrip(FlowFailedPush.self),
        "snapshots__reasons_registry": roundtrip([RespError].self),
        // #1122 / #1119：连接层关闭码注册表（取值核对见 DesktopCloseCodesContractTests）
        "snapshots__close_codes_registry": roundtrip([CloseCodeEntry].self),
    ]

    /// decode → encode，并确认再 decode 一次与第一次相等（往返稳定）。
    private static func roundtrip<T: Codable & Equatable>(_ type: T.Type) -> (Data) throws -> (decoded: JSONValue, again: Bool) {
        { body in
            let value = try ProtoJSON.decode(T.self, from: body)
            let encoded = try ProtoJSON.encode(value)
            let again = try ProtoJSON.decode(T.self, from: encoded)
            return (try JSONValue.parse(encoded), again == value)
        }
    }

    func testEveryGoldenRoundTripsToTheSameJSON() throws {
        for (name, check) in Self.registry.sorted(by: { $0.key < $1.key }) {
            let body = try RepoFixtures.goldenBody(name)
            let golden = try JSONValue.parse(body)
            let result = try check(body)
            XCTAssertEqual(result.decoded, golden, "\(name): Swift 重新编码与 Rust golden 不全等\n\(JSONDiff.describe(golden: golden, encoded: result.decoded))")
            XCTAssertTrue(result.again, "\(name): 往返不稳定")
        }
    }

    /// 每个 JSON 形状的样本都必须登记：新增 Rust 消息而 Swift 没镜像，这里红，而不是在线上。
    /// `_hex` 是长度前缀帧的字节，帧编解码来自 FFI（#313），不归这里。
    func testEverySnapshotIsCovered() throws {
        let onDisk = try RepoFixtures.snapshotNames().filter { !$0.hasSuffix("_hex") }
        XCTAssertEqual(Set(onDisk), Set(Self.registry.keys), "snapshot coverage drifted")
    }
}

/// 读仓库里的共享 fixture：从本文件位置往上找仓库根。`swift test`（host）与 iOS 模拟器都能直接读宿主路径。
enum RepoFixtures {
    static func repoRoot(file: String = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("crates/proto/tests/snapshots").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw NSError(domain: "RepoFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "crates/proto/tests/snapshots not found above \(file)"])
    }

    static func snapshotsDir() throws -> URL {
        try repoRoot().appendingPathComponent("crates/proto/tests/snapshots")
    }

    static func snapshotNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: snapshotsDir().path)
            .filter { $0.hasSuffix(".snap") }
            .map { String($0.dropLast(".snap".count)) }
    }

    /// insta 的 `.snap`：`---` 包起来的 YAML 头，之后是 pretty JSON。
    static func goldenBody(_ name: String) throws -> Data {
        let text = try String(contentsOf: snapshotsDir().appendingPathComponent("\(name).snap"), encoding: .utf8)
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else { throw NSError(domain: "RepoFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name): no insta front matter"]) }
        let body = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(body.utf8)
    }
}

/// 失败时说清楚哪里不等（缺键 / 多键 / 值不同），省得对着两坨 JSON 找。
enum JSONDiff {
    static func describe(golden: JSONValue, encoded: JSONValue, path: String = "$") -> String {
        var out: [String] = []
        walk(golden, encoded, path, &out)
        return out.joined(separator: "\n")
    }

    private static func walk(_ g: JSONValue, _ e: JSONValue, _ path: String, _ out: inout [String]) {
        switch (g, e) {
        case let (.object(go), .object(eo)):
            for key in Set(go.keys).union(eo.keys).sorted() {
                switch (go[key], eo[key]) {
                case let (gv?, ev?): walk(gv, ev, "\(path).\(key)", &out)
                case (_?, nil): out.append("\(path).\(key): golden 有、Swift 没写")
                case (nil, _?): out.append("\(path).\(key): Swift 多写了（golden 没有）")
                case (nil, nil): break
                }
            }
        case let (.array(ga), .array(ea)) where ga.count == ea.count:
            for (i, pair) in zip(ga, ea).enumerated() { walk(pair.0, pair.1, "\(path)[\(i)]", &out) }
        default:
            if g != e { out.append("\(path): golden=\(g) swift=\(e)") }
        }
    }
}

/// `close_codes_registry` 金样的一行（只用于测试：核对 `DesktopCloseCodes`）。
struct CloseCodeEntry: Codable, Equatable {
    var code: UInt64
    var reason: String
}

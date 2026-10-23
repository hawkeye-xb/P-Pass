// #890：golden 覆盖不到的线上语义——缺键默认值（serde `#[serde(default)]`）、严格解码、全等比较器本身。
import Foundation
import XCTest
@testable import PPassCore

final class WireSemanticsTests: XCTestCase {

    private func decodeEmpty<T: Decodable>(_ type: T.Type) throws -> T {
        try ProtoJSON.decode(T.self, from: Data("{}".utf8))
    }

    /// `{}` 解出 Rust 的 `Default`——不是 Swift 的零值。逐个写死 Rust 那边的非零默认。
    func testEmptyObjectDecodesToRustDefaults() throws {
        // #1070：缺 `ver` / `min_ver` = v1 发送方（新建时才取本端版本）。
        XCTAssertEqual(try decodeEmpty(Req.self), Req(id: "", method: "", params: .null, minVer: 1, ver: 1))
        XCTAssertEqual(try decodeEmpty(Resp.self), Resp(id: "", ok: false, result: nil, error: nil, ver: 1, minVer: 1))
        XCTAssertEqual(try decodeEmpty(Hello.self), Hello(protoVer: ProtoVersion.current, capabilities: [], deviceName: ""))
        XCTAssertEqual(try decodeEmpty(PairRequest.self).role, "member")
        XCTAssertFalse(try decodeEmpty(PairRequest.self).ackThenPoll)
        XCTAssertEqual(try decodeEmpty(TimelineQuery.self), TimelineQuery(cursor: nil, limit: 200))
        XCTAssertEqual(try decodeEmpty(ThumbGet.self).size, .s256)
        XCTAssertEqual(try decodeEmpty(FlowFetchRequest.self), FlowFetchRequest())
        XCTAssertEqual(try decodeEmpty(FlowFetchRequest.self).sizeBytes, 0)
        XCTAssertEqual(try decodeEmpty(FlowStatusReply.self), FlowStatusReply(state: "", receipt: nil, taskRunning: false))
        XCTAssertEqual(try decodeEmpty(FlowAuditEvent.self).payload, [:])
        XCTAssertEqual(try decodeEmpty(BackupCommit.self).generation, nil)
        XCTAssertEqual(try decodeEmpty(DiagStatus.self), DiagStatus(state: "", detail: nil))
    }

    /// 三端唯一一处登记过的默认值分歧：Rust 缺键给 false，Android 给 true，Swift 跟 Android（手机解释这个字段）。
    func testDesktopHealthMissingBooleansFollowAndroid() throws {
        let health = try decodeEmpty(DesktopHealthWire.self)
        XCTAssertNil(health.freeBytes)
        XCTAssertTrue(health.libraryWritable)
        XCTAssertTrue(health.indexOk)
    }

    /// 旧桌面的 hello 没有 health → nil（视为健康），有 health 时 `free_bytes: null` 原样保留为 nil。
    func testHelloWithoutHealthIsNil() throws {
        let hello = try ProtoJSON.decode(Hello.self, from: Data(#"{"proto_ver":1,"capabilities":[],"device_name":"PC"}"#.utf8))
        XCTAssertNil(hello.health)
        XCTAssertNil(hello.pairingId)
    }

    func testUnknownKeysAreIgnored() throws {
        let tuple = try ProtoJSON.decode(FlowTupleRef.self, from: Data(#"{"queue_sequence":7,"future_field":{"x":1}}"#.utf8))
        XCTAssertEqual(tuple.queueSequence, 7)
    }

    /// #1070：Rust 的 `RespError` 缺键取默认（code/reason 空串、无 params），这里同样宽容。
    func testRespErrorMissingKeysTakeDefaults() throws {
        let e = try ProtoJSON.decode(RespError.self, from: Data(#"{"code":"NOT_FOUND"}"#.utf8))
        XCTAssertEqual(e, RespError(code: "NOT_FOUND", msgKey: "", reason: "", params: nil))
        XCTAssertEqual(e.reasonKind, .unknown)
    }

    /// #1070 验收 4：未登记的 reason 解码不失败，原值保留，映射为 `.unknown`。
    func testUnknownReasonDecodesAndKeepsItsString() throws {
        let resp = try ProtoJSON.decode(
            Resp.self,
            from: Data(#"{"id":"1","ok":false,"error":{"code":"FUTURE","reason":"from_the_future","params":{"n":1}},"ver":3,"min_ver":2}"#.utf8)
        )
        let error = try XCTUnwrap(resp.error)
        XCTAssertEqual(error.reason, "from_the_future")
        XCTAssertEqual(error.reasonKind, .unknown)
        XCTAssertEqual(error.msgKey, "")
        XCTAssertEqual(resp.ver, 3)
    }

    /// #1070：Swift 的 `ProtoReason` 与 Rust 登记表一一对应（`reasons_registry` 金样）。
    func testReasonRegistryMatchesRust() throws {
        let rust = try ProtoJSON.decode([RespError].self, from: RepoFixtures.goldenBody("snapshots__reasons_registry"))
        for e in rust {
            XCTAssertNotEqual(e.reasonKind, .unknown, "Swift 没有登记 Rust reason \(e.reason)")
        }
        XCTAssertEqual(
            Set(ProtoReason.allCases.filter { $0 != .unknown }.map(\.rawValue)),
            Set(rust.map(\.reason))
        )
    }

    /// #1118：`pair_code_wrong` 登记在两边的表里，线上字符串与方法名钉死；归类 = 不是丢配对 / 版本问题（走配对自己的判决）。
    func testPairCodeWrongIsRegisteredAndNotAPairingLoss() throws {
        XCTAssertEqual(ProtoReason.pairCodeWrong.rawValue, "pair_code_wrong")
        XCTAssertEqual(DesktopReason(wire: "pair_code_wrong"), .registered(.pairCodeWrong))
        XCTAssertEqual(Methods.pairConfirm, "pair.confirm")
        XCTAssertEqual(reasonClass(.registered(.pairCodeWrong)), .itemFailure)
    }

    /// #1118：pake_a 空串时不上线（旧样本不变），非空时原样上线。
    func testPairRequestOmitsEmptyPakeAndSendsNonEmpty() throws {
        let plain = try JSONValue.parse(ProtoJSON.encode(PairRequest(token: "t", deviceName: "d", ackThenPoll: true)))
        XCTAssertEqual(plain, try JSONValue.parse(Data(#"{"token":"t","device_name":"d","role":"member","ack_then_poll":true}"#.utf8)))
        let pake = try JSONValue.parse(ProtoJSON.encode(PairRequest(token: "t", deviceName: "d", ackThenPoll: true, pakeA: "41ab")))
        XCTAssertEqual(pake, try JSONValue.parse(Data(#"{"token":"t","device_name":"d","role":"member","ack_then_poll":true,"pake_a":"41ab"}"#.utf8)))
    }

    /// #1070：新建的请求带本端版本。
    func testBuiltRequestCarriesThisBuildsVersions() throws {
        let wire = try JSONValue.parse(ProtoJSON.encode(Req(id: "1", method: "hello")))
        XCTAssertEqual(wire, try JSONValue.parse(Data(#"{"id":"1","method":"hello","params":null,"ver":3,"min_ver":3}"#.utf8)))
    }

    func testThumbSizeRejectsUnknownValues() {
        XCTAssertThrowsError(try ProtoJSON.decode(ThumbGet.self, from: Data(#"{"hash":"x","size":512}"#.utf8)))
        XCTAssertEqual(try ProtoJSON.decode(ThumbGet.self, from: Data(#"{"size":1024}"#.utf8)).size, .s1024)
    }

    /// `"result": null` 与缺键同义（serde 把它解成 None）。
    func testRespNullResultIsNone() throws {
        let resp = try ProtoJSON.decode(Resp.self, from: Data(#"{"id":"1","ok":true,"result":null}"#.utf8))
        XCTAssertNil(resp.result)
        // #1070：信封总是写出 ver / min_ver（与 Rust 一致）；缺键解码 = v1。
        XCTAssertEqual(
            try JSONValue.from(resp),
            .object(["id": .string("1"), "ok": .bool(true), "ver": .int(1), "min_ver": .int(1)])
        )
    }

    /// u64 的 queue_sequence 不能过 Double：取一个 Double 表示不了的值往返。
    func testSixtyFourBitIntegersSurvive() throws {
        let big: UInt64 = 9_007_199_254_740_993 // 2^53 + 1
        let tuple = FlowTupleRef(queueSequence: big, pairingId: "e", leaseToken: "lease-x")
        let back = try ProtoJSON.decode(FlowTupleRef.self, from: ProtoJSON.encode(tuple))
        XCTAssertEqual(back.queueSequence, big)
        let max = FlowTupleRef(queueSequence: .max)
        XCTAssertEqual(try ProtoJSON.decode(FlowTupleRef.self, from: ProtoJSON.encode(max)).queueSequence, .max)
    }

    // MARK: 全等比较器本身（契约测试靠它，它必须对每种漂移都敏感）

    func testComparatorSeesEveryKindOfDrift() throws {
        let base = try JSONValue.parse(Data(#"{"a":1,"b":null,"c":true,"d":"x"}"#.utf8))
        XCTAssertEqual(base, try JSONValue.parse(Data(#"{"d":"x","c":true,"b":null,"a":1}"#.utf8)), "键序不算漂移")
        XCTAssertNotEqual(base, try JSONValue.parse(Data(#"{"a":1,"c":true,"d":"x"}"#.utf8)), "null 与缺键必须区分")
        XCTAssertNotEqual(base, try JSONValue.parse(Data(#"{"a":1,"b":null,"c":1,"d":"x"}"#.utf8)), "true 与 1 必须区分")
        XCTAssertNotEqual(base, try JSONValue.parse(Data(#"{"a":1,"b":null,"c":true,"d":"x","e":0}"#.utf8)), "多一个键必须算漂移")
        XCTAssertNotEqual(base, try JSONValue.parse(Data(#"{"A":1,"b":null,"c":true,"d":"x"}"#.utf8)), "键名改了必须算漂移")
    }

    /// 改一个线上字段名，重新编码就不再等于 golden（与「手改 CodingKey 让契约测试变红」是同一件事的自动化版本）。
    func testRenamedWireFieldIsCaughtAgainstTheGolden() throws {
        let body = try RepoFixtures.goldenBody("snapshots__flow_fetch_request")
        let golden = try JSONValue.parse(body)
        guard case var .object(fields) = golden, let v = fields.removeValue(forKey: "size_bytes") else {
            return XCTFail("golden 里没有 size_bytes")
        }
        fields["sizeBytes"] = v
        XCTAssertNotEqual(JSONValue.object(fields), golden)
        // 用改名后的 JSON 解码：size_bytes 落回默认 0，重新编码后与 golden 不等。
        let renamed = try ProtoJSON.decode(FlowFetchRequest.self, from: ProtoJSON.encode(JSONValue.object(fields)))
        XCTAssertEqual(renamed.sizeBytes, 0)
        XCTAssertNotEqual(try JSONValue.from(renamed), golden)
    }
}

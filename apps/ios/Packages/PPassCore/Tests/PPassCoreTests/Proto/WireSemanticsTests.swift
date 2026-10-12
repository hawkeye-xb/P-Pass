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
        XCTAssertEqual(try decodeEmpty(Req.self), Req(id: "", method: "", params: .null, minVer: 1))
        XCTAssertEqual(try decodeEmpty(Resp.self), Resp(id: "", ok: false, result: nil, error: nil))
        XCTAssertEqual(try decodeEmpty(Hello.self), Hello(protoVer: 1, capabilities: [], deviceName: ""))
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
        XCTAssertNil(hello.pairingEpoch)
    }

    func testUnknownKeysAreIgnored() throws {
        let tuple = try ProtoJSON.decode(FlowTupleRef.self, from: Data(#"{"queue_sequence":7,"future_field":{"x":1}}"#.utf8))
        XCTAssertEqual(tuple.queueSequence, 7)
    }

    /// Rust 的 `RespError` 没有 `#[serde(default)]`：缺字段解码失败，这里同样严格。
    func testRespErrorIsStrict() {
        XCTAssertThrowsError(try ProtoJSON.decode(RespError.self, from: Data(#"{"code":"NOT_FOUND"}"#.utf8)))
    }

    func testThumbSizeRejectsUnknownValues() {
        XCTAssertThrowsError(try ProtoJSON.decode(ThumbGet.self, from: Data(#"{"hash":"x","size":512}"#.utf8)))
        XCTAssertEqual(try ProtoJSON.decode(ThumbGet.self, from: Data(#"{"size":1024}"#.utf8)).size, .s1024)
    }

    /// `"result": null` 与缺键同义（serde 把它解成 None）。
    func testRespNullResultIsNone() throws {
        let resp = try ProtoJSON.decode(Resp.self, from: Data(#"{"id":"1","ok":true,"result":null}"#.utf8))
        XCTAssertNil(resp.result)
        XCTAssertEqual(try JSONValue.from(resp), .object(["id": .string("1"), "ok": .bool(true)]))
    }

    /// u64 的 queue_sequence 不能过 Double：取一个 Double 表示不了的值往返。
    func testSixtyFourBitIntegersSurvive() throws {
        let big: UInt64 = 9_007_199_254_740_993 // 2^53 + 1
        let tuple = FlowTupleRef(queueSequence: big, pairingEpoch: "e", leaseToken: "lease-x")
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

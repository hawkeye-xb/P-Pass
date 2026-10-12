// #890：类型化客户端对着 [CtrlTransport] 假实现跑——证明「参数编码 → 信封解码 → 结果解码」这条链与线上形状一致。
import Foundation
import XCTest
@testable import PPassCore

/// 假控制面：记下收到的 (method, params)，按脚本回一个 `Resp` JSON。
final class ScriptedTransport: CtrlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(method: String, params: JSONValue, timeoutMs: UInt64?)] = []
    private let reply: (String, JSONValue) throws -> Resp

    init(reply: @escaping (String, JSONValue) throws -> Resp) {
        self.reply = reply
    }

    var calls: [(method: String, params: JSONValue, timeoutMs: UInt64?)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        let params = try JSONValue.parse(paramsJSON)
        lock.lock()
        _calls.append((method, params, timeoutMs))
        lock.unlock()
        return try ProtoJSON.encode(reply(method, params))
    }
}

final class ProtoClientTests: XCTestCase {

    func testParamsGoOutInWireShapeAndResultComesBackTyped() async throws {
        let transport = ScriptedTransport { _, _ in
            Resp(id: "1", ok: true, result: try JSONValue.from(FlowStatusReply(state: "active", taskRunning: true)))
        }
        let client = ProtoClient(transport: transport)
        let tuple = FlowTupleRef(queueSequence: 42, pairingEpoch: "epoch-7", leaseToken: "lease-42")
        let reply = try await client.call(Methods.flowStatus, tuple, as: FlowStatusReply.self, timeoutMs: 3_000)
        XCTAssertEqual(reply, FlowStatusReply(state: "active", taskRunning: true))
        XCTAssertEqual(transport.calls.count, 1)
        XCTAssertEqual(transport.calls[0].method, "flow.status")
        XCTAssertEqual(transport.calls[0].timeoutMs, 3_000)
        XCTAssertEqual(
            transport.calls[0].params,
            .object(["queue_sequence": .int(42), "pairing_epoch": .string("epoch-7"), "lease_token": .string("lease-42")])
        )
    }

    func testRejectionCarriesCodeAndMessageKey() async throws {
        let transport = ScriptedTransport { _, _ in Resp(id: "1", ok: false, error: RespError(code: "STORAGE_FULL", msgKey: "storage_full")) }
        do {
            _ = try await ProtoClient(transport: transport).call(Methods.flowOffer, FlowFetchRequest(), as: FlowStatusReply.self)
            XCTFail("expected rejection")
        } catch let rejection as ProtoRejection {
            XCTAssertEqual(rejection, ProtoRejection(method: "flow.offer", error: RespError(code: "STORAGE_FULL", msgKey: "storage_full")))
        }
    }

    func testOkWithoutResultIsMalformedNotSuccess() async throws {
        let transport = ScriptedTransport { _, _ in Resp(id: "1", ok: true) }
        do {
            _ = try await ProtoClient(transport: transport).call(Methods.backupPresence, BackupPresenceQuery(), as: BackupMissing.self)
            XCTFail("expected malformed")
        } catch is ProtoMalformed {}
    }
}

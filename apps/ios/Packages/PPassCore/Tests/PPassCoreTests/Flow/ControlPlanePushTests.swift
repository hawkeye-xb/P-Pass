// #963：`timeline.subscribe` 订阅流的帧解析与推送源（对位 Android `SubscribeAck.kt`）。
import XCTest
@testable import PPassCore

/// 假流式传输：把预设帧依次交给 onFrame，然后按 [end] 结束（正常返回或抛错）。
private struct ScriptedStream: CtrlStreamTransport {
    let frames: [String]
    var end: Error?
    let opened = Locked<[String]>([])

    func stream(method: String, paramsJSON: Data, onFrame: @escaping @Sendable (Data) throws -> Void) async throws {
        opened.update { $0.append(method) }
        for f in frames { try onFrame(Data(f.utf8)) }
        if let end { throw end }
    }
}

private struct Boom: Error {}

final class ControlPlanePushTests: XCTestCase {
    private func run(_ frames: [String], end: Error? = nil) async -> (connected: Int, events: [(String, JSONValue)], error: Error?, opened: [String]) {
        let transport = ScriptedStream(frames: frames, end: end)
        let connected = Locked(0)
        let events = Locked<[(String, JSONValue)]>([])
        var thrown: Error?
        do {
            try await ControlPlanePush(transport: transport).subscribe(
                onConnected: { connected.update { $0 += 1 } },
                onEvent: { kind, data in events.update { $0.append((kind, data)) } }
            )
        } catch {
            thrown = error
        }
        return (connected.get(), events.get(), thrown, transport.opened.get())
    }

    func testAckConnectsAndOnlyFlowEventsAreForwarded() async {
        let r = await run([
            #"{"id":"x","ok":true,"result":{"subscribed":true}}"#,
            #"{"event":"timeline.invalidated","data":{}}"#,
            #"{"event":"flow.delivered","data":{"queue_sequence":7}}"#,
            #"{"event":"flow.failed","data":{"queue_sequence":8,"reason":"fetch_failed"}}"#,
            #"{"event":"flow.delivered"}"#,
            #"{"no_event":true}"#,
        ])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.opened, [Methods.timelineSubscribe])
        XCTAssertEqual(r.connected, 1)
        XCTAssertEqual(r.events.map(\.0), ["flow.delivered", "flow.failed"])
        XCTAssertEqual(r.events.first?.1, .object(["queue_sequence": .int(7)]))
    }

    func testRejectedFirstFrameThrowsAndNeverConnects() async {
        let r = await run([#"{"id":"x","ok":false,"error":{"code":"NOT_AUTHORIZED","reason":"revoked"}}"#])
        XCTAssertEqual(r.connected, 0)
        XCTAssertEqual(r.error as? SubscribeRejected, SubscribeRejected(code: "NOT_AUTHORIZED", reason: .registered(.revoked)))
    }

    func testStreamErrorPropagatesAfterConnecting() async {
        let r = await run([#"{"id":"x","ok":true,"result":{"subscribed":true}}"#], end: Boom())
        XCTAssertEqual(r.connected, 1)
        XCTAssertTrue(r.error is Boom)
    }

    func testStreamThatEndsBeforeAnyFrameNeverConnects() async {
        let r = await run([])
        XCTAssertNil(r.error)
        XCTAssertEqual(r.connected, 0)
    }
}

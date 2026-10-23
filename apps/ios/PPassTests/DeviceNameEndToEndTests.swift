// 真机事故（2026-10-23）：设置页把本机名改成「iPhone test」后配对，电脑审计里 pair.requested 的 deviceName 仍是「iPhone」。
// 日志里从没出现过保存记录：输完没按回车、也没离开输入框，App 就被切走 / 回收了，旧实现只在这两个时机保存。
// 这里走用户的真实路径：AppModel 收到逐字输入（不回车、不结束编辑）→ 落盘 → 配对时 pair.request 带新名字。
import PPassCore
import XCTest
@testable import PPass

@MainActor
final class DeviceNameEndToEndTests: XCTestCase {
    func test_typed_name_reaches_pair_request_without_enter_or_leaving_the_field() async throws {
        let h = try LiveHarness(desk: [Methods.hello: [try PairFixtures.hello()], Methods.pairRequest: [try PairFixtures.submitted()],
                                       Methods.pairStatus: [try .ok(PairStatusReply(state: "expired"))]])
        let demo = FakeBackend.make(.notPaired)
        let app = AppModel(backend: Backend(isDemo: false, timeline: demo.timeline, live: demo.live, media: demo.media,
                                            pairing: h.pairing, engine: demo.engine))
        // 逐字输入，像键盘一样；之后什么都不做（没有回车、没有 deviceNameEditingEnded）。
        let typed = "iPhone test"
        for n in 1...typed.count { app.deviceNameEdited(String(typed.prefix(n))) }

        // 进程被回收后重新打开：盘上的值就是新名字。
        XCTAssertEqual(DeviceNamePrefs(directory: h.dir).custom(), "iPhone test")

        _ = await h.pairing.pair(code: h.link)
        let raw = try XCTUnwrap(h.desk.params(Methods.pairRequest, as: RawParams.self).first, "pair.request 没发出去")
        let sent = (try JSONSerialization.jsonObject(with: raw.json) as? [String: Any])?["device_name"] as? String
        XCTAssertEqual(sent, "iPhone test")
    }
}

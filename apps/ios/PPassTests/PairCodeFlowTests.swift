import Foundation
import PPassCore
import PPassTransport
import XCTest
@testable import PPass

/// #1118 配对验证码状态机（假电脑 + 假 PAKE；真 PairPhone 由 FFI 冒烟与集成 / 真机覆盖）。
/// 每条断言的反证（临时改坏实现 → 红 → 改回）见汇报。
final class PairCodeFlowTests: XCTestCase {
    private typealias F = PairFixtures

    // MARK: 被拒的提交不显示码

    /// 反证：把 `onCode` 挪到 `guard submit.ok` 之前，本条红。
    func test_rejected_submit_never_shows_the_code() async throws {
        for rejection in [FakeDesk.Step.err(Codes.notAuthorized, "pair_token_invalid"), .err(Codes.versionMismatch, "phone_outdated"),
                          .err("SOMETHING_NEW", "from_the_future"), .fail] {
            let shown = Box<[PairCodeShown]>([])
            let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [rejection]])
            let v = try await F.loop(desk, onCode: { s in shown.update { $0.append(s) } }).run(token: "t", deviceName: "d")
            XCTAssertTrue(shown.value.isEmpty, "被拒 / 没送达的提交不许显示验证码：\(v)")
            XCTAssertFalse(desk.methods.contains(Methods.pairStatus), "没提交成功就不轮询")
        }
    }

    /// 提交成功才显示，而且是 pair.request 之后；码与本机 NodeId 一并交出。
    func test_code_is_shown_only_after_the_request_was_accepted() async throws {
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try .ok(PairStatusReply(state: "denied"))]])
        let seen = Box<[(PairCodeShown, [String])]>([])
        _ = try await F.loop(desk, onCode: { s in seen.update { $0.append((s, desk.methods)) } }).run(token: "t", deviceName: "d")
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertEqual(seen.value.first?.0, PairCodeShown(code: "123456", desktop: F.desktopInfo(), phoneNode: F.phoneNode))
        XCTAssertEqual(seen.value.first?.1, [Methods.hello, Methods.pairRequest], "显示验证码时已发出 pair.request、还没轮询")
    }

    /// pair.request 带的是 PairPhone 的 pake_a、本机 / 电脑 NodeId 与二维码令牌原样交给 PAKE。
    func test_request_carries_pake_a_and_the_pake_gets_both_identities() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try .ok(PairStatusReply(state: "expired"))]])
        _ = try await F.loop(desk, crypto: crypto).run(token: "deadbeef", deviceName: "My iPhone")
        let req = try XCTUnwrap(desk.params(Methods.pairRequest, as: PairRequest.self).first)
        XCTAssertEqual(req.pakeA, crypto.session.pake)
        XCTAssertEqual(req.role, "member")
        XCTAssertTrue(req.ackThenPoll)
        XCTAssertEqual(req.deviceName, "My iPhone")
        let start = try XCTUnwrap(crypto.starts.first)
        XCTAssertEqual(start.token, "deadbeef")
        XCTAssertEqual(start.phone, F.phoneNode)
        XCTAssertEqual(start.desk, F.deskNode)
        XCTAssertEqual(start.code, "123456")
    }

    // MARK: 扫码后直接到验证码页（不再问「要连接这台电脑吗？」）

    /// 扫码后没有任何等用户点的步骤：没有任何外部输入，验证码页（onCode，带电脑名 + 标识）也会在 hello → pair.request 之后自己出现。
    /// 反证：在 pair.request 之前塞回一个要等用户回答的步骤（如原来的 review 闸门），onCode 等不到，本条超时红。
    func test_scan_goes_straight_to_the_code_page_without_asking() async throws {
        for (name, shownName) in [("Home Mac", "Home Mac"), ("", L.s("storage_device_default"))] {
            let desk = FakeDesk([Methods.hello: [try F.hello(name: name)], Methods.pairRequest: [try F.submitted()],
                                 Methods.pairStatus: [try .ok(PairStatusReply(state: "pending"))]])
            let seen = Box<[(PairCodeShown, [String])]>([])
            let shown = expectation(description: "验证码页")
            let run = Task { _ = try? await F.loop(desk, onCode: { s in seen.update { $0.append((s, desk.methods)) }; shown.fulfill() }).run(token: "t", deviceName: "d") }
            await fulfillment(of: [shown], timeout: 5)
            run.cancel()
            XCTAssertEqual(seen.value.first?.1, [Methods.hello, Methods.pairRequest], "hello 之后直接 pair.request")
            XCTAssertEqual(seen.value.first?.0.desktop, PairDesktopInfo(name: shownName, fingerprint: FakePairCrypto.expectedFingerprint(F.deskNode)))
        }
    }

    /// 标识只能由二维码里的 node（实际拨号的那个）算出：电脑自报的名字里带「像指纹的串」、或与二维码不符的任何身份信息，
    /// 都不影响验证码页的标识。反证：把 `fingerprint(nodeId: deskNode)` 临时改成取 hello 自报的名字，本条红。
    func test_fingerprint_comes_from_the_qr_node_never_from_the_desktops_self_report() async throws {
        for selfReported in ["AAAA BBBB", "FP-" + String(repeating: "c", count: 8), PairFixtures.phoneNode] {
            let desk = FakeDesk([Methods.hello: [try F.hello(name: selfReported)], Methods.pairRequest: [try F.submitted()],
                                 Methods.pairStatus: [try .ok(PairStatusReply(state: "expired"))]])
            let seen = Box<[PairDesktopInfo]>([])
            _ = try await F.loop(desk, onCode: { s in seen.update { $0.append(s.desktop) } }).run(token: "t", deviceName: "d")
            let info = try XCTUnwrap(seen.value.first)
            XCTAssertEqual(info.fingerprint, FakePairCrypto.expectedFingerprint(F.deskNode), "自报「\(selfReported)」")
            XCTAssertEqual(info.name, selfReported, "名字只是辨认用的标签，原样显示")
        }
    }

    // MARK: pake_b 出现才 finish、才发 pair.confirm

    /// 反证：把 `confirmA == nil, let pakeB` 的条件改成无条件 finish，没有 pake_b 的轮次就会 finish，本条红；
    /// 把 pending 分支的 confirm 挪到判断 pake_b 之外之前，同样红。
    func test_finish_and_confirm_happen_only_once_pake_b_appears() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(), try F.pending(), try F.pending(pakeB: F.pakeB)],
                             Methods.pairConfirm: [try F.confirmed()]])
        let v = try await F.loop(desk, crypto: crypto).run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .accepted(PairAccepted(storageDeviceName: "Home Mac", pairingId: "e1")))
        XCTAssertEqual(desk.methods, [Methods.hello, Methods.pairRequest, Methods.pairStatus, Methods.pairStatus, Methods.pairStatus, Methods.pairConfirm],
                       "前两轮没有 pake_b：不 finish、不 confirm")
        XCTAssertEqual(crypto.session.events, ["finish:\(F.pakeB)", "verify:\(F.confirmB)"])
        let confirm = try XCTUnwrap(desk.params(Methods.pairConfirm, as: PairConfirmRequest.self).first)
        XCTAssertEqual(confirm, PairConfirmRequest(requestId: "r1", confirmA: crypto.session.confirmA))
    }

    /// confirm 失败（网络 / 其它错误）：下一轮重发**同一个** confirm_a，finish 只调一次（idempotent）。
    /// 反证：每轮都重新 finish（或不重发 confirm），本条红。
    func test_failed_confirm_is_retried_with_the_same_confirm_a() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(pakeB: F.pakeB)],
                             Methods.pairConfirm: [.fail, .err(Codes.invalidRequest, "internal"), try F.confirmed()]])
        var l = F.loop(desk, crypto: crypto)
        l.maxConsecutiveFailures = 3
        let v = try await l.run(token: "t", deviceName: "d")
        guard case .accepted = v else { return XCTFail("\(v)") }
        let sent = desk.params(Methods.pairConfirm, as: PairConfirmRequest.self)
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(Set(sent.map(\.confirmA)), [crypto.session.confirmA], "三次都是同一个 confirm_a")
        XCTAssertEqual(crypto.session.events.filter { $0.hasPrefix("finish") }.count, 1)
    }

    /// 连续失败预算：confirm 一直失败 → 3 轮后判不可达（不无限重发）。
    func test_confirm_failures_spend_the_consecutive_failure_budget() async throws {
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(pakeB: F.pakeB)], Methods.pairConfirm: [.fail]])
        let v = try await F.loop(desk).run(token: "t", deviceName: "d")
        guard case .unreachable = v else { return XCTFail("\(v)") }
        XCTAssertEqual(desk.methods.filter { $0 == Methods.pairConfirm }.count, 3)
    }

    /// 畸形的 pake_b：PAKE 会话作废，显示「电脑没能证明…」，不重试。
    func test_malformed_pake_b_is_a_proof_failure() async throws {
        let crypto = FakePairCrypto()
        crypto.session.finishError = FakePairSession.Failure()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(pakeB: "zz")]])
        let v = try await F.loop(desk, crypto: crypto).run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .desktopProofFailed)
        XCTAssertFalse(desk.methods.contains(Methods.pairConfirm))
    }

    // MARK: confirm_b 验不过不保存

    /// 反证：把 `verified` 里的 `try phone.verify` 去掉（或吞掉错误照样返回 .accepted），本条红。
    func test_unverifiable_confirm_b_is_never_accepted_on_either_path() async throws {
        // 路径 1：pair.confirm 的回复里 confirm_b 验不过。
        let crypto1 = FakePairCrypto()
        crypto1.session.verifyError = FakePairSession.Failure()
        let desk1 = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                              Methods.pairStatus: [try F.pending(pakeB: F.pakeB)], Methods.pairConfirm: [try F.confirmed()]])
        let v1 = try await F.loop(desk1, crypto: crypto1).run(token: "t", deviceName: "d")
        XCTAssertEqual(v1, .desktopProofFailed)
        XCTAssertEqual(v1.outcome, .refused(note: .desktopProofFailed, ownerSaidNo: false))
        // 路径 2：pair.confirm 的回复丢了，pair.status 带着 accepted + confirm_b 回来，同样验不过。
        let crypto2 = FakePairCrypto()
        crypto2.session.verifyError = FakePairSession.Failure()
        let desk2 = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                              Methods.pairStatus: [try F.pending(pakeB: F.pakeB), try F.confirmed()], Methods.pairConfirm: [.fail]])
        let v2 = try await F.loop(desk2, crypto: crypto2).run(token: "t", deviceName: "d")
        XCTAssertEqual(v2, .desktopProofFailed)
    }

    /// 经 LivePairing：验不过 → 不写配对记录、不触发 onPaired。
    func test_unverifiable_confirm_b_saves_nothing() async throws {
        let h = try LiveHarness(desk: [Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                                       Methods.pairStatus: [try F.pending(pakeB: F.pakeB)], Methods.pairConfirm: [try F.confirmed()]])
        h.crypto.session.verifyError = FakePairSession.Failure()
        let outcome = await h.pairing.pair(code: h.link)
        XCTAssertEqual(outcome, .refused(note: .desktopProofFailed, ownerSaidNo: false))
        XCTAssertNil(h.store.load(), "验不过不许存配对")
        XCTAssertEqual(h.paired.value, 0)
    }

    /// 验过才保存：配对记录 = 电脑回的名字与 pairing_id；验证码交给 onCode。
    func test_verified_pairing_is_saved_and_the_code_was_handed_to_the_ui() async throws {
        let h = try LiveHarness(desk: [Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                                       Methods.pairStatus: [try F.pending(pakeB: F.pakeB)], Methods.pairConfirm: [try F.confirmed(pairingId: "e9")]])
        let shown = Box<[PairCodeShown]>([])
        let outcome = await h.pairing.pair(code: h.link, onCode: { s in shown.update { $0.append(s) } })
        XCTAssertEqual(outcome, .joined(firstTime: true))
        XCTAssertEqual(h.store.load()?.pairingId, "e9")
        XCTAssertEqual(h.store.load()?.storageDeviceName, "Home Mac")
        XCTAssertEqual(shown.value.map(\.code), ["123456"])
        XCTAssertEqual(shown.value.map(\.phoneNode), [h.nodeId])
        XCTAssertEqual(h.crypto.starts.first?.desk, h.deskNodeInLink, "PAKE 的电脑身份来自二维码")
    }

    /// pair.request 带的是用户在设置里起的本机名；没起过（或清空）才用系统名（iOS 16 起没有权限时就是「iPhone」）。
    func test_pair_request_carries_the_device_name_from_settings() async throws {
        func sentName(_ configure: (LivePairing) throws -> Void) async throws -> String? {
            let h = try LiveHarness(desk: [Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                                           Methods.pairStatus: [try .ok(PairStatusReply(state: "expired"))]])
            try configure(h.pairing)
            _ = await h.pairing.pair(code: h.link)
            let raw = try XCTUnwrap(h.desk.params(Methods.pairRequest, as: RawParams.self).first, "pair.request 没发出去")
            return (try JSONSerialization.jsonObject(with: raw.json) as? [String: Any])?["device_name"] as? String
        }
        let custom = try await sentName { try $0.setDeviceName(" 妈妈的手机 ") }
        XCTAssertEqual(custom, "妈妈的手机")
        let fallback = try await sentName { try $0.setDeviceName("妈妈的手机"); try $0.setDeviceName("") }
        XCTAssertEqual(fallback, "iPhone")
    }

    // MARK: pair_code_wrong / failed → 验证码不对

    /// 反证：把 `case "failed": return .codeWrong` 改成 `.denied`，或 confirm 的 pair_code_wrong 判成普通失败，对应断言红。
    func test_wrong_code_lands_on_the_code_wrong_note_from_both_signals() async throws {
        // pair.confirm 回 pair_code_wrong
        let crypto = FakePairCrypto()
        let d1 = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                           Methods.pairStatus: [try F.pending(pakeB: F.pakeB)],
                           Methods.pairConfirm: [.err(Codes.notAuthorized, "pair_code_wrong")]])
        let v1 = try await F.loop(d1, crypto: crypto).run(token: "t", deviceName: "d")
        XCTAssertEqual(v1, .codeWrong)
        XCTAssertEqual(d1.methods.filter { $0 == Methods.pairConfirm }.count, 1, "码错不重试")
        XCTAssertFalse(crypto.session.events.contains { $0.hasPrefix("verify") })
        // pair.status 回 failed
        let d2 = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                           Methods.pairStatus: [try F.pending(), try .ok(PairStatusReply(state: "failed"))]])
        let v2 = try await F.loop(d2).run(token: "t", deviceName: "d")
        XCTAssertEqual(v2, .codeWrong)
        for v in [v1, v2] {
            XCTAssertEqual(v.outcome, .refused(note: .codeWrong, ownerSaidNo: false))
        }
        XCTAssertEqual(PairNote.codeWrong.key, "pair_refused_detail_code_wrong")
        XCTAssertNotEqual(PairNote.codeWrong.text, "pair_refused_detail_code_wrong", "文案已打包")
        XCTAssertEqual(PairNote.desktopProofFailed.key, "pair_desktop_proof_failed")
    }

    // MARK: 轮询间隔 1 秒

    /// 反证：把 `codePollIntervalNs` 改回 5_000_000_000，两条断言都红。
    func test_poll_interval_is_one_second() async throws {
        XCTAssertEqual(PairVerdictLoop.codePollIntervalNs, 1_000_000_000)
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(), try F.pending(), try .ok(PairStatusReply(state: "denied"))]])
        let slept = Box<[UInt64]>([])
        var l = PairVerdictLoop(rpc: { try await desk.rpc($0, $1) })   // 间隔取默认值，不覆盖
        l.crypto = FakePairCrypto()
        l.sleep = { ns in slept.update { $0.append(ns) } }
        _ = try await l.run(token: "t", deviceName: "d")
        XCTAssertEqual(slept.value, [1_000_000_000, 1_000_000_000, 1_000_000_000], "每次轮询前睡 1 秒")
    }

    /// 截止仍按 ttl_ms 算：ttl 3 秒 + 1 秒间隔 = 轮询 4 次后过期。
    func test_deadline_still_follows_ttl() async throws {
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted(ttlMs: 3_000)],
                             Methods.pairStatus: [try F.pending()]])
        var l = PairVerdictLoop(rpc: { try await desk.rpc($0, $1) })
        l.crypto = FakePairCrypto()
        l.sleep = { _ in }
        let v = try await l.run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .expired)
        XCTAssertEqual(desk.methods.filter { $0 == Methods.pairStatus }.count, 4)
    }

    // MARK: accepted 但缺 confirm_b 不算加入

    /// 反证：accepted 分支不检查 confirm_b（有 pairing_id 就返回 .accepted），本条红。
    func test_accepted_without_confirm_b_is_not_a_join() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(pakeB: F.pakeB), try F.confirmed(confirmB: nil)],
                             Methods.pairConfirm: [.fail]])
        let v = try await F.loop(desk, crypto: crypto).run(token: "t", deviceName: "d")
        guard case .unreachable = v else { return XCTFail("缺 confirm_b 按畸形回复计失败，实际 \(v)") }
        XCTAssertFalse(crypto.session.events.contains { $0.hasPrefix("verify") })
    }

    /// accepted 却从没 finish（没有交换过验证码）：同样不算加入，也不 verify。
    func test_accepted_before_any_exchange_is_not_a_join() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.confirmed()]])
        let v = try await F.loop(desk, crypto: crypto).run(token: "t", deviceName: "d")
        guard case .unreachable = v else { return XCTFail("\(v)") }
        XCTAssertTrue(crypto.session.events.isEmpty)
    }

    /// pair.confirm 的回复丢了：下一轮 pair.status 带 accepted + confirm_b → verify 通过才加入。
    func test_lost_confirm_reply_is_recovered_through_status() async throws {
        let crypto = FakePairCrypto()
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending(pakeB: F.pakeB), try F.confirmed()], Methods.pairConfirm: [.fail]])
        let v = try await F.loop(desk, crypto: crypto).run(token: "t", deviceName: "d")
        guard case .accepted = v else { return XCTFail("\(v)") }
        XCTAssertEqual(crypto.session.events, ["finish:\(F.pakeB)", "verify:\(F.confirmB)"])
    }

    /// 老电脑直接回 accepted（没有 request_id、没有验证码交换）：绝不当作加入。
    func test_legacy_accepted_reply_without_exchange_is_not_a_join() async throws {
        let desk = FakeDesk([Methods.hello: [try F.hello()],
                             Methods.pairRequest: [try .ok(PairAccepted(storageDeviceName: "Mac", pairingId: "e9"))]])
        let v = try await F.loop(desk).run(token: "t", deviceName: "d")
        XCTAssertEqual(v, .desktopTooOld)
    }

    // MARK: 取消 / 版本

    /// 等待中取消：照旧发 pair.cancel（电脑声明了能力）。
    func test_cancelling_while_waiting_withdraws_the_request() async throws {
        let desk = FakeDesk([Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                             Methods.pairStatus: [try F.pending()], Methods.pairCancel: [try .ok(PairStatusReply(state: "denied"))]])
        var l = F.loop(desk)
        l.sleep = { _ in try await Task.sleep(nanoseconds: 50_000_000) }
        let task = Task { try await l.run(token: "t", deviceName: "d") }
        try await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("应当抛取消") } catch is CancellationError {}
        XCTAssertEqual(desk.methods.last, Methods.pairCancel)
    }

    // MARK: 小件

    func test_code_is_grouped_three_plus_three() {
        XCTAssertEqual(PairCodeFormat.grouped("123456"), "123 456")
        XCTAssertEqual(PairCodeFormat.grouped("000012"), "000 012")
    }

    #if DEBUG
    /// e2e 取码约定：一行 `PAIR_CODE=<码> node=<本机NodeId>` 追加进 `<PPASS_E2E_DIR>/pair_code.txt`；没设目录什么都不写。
    func test_e2e_pair_code_file_convention() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = PairCodeShown(code: "123456", desktop: F.desktopInfo(), phoneNode: F.phoneNode)
        let b = PairCodeShown(code: "654321", desktop: F.desktopInfo(), phoneNode: F.deskNode)
        E2EPairCode.record(a, dir: dir); E2EPairCode.record(b, dir: dir)
        let text = try String(contentsOf: dir.appendingPathComponent("pair_code.txt"), encoding: .utf8)
        XCTAssertEqual(text, "PAIR_CODE=123456 node=\(F.phoneNode)\nPAIR_CODE=654321 node=\(F.deskNode)\n")
        // 宿主脚本用的正则（sandbox-desk.sh desk_auto_allow）能按 node 取到各自的码。
        let re = try NSRegularExpression(pattern: "PAIR_CODE=([0-9]{6}) node=\(F.deskNode)")
        let m = try XCTUnwrap(re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        XCTAssertEqual((text as NSString).substring(with: m.range(at: 1)), "654321")
        E2EPairCode.record(a, dir: nil) // 不抛、不写
    }

    func test_e2e_pair_is_auto_connect_and_records_the_code() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = try LiveHarness(desk: [Methods.hello: [try F.hello()], Methods.pairRequest: [try F.submitted()],
                                       Methods.pairStatus: [try F.pending(pakeB: F.pakeB)], Methods.pairConfirm: [try F.confirmed()]])
        let outcome = await E2EPairCode.pair(h.pairing, link: h.link, dir: dir)
        XCTAssertEqual(outcome, .joined(firstTime: true))
        let text = try String(contentsOf: dir.appendingPathComponent("pair_code.txt"), encoding: .utf8)
        XCTAssertEqual(text, "PAIR_CODE=123456 node=\(h.nodeId)\n")
    }
    #endif

    // MARK: 真 FFI 冒烟（原生库在模拟器里可调）

    func test_real_ffi_crypto_smoke() throws {
        let client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.shutdown() }
        let node = try client.nodeId()
        let crypto = FfiPairCrypto()
        let code = try crypto.generateCode()
        XCTAssertNotNil(code.range(of: "^[0-9]{6}$", options: .regularExpression), code)
        XCTAssertNotNil(crypto.fingerprint(nodeId: node).range(of: "^[0-9A-F]{4} [0-9A-F]{4}$", options: .regularExpression), crypto.fingerprint(nodeId: node))
        let session = try crypto.start(code: code, token: "deadbeef", phoneNode: node, deskNode: node)
        XCTAssertEqual(session.pakeA().count, 66)
        XCTAssertThrowsError(try crypto.start(code: "12345", token: "deadbeef", phoneNode: node, deskNode: node), "5 位码不合法")
    }
}

/// 经 LivePairing 的集成夹具：假电脑 + 假 PAKE + 临时配对库；链接里的电脑 NodeId 是真合法的曲线点。
final class LiveHarness {
    let dir: URL
    let store: PairingStore
    let crypto = FakePairCrypto()
    let desk: FakeDesk
    let paired = Box(0)
    let nodeId = PairFixtures.phoneNode
    let link: String
    let deskNodeInLink: String
    let pairing: LivePairing

    init(desk steps: [String: [FakeDesk.Step]], onboarded: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pair-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let client = try CtrlClient.bind(config: CtrlConfig(secretKey: nil, relayUrls: [], offline: true, bindTimeoutMs: 0))
        defer { client.shutdown() }
        deskNodeInLink = try client.nodeId()
        link = "ppf://pair?node=\(deskNodeInLink)&t=deadbeef"
        store = PairingStore(root: dir)
        desk = FakeDesk(steps)
        let transport = DeskTransport(desk)
        let paired = self.paired
        pairing = LivePairing(transportFor: { _ in transport }, store: store, onboarded: { _ in onboarded },
                              onPaired: { _, _ in paired.update { $0 += 1 }; return false },
                              onDisconnect: {}, logger: NullLogger(), localNodeId: { PairFixtures.phoneNode },
                              names: DeviceNamePrefs(directory: dir), systemName: { "iPhone" }, crypto: crypto)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

struct NullLogger: CoreLogger { func log(_ message: String) {} }

/// FakeDesk 当控制面传输：方法名取自请求的 method（ProtoClient 把 method 作为参数传下来）。
final class DeskTransport: CtrlTransport, @unchecked Sendable {
    private let desk: FakeDesk
    init(_ desk: FakeDesk) { self.desk = desk }
    func call(method: String, paramsJSON: Data, timeoutMs: UInt64?) async throws -> Data {
        let r = try await desk.rpc(method, RawParams(json: paramsJSON, method: method))
        return try ProtoJSON.encode(r)
    }
}

/// 经传输层进来的参数：按方法解码回类型，测试里 `desk.params(method, as:)` 照样能取。
struct RawParams: Encodable {
    let json: Data
    let method: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(JSONValue.parse(json))
    }
}

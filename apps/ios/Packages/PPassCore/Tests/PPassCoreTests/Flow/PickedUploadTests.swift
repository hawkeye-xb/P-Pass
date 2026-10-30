// #1272 挑几张传（iOS）：手选走同一条传输链路，但不进 order / 范围 / 对账；只在前台传；不需要照片权限。
import Foundation
import XCTest
@testable import PPassCore

private struct Stub: PickedPayload {}

/// 没有照片权限：照片库这一侧每个读取都抛错。
private struct DeniedMedia: MediaSource {
    struct Denied: Error {}
    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] { throw Denied() }
    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] { throw Denied() }
    func currentPosition() async throws -> DiscoveryPosition { throw Denied() }
    func libraryIdentity() async throws -> String? { throw Denied() }
    func lookup(_ mediaId: String) async throws -> MediaDetails? { throw Denied() }
    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? { throw Denied() }
}

final class PickedUploadTests: XCTestCase {
    private func pick(_ rig: Rig, _ names: [String]) {
        rig.picked.addBatch(names.map { (fileName: $0, mimeType: "image/jpeg", payload: Stub()) })
    }

    /// 验收：不给任何照片权限（照片库每个读取都抛）、自动备份没开，手选照样传完；请求带 source=picked，序号与 order 隔开；
    /// 不建任何 order。反证：引擎入口不放行手选（照片库抛错就整轮失败）⇒ 一张都没传，红。
    func testPickedTransfersWithoutPhotoAccessAndAutoBackupOff() async throws {
        let rig = try Rig(source: { _ in DeniedMedia() })
        rig.conditions.set(Conditions(autoBackupEnabled: false))
        await rig.start()
        pick(rig, ["a.jpg", "b.jpg"])
        await rig.trigger(.pickedAdded)

        let requests = rig.delivery.requests.get()
        XCTAssertEqual(requests.map(\.source), ["picked", "picked"])
        XCTAssertTrue(requests.allSatisfy { $0.orderId >= PickedQueue.sequenceBase })
        XCTAssertEqual(rig.picked.summary(), PickedBatchSummary(total: 2, delivered: 2, alreadyThere: 0, failed: 0, interrupted: false))
        XCTAssertEqual(try rig.store.currentInStates(OrderState.open).count, 0)
        XCTAssertEqual(rig.importer.released.get(), ["picked-hash-a.jpg", "picked-hash-b.jpg"], "传完放掉导入")
    }

    /// 手选优先于自动备份：同时有范围内的新照片时，手选先传；自动备份的请求不带 source。
    func testPickedGoesBeforeAutoBackup() async throws {
        let rig = try Rig()
        rig.photo(1, generation: 1)
        await rig.start()
        pick(rig, ["a.jpg"])
        await rig.trigger(.appForeground)

        let requests = rig.delivery.requests.get()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.source, "picked")
        XCTAssertNil(requests.last?.source)
    }

    /// 电脑上已有：offer 直接给完成、一个字节没发 → 记「已有」。
    func testZeroBytesSentIsRecordedAsAlreadyThere() async throws {
        let rig = try Rig(source: { _ in DeniedMedia() })
        rig.delivery.reportsBytes.set(false)
        await rig.start()
        pick(rig, ["a.jpg", "b.jpg"])
        await rig.trigger(.pickedAdded)
        let s = try XCTUnwrap(rig.picked.summary())
        XCTAssertEqual(s.alreadyThere, 2)
        XCTAssertEqual(s.delivered, 0)
    }

    /// 读不到（临时文件没了）：这一张记没传成，后面的照常传。
    func testUnreadableOneFailsAndTheRestContinue() async throws {
        let rig = try Rig(source: { _ in DeniedMedia() })
        rig.importer.pickedUnreadable.set(["a.jpg"])
        await rig.start()
        pick(rig, ["a.jpg", "b.jpg"])
        await rig.trigger(.pickedAdded)
        let s = try XCTUnwrap(rig.picked.summary())
        XCTAssertEqual(s.failed, 1)
        XCTAssertEqual(s.delivered, 1)
        XCTAssertEqual(s.open, 0)
    }

    /// 离开 P-Pass 不传；回前台接着传。反证：不看 isForeground ⇒ 后台也传，红。
    func testNothingIsTransferredWhileInBackground() async throws {
        let rig = try Rig(source: { _ in DeniedMedia() })
        rig.foreground.set(false)
        await rig.start()
        pick(rig, ["a.jpg"])
        await rig.trigger(.pickedAdded)
        XCTAssertTrue(rig.delivery.requests.get().isEmpty)
        XCTAssertTrue(rig.picked.hasOpen())

        rig.foreground.set(true)
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.delivery.requests.get().count, 1)
        XCTAssertEqual(rig.picked.summary()?.delivered, 1)
    }

    /// 在传的这张遇到退后台：打断这一轮（传输端口收到取消），这张留在队列里；回前台续传，不丢、不重复计数。
    func testLeavingTheAppInterruptsTheInFlightPickedAndResumesOnForeground() async throws {
        let rig = try Rig(source: { _ in DeniedMedia() })
        rig.delivery.hold.set(true)
        await rig.start()
        pick(rig, ["a.jpg", "b.jpg"])
        await rig.engine.trigger(.pickedAdded)
        await eventually("first picked in flight") { rig.delivery.requests.get().count == 1 }

        rig.foreground.set(false)
        await rig.engine.onAppBackground()
        XCTAssertEqual(rig.delivery.cancelled.get().count, 1, "在飞的这张被取消")
        XCTAssertEqual(rig.picked.summary()?.delivered, 0)
        XCTAssertTrue(rig.picked.hasOpen())

        rig.delivery.release()
        rig.delivery.hold.set(false)
        rig.foreground.set(true)
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.picked.summary(), PickedBatchSummary(total: 2, delivered: 2, alreadyThere: 0, failed: 0, interrupted: false))
    }

    /// 进程被杀：新进程读到上一批没传完的汇总，标成被打断，张数 = 没送达的。
    func testKilledProcessLeavesAnInterruptedSummary() throws {
        let dir = TempDir()
        let first = PickedQueue(directory: dir.url)
        first.addBatch((0..<12).map { (fileName: "p\($0).jpg", mimeType: "image/jpeg", payload: Stub()) })
        for _ in 0..<9 { first.mark(try XCTUnwrap(first.nextOpen()).id, .delivered) }
        XCTAssertEqual(first.summary()?.open, 3)

        let relaunched = PickedQueue(directory: dir.url)
        let s = try XCTUnwrap(relaunched.summary())
        XCTAssertTrue(s.interrupted)
        XCTAssertEqual(s.total, 12)
        XCTAssertEqual(s.notReached, 3)
        XCTAssertFalse(relaunched.hasOpen(), "句柄随进程没了，不假装还能传")
        // 新挑一批：旧汇总被替换，序号接着往后不回头。
        relaunched.addBatch([(fileName: "n.jpg", mimeType: "image/jpeg", payload: Stub())])
        XCTAssertFalse(try XCTUnwrap(relaunched.summary()).interrupted)
        XCTAssertGreaterThan(try XCTUnwrap(relaunched.nextOpen()).id, 12)
    }

    func testBatchIsCappedAt100() {
        let q = PickedQueue(directory: TempDir().url)
        XCTAssertEqual(q.addBatch((0..<130).map { (fileName: "p\($0)", mimeType: "image/jpeg", payload: Stub()) }), 100)
    }

    /// 规则关着：范围内的新照片不传（自动备份那一支不跑）；手选照传。反证：不看规则 ⇒ 照片 1 被传，红。
    func testAutoRuleOffSendsOnlyPicked() async throws {
        let rig = try Rig()
        rig.autoRule.set(false)
        rig.photo(1, generation: 1)
        await rig.start()
        await rig.trigger(.appForeground)
        XCTAssertTrue(rig.delivery.requests.get().isEmpty, "规则关着：没有手选就什么都不传")

        pick(rig, ["a.jpg"])
        await rig.trigger(.pickedAdded)
        XCTAssertEqual(rig.delivery.requests.get().map(\.source), ["picked"])
        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.delivery.requests.get().count, 1, "之后的前台触发也不带出自动备份")
    }

    func testRulePrefsInitializeOnceFromCurrentStateAndKeepStoredValue() throws {
        let dir = TempDir()
        let prefs = AutoBackupRulePrefs(directory: dir.url)
        XCTAssertNil(prefs.stored())
        XCTAssertTrue(prefs.initIfAbsent(current: true))
        XCTAssertTrue(AutoBackupRulePrefs(directory: dir.url).initIfAbsent(current: false), "已存的值不被覆盖")
        XCTAssertFalse(AutoBackupRulePrefs(directory: TempDir().url).initIfAbsent(current: false))
    }

    /// 线上形状：自动备份不带 source（老电脑原样认得），手选带 "picked"；缺省解码为 nil。
    func testSourceFieldWireShape() throws {
        let auto = try JSONEncoder().encode(FlowFetchRequest(queueSequence: 1))
        XCTAssertFalse(String(decoding: auto, as: UTF8.self).contains("source"))
        let picked = try JSONEncoder().encode(FlowFetchRequest(queueSequence: 1, source: "picked"))
        XCTAssertTrue(String(decoding: picked, as: UTF8.self).contains("\"source\":\"picked\""))
        XCTAssertNil(try JSONDecoder().decode(FlowFetchRequest.self, from: auto).source)
        XCTAssertEqual(try JSONDecoder().decode(FlowFetchRequest.self, from: picked).source, "picked")
    }
}

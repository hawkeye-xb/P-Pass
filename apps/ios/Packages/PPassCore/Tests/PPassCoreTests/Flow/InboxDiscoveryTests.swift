// #958 收件箱（取新系统）的引擎级端到端测试：引擎不改，只验证「按 seq 取件」的媒体源在现有引擎下的行为。
// 设计：P-Pass-iOS-取新系统-设计.md §3 / §6；每条测试注释标注对应的 §6 条目。
//
// SeqInboxMedia 按 App 层 `PhotoMediaSource` + PPassMedia `Inbox` 的契约建模（收件箱本身的单测在 PPassMedia/InboxTests）：
// - 系统变更先挂着（未进箱）；`changes(after:)` 在 G 之后不够 limit 条时进箱：每条变更内按 id 排序、各占一个 AUTOINCREMENT 序号；
// - 取件时过滤「照片库里还在」与「在范围内」，不够就往后翻；每张的位置 = 它的 seq（8 字节大端，与 `Inbox.position(of:)` 相同）；
// - `currentPosition()` = 序号高水位，并清掉 `seq <= 它` 的行；
// - 令牌失效：只把未进箱的变更丢掉（缺口交给对账），不抛错、不动 G。
import Foundation
import XCTest
@testable import PPassCore

/// 收件箱的持久部分（模拟和账本同一个文件：重启后还在）。
final class InboxState: @unchecked Sendable {
    let box = Locked<(pending: [[String]], rows: [(seq: Int64, id: String)], top: Int64, initialized: Bool)>(([], [], 0, false))
    var rowCount: Int { box.get().rows.count }
}

final class SeqInboxMedia: MediaSource, @unchecked Sendable {
    let library: FakeMedia
    let state: InboxState
    /// 每次 `changes` 算好结果之后、返回之前调用（模拟「取到之后、处理之前」照片被删）。
    let afterChanges = Locked<(([MediaSnapshot]) -> Void)?>(nil)

    init(_ library: FakeMedia, state: InboxState = InboxState()) {
        self.library = library
        self.state = state
    }

    static func position(_ seq: Int64) -> DiscoveryPosition { DiscoveryPosition(raw: withUnsafeBytes(of: seq.bigEndian) { Data($0) }) }
    static func seq(_ p: DiscoveryPosition) -> Int64 { p.raw.count == 8 ? p.raw.reduce(Int64(0)) { ($0 << 8) | Int64($1) } : 0 }

    /// 一条系统变更：这些照片一起入库（还没进箱）。
    func change(_ ids: [String]) { state.box.update { $0.pending.append(ids) } }
    /// 令牌失效：未进箱的变更读不到了。
    func expireToken() { state.box.update { $0.pending = [] } }

    private func entries(after: Int64, limit: Int) -> [(seq: Int64, id: String)] {
        state.box.update { s in
            let before = Array(s.rows.filter { $0.seq > after }.prefix(limit))
            if before.count >= limit || !s.initialized { return before }
            for change in s.pending {
                for id in Array(Set(change)).sorted(by: MediaOrder.precedes) {
                    s.top += 1
                    s.rows.append((s.top, id))
                }
            }
            s.pending = []
            return Array(s.rows.filter { $0.seq > after }.prefix(limit))
        }
    }

    func changes(after position: DiscoveryPosition, limit: Int) async throws -> [MediaSnapshot] {
        var after = Self.seq(position)
        var out: [MediaSnapshot] = []
        while out.count < limit {
            let rows = entries(after: after, limit: limit)
            guard let last = rows.last else { break }
            after = last.seq
            for row in rows {
                guard let p = library.photos.first(where: { MediaOrder.same($0.mediaId, row.id) }), library.isInScope(p.bucket) else { continue }
                out.append(library.snapshot(p, position: Self.position(row.seq)))
            }
        }
        let result = Array(out.prefix(limit))
        afterChanges.get()?(result)
        return result
    }

    func currentPosition() async throws -> DiscoveryPosition {
        let top = state.box.update { s -> Int64 in
            if !s.initialized { s.initialized = true; s.pending = [] }
            s.rows.removeAll { $0.seq <= s.top }
            return s.top
        }
        return Self.position(top)
    }

    func inScope(after: String?, limit: Int) async throws -> [MediaSnapshot] { try await library.inScope(after: after, limit: limit) }
    func libraryIdentity() async throws -> String? { try await library.libraryIdentity() }
    func lookup(_ mediaId: String) async throws -> MediaDetails? { try await library.lookup(mediaId) }
    func existingIds(_ mediaIds: [String]) async throws -> Set<String>? { try await library.existingIds(mediaIds) }
    var preciseDiscovery: Bool { library.preciseDiscovery }
}

final class InboxDiscoveryTests: XCTestCase {
    /// 一套「装好之后一直在跑」的引擎：收件箱已初始化，G = 0。
    private func makeRig(_ name: String = #function, directory: TempDir? = nil, state: InboxState = InboxState(), initialize: Bool = true) async throws -> (Rig, SeqInboxMedia) {
        var inbox: SeqInboxMedia!
        let rig = try Rig(name, cursors: false, directory: directory, source: { inbox = SeqInboxMedia($0, state: state); return inbox })
        if initialize {
            let g = try await inbox.currentPosition()
            try rig.store.saveDiscoveryState(DiscoveryState(position: g, libraryIdentity: "lib-1"))
        }
        return (rig, inbox)
    }

    private func g(_ rig: Rig) throws -> Int64 { SeqInboxMedia.seq(try XCTUnwrap(rig.store.discoveryState()).position) }

    /// 新拍 [ns]：放进照片库，并作为**一条**系统变更。
    private func shoot(_ rig: Rig, _ inbox: SeqInboxMedia, _ ns: [Int], bucket: String = "B7", video: Set<Int> = []) {
        for n in ns { rig.photo(n, generation: Int64(n), bucket: bucket, video: video.contains(n)) }
        inbox.change(ns.map(mid))
    }

    private func confirmedCount(_ rig: Rig) -> [String: Int] {
        var out: [String: Int] = [:]
        for r in rig.delivery.requests.get() { out[r.details.snapshot.mediaId, default: 0] += 1 }
        return out
    }

    // MARK: §6-1 逐张推进

    /// §6-1：一条变更新增 6 张，逐张提交，6 张全部送达，每张恰好一次；G 逐张走到第 6 张的 seq。
    func testS6_1_oneChangeWithSixPhotosDeliversAllSixExactlyOnce() async throws {
        let (rig, inbox) = try await makeRig()
        shoot(rig, inbox, [1, 2, 3, 4, 5, 6])
        var gAtStart: [Int64] = []
        rig.delivery.onStart.set { _ in gAtStart.append((try? self.g(rig)) ?? -1) }
        await rig.start()
        let pending = await rig.pending()
        XCTAssertEqual(pending, 6, "计数路径（countTodo）同样按 seq 看到 6 张")

        await rig.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 3, 4, 5, 6])
        for n in 1...6 { XCTAssertEqual(try rig.state(n), .confirmed) }
        XCTAssertEqual(gAtStart, [0, 1, 2, 3, 4, 5], "每张开始时 G 停在上一张：提交一张推进一格，不会一下跳到整批末尾")
        XCTAssertEqual(try g(rig), 6)
    }

    // MARK: §6-2 断点续取

    /// §6-2：100 张（3 条变更）分 3 次短任务传完：每次从 G 接着取，没有重复，也没有遗漏。
    func testS6_2_hundredPhotosAcrossThreeShortTasksNoDuplicatesNoGaps() async throws {
        let (rig, inbox) = try await makeRig()
        shoot(rig, inbox, Array(1...40))
        shoot(rig, inbox, Array(41...70))
        shoot(rig, inbox, Array(71...100))
        let stops: Set<Int> = [34, 68]
        rig.delivery.onStart.set { _ in if stops.contains(rig.delivery.requests.get().count) { rig.lease.held.set(false) } }
        await rig.start()

        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, Array(1...34))
        XCTAssertEqual(try g(rig), 34, "第一次短任务到期：G 停在最后一张已出结局的照片上")
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, Array(1...68))
        XCTAssertEqual(try g(rig), 68)
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, Array(1...100), "三次合起来恰好 1…100，每张一次")
        XCTAssertEqual(try g(rig), 100)
    }

    // MARK: §6-3 被杀后结果一致

    /// §6-3（传输途中被杀）：第 3 张传到一半进程没了 → 重启：G 停在第 2 张；第 3 张处于 TRANSFERRING 优先续传，然后 4…6；
    /// 每张恰好确认一次，G 走到末尾。
    func testS6_3_killedMidTransferResumesWithTheSameResult() async throws {
        let dir = TempDir(#function)
        let state = InboxState()
        let (rig, inbox) = try await makeRig(directory: dir, state: state)
        shoot(rig, inbox, [1, 2, 3, 4, 5, 6])
        rig.delivery.onStart.set { _ in if rig.delivery.requests.get().count == 3 { rig.delivery.hold.set(true) } }
        await rig.start()
        _ = await rig.engine.trigger(.mediaChange)
        await eventually("third delivery started") { rig.delivery.requests.get().count == 3 }
        await rig.engine.stopForDisconnect() // 进程被杀：在飞的那张没有结局
        XCTAssertEqual(try g(rig), 2, "G 停在最后一张已出结局的照片上")
        XCTAssertEqual(try rig.state(3), .transferring)

        let (rebooted, _) = try await makeRig(directory: dir, state: state, initialize: false)
        for p in rig.media.photos { rebooted.media.put(p) }
        await rebooted.start()
        await rebooted.trigger()

        XCTAssertEqual(rebooted.delivery.deliveredIds, [3, 4, 5, 6], "续传第 3 张，再从 seq > G 接着取")
        for n in 1...6 { XCTAssertEqual(try rebooted.state(n), .confirmed) }
        XCTAssertEqual(try g(rebooted), 6)
    }

    /// §6-3（提交之后、取下一张之前被杀）：第 3 张已出结局 → 重启从 seq > 3 接着取，1…3 不重传。
    func testS6_3_killedRightAfterACommitResumesAfterIt() async throws {
        let dir = TempDir(#function)
        let state = InboxState()
        let (rig, inbox) = try await makeRig(directory: dir, state: state)
        shoot(rig, inbox, [1, 2, 3, 4, 5, 6])
        rig.delivery.onStart.set { _ in if rig.delivery.requests.get().count == 3 { rig.lease.held.set(false) } }
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(try g(rig), 3)

        let (rebooted, _) = try await makeRig(directory: dir, state: state, initialize: false)
        for p in rig.media.photos { rebooted.media.put(p) }
        await rebooted.start()
        await rebooted.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds + rebooted.delivery.deliveredIds, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(try g(rebooted), 6)
    }

    /// §6-3（进箱之后、处理之前被杀）：已进箱的行和账本在同一个文件里，重启后照常从 seq > G 取到。
    func testS6_3_killedAfterIngestBeforeProcessing() async throws {
        let dir = TempDir(#function)
        let state = InboxState()
        let (rig, inbox) = try await makeRig(directory: dir, state: state)
        shoot(rig, inbox, [1, 2, 3])
        _ = try await inbox.changes(after: SeqInboxMedia.position(0), limit: 64) // 只进箱，不处理
        XCTAssertEqual(state.rowCount, 3)

        let (rebooted, _) = try await makeRig(directory: dir, state: state, initialize: false)
        for p in rig.media.photos { rebooted.media.put(p) }
        await rebooted.start()
        await rebooted.trigger()
        XCTAssertEqual(rebooted.delivery.deliveredIds, [1, 2, 3])
        XCTAssertEqual(try g(rebooted), 3)
    }

    // MARK: §6-5 查不到即跳过

    /// §6-5：新增之后、处理之前照片被删除：跳过，G 前进，后面的照片不受影响。
    /// 两种时机都覆盖：取件之前就删了（媒体源不返回它），以及取到之后、处理之前才删（lookup 返回 nil，引擎跳过）。
    func testS6_5_aPhotoDeletedBeforeProcessingIsSkippedAndGMovesOn() async throws {
        let (rig, inbox) = try await makeRig()
        shoot(rig, inbox, [1, 2, 3, 4])
        rig.media.remove(2) // 取件之前
        var removedOne = false
        inbox.afterChanges.set { batch in // 取到之后、处理之前
            if !removedOne, batch.first?.mediaId == mid(3) { removedOne = true; rig.media.remove(3) }
        }
        await rig.start()
        await rig.trigger()

        XCTAssertTrue(removedOne)
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 4])
        XCTAssertNil(try rig.current(2))
        XCTAssertNil(try rig.current(3), "查不到：不建行、不计失败")
        XCTAssertEqual(try g(rig), 4)
    }

    // MARK: §6-6 范围语义

    /// §6-6：范围缩小——范围外的照片被跳过，G 前进；范围再扩大后，触发 SCOPE_ADDED 由对账补回。
    func testS6_6_outOfScopePhotosAreSkippedAndScopeAddedBringsThemBack() async throws {
        let (rig, inbox) = try await makeRig()
        rig.photo(1, generation: 1)
        rig.photo(2, generation: 2, bucket: "B8")
        rig.photo(3, generation: 3)
        inbox.change([mid(1), mid(2), mid(3)])
        // 范围外的照片排在最后：媒体源要往后翻页、不能卡住
        rig.photo(4, generation: 4, bucket: "B8")
        inbox.change([mid(4)])
        await rig.start()
        await rig.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds, [1, 3])
        XCTAssertNil(try rig.current(2))
        XCTAssertEqual(try g(rig), 3, "G 越过范围外的 #2")
        XCTAssertFalse(try rig.store.scanState().dirty)

        rig.media.scope = ["B7", "B8"]
        await rig.trigger(.scopeAdded)
        XCTAssertEqual(Set(rig.delivery.deliveredIds), [1, 2, 3, 4], "SCOPE_ADDED 置脏扫描，对账补回 G 之前的范围外照片")
        XCTAssertEqual(confirmedCount(rig).values.max(), 1, "每张一次")
    }

    // MARK: §6-7 换电脑

    /// §6-7：换电脑——G 被清空后，重置为收件箱当前最大序号并把扫描置脏；旧照片（含收件箱里没处理的旧行）由对账处理，
    /// 之后进箱的照片走收件箱；同一台电脑重新配对时 G 保持不动。
    func testS6_7_changingDesktopsResetsGToTheTopSeqAndLeavesOldRowsToReconcile() async throws {
        let (rig, inbox) = try await makeRig()
        XCTAssertFalse(try rig.store.claimOwner("desk-a", idFloor: 0))
        shoot(rig, inbox, [1, 2])
        await rig.start()
        await rig.trigger()
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(try g(rig), 2)

        shoot(rig, inbox, [3])
        _ = try await inbox.changes(after: SeqInboxMedia.position(2), limit: 64) // #3 已进箱、还没处理
        XCTAssertTrue(try rig.store.claimOwner("desk-b", idFloor: 1_800_000_000_000))
        XCTAssertNil(try rig.store.discoveryState(), "换电脑清掉 G")
        shoot(rig, inbox, [4]) // 换电脑之后才进箱

        let before = rig.delivery.requests.get().count
        await rig.trigger()
        XCTAssertEqual(state(rig, after: before), [1, 2, 3, 4], "新电脑：对账把全部照片补上，每张一次")
        XCTAssertEqual(try g(rig), 4, "G 先重置到当时的最大序号 3；#4 进箱后已被对账处理，发现只推进 G")
        XCTAssertFalse(try rig.store.scanState().dirty)
        XCTAssertEqual(inbox.state.rowCount, 1, "重置时清掉了 seq <= 3 的旧行，只剩 #4 那行")

        shoot(rig, inbox, [5])
        let mark = rig.delivery.requests.get().count
        await rig.trigger()
        XCTAssertEqual(state(rig, after: mark), [5], "之后的新照片走收件箱")
        XCTAssertEqual(try g(rig), 5)

        XCTAssertFalse(try rig.store.claimOwner("desk-b", idFloor: 1_800_000_000_000), "同一台电脑重新配对不清账本")
        XCTAssertEqual(try g(rig), 5, "G 不动")
    }

    private func state(_ rig: Rig, after index: Int) -> [Int] { Array(rig.delivery.deliveredIds.dropFirst(index)).sorted() }

    // MARK: §6-9 令牌过期（I-06 的 iOS 变体）

    /// §6-9 / I-06（iOS 变体）：令牌失效时收件箱只重置自己的令牌，不抛错、G 不动；已进箱的照片照常往下取，
    /// 之后的新照片照常进箱；缺口里没进箱的照片由下一个对账轮补回（`preciseDiscovery = false`，每个对账轮都置脏扫描），不重传。
    func testS6_9_anExpiredTokenLeavesGAloneAndTheGapIsReconciled() async throws {
        let (rig, inbox) = try await makeRig()
        rig.media.precise.set(false)
        shoot(rig, inbox, [1, 2])
        _ = try await inbox.changes(after: SeqInboxMedia.position(0), limit: 64) // #1 #2 已进箱
        shoot(rig, inbox, [3])
        inbox.expireToken() // #3 落在缺口里：没进箱
        shoot(rig, inbox, [4]) // 令牌重置之后的新照片
        await rig.start()

        await rig.trigger(.mediaChange)
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 4], "不抛错：已进箱的与之后的新照片照常走收件箱")
        XCTAssertEqual(try g(rig), 3, "G 不重置：只沿收件箱序号前进")
        XCTAssertNil(try rig.current(3))
        XCTAssertFalse(try rig.store.scanState().dirty, "非对账轮不扫")

        await rig.trigger(.appForeground)
        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2, 4, 3], "对账轮把缺口里的 #3 补回，已确认的不重传")
        XCTAssertEqual(try rig.state(3), .confirmed)
        XCTAssertEqual(try g(rig), 3)
    }

    // MARK: §6-10 同一个 id 重复进箱

    /// §6-10：同一个 id 两次进箱（例如删除后恢复、id 不变）：只送达一次，G 越过两行。
    func testS6_10_theSameIdIngestedTwiceIsDeliveredOnce() async throws {
        let (rig, inbox) = try await makeRig()
        shoot(rig, inbox, [1])
        inbox.change([mid(1)])
        shoot(rig, inbox, [2])
        await rig.start()
        await rig.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds, [1, 2])
        XCTAssertEqual(try g(rig), 3)
    }

    // MARK: §6-11 只剩短任务窗口时遇到视频

    /// §6-11（#958）：只剩短任务窗口时遇到视频——建一条待传记录，G 前进，后面的照片照常处理。
    func testS6_11_aVideoUnderTheShortWindowIsLeftPendingAndGMovesOn() async throws {
        let (rig, inbox) = try await makeRig()
        rig.lease.photosOnlyFlag.set(true)
        shoot(rig, inbox, [1, 2, 3], video: [2])
        await rig.start()
        await rig.trigger()

        XCTAssertEqual(rig.delivery.deliveredIds, [1, 3])
        XCTAssertEqual(try rig.state(2), .pending)
        XCTAssertEqual(try rig.current(2)?.attempts, 0)
        XCTAssertEqual(try g(rig), 3, "G 越过视频，不挡后面的照片")
    }
}

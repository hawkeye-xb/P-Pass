import SwiftUI
@testable import PPass
import PPassCore
import UIKit
import XCTest

/// #1962 / #2106：英雄卡与 Android `HomeScreen.kt` 双端对齐的纯值测试及真实视图几何回归测试。
@MainActor
final class HeroCardTests: XCTestCase {
    private final class StubHeroEngine: BackupEngine {
        var stubFacts: FlowFacts
        init(facts: FlowFacts) { self.stubFacts = facts }
        func facts() -> FlowFacts { stubFacts }
        func observe(_ onChange: @escaping () -> Void) {}
        func pauseOrResume() async {}
        func wake() async {}
        func autoRule() -> Bool { true }
        func setAutoRule(_ on: Bool) throws {}
        func sendAllowedPhotos() async -> Int { 0 }
        func pickedSummary() -> PickedBatchSummary? { nil }
        func addPicked(_ items: [(fileName: String, mimeType: String, payload: PickedPayload)]) async -> Int { items.count }
        func retryFailed() async throws {}
        func remainingSnapshot() async throws -> RemainingSnapshot { throw FakeBackendError.demoHasNoLedger }
        func cancelRemaining(_ snapshot: RemainingSnapshot) async throws -> Int? { nil }
        func restoreSkipped() async throws {}
        func acknowledgeMissingSource() {}
        func notifyOnFailure() -> Bool { true }
        func setNotifyOnFailure(_ on: Bool) throws {}
        func notificationAuthorization() async -> NotificationAuthorization { .authorized }
        func requestNotificationAuthorization() async -> NotificationAuthorization { .authorized }
        @MainActor func openNotificationSettings() {}
        func onboardedCurrent() -> Bool { true }
        func finishOnboarding() throws {}
        func wifiOnly() -> Bool { true }
        func setWifiOnly(_ on: Bool) throws {}
        func autoBackup() -> Bool { true }
        func setAutoBackup(_ on: Bool) throws {}
        func backgroundCardDismissed() -> Bool { false }
        func dismissBackgroundCard() throws {}
        func pendingFullPhotoAccess() -> Bool { false }
        func setPendingFullPhotoAccess(_ pending: Bool) throws {}
        func backgroundRefresh() -> BackgroundRefreshAvailability { .available }
        func folderSourceCount() -> Int { 0 }
        func folderSources() async -> [FolderSourceInfo] { [] }
        func addFolderSource(at url: URL, displayName: String) async throws {}
        func reauthorizeFolderSource(id: String, at url: URL) async throws {}
        func removeFolderSource(id: String) throws {}
    }

    private func firstCollectionView(in root: UIView) -> UICollectionView? {
        if let cv = root as? UICollectionView { return cv }
        for sub in root.subviews {
            if let found = firstCollectionView(in: sub) { return found }
        }
        return nil
    }

    private func measureHeroLayout(
        app: AppModel,
        sizeCategory: ContentSizeCategory
    ) throws -> (cellHeight: CGFloat, frames: [String: CGRect]) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "宿主 App 必须提供可用的 UIWindowScene"
        )
        var measured: [String: CGRect] = [:]
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("PPassHeroLayoutMeasured"),
            object: nil,
            queue: .main
        ) { note in
            if let raw = note.userInfo?["frames"] as? [String: NSValue] {
                for (k, v) in raw {
                    measured[k] = v.cgRectValue
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let view = AnyView(
            List {
                HeroCard()
                    .environmentObject(app)
            }
            .ppList()
            .ppCardSpacing()
            .environment(\.sizeCategory, sizeCategory)
        )
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        let cv = try XCTUnwrap(firstCollectionView(in: host.view), "HeroCard 必须渲染在 List(UICollectionView) 内")
        cv.layoutIfNeeded()
        let cell = try XCTUnwrap(cv.cellForItem(at: IndexPath(item: 0, section: 0)), "HeroCard cell 未实例化")
        return (cell.frame.height, measured)
    }

    private func makeHeroApp(state: GlobalState, pending: Int, currentFile: String? = nil, bytesSent: Int64 = 0, totalBytes: Int64 = 0) -> AppModel {
        let fake = FakeBackend.make(.allSafe)
        let facts = FlowFacts(
            view: EngineSnapshot(
                state: state,
                pending: pending,
                doneThisRound: 11,
                currentFileName: currentFile,
                currentOrderId: currentFile == nil ? nil : 1,
                currentBytesSent: bytesSent,
                currentTotalBytes: totalBytes
            ),
            confirmed: 100,
            inScopeTotal: 100,
            lastSuccessAt: Int64(Date().timeIntervalSince1970 * 1000) - 42 * 60_000
        )
        let engine = StubHeroEngine(facts: facts)
        let backend = Backend(isDemo: true, timeline: fake.timeline, live: fake.live, media: fake.media, pairing: fake.pairing, engine: engine)
        return AppModel(backend: backend)
    }
    /// 反证：`showsFromTodayEmpty` 去掉 `since` 或 0/0 任一条件，对应断言红。
    func testShowsFromTodayEmptyOnlyForZeroTripletWithAStartDate() {
        let zero = BackupTriplet(n: 0, m: 0, lastSuccessAt: 0, confirmedRaw: 0)
        let nonZero = BackupTriplet(n: 1, m: 1, lastSuccessAt: 0, confirmedRaw: 1)
        let since = BackupSince.since(ms: 1_700_000_000_000)

        XCTAssertTrue(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: since), "0/0 + 从今天起")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: .all), "0/0 + 全部")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: zero, since: nil), "0/0 + 没存时间档")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .triplet, triplet: nonZero, since: since), "1/1 + 从今天起")
        XCTAssertFalse(HeroCard.showsFromTodayEmpty(render: .accessBlocked, triplet: zero, since: since), "非三元组")
    }

    /// 中英文词条都存在且不是 fallback key（L.s 缺 key 会断言失败 / 返回 key 本身）。
    func testFromTodayEmptyCopyExistsInBothLanguages() {
        for lang in ["en", "zh-Hans"] {
            guard let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                XCTFail("缺 \(lang).lproj")
                continue
            }
            let missing = "\u{1}__missing__"
            let value = bundle.localizedString(forKey: "auto_backup_from_today_empty", value: missing, table: nil)
            XCTAssertNotEqual(value, missing, "\(lang) 缺 auto_backup_from_today_empty")
            XCTAssertNotEqual(value, "auto_backup_from_today_empty", "\(lang) 是 fallback key")
            XCTAssertFalse(value.isEmpty, "\(lang) 词条为空")
        }
    }

    /// 紧凑描边次级按钮的样式与 Android 英雄卡 OutlinedButton 对齐：
    /// 高 40、圆角 14、1pt 描边 @40%、act 字色、15pt 粗体。
    func testCompactActionButtonStyleMatchesAndroid() {
        let style = HeroActionButtonStyleConfig.standard
        XCTAssertEqual(style.height, 40)
        XCTAssertEqual(style.cornerRadius, 14)
        XCTAssertEqual(style.borderWidth, 1)
        XCTAssertEqual(style.borderOpacity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(style.fontSize, 15)
        XCTAssertTrue(UIColor(style.contentColor).isEqual(UIColor(PPColor.act)), "文字颜色必须是 PPColor.act")

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(style.borderColor).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(a, 0.4, accuracy: 0.01, "描边是 act 的 40%")
    }

    /// 按钮组件确实按样式绘制：标题、动作都可传入（编译期契约 + 运行期构造不崩）。
    func testCompactActionButtonConstructsWithTitleAndAction() {
        var tapped = false
        let button = HeroCompactActionButton(title: L.s("auto_backup_blocked_action")) { tapped = true }
        XCTAssertEqual(button.title, L.s("auto_backup_blocked_action"))
        button.action()
        XCTAssertTrue(tapped)
    }

    /// #2082：英雄卡四档底色与分隔线颜色一一对应 tokens.json 语义色。
    func testHeroSurfaceToneColorsAndDividers() {
        XCTAssertEqual(HeroCard.surfaceBackground(.act), PPColor.actBg)
        XCTAssertEqual(HeroCard.dividerColor(.act), PPColor.act.opacity(0.18))
        XCTAssertEqual(HeroCard.surfaceBackground(.waiting), PPColor.waitingBg)
        XCTAssertEqual(HeroCard.dividerColor(.waiting), PPColor.waiting.opacity(0.18))
        XCTAssertEqual(HeroCard.surfaceBackground(.neutral), PPColor.linen)
        XCTAssertEqual(HeroCard.dividerColor(.neutral), PPColor.hairline)
        XCTAssertEqual(HeroCard.surfaceBackground(.safe), PPColor.safeBg)
        XCTAssertEqual(HeroCard.dividerColor(.safe), PPColor.safe.opacity(0.18))
    }

    /// #2082：上半区 lastLine 只显示最近成功，即使 k > 0 也不再拼接待备份张数（避免与下半区 state_pending 重复）。
    func testLastLineDoesNotAppendPendingCountWhenKIsPositive() {
        let withPending = BackupTriplet(n: 10, m: 4, lastSuccessAt: 1_700_000_000_000, confirmedRaw: 4)
        let zeroPending = BackupTriplet(n: 10, m: 10, lastSuccessAt: 1_700_000_000_000, confirmedRaw: 10)
        XCTAssertEqual(HeroCard.lastLine(withPending), HeroCard.lastLine(zeroPending))
        XCTAssertFalse(HeroCard.lastLine(withPending).contains("·"))
    }

    private func assertFrameContained(_ childName: String, _ child: CGRect, in container: CGRect,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(child.minX, container.minX - 0.5, "\(childName) minX(\(child.minX)) 超出进度行左边界(\(container.minX))", file: file, line: line)
        XCTAssertLessThanOrEqual(child.maxX, container.maxX + 0.5, "\(childName) maxX(\(child.maxX)) 超出进度行右边界(\(container.maxX))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(child.minY, container.minY - 0.5, "\(childName) minY(\(child.minY)) 超出进度行上边界(\(container.minY))", file: file, line: line)
        XCTAssertLessThanOrEqual(child.maxY, container.maxY + 0.5, "\(childName) maxY(\(child.maxY)) 超出进度行下边界(\(container.maxY))", file: file, line: line)
    }

    /// #2106：标准字号下空闲态（AllSafe / Pending）与忙碌态（Preparing / Sending）进度行及整卡高度一致，
    /// 1.5× 大字号下进度行自身自然撑高，且两行文字与进度条完整落在进度行区域内不裁剪。
    func testHeroProgressRowHeightIsStableAcrossIdleAndBusyStatesAndExpandsAt1_5x() throws {
        let safeApp = makeHeroApp(state: .idle, pending: 0)
        let pendingApp = makeHeroApp(state: .idle, pending: 20)
        let preparingApp = makeHeroApp(state: .running, pending: 20, currentFile: nil)
        let sendingApp = makeHeroApp(
            state: .running,
            pending: 20,
            currentFile: "IMG_4821.HEIC",
            bytesSent: 12_300_000,
            totalBytes: 45_600_000
        )

        XCTAssertEqual(HomeProjection.statusLine(safeApp.uiState, pendingK: safeApp.triplet?.k ?? 0), .allSafe)
        XCTAssertEqual(HomeProjection.statusLine(pendingApp.uiState, pendingK: pendingApp.triplet?.k ?? 0), .pending(20))
        XCTAssertEqual(preparingApp.uiState, .preparing)
        XCTAssertEqual(sendingApp.uiState, .sending(done: 12, total: 31, currentFile: "IMG_4821.HEIC"))

        let safe = try measureHeroLayout(app: safeApp, sizeCategory: .large)
        let pending = try measureHeroLayout(app: pendingApp, sizeCategory: .large)
        let preparing = try measureHeroLayout(app: preparingApp, sizeCategory: .large)
        let sending = try measureHeroLayout(app: sendingApp, sizeCategory: .large)

        XCTAssertEqual(safe.cellHeight, sending.cellHeight, accuracy: 1.0,
                       "AllSafe(\(safe.cellHeight)) 与 Sending(\(sending.cellHeight)) 英雄卡高度必须一致")
        XCTAssertEqual(pending.cellHeight, sending.cellHeight, accuracy: 1.0,
                       "Pending(\(pending.cellHeight)) 与 Sending(\(sending.cellHeight)) 英雄卡高度必须一致")
        XCTAssertEqual(preparing.cellHeight, sending.cellHeight, accuracy: 1.0,
                       "Preparing(\(preparing.cellHeight)) 与 Sending(\(sending.cellHeight)) 英雄卡高度必须一致")

        let safeRow = try XCTUnwrap(safe.frames["hero_progress_row"], "AllSafe 缺 hero_progress_row 测量框：\(safe.frames.keys)")
        let pendingRow = try XCTUnwrap(pending.frames["hero_progress_row"], "Pending 缺 hero_progress_row 测量框：\(pending.frames.keys)")
        let preparingRow = try XCTUnwrap(preparing.frames["hero_progress_row"], "Preparing 缺 hero_progress_row 测量框：\(preparing.frames.keys)")
        let sendingRow = try XCTUnwrap(sending.frames["hero_progress_row"], "Sending 缺 hero_progress_row 测量框：\(sending.frames.keys)")
        let line1_10x = try XCTUnwrap(sending.frames["hero_progress_line1"], "1.0× 缺 hero_progress_line1")
        let line2_10x = try XCTUnwrap(sending.frames["hero_progress_line2"], "1.0× 缺 hero_progress_line2")

        XCTAssertGreaterThanOrEqual(sendingRow.height, 55.5, "进度行最小高度须 >= 56pt（实际=\(sendingRow.height)）")
        XCTAssertEqual(safeRow.height, sendingRow.height, accuracy: 1.0, "AllSafe 与 Sending 进度行自身高度必须一致")
        XCTAssertEqual(pendingRow.height, sendingRow.height, accuracy: 1.0, "Pending 与 Sending 进度行自身高度必须一致")
        XCTAssertEqual(preparingRow.height, sendingRow.height, accuracy: 1.0, "Preparing 与 Sending 进度行自身高度必须一致")

        // 1.5× 动态字号下直接量测进度行自身及其内部两行文字、进度条边界
        let scale15Trait = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        let scaledBody = UIFontMetrics(forTextStyle: .body).scaledValue(for: PPSize.bodyMin, compatibleWith: scale15Trait)
        XCTAssertGreaterThanOrEqual(scaledBody, PPSize.bodyMin * 1.5, "测试档位须达到至少 1.5× 放大倍数")

        let sending15x = try measureHeroLayout(app: sendingApp, sizeCategory: .accessibilityMedium)
        let row15x = try XCTUnwrap(sending15x.frames["hero_progress_row"], "1.5× 缺 hero_progress_row")
        let line1_15x = try XCTUnwrap(sending15x.frames["hero_progress_line1"], "1.5× 缺 hero_progress_line1")
        let line2_15x = try XCTUnwrap(sending15x.frames["hero_progress_line2"], "1.5× 缺 hero_progress_line2")
        let bar_15x = try XCTUnwrap(sending15x.frames["hero_progress_bar"], "1.5× 缺 hero_progress_bar")

        XCTAssertGreaterThan(row15x.height, sendingRow.height + 4.0,
                             "1.5× 下进度行自身高度(\(row15x.height))必须严格大于 1.0×(\(sendingRow.height))")
        XCTAssertGreaterThan(line1_15x.height, line1_10x.height * 1.35,
                             "1.5× 下第一行文字高度(\(line1_15x.height))须按动态字号放大，不能被压缩")
        XCTAssertGreaterThan(line2_15x.height, line2_10x.height * 1.35,
                             "1.5× 下第二行文字高度(\(line2_15x.height))须按动态字号放大，不能被压缩")
        assertFrameContained("line1", line1_15x, in: row15x)
        assertFrameContained("line2", line2_15x, in: row15x)
        assertFrameContained("bar", bar_15x, in: row15x)
        XCTAssertLessThanOrEqual(line1_15x.maxY, line2_15x.minY + 0.5, "1.5× 下两行文字不能重叠")
        XCTAssertLessThanOrEqual(line2_15x.maxY, bar_15x.minY + 0.5, "1.5× 下第二行文字与进度条不能重叠")
        XCTAssertGreaterThanOrEqual(bar_15x.height, 5.5, "1.5× 下进度条高度必须保持 >= 6pt")
    }
}

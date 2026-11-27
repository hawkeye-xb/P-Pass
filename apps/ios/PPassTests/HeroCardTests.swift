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

    private func measureHeroCardCellHeight(
        app: AppModel,
        sizeCategory: ContentSizeCategory
    ) throws -> CGFloat {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "宿主 App 必须提供可用的 UIWindowScene"
        )
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
        return cell.frame.height
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

    /// #2106：标准字号下空闲态（AllSafe / Pending）与忙碌态（Preparing / Sending）底部高度一致，
    /// 1.5× 大字号下可自然撑高而不截断。
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

        let safeHeight = try measureHeroCardCellHeight(app: safeApp, sizeCategory: .large)
        let pendingHeight = try measureHeroCardCellHeight(app: pendingApp, sizeCategory: .large)
        let preparingHeight = try measureHeroCardCellHeight(app: preparingApp, sizeCategory: .large)
        let sendingHeight = try measureHeroCardCellHeight(app: sendingApp, sizeCategory: .large)

        XCTAssertEqual(safeHeight, sendingHeight, accuracy: 1.0,
                       "AllSafe(\(safeHeight)) 与 Sending(\(sendingHeight)) 英雄卡高度必须一致")
        XCTAssertEqual(pendingHeight, sendingHeight, accuracy: 1.0,
                       "Pending(\(pendingHeight)) 与 Sending(\(sendingHeight)) 英雄卡高度必须一致")
        XCTAssertEqual(preparingHeight, sendingHeight, accuracy: 1.0,
                       "Preparing(\(preparingHeight)) 与 Sending(\(sendingHeight)) 英雄卡高度必须一致")

        // 1.5× 动态字号下自然撑高，不截断
        let scale15Trait = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        let scaledBody = UIFontMetrics(forTextStyle: .body).scaledValue(for: PPSize.bodyMin, compatibleWith: scale15Trait)
        XCTAssertGreaterThanOrEqual(scaledBody, PPSize.bodyMin * 1.5, "测试档位须达到至少 1.5× 放大倍数")

        let safe15xHeight = try measureHeroCardCellHeight(app: safeApp, sizeCategory: .accessibilityMedium)
        let sending15xHeight = try measureHeroCardCellHeight(app: sendingApp, sizeCategory: .accessibilityMedium)
        XCTAssertGreaterThan(
            safe15xHeight,
            safeHeight,
            "1.5× 大字号下空闲态英雄卡(\(safe15xHeight))应高于标准字号(\(safeHeight))，字体缩放真实生效"
        )
        XCTAssertGreaterThan(
            sending15xHeight,
            sendingHeight,
            "1.5× 大字号下忙碌态英雄卡(\(sending15xHeight))应高于标准字号(\(sendingHeight))，不能固定死高度导致截断"
        )
    }
}

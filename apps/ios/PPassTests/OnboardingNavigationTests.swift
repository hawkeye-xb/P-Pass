@testable import PPassCore
import XCTest
@testable import PPass

/// 手动输入配对串的「返回」：从哪儿进来就回哪儿（Android ScanScreen `leaveManual`）。
/// #1323 onboarding 闸门：冷启动首屏、决定页主按钮的落点（纯函数，对位 Android `launchScreen` / `decisionLanding`）。
final class OnboardingNavigationTests: XCTestCase {
    func testManualFromScanGoesBackToScan() {
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: true), .scan)
    }

    func testManualFromWelcomeGoesBackToWelcome() {
        XCTAssertEqual(OnboardingFlow.manualBackTarget(fromScan: false), .welcome)
    }

    // MARK: #1324 照片页引导位（ADR 结论 6、7，对位 Android PhotosGuideTest）

    private func facts(scopeOn: Bool = false, firstUploaded: Bool = false, backgroundOn: Bool = false, finished: Bool = false) -> GuideFacts {
        GuideFacts(scopeOn: scopeOn, firstUploaded: firstUploaded, backgroundOn: backgroundOn, finished: finished)
    }

    /// 按状态现算，同一时间最多一张（返回值只有一个）。
    /// 反证：去掉「已开启不出现」判断（后台开了仍出第二步），最后一条红。
    func testGuideFollowsTheCurrentSwitches() {
        XCTAssertEqual(AppModel.photosGuideOf(facts()), .enableScope, "没开范围备份 → 第一步")
        XCTAssertEqual(AppModel.photosGuideOf(facts(firstUploaded: true)), .enableScope, "单张传过也一样先引导开范围备份")
        XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: true)), .none, "范围已开、还没传成功 → 不出卡")
        XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: true, firstUploaded: true)), .enableBackground, "第一张已传、后台没开 → 第二步")
        XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: true, firstUploaded: true, backgroundOn: true)), .none, "都开了 → 结束")
    }

    /// 起点按现状：决定页直接选了范围备份的，不出「开启范围备份」，第一张成功后直接出后台备份卡。
    /// 反证：把起点写死为第一步（没走过第一步就一直给第一步），第一条红。
    func testStartingPointIsTheCurrentStateNotStepOne() {
        let decidedScope = facts(scopeOn: true)
        XCTAssertNotEqual(AppModel.photosGuideOf(decidedScope), .enableScope)
        XCTAssertEqual(AppModel.photosGuideOf(GuideFacts(scopeOn: true, firstUploaded: true, backgroundOn: false, finished: false)), .enableBackground)
    }

    /// 点过 × 不再出卡（开关怎么变都一样）；标记按手机记：断开清单里这一行是 KEEP（断开、配对失效、换电脑都走断开清单）。
    /// 反证：换电脑时清掉标记（断开清单把 backgroundBackupOffer 改成 clear），最后一条红。
    func testDismissalEndsTheGuideAndSurvivesDisconnectAndANewDesktop() {
        for scope in [false, true] { for up in [false, true] { for bg in [false, true] {
            XCTAssertEqual(AppModel.photosGuideOf(facts(scopeOn: scope, firstUploaded: up, backgroundOn: bg, finished: true)), .none, "\(scope)/\(up)/\(bg)")
        } } }
        XCTAssertEqual(DisconnectState.backgroundBackupOffer.disposition, .keep)
        XCTAssertEqual(DisconnectState.backgroundBackupOffer.path, BackgroundBackupOfferPrefs.fileName)
    }

    /// 范围内无照片是状态提示：范围开着且一张都没有才说；不受 ×；有第一张就不说；没数出来不说。
    /// 反证：提示也看 ×（点过 × 就不说），第二条红。
    func testScopeEmptyHintIsAStatusLineNotAGuide() {
        XCTAssertTrue(AppModel.scopeEmptyHintShown(facts(scopeOn: true), inScope: 0))
        XCTAssertTrue(AppModel.scopeEmptyHintShown(facts(scopeOn: true, finished: true), inScope: 0), "不受 × 影响")
        XCTAssertFalse(AppModel.scopeEmptyHintShown(facts(scopeOn: true), inScope: 1), "有了第一张就不说")
        XCTAssertFalse(AppModel.scopeEmptyHintShown(facts(), inScope: 0), "范围备份没开不说（那是引导位的事）")
        XCTAssertFalse(AppModel.scopeEmptyHintShown(facts(scopeOn: true), inScope: nil), "还没数出来不说")
    }

    // MARK: #1323 判断 B：冷启动只看记录，不看范围

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// 冷启动的首屏：真实的记录文件与这台电脑的范围文件，经 `LiveBackend.onboardedForLaunch`（App 冷启动用的同一个函数）。
    /// 四种：无配对 → 欢迎页；有配对无记录（含决定页被杀）→ 决定页；有记录有范围 → 照片页；有记录无范围（单张备份）→ 照片页。
    /// 反证：`onboardedForLaunch` 改用完整判据（`knownDesktopCheck`：有记录 && 范围非空），「有记录无范围」红。
    func testLaunchPhaseLooksAtTheRecordOnly() throws {
        let dir = try tempDir()
        let store = OnboardedDesktopsStore(directory: dir)
        func launch(_ node: String?) -> AppModel.Phase {
            let pairing: PairingStatus = node == nil ? .notPaired : .paired(desktopName: "Mac")
            return AppModel.launchPhase(pairing, onboarded: LiveBackend.onboardedForLaunch(store, daemonNodeId: node))
        }
        XCTAssertEqual(launch(nil), .onboarding, "无配对 → 欢迎页")
        XCTAssertEqual(launch("node-new"), .decision, "有配对、这台没有记录 → 决定页")

        try store.markOnboarded("node-scope")
        try BackupScopeStore(directory: dir, daemonNodeId: "node-scope").saveScope(selected: ["a"], allCurrent: ["a"])
        XCTAssertEqual(launch("node-scope"), .main, "有记录有范围 → 照片页")

        try store.markOnboarded("node-pick") // 决定页选了单张备份：有记录、范围为空
        XCTAssertEqual(launch("node-pick"), .main, "有记录无范围 → 照片页（不能每次打开都被拦进决定页）")
    }

    /// 配对失效：照片页才有「重新连接」红卡，决定页没有出路——不管有没有记录都进照片页。
    func testLostPairingLaunchesIntoMainForTheReconnectCard() {
        XCTAssertEqual(AppModel.launchPhase(.lost(desktopName: "Mac"), onboarded: false), .main)
        XCTAssertEqual(AppModel.launchPhase(.lost(desktopName: "Mac"), onboarded: true), .main)
    }

    /// 决定页主按钮「选择备份范围」在照片权限框之后：全部允许 → 选范围页；部分 / 拒绝 → 系统选图（ADR 结论 5）。
    func testDecisionLandingByPhotoAccess() {
        XCTAssertEqual(AppModel.decisionLanding(.full), .chooseScope)
        XCTAssertEqual(AppModel.decisionLanding(.partial), .registerAllowed, "部分允许：系统已弹过选照片页，不再弹 App 的选图器")
        XCTAssertEqual(AppModel.decisionLanding(.none), .pickPhotos)
    }

    /// 产品负责人 2026-11-04：部分照片权限下不让系统在 App 回前台 / 首次读相册时自动弹「选择更多照片」——
    /// 苹果标准做法是 Info.plist 的 PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES。反证：删掉这个键，本条红。
    func testLimitedAccessAutoAlertIsSuppressed() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "PHPhotoLibraryPreventAutomaticLimitedAccessAlert") as? Bool, true)
    }

    /// 决定页小字与部分权限时引导卡正文用同一句路径说明（iOS 独有文案，按苹果官方「隐私与安全性 › 照片」）。
    func testChangeLaterHintIsTheOfficialPathInBothScreens() throws {
        let hint = L.s("photo_access_change_later_hint")
        XCTAssertNotEqual(hint, "photo_access_change_later_hint", "词条要在 IOS.strings 里")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let decision = try String(contentsOf: root.appendingPathComponent("PPass/Home/DecisionScreen.swift"), encoding: .utf8)
        let photos = try String(contentsOf: root.appendingPathComponent("PPass/Photos/PhotosScreen.swift"), encoding: .utf8)
        XCTAssertTrue(decision.contains("L.s(\"photo_access_change_later_hint\")"))
        XCTAssertTrue(photos.contains("L.s(\"photo_access_change_later_hint\")"))
        for lang in ["zh-Hans", "en"] {
            let strings = try String(contentsOf: root.appendingPathComponent("PPass/Resources/\(lang).lproj/IOS.strings"), encoding: .utf8)
            XCTAssertTrue(strings.contains("\"photo_access_change_later_hint\""), lang)
        }
        let zh = try String(contentsOf: root.appendingPathComponent("PPass/Resources/zh-Hans.lproj/IOS.strings"), encoding: .utf8)
        XCTAssertTrue(zh.contains("设置 › 隐私与安全性 › 照片 › P-Pass") && zh.contains("完全访问"))
    }
}

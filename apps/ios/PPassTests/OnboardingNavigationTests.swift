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
        XCTAssertEqual(AppModel.decisionLanding(.partial), .pickPhotos)
        XCTAssertEqual(AppModel.decisionLanding(.none), .pickPhotos)
    }
}

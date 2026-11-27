@testable import PPassCore
import SwiftUI
import UIKit
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

    func testDecisionProvidesSeparatePhotoAndFileEntries() throws {
        let source = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Home/DecisionScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("title: L.s(\"pick_from_photos_label\"), action: app.decisionPickPhotos"))
        XCTAssertTrue(source.contains("title: L.s(\"pick_from_files_label\"), action: app.decisionPickFiles"))
    }

    /// #1945：决定页单次传输独立卡片使用品牌圆角 PPRadius.card、1pt PPColor.border 描边、PPDivider()、
    /// PPUI.Layout.rowMinHeight 与 16pt 水平内边距，不再硬编码 cornerRadius: 12 或裸 Divider()。
    /// 反证：回退 DecisionScreen.swift 到旧写法，本条判红。
    func testDecisionSingleTransferCardFollowsDesignTokens() throws {
        let source = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Home/DecisionScreen.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("PPRadius.card"), "决定页单次传输卡片圆角须使用 PPRadius.card")
        XCTAssertTrue(source.contains(".strokeBorder(PPColor.border, lineWidth: 1)"), "决定页单次传输卡片须带 1pt PPColor.border 描边")
        XCTAssertTrue(source.contains("PPDivider().padding(.leading, 16)"), "决定页单次传输卡片分割线须使用 PPDivider().padding(.leading, 16)")
        XCTAssertTrue(source.contains("PPUI.Layout.rowMinHeight"), "决定页单次传输行高须使用 PPUI.Layout.rowMinHeight")
        XCTAssertEqual(SingleTransferSelectionRow(title: "x", action: {}).minimumHeight, PPUI.Layout.rowMinHeight)
        XCTAssertEqual(SingleTransferSelectionRow(title: "x", action: {}).disclosureSymbol, "chevron.right")
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"), "决定页单次传输卡片须设置 .buttonStyle(.plain)")
        XCTAssertFalse(source.contains("cornerRadius: 12"), "决定页单次传输卡片不得硬编码 cornerRadius: 12")
        XCTAssertNil(source.range(of: #"\bDivider\(\)"#, options: .regularExpression), "决定页单次传输卡片不得使用裸 Divider()")
    }

    /// 产品负责人 2026-11-04：部分照片权限下不让系统在 App 回前台 / 首次读相册时自动弹「选择更多照片」——
    /// 苹果标准做法是 Info.plist 的 PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES。反证：删掉这个键，本条红。
    func testLimitedAccessAutoAlertIsSuppressed() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "PHPhotoLibraryPreventAutomaticLimitedAccessAlert") as? Bool, true)
    }

    /// 两条失败通知的指路是同一句话（产品负责人 11-04 定「可随时在…」）。
    func testChangeLaterHintIsTheOfficialPathInNotifications() throws {
        let zh = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings"), encoding: .utf8)
        let en = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Resources/en.lproj/IOS.strings"), encoding: .utf8)
        let zhExpected = "可随时在「设置 › 隐私与安全性 › 照片 › P-Pass」改为「完全访问」。"
        let enExpected = "You can change it to “Full Access” anytime in Settings › Privacy & Security › Photos › P-Pass."
        for key in ["notif_media_partial_body", "notif_media_none_body"] {
            let lineZh = zh.components(separatedBy: "\n").first { $0.hasPrefix("\"\(key)\"") } ?? ""
            XCTAssertTrue(lineZh.contains(zhExpected), "zh \(key)")
            let lineEn = en.components(separatedBy: "\n").first { $0.hasPrefix("\"\(key)\"") } ?? ""
            XCTAssertTrue(lineEn.contains(enExpected), "en \(key)")
        }
    }

    /// #1964：扫码页首次申请相机权限被拒时自动去手动输入页（对位 Android），之前拒过则停在说明页（仍有底部链接）。
    /// 反证：把 `.task` 里的 `onManual()` 去掉，本条红。
    func testScanScreenRoutesAFreshCameraDenialToManualEntry() throws {
        let scan = try String(contentsOf: RepoPaths.root.appendingPathComponent("apps/ios/PPass/Pairing/ScanScreen.swift"), encoding: .utf8)
        XCTAssertTrue(scan.contains("deniedOnFirstAsk"), "首次拒绝要单独分出来")
        XCTAssertTrue(scan.contains("onManual()"), "首次拒绝 → 自动去手动输入页")
    }

    /// 决定页标题下一行说明照片传到哪台电脑（对位 Android decision_destination）；没有电脑名时退回默认叫法。
    func testDecisionPageSaysWherePhotosGo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let decision = try String(contentsOf: root.appendingPathComponent("PPass/Home/DecisionScreen.swift"), encoding: .utf8)
        XCTAssertTrue(decision.contains("L.f(\"decision_destination\", computerName)"))
        XCTAssertTrue(decision.contains("return L.s(\"storage_device_default\")"))
        XCTAssertNotEqual(L.s("decision_destination"), "decision_destination")
    }

    func testWelcomeDesktopLinkLocalizedInBothLanguages() throws {
        let en = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zh = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(L.s("welcome_desktop_link", bundle: en), "No desktop app yet? Get the link")
        XCTAssertEqual(L.s("welcome_desktop_link", bundle: zh), "还没装电脑端？获取下载链接")
        XCTAssertEqual(L.s("scan_manual_link", bundle: en), "Can't scan? Pair manually")
        XCTAssertEqual(L.s("scan_manual_link", bundle: zh), "无法扫码？手动配对")
        XCTAssertEqual(L.s("welcome_scan", bundle: en), "Scan to connect to a computer")
        XCTAssertEqual(L.s("welcome_scan", bundle: zh), "扫码连接电脑")
    }

    func testWelcomeHierarchyTokensWeakenFooterAndGroupManualLink() {
        XCTAssertEqual(WelcomeScreen.manualLinkColor, PPColor.ink60)
        XCTAssertEqual(WelcomeScreen.manualLinkWeight, .bold)
        XCTAssertTrue((6 ... 8).contains(WelcomeScreen.manualLinkTopPadding))
        XCTAssertEqual(WelcomeScreen.desktopLinkColor, PPColor.ink40)
        XCTAssertEqual(WelcomeScreen.desktopLinkWeight, .regular)
        XCTAssertGreaterThanOrEqual(WelcomeScreen.desktopLinkMinSpacer, 28)
    }

    @MainActor
    private func hostWelcomeScreen(
        bundle: Bundle,
        sizeCategory: ContentSizeCategory,
        viewportHeight: CGFloat = 852,
        onScan: @escaping () -> Void = {},
        onManual: @escaping () -> Void = {}
    ) throws -> (window: UIWindow, host: UIHostingController<AnyView>, scrollView: UIScrollView, frames: WelcomeMeasuredFrames, screen: WelcomeScreen) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "宿主 App 必须提供可用的 UIWindowScene"
        )
        var measured = WelcomeMeasuredFrames()
        let screen = WelcomeScreen(bundle: bundle, onScan: onScan, onManual: onManual)
        let view = AnyView(
            screen
                .environment(\.sizeCategory, sizeCategory)
                .onPreferenceChange(WelcomeFramePreferenceKey.self) { measured = $0 }
        )
        let host = UIHostingController(rootView: view)
        host.additionalSafeAreaInsets = .zero
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: viewportHeight)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let sv = try XCTUnwrap(firstScrollView(in: host.view), "WelcomeScreen 必须基于 ScrollView 渲染")
        return (window, host, sv, measured, screen)
    }

    private func firstScrollView(in root: UIView) -> UIScrollView? {
        if let sv = root as? UIScrollView { return sv }
        for sub in root.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private struct WelcomeControls {
        var scanButton: PPButton?
        var manualAction: (@MainActor () -> Void)?
        var manualLabelFound = false
        var shareURLs: [URL] = []
        var shareLabelFound = false
    }

    private func inspectWelcomeControls(in root: Any, expectedManual: String, expectedDesktop: String) -> WelcomeControls {
        var found = WelcomeControls()
        func containsText(_ value: Any, _ target: String) -> Bool {
            if let s = value as? String, s == target { return true }
            if let key = value as? LocalizedStringKey {
                let m = Mirror(reflecting: key)
                if let k = m.children.first(where: { $0.label == "key" })?.value as? String, k == target { return true }
            }
            for child in Mirror(reflecting: value).children {
                if containsText(child.value, target) { return true }
            }
            return false
        }
        func walk(_ value: Any) {
            if let pp = value as? PPButton {
                found.scanButton = pp
                return
            }
            let typeName = String(describing: type(of: value))
            let mirror = Mirror(reflecting: value)
            if typeName.hasPrefix("Button<") {
                if containsText(value, expectedManual),
                   let actionObj = mirror.children.first(where: { $0.label == "action" })?.value {
                    let closureVal = Mirror(reflecting: actionObj).children.first(where: { $0.label == "closure" })?.value
                    if let fn = closureVal as? (@MainActor () -> Void) {
                        found.manualAction = fn
                        found.manualLabelFound = true
                    } else if let fn = closureVal as? (() -> Void) {
                        found.manualAction = { fn() }
                        found.manualLabelFound = true
                    }
                }
                return
            }
            if typeName.hasPrefix("ShareLink<") {
                if containsText(value, expectedDesktop) {
                    found.shareLabelFound = true
                }
                if let items = mirror.children.first(where: { $0.label == "items" })?.value {
                    for itemChild in Mirror(reflecting: items).children {
                        if let url = itemChild.value as? URL {
                            found.shareURLs.append(url)
                        }
                    }
                }
                return
            }
            for child in mirror.children {
                walk(child.value)
            }
        }
        walk(root)
        return found
    }

    @MainActor
    func testWelcomeLayoutHierarchyScrollingAndInteractionsInBothLanguages() throws {
        XCTAssertEqual(OnboardingFlow.desktopDownloadURL, URL(string: "https://p-pass.hawkeye-xb.com"))
        XCTAssertEqual(OnboardingFlow.welcomeTarget(.scan), .scan)
        XCTAssertEqual(OnboardingFlow.welcomeTarget(.manual), .manual(fromScan: false))

        // 1.5× 动态字号下，body(17pt) 至少放大至 25.5pt（.accessibilityMedium 实测 >= 1.5×）。
        let scale15Trait = UITraitCollection(preferredContentSizeCategory: .accessibilityMedium)
        let scaledBody = UIFontMetrics(forTextStyle: .body).scaledValue(for: PPSize.bodyMin, compatibleWith: scale15Trait)
        XCTAssertGreaterThanOrEqual(scaledBody, PPSize.bodyMin * 1.5)

        let enBundle = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let zhBundle = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))

        for (lang, bundle) in [("en", enBundle), ("zh-Hans", zhBundle)] {
            var scanTaps = 0
            var manualTaps = 0
            let (win, _, baseScroll, baseFrames, screen) = try hostWelcomeScreen(
                bundle: bundle,
                sizeCategory: .large,
                onScan: { scanTaps += 1 },
                onManual: { manualTaps += 1 }
            )
            defer { win.isHidden = true }

            let scanTitle = L.s("welcome_scan", bundle: bundle)
            let manualTitle = L.s("scan_manual_link", bundle: bundle)
            let desktopTitle = L.s("welcome_desktop_link", bundle: bundle)

            let controls = inspectWelcomeControls(in: screen.welcomeContent(minHeight: 852), expectedManual: manualTitle, expectedDesktop: desktopTitle)
            let scanBtn = try XCTUnwrap(controls.scanButton, "\(lang): 缺少主按钮")
            XCTAssertEqual(scanBtn.title, scanTitle)
            let manualAction = try XCTUnwrap(controls.manualAction, "\(lang): 缺少无法扫码按钮动作")
            XCTAssertTrue(controls.manualLabelFound, "\(lang): 无法扫码文案不匹配")
            XCTAssertTrue(controls.shareLabelFound, "\(lang): 电脑端下载分享链接文案不匹配")
            XCTAssertEqual(controls.shareURLs, [OnboardingFlow.desktopDownloadURL], "\(lang): ShareLink 须绑定电脑端下载链接")

            scanBtn.action()
            manualAction()
            XCTAssertEqual(scanTaps, 1, "\(lang): 点击主按钮须触发 onScan")
            XCTAssertEqual(manualTaps, 1, "\(lang): 点击无法扫码须触发 onManual")

            let scanFrame = try XCTUnwrap(baseFrames.scan, "\(lang): 缺少主按钮布局框")
            let manualFrame = try XCTUnwrap(baseFrames.manual, "\(lang): 缺少无法扫码布局框")
            let desktopFrame = try XCTUnwrap(baseFrames.desktop, "\(lang): 缺少电脑端下载链接布局框")

            XCTAssertGreaterThanOrEqual(scanFrame.height, 64, "\(lang): 主按钮高度须 >= 64pt")
            XCTAssertGreaterThanOrEqual(manualFrame.height, 44, "\(lang): 无法扫码触摸高度须 >= 44pt")
            XCTAssertGreaterThanOrEqual(desktopFrame.height, 44, "\(lang): 电脑端下载链接触摸高度须 >= 44pt")
            XCTAssertLessThanOrEqual(scanFrame.maxX, 393)
            XCTAssertLessThanOrEqual(manualFrame.maxX, 393)
            XCTAssertLessThanOrEqual(desktopFrame.maxX, 393)

            let manualGap = manualFrame.minY - scanFrame.maxY
            let footerGap = desktopFrame.minY - manualFrame.maxY
            XCTAssertGreaterThanOrEqual(manualGap, 4, "\(lang): 主按钮与无法扫码不能重叠")
            XCTAssertLessThanOrEqual(manualGap, 10, "\(lang): 无法扫码须紧贴主按钮（实际间距 \(manualGap)）")
            XCTAssertGreaterThanOrEqual(footerGap, 28, "\(lang): 页脚链接与配对操作组留白须 >= 28pt（实际 \(footerGap)）")
            XCTAssertGreaterThan(footerGap, manualGap * 2, "\(lang): 页脚留白须明显大于操作组内间距")
            XCTAssertEqual(
                desktopFrame.maxY,
                baseScroll.contentSize.height - 32,
                accuracy: 2,
                "\(lang): 页脚链接应沉至内容区最底部（desktopMaxY=\(desktopFrame.maxY), contentH=\(baseScroll.contentSize.height)）"
            )

            // 1.5×（小屏 667pt）及最大字号（852pt）下整屏可滚、不截断、不重叠、按钮仍可触发
            for (largeSize, viewportH) in [
                (ContentSizeCategory.accessibilityMedium, CGFloat(667)),
                (ContentSizeCategory.accessibilityExtraExtraExtraLarge, CGFloat(852)),
            ] {
                var lgScanTaps = 0
                var lgManualTaps = 0
                let (lgWin, _, lgScroll, lgFrames, lgScreen) = try hostWelcomeScreen(
                    bundle: bundle,
                    sizeCategory: largeSize,
                    viewportHeight: viewportH,
                    onScan: { lgScanTaps += 1 },
                    onManual: { lgManualTaps += 1 }
                )
                defer { lgWin.isHidden = true }

                let visibleHeight = lgScroll.bounds.height - lgScroll.adjustedContentInset.top - lgScroll.adjustedContentInset.bottom
                XCTAssertGreaterThan(
                    lgScroll.contentSize.height,
                    visibleHeight,
                    "\(lang) \(largeSize)@\(viewportH): 大字号下内容超出视口并可纵向滚动（content=\(lgScroll.contentSize.height), visible=\(visibleHeight)）"
                )

                let lgScan = try XCTUnwrap(lgFrames.scan)
                let lgManual = try XCTUnwrap(lgFrames.manual)
                let lgDesktop = try XCTUnwrap(lgFrames.desktop)

                XCTAssertGreaterThanOrEqual(lgScan.height, 64)
                XCTAssertGreaterThanOrEqual(lgManual.height, 44)
                XCTAssertGreaterThanOrEqual(lgDesktop.height, 44)
                XCTAssertLessThanOrEqual(lgScan.maxY, lgManual.minY)
                XCTAssertGreaterThanOrEqual(
                    lgDesktop.minY - lgManual.maxY,
                    28,
                    "\(lang) \(largeSize)@\(viewportH): 大字号滚动时页脚链接仍须保底留白 >= 28pt"
                )

                let lgControls = inspectWelcomeControls(in: lgScreen.welcomeContent(minHeight: viewportH), expectedManual: manualTitle, expectedDesktop: desktopTitle)
                try XCTUnwrap(lgControls.scanButton).action()
                try XCTUnwrap(lgControls.manualAction)()
                XCTAssertEqual(lgScanTaps, 1)
                XCTAssertEqual(lgManualTaps, 1)
            }
        }
    }

    @MainActor
    func testOnboardingFlowWelcomeButtonsWireIntoScanAndManualSteps() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "宿主 App 必须提供可用的 UIWindowScene"
        )
        let app = AppModel(backend: FakeBackend.make(.notPaired))
        let flowModel = OnboardingFlow.FlowModel()
        let flow = OnboardingFlow(flowModel: flowModel)
        let host = UIHostingController(rootView: flow.environmentObject(app))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertEqual(flowModel.step, .welcome)
        let welcomeScreen = OnboardingFlow.makeWelcomeScreen(flowModel: flowModel)
        let controls = inspectWelcomeControls(
            in: welcomeScreen.welcomeContent(minHeight: 852),
            expectedManual: L.s("scan_manual_link"),
            expectedDesktop: L.s("welcome_desktop_link")
        )
        try XCTUnwrap(controls.scanButton).action()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(flowModel.step, .scan, "欢迎页主按钮必须把 OnboardingFlow 切到 .scan")

        flowModel.step = .welcome
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try XCTUnwrap(controls.manualAction)()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(flowModel.step, .manual(fromScan: false), "无法扫码链接必须把 OnboardingFlow 切到 .manual(fromScan: false)")
    }
}

/// #1964：被电脑端移除配对之后的一次性说明（对位 Android `PairingRemovedNoticeStore`）；
/// 相机已授权时「重新连接」直达扫码页（对位 Android #355）。
@MainActor
final class PairingRemovedNoticeAndStartOverTests: XCTestCase {
    private func fake(_ scenario: FakeScenario) -> (Backend, FakePairingRemovedNotice) {
        let backend = FakeBackend.make(scenario)
        return (backend, backend.pairingRemovedNotice as! FakePairingRemovedNotice)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), what)
    }

    /// 未配对 + 有一条待说明的移除 → 弹一次；点「知道了」清标记，不再弹。
    /// 反证：`refresh()` 不读 `pairingRemovedNotice.pending()`，第一条红；`dismiss` 不清标记，第三条红。
    func testRemovedNoticeShowsInTheUnpairedPageAndClearsOnDismiss() {
        let (backend, notice) = fake(.notPaired)
        notice.pendingFlag = true
        let app = AppModel(backend: backend)
        XCTAssertTrue(app.showPairingRemovedNotice, "被移除的配对要在未配对页说明一次")
        app.dismissPairingRemovedNotice()
        XCTAssertFalse(app.showPairingRemovedNotice)
        XCTAssertFalse(notice.pendingFlag, "确认后清标记，不再弹")
    }

    /// 已经重新配对：残留标记顺手清掉，不再说明。
    /// 反证：`refresh()` 在已配对时不 `dismiss`，第二条红。
    func testStaleNoticeIsClearedOncePaired() {
        let (backend, notice) = fake(.normal)
        notice.pendingFlag = true
        let app = AppModel(backend: backend)
        XCTAssertFalse(app.showPairingRemovedNotice, "已配对不说明")
        XCTAssertFalse(notice.pendingFlag, "残留标记顺手清掉")
    }

    /// 相机已授权：配对失效卡点「重新连接」直达扫码页，不停在欢迎页。
    /// 反证：`startOver()` 不置 `resumeToScan`，第二条红。
    func testStartOverJumpsStraightToScanWhenCameraIsAuthorized() async {
        let (backend, _) = fake(.lost)
        let app = AppModel(backend: backend)
        app.cameraAuthorized = { true }
        app.startOver()
        await waitUntil("startOver 清本地后回欢迎页") { app.phase == .onboarding }
        XCTAssertTrue(app.resumeToScan, "相机已授权 → 直达扫码页")
        app.consumeResumeToScan()
        XCTAssertFalse(app.resumeToScan, "只消费一次")
    }

    /// 相机没授权：照常停在欢迎页（底部仍有「手动输入」的退路）。
    func testStartOverStaysOnWelcomeWhenCameraIsNotAuthorized() async {
        let (backend, _) = fake(.lost)
        let app = AppModel(backend: backend)
        app.cameraAuthorized = { false }
        app.startOver()
        await waitUntil("startOver 清本地后回欢迎页") { app.phase == .onboarding }
        XCTAssertFalse(app.resumeToScan, "没授权 → 停在欢迎页")
    }
}

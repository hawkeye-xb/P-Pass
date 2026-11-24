import XCTest

/// #1744 目录来源真机 E3：只负责像用户一样点系统目录选择器（我的 iPhone → 目标目录路径 → 打开）。
/// 判定一律看 App 落盘日志与 status.json（UIRegress 同一约定：这里不判 PASS/FAIL，点不到才让 XCTest 失败）。
/// 由 tools/e3/scenarios/ios/folder-blackmagic.sh 经 xcodebuild test -only-testing 驱动；环境经 TEST_RUNNER_ 前缀传入：
///   UIREG_RUN     登记轮次串（透传给 App 的 PPASS_E2E_RUN）
///   UIREG_TARGET  要在「我的 iPhone」里逐级打开的目录路径，`/` 分隔（默认 Blackmagic Cam/Media）
///   UIREG_STAGE   =1 时 App 侧把所选目录里最小的媒体文件拷进 seed（相册+目录同内容去重用例）
final class FolderPickerDrive: XCTestCase {
    func testPickFolder() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["PPASS_E2E_DIR"] = "container"
        app.launchEnvironment["PPASS_E2E_RUN"] = env["UIREG_RUN"] ?? ""
        app.launchEnvironment["PPASS_BGTEST_FOLDER_PICK"] = "1"
        if env["UIREG_STAGE"] == "1" { app.launchEnvironment["PPASS_BGTEST_FOLDER_STAGE"] = "1" }
        app.launch()

        let rawTarget = env["UIREG_TARGET"] ?? "Blackmagic Cam/Media"
        let segments = rawTarget.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let firstTarget = segments.first, let lastTarget = segments.last else {
            XCTFail("UIREG_TARGET 为空")
            return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // 系统目录选择器是跨进程的 Files UI：优先在 app 树里找，找不到再试 springboard（中英都列）。
        // 真机实测：iOS 文件选择器会记住上次停留的目录——若上次已在末段目录（如 Title: Media + 打开按钮），
        // 树里只有 Browse View (Picker) 与末段标题，不会有位置列表或上层段名；先认出 picker 本身，再按当前所在层级导航。
        guard waitForPicker(app: app, springboard: springboard, segments: segments, timeout: 120) else {
            dumpTrees(app: app, springboard: springboard, tag: "选择器未出现")
            XCTFail("120s 内系统目录选择器未出现（路径 \(rawTarget)）")
            return
        }
        sleep(3) // 选择器刚呈现时还在动画里，太早点会被吞掉
        if !isAlreadyAtTargetFolder(lastSegment: lastTarget, app: app, springboard: springboard) {
            // 若当前不在末段目录、也看不到第一段（例如停在别的深层目录），先点底部「浏览 / Browse」回位置列表，再进「我的 iPhone」。
            if !anyLabel(contains: firstTarget, in: [app, springboard]) {
                _ = tapIfPresent(in: [app, springboard], labels: ["浏览", "Browse"], timeout: 5)
                sleep(2)
            }
            if !anyLabel(contains: firstTarget, in: [app, springboard]) {
                _ = tapIfPresent(in: [app, springboard], labels: ["我的 iPhone", "我的iPhone", "On My iPhone"], timeout: 10)
                sleep(2)
            }
            // 找到当前可见的最深起始段（支持选择器停在中间层如 Blackmagic Cam 的情况）
            var startIdx = 0
            for idx in segments.indices.reversed() {
                if idx > 0, isInFolder(named: segments[idx - 1], app: app, springboard: springboard),
                   anyLabel(contains: segments[idx], in: [app, springboard]) {
                    startIdx = idx
                    break
                }
            }
            for idx in startIdx..<segments.count {
                let segment = segments[idx]
                let nextSegment = (idx + 1 < segments.count) ? segments[idx + 1] : nil
                var entered = false
                for _ in 0..<4 where !entered {
                    guard let row = largestElement(containing: segment, in: [app, springboard]) else {
                        sleep(1)
                        continue
                    }
                    print("TARGET_ROW[\(segment)] frame=\(row.frame) hittable=\(row.isHittable)")
                    row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    sleep(2)
                    if let nextSegment {
                        entered = waitForLabel(contains: nextSegment, in: [app, springboard], timeout: 10)
                    } else {
                        entered = isAlreadyAtTargetFolder(lastSegment: lastTarget, app: app, springboard: springboard)
                            || waitForOpenButton(app: app, springboard: springboard, timeout: 12)
                    }
                }
                if !entered {
                    dumpTrees(app: app, springboard: springboard, tag: "进目录失败:\(segment)")
                    XCTFail("进不去目标目录段 \(segment)（完整路径 \(rawTarget)）或没出现「打开/Open」")
                    return
                }
            }
        } else {
            print("PICKER_ALREADY_AT_TARGET[\(lastTarget)]")
        }
        let action = app.buttons["DOCPicker.actionButton"].firstMatch
        if action.exists && action.isHittable {
            action.tap()
        } else {
            tapFirst(in: [app, springboard], labels: ["打开", "Open", "完成", "Done"], what: "打开确认")
        }
        // 等授权回调真的完成再收：登记与取样（拷贝）同步跑在主线程，选择器只在回调返回后才开始
        // 收起——「打开」类按钮从两棵树里消失（有界 90s）就是完成信号，不用固定 sleep 猜；
        // 提前返回会让会话收尾杀掉 App，回调半路夭折，status.json 里永远等不到 folder_picked。
        let confirmGone = Date().addingTimeInterval(90)
        while Date() < confirmGone {
            var stillThere = false
            // 只认按钮：App 自己的说明文字里有「备份会在打开 App 时进行」，按 label 包含「打开」
            // 搜任意元素会把那一行文字当成按钮（真机实测：按钮已点、选择器已收起，循环却永不退出）。
            for application in [app, springboard] {
                if application.buttons["DOCPicker.actionButton"].firstMatch.exists { stillThere = true }
                for label in ["打开", "Open"] where application.buttons[Self.norm(label)].firstMatch.exists {
                    stillThere = true
                }
            }
            if !stillThere { return }
            sleep(1)
        }
        // 90s 后「打开」还在 = 选择器始终没收起，授权回调没完成：必须判失败，
        // 否则测试会在什么都没确认的情况下报成功。
        dumpTrees(app: app, springboard: springboard, tag: "选择器未收起")
        XCTFail("90s 后系统目录选择器仍未收起（打开/Open 按钮还在），授权回调未完成")
    }

    /// 在给定的 app 树里找第一个标签匹配（去省略号/引号、比小写）可命中的元素并点它；30s 内找不到就失败。
    private func tapFirst(in apps: [XCUIApplication], labels: [String], what: String) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for application in apps {
                for label in labels {
                    let wanted = Self.norm(label)
                    let queries = [application.buttons[wanted], application.cells[wanted], application.otherElements[wanted],
                                   application.staticTexts[wanted], application.collectionViews[wanted]]
                    for query in queries {
                        if query.firstMatch.exists {
                            if query.firstMatch.isHittable {
                                query.firstMatch.tap()
                                return
                            }
                        }
                    }
                    // 精确 label 没命中时按包含匹配兜底（系统 UI 的可达 label 可能带后缀）。
                    let any = application.descendants(matching: .any).matching(
                        NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
                    if any.exists && any.isHittable {
                        any.tap()
                        return
                    }
                }
            }
            sleep(1)
        }
        for application in apps { print("TREE(\(what)):\n\(application.debugDescription)") }
        XCTFail("点不到：\(what)（候选 \(labels)，先 app 后 springboard 都没命中）")
    }

    /// 失败时把两棵可达树打进 xcodebuild 日志：系统 Files UI 的 label 与层级因系统版本而异，
    /// 没有树就只能靠猜（上一轮就是这样连「打开」都点不到）。
    private func dumpTrees(app: XCUIApplication, springboard: XCUIApplication, tag: String) {
        print("== 选择器树（\(tag)）==")
        print("APP:\n\(app.debugDescription)")
        print("SPRINGBOARD:\n\(springboard.debugDescription)")
    }

    /// 限时点中任一标签就返回 true，点不到返回 false（不判失败，用于可选导航步骤）。
    @discardableResult
    private func tapIfPresent(in apps: [XCUIApplication], labels: [String], timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for application in apps {
                for label in labels {
                    let wanted = Self.norm(label)
                    let queries = [application.buttons[wanted], application.cells[wanted], application.otherElements[wanted],
                                   application.staticTexts[wanted], application.collectionViews[wanted]]
                    for query in queries where query.firstMatch.exists && query.firstMatch.isHittable {
                        query.firstMatch.tap()
                        return true
                    }
                    let any = application.descendants(matching: .any).matching(
                        NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch
                    if any.exists && any.isHittable {
                        any.tap()
                        return true
                    }
                }
            }
            sleep(1)
        }
        return false
    }

    /// 等系统目录选择器真的出现：Browse View (Picker) / DOCPicker.actionButton / 任一段名 / 位置页标签任一可见。
    @discardableResult
    private func waitForPicker(app: XCUIApplication, springboard: XCUIApplication, segments: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for application in [app, springboard] {
                if application.otherElements["Browse View (Picker)"].firstMatch.exists { return true }
                if application.buttons["DOCPicker.actionButton"].firstMatch.exists { return true }
                if application.navigationBars["FullDocumentManagerViewControllerNavigationBar"].firstMatch.exists { return true }
            }
            for seg in segments where anyLabel(contains: seg, in: [app, springboard]) { return true }
            for label in ["我的 iPhone", "我的iPhone", "On My iPhone", "位置", "浏览", "Browse"] {
                if anyLabel(contains: label, in: [app, springboard]) { return true }
            }
            sleep(1)
        }
        return false
    }

    /// 判断选择器当前是否已经处在指定目录内（看 DOC.browsingRoot 的 Title: <name> 或导航栏标题按钮「<name>, 操作菜单」）。
    private func isInFolder(named folder: String, app: XCUIApplication, springboard: XCUIApplication) -> Bool {
        for application in [app, springboard] {
            if application.otherElements.matching(NSPredicate(format: "identifier CONTAINS[c] %@", "Title: \(folder)")).firstMatch.exists {
                return true
            }
            let nav = application.navigationBars["FullDocumentManagerViewControllerNavigationBar"].firstMatch
            if nav.exists, nav.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", folder)).firstMatch.exists {
                return true
            }
        }
        return false
    }

    /// 选择器已处在目标末段目录且右上角「打开/Open」按钮就绪。
    private func isAlreadyAtTargetFolder(lastSegment: String, app: XCUIApplication, springboard: XCUIApplication) -> Bool {
        isInFolder(named: lastSegment, app: app, springboard: springboard)
            && waitForOpenButton(app: app, springboard: springboard, timeout: 3)
    }

    /// 选择器里是否已经出现确认按钮：DOCPicker.actionButton（identifier）优先，其次 label 打开/Open。
    private func waitForOpenButton(app: XCUIApplication, springboard: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for application in [app, springboard] {
                if application.buttons["DOCPicker.actionButton"].firstMatch.exists { return true }
                for label in ["打开", "Open"] {
                    if application.buttons[Self.norm(label)].firstMatch.exists { return true }
                }
            }
            sleep(1)
        }
        return false
    }

    /// 位置页里的目标行（Link；label 形如「Blackmagic Cam, 文件夹 · 22.4 MB」）。存在就返回，
    /// 不按 isHittable 过滤——远程视图里它常报 false 但坐标点仍可命中，过滤掉就永远点不到。
    private func firstLink(containing text: String, in apps: [XCUIApplication]) -> XCUIElement? {
        for application in apps {
            for query in [application.links, application.cells, application.buttons] {
                let m = query.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
                if m.exists { return m }
            }
        }
        return nil
    }

    /// label 含目标的元素里 frame 面积最大的那个（文件夹块本身，而不是块里的小标题）。
    private func largestElement(containing text: String, in apps: [XCUIApplication]) -> XCUIElement? {
        var best: XCUIElement?
        var bestArea: CGFloat = 0
        for application in apps {
            let matches = application.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).allElementsBoundByIndex
            for m in matches where m.exists {
                let f = m.frame
                let area = f.width * f.height
                if area > bestArea { bestArea = area; best = m }
            }
        }
        return best
    }

    /// 任意树的任意元素 label 含给定片段（用来确认选择器当前就在目标目录：面包屑/标题里有名字）。
    private func anyLabel(contains text: String, in apps: [XCUIApplication]) -> Bool {
        for application in apps {
            if application.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch.exists { return true }
        }
        return false
    }

    private func waitForLabel(contains text: String, in apps: [XCUIApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if anyLabel(contains: text, in: apps) { return true }
            sleep(1)
        }
        return false
    }

    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// #1744 E3「后台只记录系统实际行为」：本用例自己带 env 启动 App（配对+备份一轮），
    /// 启动 UIREG_HOME_WAIT 秒后按 Home 把它退到后台（记录系统真实行为，不做任何进度承诺）。
    /// TEST_RUNNER_UIREG_HOME_WAIT = 按 Home 前等待的秒数（场景脚本用它对齐「进入传输中」）。
    /// TEST_RUNNER_UIREG_RUN / TEST_RUNNER_UIREG_PAIR_LINK 透传给 App 的 PPASS_E2E_*。
    /// 卸载重装后相册权限会被重置：启动时若有系统照片权限弹窗，先点「允许完全访问」（UIRegress 同一按钮表）。
    func testPressHome() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchEnvironment["PPASS_E2E_DIR"] = "container"
        app.launchEnvironment["PPASS_E2E_RUN"] = env["UIREG_RUN"] ?? ""
        app.launchEnvironment["PPASS_E2E_PAIR_LINK"] = env["UIREG_PAIR_LINK"] ?? ""
        app.launchEnvironment["PPASS_BGTEST_FOLDER_RUN"] = "1"
        app.launch()
        // 系统照片权限弹窗（中英）：弹窗只会出现在启动后一两秒内——轮询 6 秒，点到就处理；
        // 没弹窗（权限已在）立即走 HOME_WAIT，不再陪等 20 秒把「+45s 按Home」拖成「+65s」，
        // 否则短备份在按 Home 前就收场，E3-6 的「传输中退后台」窗口就没了。
        // 按钮表与点击方式跟 UIRegress 共用一份：弹窗在 SpringBoard 的 staged alert 里，label 还会出现两份。
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var granted = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            // 点完要确认框真的没了：坐标兜底没点中时框还在，这时按 Home 等于没授权。
            if let tapped = UIReg.tapAlertButton(SystemButton.photosFull, roots: [springboard, app]) {
                UIReg.say("SYSTEM_ALERT photos tapped=\(tapped.label) (press-home)")
                if UIReg.alertGone(tapped, springboard: springboard, app: app) { granted = true; break }
            }
            sleep(1)
        }
        // UIREG_HOME_WAIT = 启动后按 Home 前的等待秒数；点了权限弹窗就先让授权落两拍再计时。
        if granted { sleep(2) }
        let wait = Int(env["UIREG_HOME_WAIT"] ?? "0") ?? 0
        sleep(UInt32(max(0, wait)))
        XCUIDevice.shared.press(XCUIDevice.Button.home)
        sleep(3)
    }
}

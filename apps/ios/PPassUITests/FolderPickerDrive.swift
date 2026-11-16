import XCTest

/// #1744 目录来源真机 E3：只负责像用户一样点系统目录选择器（我的 iPhone → 目标目录 → 打开）。
/// 判定一律看 App 落盘日志与 status.json（UIRegress 同一约定：这里不判 PASS/FAIL，点不到才让 XCTest 失败）。
/// 由 tools/e3/scenarios/ios/folder-blackmagic.sh 经 xcodebuild test -only-testing 驱动；环境经 TEST_RUNNER_ 前缀传入：
///   UIREG_RUN     登记轮次串（透传给 App 的 PPASS_E2E_RUN）
///   UIREG_TARGET  要在「我的 iPhone」里打开的目录名（默认 Blackmagic Cam）
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

        let target = env["UIREG_TARGET"] ?? "Blackmagic Cam"
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // 系统目录选择器是跨进程的 Files UI：优先在 app 树里找，找不到再试 springboard（中英都列）。
        tapFirst(in: [app, springboard], labels: ["我的iPhone", "On My iPhone"], what: "我的 iPhone 位置")
        tapFirst(in: [app, springboard], labels: [target], what: "目标目录 \(target)")
        tapFirst(in: [app, springboard], labels: ["打开", "Open", "完成", "Done"], what: "打开确认")
        // 等授权回调真的完成再收：登记与取样（拷贝）同步跑在主线程，选择器只在回调返回后才开始
        // 收起——「打开」类按钮从两棵树里消失（有界 90s）就是完成信号，不用固定 sleep 猜；
        // 提前返回会让会话收尾杀掉 App，回调半路夭折，status.json 里永远等不到 folder_picked。
        let confirmGone = Date().addingTimeInterval(90)
        while Date() < confirmGone {
            var stillThere = false
            for application in [app, springboard] {
                for label in ["打开", "Open"] {
                    if application.buttons[Self.norm(label)].firstMatch.exists { stillThere = true }
                    if application.descendants(matching: .any)
                        .matching(NSPredicate(format: "label CONTAINS[c] %@", label)).firstMatch.exists {
                        stillThere = true
                    }
                }
            }
            if !stillThere { return }
            sleep(1)
        }
        // 90s 后「打开」还在 = 选择器始终没收起，授权回调没完成：必须判失败，
        // 否则测试会在什么都没确认的情况下报成功。
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
        XCTFail("点不到：\(what)（候选 \(labels)，先 app 后 springboard 都没命中）")
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
        let photosFull = ["allow full access", "allow access to all photos", "允许完全访问", "允许访问所有照片", "允许访问全部照片"]
        var granted = false
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for label in photosFull {
                let button = app.buttons[label].firstMatch
                if button.exists && button.isHittable {
                    button.tap()
                    granted = true
                    break
                }
            }
            if granted { break }
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

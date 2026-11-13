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
        // 给 App 的授权回调留点时间写 status（场景脚本按 status.json 判，这里只等登记落盘）。
        sleep(3)
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

    /// #1744 E3「后台只记录系统实际行为」：App 已由场景脚本经 devicectl 启动并在前台备份；
    /// 本用例不 launch 任何东西，只按 Home 键把它退到后台（记录系统真实行为，不做任何进度承诺）。
    /// TEST_RUNNER_UIREG_HOME_WAIT = 按 Home 前等待的秒数（场景脚本用它对齐「进入传输中」）。
    func testPressHome() throws {
        let wait = Int(ProcessInfo.processInfo.environment["UIREG_HOME_WAIT"] ?? "0") ?? 0
        sleep(UInt32(max(0, wait)))
        XCUIDevice.shared.press(XCUIDevice.Button.home)
        sleep(3)
    }
}

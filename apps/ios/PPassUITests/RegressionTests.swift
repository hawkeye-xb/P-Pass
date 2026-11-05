import XCTest

/// 界面回归用例（#1458）。每个用例由 tools/ios/ui-regress.sh 单独跑一次（-only-testing），从欢迎页起：
/// 清 App 数据 → 手动配对到隔离配对桩 → 决定页。判定看 App 日志（tools/ios/ui-regress-rules.tsv），不在这里断言结果。
/// 用例名（去掉 test 前缀）= 判定表里的名字 = --invert 的参数。
final class RegressionTests: UIRegressCase {
    // MARK: 决定页

    /// 决定页「选择备份范围」→ 系统照片权限选「允许全部」。只判到权限结果，不保存范围（不把真照片传出去）。
    func testDecisionScopeFull() {
        launchFreshAndPair(resetPhotos: true)
        app.buttons["decisionChooseScope"].tap()
        answerSystemAlert(inverted ? SystemButton.dontAllow : SystemButton.photosFull, what: "photos")
        settle()
    }

    /// 决定页「先挑几张试试」→ 系统照片选择器选 1 张 → 进照片页。
    func testDecisionPick() {
        launchFreshAndPair(resetPhotos: false)
        app.buttons["decisionPickPhotos"].tap()
        pickOnePhoto(cancel: inverted)
        settle(5)
    }

    // MARK: 设置页「自动备份」开关触发照片权限

    func testSettingsRuleFull() {
        ruleCase(answer: inverted ? SystemButton.dontAllow : SystemButton.photosFull)
    }

    func testSettingsRuleLimited() {
        ruleCase(answer: inverted ? SystemButton.photosFull : SystemButton.photosLimited, limited: !inverted)
    }

    func testSettingsRuleDenied() {
        ruleCase(answer: inverted ? SystemButton.photosFull : SystemButton.dontAllow)
    }

    private func ruleCase(answer: [String], limited: Bool = false) {
        launchFreshAndPair(resetPhotos: true)
        reachSettingsViaPick()
        let rule = toggle(id: "autoBackupRuleToggle")
        flip(rule)
        answerSystemAlert(answer, what: "photos")
        if limited {
            // 「限制访问」之后系统给一页选照片：选第一张、点完成。
            pickOnePhotoInLimitedSheet()
        }
        settle(5)
    }

    private func pickOnePhotoInLimitedSheet() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for root in [app, springboard] {
                let img = root.scrollViews.otherElements.images.firstMatch
                let cell = root.collectionViews.cells.firstMatch
                let target = img.exists ? img : (cell.exists ? cell : nil)
                if let target, target.isHittable {
                    target.tap()
                    UIReg.say("LIMITED_SELECTED 1")
                    tapButton(SystemButton.limitedDone, what: "limited-done")
                    return
                }
            }
            usleep(500_000)
        }
        dump("limited-sheet")
        XCTFail("20 秒内没看到「限制访问」的选照片页")
    }

    // MARK: 设置页「挑几张传」

    /// 规则关着时设置页第二行「挑几张传」→ 系统选择器选 1 张。
    func testSettingsPick() {
        launchFreshAndPair(resetPhotos: false)
        reachSettingsViaPick()
        let row = app.buttons["pickPhotosRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "设置页没有「挑几张传」")
        row.tap()
        pickOnePhoto(cancel: inverted)
        settle(5)
    }

    // MARK: 设置页「通知」开关触发系统授权（iOS 只问一次：两例之间宿主卸载重装）

    func testNotifyAllow() {
        notifyCase(answer: inverted ? SystemButton.dontAllow : SystemButton.allow)
    }

    func testNotifyDeny() {
        notifyCase(answer: inverted ? SystemButton.allow : SystemButton.dontAllow)
    }

    private func notifyCase(answer: [String]) {
        launchFreshAndPair(resetPhotos: false)
        reachSettingsViaPick()
        let notify = toggle(labels: UIReg.labels("UIREG_NOTIFY_LABEL", fallback: ["通知", "Notifications"]))
        if (notify.value as? String) == "1" {
            // 已开（不该出现在全新安装上）：先关再开才会走授权。
            flip(notify)
            settle(1)
        }
        flip(notify)
        answerSystemAlert(answer, what: "notifications")
        settle()
    }
}

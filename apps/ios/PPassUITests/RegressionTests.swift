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

    // 设置页「自动备份」只写规则，不再主动弹照片权限；反向用例用真实的「再关一次开关」判反证。
    func testSettingsRuleFull() {
        ruleCase()
    }

    func testSettingsRuleLimited() {
        ruleCase()
    }

    // 「设置页拒绝」一例等 #1453 的日志行（settings: auto-rule photo access after prompt=none）合入后再加：
    // 现在 App 不打那一行，加了必红，会让整个回归永久退出 1。

    private func ruleCase() {
        prepareScopeAndOpenSettings()
        let rule = toggle(id: "autoBackupRuleToggle")
        if (rule.value as? String) == "1" {
            flip(rule)
        }
        flip(rule)
        if inverted {
            // 反向操作：关闭刚打开的规则，最终不应出现 enabled=true 的通过行。
            flip(rule)
            // 正向用例要求最终开启；反向关闭后必须让本例失败，不能只看首次保存的 enabled=true。
            XCTAssertEqual(rule.value as? String, "1", "正向预期是最终开启，反向关闭必须判 FAIL")
        }
        settle(5)
    }

    /// 先保存一个有效范围，避免首次开启规则时被送进范围编辑页，反向用例才能真实再关一次。
    private func prepareScopeAndOpenSettings() {
        launchFreshAndPair(resetPhotos: true)
        app.buttons["decisionChooseScope"].tap()
        answerSystemAlert(SystemButton.photosFull, what: "photos")
        settle(2)
        let save = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Start backup", "开始备份")).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15), "没有找到范围保存按钮")
        tapWhenVisible(save)
        settle(5)
        openSettingsTab()
    }

    // MARK: 设置页「挑几张传」

    /// 规则关着时设置页第二行「挑几张传」→ 系统选择器选 1 张。
    func testSettingsPick() {
        launchFreshAndPair(resetPhotos: false)
        reachSettingsViaPick()
        let row = app.buttons["pickPhotosRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "设置页没有「挑几张传」")
        tapWhenVisible(row)
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

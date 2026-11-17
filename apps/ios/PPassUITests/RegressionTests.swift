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

    // 设置页「自动备份」：判定只认实际操作阶段的日志。准备阶段保存范围也会打一条 enabled=true，
    // 它不许当作通过证据——判定要求它之后有实际操作阶段的 false→true（#1812）。
    func testSettingsRuleFull() {
        ruleCase()
    }

    /// 有限授权路径（相册-only，#1787 保留）：决定页权限选「限制访问」选 1 张 → 设置页开「自动备份」
    /// → App 带去系统设置 → 回前台（不改权限）→ 允许的照片按手选发一次、开关保持关。
    func testSettingsRuleLimited() {
        limitedRuleCase()
    }

    // 「设置页拒绝」一例等 #1453 的日志行（settings: auto-rule photo access after prompt=none）合入后再加：
    // 现在 App 不打那一行，加了必红，会让整个回归永久退出 1。

    private func ruleCase() {
        prepareScopeAndOpenSettings()
        let rule = toggle(id: "autoBackupRuleToggle")
        // 准备阶段保存范围已经开过一次规则；这里先真实关一次。
        if (rule.value as? String) == "1" {
            flip(rule)
            settle(1)
        }
        if !inverted {
            // 正向：再真实打开，最终开启。判定要求 false 之后新出现一条 enabled=true，
            // 准备阶段那条 enabled=true 不算数，实际操作失效必红（#1812）。
            flip(rule)
            settle(5)
            XCTAssertEqual(rule.value as? String, "1", "正向：实际操作后开关必须最终开启")
        } else {
            // 反向：停在真实关闭。判据要 false 之后再有一条 enabled=true，缺通过行 ⇒ FAIL。
            settle(5)
        }
    }

    private func limitedRuleCase() {
        launchFreshAndPair(resetPhotos: true)
        app.buttons["decisionChooseScope"].tap()
        // 反证：答「允许全部」→ 没走有限授权路径，判据缺通过行 ⇒ FAIL。
        answerSystemAlert(inverted ? SystemButton.photosFull : SystemButton.photosLimited, what: "photos")
        guard !inverted else { settle(2); return }
        // 「限制访问」之后系统给一页选照片：选一张、点完成。
        pickOnePhotoInLimitedSheet()
        settle(2)
        openSettingsTab()
        let rule = toggle(id: "autoBackupRuleToggle")
        flip(rule) // 部分权限下开规则：App 不预写开关，带用户去系统设置
        settle(2)
        app.activate() // 从系统设置回前台（不改权限）：登记过的照片发一次，开关保持关
        settle(5)
    }

    private func pickOnePhotoInLimitedSheet() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            // 从第 1 个格子取起：真机（iOS 27 实测）第 0 个 PXGGridLayout 不是可选照片，点它选不上（n=0 必红）；
            // 模拟器图库只有一张测试照片，第 1 个不存在，回退 0 或首个。
            if let cell = pickerCell(at: 1) ?? pickerCell(at: 0) ?? firstPickerCell() {
                tapPickerCell(cell)
                UIReg.say("LIMITED_SELECTED 1")
                tapButton(SystemButton.limitedDone, what: "limited-done")
                return
            }
            usleep(500_000)
        }
        dump("limited-sheet")
        XCTFail("20 秒内没看到「限制访问」的选照片页")
    }

    /// 先保存一个有效范围，避免开关被送进范围编辑页，两个方向的开关操作都能真实落到规则上。
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

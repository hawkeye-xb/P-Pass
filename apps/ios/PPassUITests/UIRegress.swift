import XCTest

/// 界面回归的共用部分（#1458）。只由 tools/ios/ui-regress.sh 驱动：它起隔离配对桩、给每个用例一条新配对串、
/// 跑完拉回 App 落盘日志按通过行判定。**这里不判 PASS/FAIL**：测试只负责像用户一样点界面和系统弹窗，
/// 点不到（元素 / 弹窗按钮找不到）才让 XCTest 失败；结论一律以 App 日志为准（tools/ios/ui-regress-rules.tsv）。
///
/// 宿主经 xcodebuild 的 `TEST_RUNNER_<键>` 环境变量传入（测试进程里去掉前缀）：
///   UIREG_PAIR_LINK       配对串（ppf://pair?…，每个用例一条新的）
///   UIREG_INVERT          反证：等于本用例名时，系统弹窗故意点反向选项（判定期望不变 ⇒ 该用例必须 FAIL）
///   UIREG_SETTINGS_TAB    「设置」标签页的显示文字，中英用 | 分隔（取自 App 的 Localizable.strings）
///   UIREG_NOTIFY_LABEL    「通知」开关的显示文字，同上
/// 测试打到 stdout 的 `UIREG <事件>` 行由宿主读（验证码就走这条：`UIREG PAIR_CODE=<6 位>`）。
enum UIReg {
    static let env = ProcessInfo.processInfo.environment
    static var pairLink: String { env["UIREG_PAIR_LINK"] ?? "" }
    static var invert: String { env["UIREG_INVERT"] ?? "" }
    static func labels(_ key: String, fallback: [String]) -> [String] {
        let raw = env[key] ?? ""
        let parts = raw.split(separator: "|").map(String.init).filter { !$0.isEmpty }
        return parts.isEmpty ? fallback : parts
    }

    static func say(_ line: String) {
        print("UIREG \(line)")
        fflush(stdout)
    }

    /// 点完之后那个弹窗是不是真没了（坐标兜底没点中时它还在）。弹窗可能挂在两棵树里，两边都查不到才算消失。
    static func alertGone(_ tap: SystemAlertTap, springboard: XCUIApplication, app: XCUIApplication,
                          timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let stillUp = tap.alertIdentifier.isEmpty
                ? (springboard.alerts.count > 0 || app.alerts.count > 0)
                : (springboard.alerts.matching(identifier: tap.alertIdentifier).firstMatch.exists
                    || app.alerts.matching(identifier: tap.alertIdentifier).firstMatch.exists)
            if !stillUp { return true }
            usleep(200_000)
        }
        say("PHOTO_ALERT_STILL_UP label=\(tap.alertLabel)")
        return false
    }

    /// 按按钮表点当前画面上系统弹窗的按钮（按 roots 顺序找 `alerts`）；返回点到的文字。
    /// 非 `UIRegressCase` 的驱动（FolderPickerDrive）也走这一份：按钮表、staged alert 里 label 出现两份、
    /// 点不了时按坐标点，这些细节只在这里维护一次。
    /// [photoChoices] 只在**照片权限框**里参与匹配：别的弹窗也常有「允许 / 不允许」，不能拿照片答案去点它。
    /// [photosOnly]：只认照片框（等照片答案时用），碰到的别的弹窗一律跳过、不点。
    @discardableResult
    static func tapAlertButton(_ choices: [String], photoChoices: [String] = [], photosOnly: Bool = false,
                               roots: [XCUIApplication],
                               onUnmatched: ((XCUIElement, [String]) -> Void)? = nil) -> SystemAlertTap? {
        for root in roots {
            let alerts = root.alerts
            guard alerts.count > 0 else { continue }
            for i in 0..<alerts.count {
                let alert = alerts.element(boundBy: i)
                // 弹窗身份也先读出来：点完弹窗就消失，之后再读 `alert.identifier/label` 会重新查一次、查不到就判用例失败。
                let alertIdentifier = alert.identifier
                let alertLabel = alert.label
                let buttons = alert.buttons
                // 先把 label / identifier 记下来：点完弹窗就消失，之后再读元素属性会重新查一次、查不到就判用例失败。
                var info: [(label: String, identifier: String, element: XCUIElement)] = []
                for j in 0..<buttons.count {
                    let b = buttons.element(boundBy: j)
                    if b.exists { info.append((b.label, b.identifier, b)) }
                }
                // 照片权限框按 identifier 认（staged alert 是 `kTCCServicePhotos-staged-alert`，按钮是 `kTCCServicePhotos-*-button`），
                // 不按标题文字——标题随语言、随系统版本变。
                let isPhotos = alertIdentifier.lowercased().contains("tccservicephotos")
                    || info.contains { $0.identifier.lowercased().contains("tccservicephotos") }
                let pool = isPhotos ? choices + photoChoices : choices
                let matched = (photosOnly && !isPhotos) ? [] : info.filter { SystemButton.matches($0.label, pool) }
                if !matched.isEmpty {
                    // staged alert 里同一个 label 会出现两份，优先点真能点的那个；都不能点时按第一个的坐标点。
                    let target = matched.first(where: { $0.element.isHittable }) ?? matched[0]
                    if target.element.isHittable {
                        target.element.tap()
                    } else {
                        target.element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    }
                    return SystemAlertTap(label: target.label, alertIdentifier: alertIdentifier,
                                          alertLabel: alertLabel, isPhotos: isPhotos)
                }
                onUnmatched?(alert, info.map(\.label))
            }
        }
        return nil
    }
}

/// 点到的一次系统弹窗按钮，连同它所在弹窗的身份。
struct SystemAlertTap {
    let label: String
    let alertIdentifier: String
    let alertLabel: String
    let isPhotos: Bool
}

/// 系统弹窗按钮的说法（中英；iOS 17 / 18 / 26 的写法都列上）。比对前统一去掉省略号、弯引号、大小写。
enum SystemButton {
    static let photosFull = ["Allow Full Access", "Allow Access to All Photos", "允许完全访问", "允许访问所有照片", "允许访问全部照片"]
    static let photosLimited = ["Limit Access", "Select Photos", "限制访问", "选择照片"]
    static let dontAllow = ["Don't Allow", "Don’t Allow", "不允许"]
    static let allow = ["Allow", "允许", "好"]
    /// 重装后首次联网时的「允许使用无线数据？」（选项是两种 WLAN 口径，不是「允许」）：选只走局域网的那种。
    static let cellularData = ["仅限无线局域网", "无线局域网与蜂窝网络", "WLAN", "WLAN Only", "Wi-Fi Only",
                               "WLAN & Cellular Data", "Wi-Fi & Cellular Data", "WLAN and Cellular Data"]
    /// 「限制访问」之后系统选照片页的确认按钮。
    static let limitedDone = ["Done", "Continue", "完成", "继续"]
    /// PHPicker 的确认按钮（selectionLimit > 1 时是「添加」）。
    static let pickerAdd = ["Add", "添加", "Done", "完成"]
    static let pickerCancel = ["Cancel", "取消"]

    static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func matches(_ label: String, _ choices: [String]) -> Bool {
        let l = norm(label)
        return choices.contains { norm($0) == l }
    }
}

class UIRegressCase: XCTestCase {
    let app = XCUIApplication()
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    /// 没匹配上的系统弹窗每个会话只记一次（按钮表要按真机实际标签补）。
    private static var loggedAlertLabels = Set<String>()

    /// 本用例要的照片权限答案。iOS 26+ 的照片框是 SpringBoard 的 staged alert
    /// （identifier `kTCCServicePhotos-staged-alert`），**出现时机不受测试控制**：实测重装后 App 启动约 3 秒就弹，
    /// 早于「点选择备份范围」那一步；配对阶段的清场如果只认「允许 / 无线数据」，框会留在屏幕上，
    /// 之后点 App 的按钮时被 XCUITest 当成 interruption 处理、点击被吞掉（#1844）。所以配对等待和每次点 App 之前
    /// 都按这个答案把照片框点掉。
    var photoAnswer: [String] = SystemButton.photosFull
    /// 清场时已经点掉的照片框按钮；`answerSystemAlert("photos")` 据此知道框已经答过。
    private(set) var photoAnswered: String?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        UIReg.say("CASE_START \(caseName)")
    }

    override func tearDown() {
        UIReg.say("CASE_END \(caseName)")
        super.tearDown()
    }

    /// 本用例名（testXxx 去掉前缀），与判定表、--invert 用同一个名字。
    var caseName: String {
        let raw = name.split(separator: " ").last.map(String.init) ?? name
        let method = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]-"))
        return method.hasPrefix("test") ? String(method.dropFirst(4)) : method
    }

    var inverted: Bool { UIReg.invert == caseName }

    // MARK: 启动与配对

    /// 清掉 App 的存储根与身份（DEBUG 门控键 PPASS_E2E_RESET），落在手动配对页、配对串已填好并自动提交。
    /// [photoAnswer]：本用例要的照片权限答案，照片框在启动阶段就弹时按它点（见 `photoAnswer`）。
    func launchFreshAndPair(resetPhotos: Bool, photoAnswer: [String] = SystemButton.photosFull) {
        self.photoAnswer = photoAnswer
        XCTAssertFalse(UIReg.pairLink.isEmpty, "没有配对串（UIREG_PAIR_LINK）")
        if resetPhotos {
            app.resetAuthorizationStatus(for: .photos)
            UIReg.say("PHOTOS_AUTH_RESET")
        }
        app.launchEnvironment = [
            "PPASS_E2E_RESET": "1",
            "PPASS_ROUTE": "manual",
            "PPASS_PAIR_CODE": UIReg.pairLink,
        ]
        app.launch()
        waitForPairing()
    }

    /// 等验证码出现（打给宿主去桌面那一侧输码允许），再等决定页。中途的「本地网络」系统弹窗点允许。
    private func waitForPairing() {
        let code = app.staticTexts["pairCodeValue"]
        let decision = app.buttons["decisionChooseScope"]
        var reported = ""
        var retried = false
        let deadline = Date().addingTimeInterval(150)
        while Date() < deadline {
            answerAnySystemAlert("pairing")
            if code.exists {
                let value = code.label.filter(\.isNumber)
                if value.count == 6, value != reported {
                    reported = value
                    UIReg.say("PAIR_CODE=\(value)")
                }
            }
            if decision.exists { UIReg.say("DECISION_SHOWN"); return }
            // 刚装好的第一次启动会弹「允许使用无线数据 / 本地网络 / 相机」，弹窗答完之前连接必失败。
            // 失败页出现就等弹窗答完再配一次（手动配对页会自动提交同一条配对串）。
            if !retried, app.buttons["重新扫码"].exists || app.buttons["Scan again"].exists {
                retried = true
                UIReg.say("PAIR_RETRY")
                retryPairing()
            }
            usleep(300_000)
        }
        dump("pairing")
        XCTFail("150 秒内没进决定页（验证码：\(reported.isEmpty ? "没出现" : reported)）")
    }

    /// 把挡在界面上的系统弹窗（无线数据 / 本地网络 / 相机）依次答「允许」；连续 [idle] 轮没有新弹窗就停。
    @discardableResult
    func clearSystemAlerts(_ what: String, maxSeconds: TimeInterval = 15) -> Int {
        var n = 0
        var idle = 0
        let end = Date().addingTimeInterval(maxSeconds)
        while Date() < end, idle < 6 {
            if answerAnySystemAlert(what) != nil {
                n += 1
                idle = 0
            } else {
                idle += 1
            }
            usleep(300_000)
        }
        return n
    }

    /// 失败页「重新扫码」→ 扫码页「手动输入」→ 手动页按启动环境里那条配对串自动提交。
    /// 弹窗会吞掉点击（弹窗还挂着时点按钮等于点弹窗），所以每次点之前先把弹窗清干净、确认按钮可点。
    private func retryPairing() {
        let retry = app.buttons["重新扫码"].exists ? app.buttons["重新扫码"] : app.buttons["Scan again"]
        clearSystemAlerts("pairing-retry")
        for attempt in 1...3 {
            guard retry.waitForExistence(timeout: 5) else {
                dump("pair-retry-failure-page")
                XCTFail("重试配对：找不到失败页的「重新扫码」")
                return
            }
            clearSystemAlerts("pairing-retry-\(attempt)", maxSeconds: 4)
            if retry.isHittable { retry.tap() } else { retry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            let link = app.buttons["manualLink"]
            if link.waitForExistence(timeout: 10) {
                clearSystemAlerts("camera", maxSeconds: 4)
                if link.isHittable { link.tap() } else { link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
                UIReg.say("PAIR_RETRY_MANUAL")
                return
            }
        }
        dump("pair-retry-scan")
        XCTFail("重试配对：点了「重新扫码」仍没进扫码页")
    }

    // MARK: 系统弹窗

    /// 在给定进程里找带某个按钮的弹窗并点它；返回点到的按钮文字。
    @discardableResult
    func tapAlertButton(_ choices: [String], roots: [XCUIApplication]) -> String? {
        tapAlert(choices, roots: roots)?.label
    }

    /// 同上，但带上弹窗身份（照片框要按 identifier 认，见 `UIReg.tapAlertButton`）。
    @discardableResult
    func tapAlert(_ choices: [String], photoChoices: [String] = [], photosOnly: Bool = false,
                  roots: [XCUIApplication]) -> SystemAlertTap? {
        UIReg.tapAlertButton(choices, photoChoices: photoChoices, photosOnly: photosOnly, roots: roots) { alert, labels in
            if !Self.loggedAlertLabels.contains(alert.label) {
                Self.loggedAlertLabels.insert(alert.label)
                UIReg.say("ALERT_UNMATCHED label=\(alert.label) buttons=\(labels)")
                print("--- alert detail ---\n\(alert.debugDescription)")
            }
        }
    }

    /// 点掉当前画面上任何一种已知系统弹窗（允许 / 无线数据 / 本用例要的照片答案）；返回点到的按钮文字。
    /// 照片框的答案只有点完、框真的消失了才记下来（坐标兜底没点中时框还在，不能当已答）；
    /// 「限制访问」之后系统会给一页选照片，当场选好，不留到后面挡界面。
    @discardableResult
    func answerAnySystemAlert(_ what: String) -> String? {
        // 「限制访问」不在清场里点：系统在 App 没申请时给出的这一档只是把权限改成有限，
        // 选中的照片不会进 App 的可用集合（真机实测 App 读到 `partial access registered 0 allowed photos`），
        // 有限授权那条用例要的是 App 申请那一刻现场选的 1 张。
        let earlyPhotoChoices = photoAnswer.contains { SystemButton.matches($0, SystemButton.photosLimited) } ? [] : photoAnswer
        guard let tap = tapAlert(SystemButton.allow + SystemButton.cellularData, photoChoices: earlyPhotoChoices,
                                 roots: [springboard, app]) else { return nil }
        UIReg.say("SYSTEM_ALERT \(tap.isPhotos ? "photos " : "")tapped=\(tap.label) (\(what))")
        guard tap.isPhotos else { return tap.label }
        if photoAnswered == nil, SystemButton.matches(tap.label, photoAnswer), alertGone(tap) { photoAnswered = tap.label }
        return tap.label
    }

    /// 点完之后那个弹窗是不是真没了（坐标兜底没点中时它还在）。
    private func alertGone(_ tap: SystemAlertTap, timeout: TimeInterval = 3) -> Bool {
        UIReg.alertGone(tap, springboard: springboard, app: app, timeout: timeout)
    }

    /// 等系统弹窗并点指定选项；超时把弹窗现状打出来再失败（不猜、不点别的）。
    /// 照片框如果在清场时已经按同一答案点过，这里直接算答过（判定仍看 App 日志，不静默通过）；
    /// 答过的答案和这里要的不一致照样红。返回「这次是不是现场点的」。
    @discardableResult
    func answerSystemAlert(_ choices: [String], what: String, timeout: TimeInterval = 20) -> Bool {
        if what == "photos", let answered = photoAnswered {
            guard SystemButton.matches(answered, choices) else {
                dump("alert:\(what)")
                XCTFail("「\(what)」在清场时已经答成「\(answered)」，和用例要的 \(choices) 对不上")
                return false
            }
            UIReg.say("SYSTEM_ALERT \(what) already-answered=\(answered)")
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 等照片框时只认照片框：别的弹窗也常有「不允许」，不能拿它替照片答案（`photosOnly` 在点击前就过滤）。
            if let tap = tapAlert(choices, photosOnly: what == "photos", roots: [springboard, app]) {
                UIReg.say("SYSTEM_ALERT \(what) tapped=\(tap.label)")
                // 坐标兜底那一下可能没点中：照片框还在就继续等，别急着让调用方去选片。
                guard what != "photos" || alertGone(tap) else { continue }
                return true
            }
            usleep(300_000)
        }
        dump("alert:\(what)")
        XCTFail("\(Int(timeout)) 秒内没等到「\(what)」系统弹窗里的按钮 \(choices)")
        return false
    }

    /// 有弹窗才清：清场本身要等 6 轮空闲（约 1.8 秒），不每次白等。
    func clearSystemAlertsIfAny(_ what: String, maxSeconds: TimeInterval = 4) {
        if springboard.alerts.count > 0 || app.alerts.count > 0 { clearSystemAlerts(what, maxSeconds: maxSeconds) }
    }

    /// 点 App 里的元素前先把系统弹窗清干净：staged 照片框会吞掉点击，被吞掉的那一下会让整个流程卡住（#1844）。
    func tapApp(_ what: String, _ element: XCUIElement) {
        clearSystemAlertsIfAny("before:\(what)")
        element.tap()
    }

    // MARK: 系统照片选择器（PHPicker，进程外，界面元素经宿主 App 的无障碍树可见）

    /// 选第一张并确认；invert 时点取消。
    func pickOnePhoto(cancel: Bool = false) {
        let pickerReady = Date().addingTimeInterval(30)
        var cell: XCUIElement?
        while Date() < pickerReady, cell == nil {
            cell = firstPickerCell()
            if cell == nil { usleep(500_000) }
        }
        guard let cell else { dump("picker"); XCTFail("30 秒内没看到系统照片选择器里的照片"); return }
        UIReg.say("PICKER_SHOWN")
        if cancel {
            tapButton(SystemButton.pickerCancel, what: "picker-cancel")
            return
        }
        tapPickerCell(cell)
        UIReg.say("PICKER_SELECTED 1")
        tapButton(SystemButton.pickerAdd, what: "picker-add")
    }

    /// #1840：选第一段视频并确认。选择器里连视频格子都看不到就是失败——这是「视频可选」的真机判据。
    /// PHPicker 的视频格子 label 以「视频, 」开头（英文「Video, 」）。
    func pickOneVideo() {
        let pickerReady = Date().addingTimeInterval(30)
        var cell: XCUIElement?
        while Date() < pickerReady, cell == nil {
            let found = app.images.matching(
                NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "视频, ", "Video, ")
            ).firstMatch
            if found.exists { cell = found } else { usleep(500_000) }
        }
        guard let cell else { dump("picker"); XCTFail("30 秒内没在选择器里看到视频"); return }
        UIReg.say("PICKER_SHOWN")
        tapPickerCell(cell)
        UIReg.say("PICKER_SELECTED 1")
        tapButton(SystemButton.pickerAdd, what: "picker-add")
    }

    /// 第 index 个可选格子（0 = 第一张）。限制访问那一页要选一张「还没被挑过」的，避免重复导入后 n=0。
    func pickerCell(at index: Int) -> XCUIElement? {
        let grid = app.images.matching(identifier: "PXGGridLayout-Info").element(boundBy: index)
        if grid.exists { return grid }
        let cell = app.collectionViews.cells.element(boundBy: index)
        if cell.exists { return cell }
        return nil
    }

    func firstPickerCell() -> XCUIElement? {
        // PHPicker 的照片格子：iOS 17–26 是 identifier 为 PXGGridLayout-Info 的 Image（带「照片, 日期」的 label）。
        // 不能按「scrollView 里的第一个 image」找——选择器顶部还有一张 38×38 的说明图，会先命中它（点它不选中）。
        let queries: [XCUIElementQuery] = [
            app.images.matching(identifier: "PXGGridLayout-Info"),
            app.images.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "照片, ", "Photo, ")),
            // 兜底：更早的 iOS 上 PHPicker 是 collectionView 的 cell。
            app.collectionViews.cells,
        ]
        for q in queries {
            let el = q.firstMatch
            // 只判存在：系统选择器跑在别的进程里，格子有时报 isHittable=false，但仍可点（按坐标）。
            if el.exists { return el }
        }
        return nil
    }

    /// 点选择器格子。系统选择器的格子 isHittable 常为 false，`tap()` 会被拒，改用坐标点。
    func tapPickerCell(_ cell: XCUIElement) {
        if cell.isHittable {
            cell.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    /// 点当前画面上（App 或系统页）按文字匹配的按钮；先 App（PHPicker 在 App 的树里），再 springboard。
    /// 直接按 label 查，不逐个枚举 `root.buttons`——系统选择器的树有几十个按钮，逐个数一遍比超时还慢。
    func tapButton(_ choices: [String], what: String, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for root in [app, springboard] {
                for label in choices {
                    let b = root.buttons[label]
                    if b.exists, b.isEnabled, b.isHittable {
                        b.tap()
                        UIReg.say("BUTTON \(what) tapped=\(label)")
                        return
                    }
                }
            }
            usleep(300_000)
        }
        dump("button:\(what)")
        XCTFail("\(Int(timeout)) 秒内没找到按钮 \(choices)（\(what)）")
    }

    // MARK: 设置页

    func openSettingsTab() {
        for label in UIReg.labels("UIREG_SETTINGS_TAB", fallback: ["设置", "Settings"]) {
            let b = app.tabBars.buttons[label]
            // 清场紧贴点击：等待的这两秒里系统也可能把照片框弹出来，弹框在场时点击会被吞掉（#1844）。
            if b.waitForExistence(timeout: 2) { clearSystemAlertsIfAny("before:settings-tab"); b.tap(); UIReg.say("SETTINGS_OPEN"); return }
        }
        // iOS 26 的标签栏不一定是 tabBars：退回按文字找按钮。
        for label in UIReg.labels("UIREG_SETTINGS_TAB", fallback: ["设置", "Settings"]) {
            let b = app.buttons[label]
            if b.exists { clearSystemAlertsIfAny("before:settings-tab"); b.tap(); UIReg.say("SETTINGS_OPEN"); return }
        }
        dump("settings-tab")
        XCTFail("找不到「设置」标签")
    }

    /// 决定页选「先挑几张试试」选 1 张 → 进照片页 → 设置页。用于要先到主界面的用例。
    func reachSettingsViaPick() {
        tapApp("decisionPickPhotos", app.buttons["decisionPickPhotos"])
        pickOnePhoto()
        let tab = app.tabBars.firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "挑完照片 30 秒内没进照片页")
        openSettingsTab()
    }

    /// 开关：按 identifier 或显示文字找；点开关本体（右侧）而不是整行。
    func toggle(id: String? = nil, labels: [String] = []) -> XCUIElement {
        if let id {
            let s = app.switches[id]
            if s.waitForExistence(timeout: 10) { return s }
        }
        for l in labels {
            let s = app.switches[l]
            if s.waitForExistence(timeout: 3) { return s }
        }
        dump("toggle")
        XCTFail("找不到开关 \(id ?? "") \(labels)")
        return app.switches.firstMatch
    }

    func flip(_ s: XCUIElement) {
        // 设置页是 List，开关可能在屏幕外：先滚到可点（最多 4 屏），按坐标点右侧开关本体。
        var swipes = 0
        while !s.isHittable, swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        clearSystemAlertsIfAny("before:flip")  // 滚动这几下里可能又弹了框
        s.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// 列表行可能在屏幕外：滚到可点再点。
    func tapWhenVisible(_ el: XCUIElement) {
        var swipes = 0
        while !el.isHittable, swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        clearSystemAlertsIfAny("before:tapWhenVisible")
        el.tap()
    }

    func settle(_ seconds: UInt32 = 3) { sleep(seconds) }

    // MARK: 诊断

    /// 系统弹窗可能承载的进程（#1844）：SpringBoard 之外逐个探一眼有没有 alerts，把数量打出来。
    /// 照片权限框实测在 SpringBoard（`kTCCServicePhotos-staged-alert`），PhotosUIApp 只承载 PHPicker。
    static let otherAlertHosts = ["com.apple.PhotosUIPrivate.PhotosUIApp", "com.apple.CoreAuthUI",
                                  "com.apple.Preferences", "com.apple.InCallService"]

    func dump(_ tag: String) {
        UIReg.say("DUMP_BEGIN \(tag)")
        print("--- app ---\n\(app.debugDescription)")
        print("--- springboard（完整层级）---\n\(springboard.debugDescription)")
        print("--- springboard alerts ---\n\(springboard.alerts.debugDescription)")
        for id in Self.otherAlertHosts {
            // 没在跑的进程不能查 alerts（会报 "Application … is not running" 并让用例失败），先看 state。
            let root = XCUIApplication(bundleIdentifier: id)
            UIReg.say("ROOT_PROBE \(id) state=\(root.state.rawValue) alerts=\(root.state == .notRunning ? -1 : root.alerts.count)")
        }
        UIReg.say("DUMP_END \(tag)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "dump-\(tag)"
        shot.lifetime = .keepAlways
        add(shot)
    }
}

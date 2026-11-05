# iOS 界面回归（XCUITest）

一条命令跑完 iOS 上要点系统弹窗的回归步骤，人只看 PASS/FAIL 汇总。由 #1458 引入。

```bash
just ios-ui-regress sim                      # 模拟器
just ios-ui-regress device                   # 真机（自动持 tools/e3/lock ios）
just ios-ui-regress device --only NotifyAllow,NotifyDeny
just ios-ui-regress device --invert SettingsRuleFull   # 反证
```

便宜模型就能跑：命令、判定、证据目录都是固定的，不需要看截图做判断。

## 覆盖什么

| 用例 | 界面操作（测试自己点） | 通过行（App 日志，按顺序） |
|---|---|---|
| DecisionScopeFull | 决定页「选择备份范围」→ 照片权限「允许全部」 | `onboarding: decision shown` → `onboarding: photo access after prompt=full` |
| DecisionPick | 决定页「先挑几张试试」→ 系统选择器选 1 张 | `onboarding: decision shown` → `picked: 1 chosen` → `onboarding: marked onboarded via=pick` |
| SettingsRuleFull | 设置页「自动备份」→「允许全部」 | `… via=pick` → `auto-rule: saved enabled=true` |
| SettingsRuleLimited | 设置页「自动备份」→「限制访问」选 1 张 | `… via=pick` → `auto-rule: partial photo access, sent allowed photos n=N` |
| SettingsRuleDenied | 设置页「自动备份」→「不允许」 | `… via=pick` → `settings: auto-rule photo access after prompt=none`（#1453 补这一行，合入前本例 FAIL） |
| SettingsPick | 设置页「挑几张传」→ 系统选择器选 1 张 | `… via=pick` → `picked: 1 chosen` |
| NotifyAllow | 设置页「通知」→ 系统授权「允许」 | `… via=pick` → `notifications: system prompt result granted=true` |
| NotifyDeny | 设置页「通知」→ 系统授权「不允许」 | `… via=pick` → `notifications: system prompt result granted=false` |

判定表是 `tools/ios/ui-regress-rules.tsv`，日志行改了只改这一处。设置页的用例先走「先挑几张试试」进主界面
（规则关着、照片权限未定），所以第一个通过行是 `marked onboarded via=pick`。

不覆盖：相机扫码（配对走手动配对串），桌面收到照片的哈希核对（见 `tools/ios/e2e-device.sh`）。

## 怎么做到不用人点

- **配对**：脚本起一台隔离配对桩（`tools/ios/sandbox-desk.sh`，`daemon --ephemeral`，假 HOME、临时库，不碰本机 P-Pass），
  每例取一条新配对串，经 `TEST_RUNNER_UIREG_PAIR_LINK` 传给测试；测试用 DEBUG 门控键启动 App：
  `PPASS_E2E_RESET=1`（清存储根与身份）、`PPASS_ROUTE=manual`、`PPASS_PAIR_CODE=<配对串>`（手动配对页自动提交）。
  测试读界面上的验证码打成 `UIREG PAIR_CODE=<6 位>`，脚本从 xcodebuild 输出里读到后对桩 `pairing.confirm`（扮演桌面主人）。
  不用 `PPASS_E2E_DIR`：它会启动 E2EDriver，整条流程又绕过界面。
- **系统弹窗**：照片权限、通知授权、本地网络都是 springboard 进程的弹窗，测试用
  `XCUIApplication(bundleIdentifier: "com.apple.springboard")` 按按钮文字点（中英都认，见 `UIRegress.swift` 的 `SystemButton`）。
  点不到就把弹窗现状打进日志并让测试失败，不猜坐标、不点别的。
- **照片权限每例重置**：`XCUIApplication.resetAuthorizationStatus(for: .photos)`（真机、模拟器都可用）。
- **通知授权只问一次、没有重置 API**：脚本开跑前卸载重装一次，跑 NotifyDeny 前再卸载重装一次。
- **系统照片选择器（PHPicker）**：进程外，但它的照片格子和「添加」按钮在宿主 App 的无障碍树里可见，测试直接点。
- **判定只看日志**：每例跑完拉回 App 容器的 `Library/Logs/ppass.log`，只取本例那次启动（`process start: pid=`，
  时间不早于本例开跑）之后的行，按判定表的通过行顺序匹配。上一例留下的通过行不算（`tools/ios/test-ui-regress-judge.sh` 自测）。
  测试本身（xcodebuild）失败也算 FAIL：说明界面没点通，原因写在汇总行里。

## 输出

`apps/ios/build/ui-regress/<时间>-<sim|device>/`：

- `summary.txt`：每例一行 `用例 PASS|FAIL 依据`，末尾合计；有 FAIL 命令退出 1。
- `<用例>.ppass.log`：本例跑完拉回的 App 日志（判定依据）。
- `<用例>.xcodebuild.log`、`<用例>.xcresult`：测试输出；`UIREG` 开头的是测试打的步骤行，找不到元素时有 `DUMP_BEGIN` 界面树与截图。
- `desk/daemon.err`：配对桩日志。

## 反证

`--invert <用例>`：该例的系统弹窗故意点反向选项（允许 ↔ 不允许、选择器点取消），判定期望不变，
汇总末尾必须是「反证：… → FAIL（符合预期）」。验收时至少给一例反证输出。

## 真机前提

- 手机解锁、亮屏、开发者模式开着，`just doctor` 能列出它；设备没被别人 claim（`tools/e3/lock status`）。
- **会清掉手机上 P-Pass 的数据并卸载重装**（只在测试机上跑）。跑完 App 配着已退出的配对桩，要配回正式桌面在桌面 App
  里「添加设备」重新扫码。
- 「允许全部」的用例只判到权限结果和开关，不保存备份范围，不把手机上的真照片传出去；挑照片的用例会把选中的 1 张传给配对桩
  （临时库，跑完即删）。
- 签名：UI 测试 runner 的 bundle id 是 `<App bundle id>.uitests`，个人团队自动签名（`-allowProvisioningUpdates`）。
- 设备默认取 `$PPASS_DEVICE`、本机 `e3.env` 的 `E3_IOS_UDID`，或唯一一台在线 iPhone；也可 `--device <标识>`。

## 改界面时

用例按 accessibilityIdentifier 找控件（`decisionChooseScope`、`decisionPickPhotos`、`autoBackupRuleToggle`、
`pickPhotosRow`、`pairCodeValue`），「设置」标签与「通知」开关按显示文字找（脚本从 `Localizable.strings` 取中英文字）。
改了这些 id 或文字，先跑 `just ios-ui-regress sim`。

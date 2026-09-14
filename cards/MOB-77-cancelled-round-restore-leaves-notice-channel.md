# MOB-77 取消轮次恢复入口从常驻警告条挪进备份设置卡　级别 L2

> ✅ 状态：代码完成，Android JVM 全绿；待真机/模拟器截图走查
> 协同分支：`main`

## 问题

`MOB-59`/X-05 把「取消轮次后恢复」做成**常驻、不可关闭**的琥珀警告条
（`HomeNoticeKind.CANCELLED_ROUND`，与配对失效/中断恢复同一套视觉语言）。
用户反馈：取消传输是自己的主动操作，不是"出了问题"，却被用警告色 +
不可关闭的方式持续暗示"这里有问题、必须点按钮处理"，观感等同被追问。

讨论中同时定了两处相邻的文案精简：
1. 首页「备份」设置卡的 section 标签"备份"信息增量为 0（整页本就是
   备份设置页，卡片边框已把这组行圈起来）。
2. 「其他」标签本身不解释是什么，但承担了"这是另一组，不是备份规则"
   的分割提示，不能直接删空——换成更具体的"关于"。

## 期望行为

- 取消轮次的恢复入口不再出现在常驻提示条里；`HomeNoticeKind` 里删除
  `CANCELLED_ROUND`。
- 该入口挪到「备份」卡内，做成一行 `CellRow`（label=已跳过的照片，
  value=N 张·点击恢复），紧跟在"备份哪些相册"下面——同属"这次备份
  包含什么"的语义线；`cancelledRoundCount == null` 时这一行不渲染，不
  占位、不常驻提醒。
- 「备份」这个 section 标签删除；「其他」改为「关于」。

## 验收标准

- [x] `HomeNoticeKind.CANCELLED_ROUND` 与 `HOME_NOTICE_PRIORITY` 里的
      对应项已删除；`NoticeHost`/`HomeNotice` 不再构造该候选。
- [x] `HomeScreen` 新增 `cancelledRoundCount: Int?` / 
      `onRestoreCancelledRounds` 参数，在「备份」卡内渲染为 `CellRow`，
      `null` 时不渲染该行；点击复用既有 `restoreCancelledRounds()` 管线
      （未改动触发逻辑，只改呈现位置）。
- [x] `MainActivity.kt` 调用点同步：`NoticeHost` 移除两个已删参数，
      `HomeScreen` 新增两个参数从 `holder.cancelledRoundNotice`/
      `holder.restoreCancelledRounds()` 接入。
- [x] `res/values(-zh)/strings.xml`：`cancelled_round_notice_body`/
      `_restore`（notice 文案）替换为 `cancelled_round_cell_label`/
      `_value`（cell 文案）；`rules_title`（"备份"）整体删除；
      `other_section_title` 改为 "About"/"关于"。
- [x] `HomeNoticesTest.kt` 里引用 `CANCELLED_ROUND` 的三处测试改用
      `SOURCE_MISSING` 占位，保持"多候选选最高优先级"的断言意图不变。
- [x] Android JVM 全量测试绿（真实生成 XML，非退出码判断）。
- [ ] 真机或模拟器截图对比：备份卡内新增的恢复行、「关于」标签渲染
      正确，且取消轮次后不再弹出警告条。

## 范围

- 只准动：`apps/android/.../ui/HomeNotices.kt`、`ui/HomeScreen.kt`、
  `MainActivity.kt` 的 `NoticeHost`/`HomeScreen` 调用点、
  `res/values*/strings.xml` 对应字符串、`HomeNoticesTest.kt`
- 不准动：`restoreCancelledRounds()` 的触发条件与底层管线
  （`BackupUiStateHolder.kt`）、其余 `HomeNoticeKind` 的呈现方式

## 阻塞与依赖

无。

## 实施记录

2026-09-14 完成（用户对话中拍板，非独立开卡讨论）：

- `HomeNotices.kt`：删除 `CANCELLED_ROUND` kind、优先级项、`NoticeHost`
  的两个参数与候选构造分支；补充注释说明改动去向。
- `HomeScreen.kt`：`cancelledRoundCount`/`onRestoreCancelledRounds` 新增
  为可选参数（默认 null/no-op）；「备份」卡内 `backup_scope` 行下方按
  条件渲染新 `CellRow`；删除 `rules_title` 的 `Text` 渲染；「其他」标签
  文案改用同一个 `other_section_title` 资源（值已改，代码零改动）。
- `MainActivity.kt`：两处调用点同步新增/删除参数。
- 字符串资源四处改动，en/zh 对称。
- `HomeNoticesTest.kt`：3 处 `CANCELLED_ROUND` 引用替换为
  `SOURCE_MISSING`（同为"非最高优先级"占位，断言逻辑不变）。
- 验证：`export ANDROID_NDK_HOME=.../28.2.13676358 && ./gradlew
  testDebugUnitTest` → **69 类 / 346 tests / 0 failures / 0 errors /
  4 skipped**（`TEST-com.hawkeyexb.ppass.ui.HomeNoticesTest.xml` 显示
  6/6，时间戳为本次运行），全部真实生成、非退出码判断。
- **未做**：真机/模拟器截图走查（验收标准最后一条）。

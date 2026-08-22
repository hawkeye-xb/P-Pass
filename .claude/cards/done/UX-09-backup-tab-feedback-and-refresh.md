# UX-09 备份/照片页三处走查反馈　级别 L1　【用户真机反馈 2026-08-12】

## 背景

用户在真机上验证完 MOB-05（部分授权误判）后，接着走查备份/照片两个
tab，提了三条反馈：

1. 「立即备份」点了没反应——多次点击看不出任何变化。
2. 「备份」tab 名不副实——里面装的是开关/规则/版本/断开，不是备份进度。
3. 照片 tab 停留不动时，后台自动备份成功的新照片不会自己冒出来，怀疑
   状态没同步。

## 根因

1. `BackupStatus.kt` 的 `statusLineOf` 早就算出了 `Pending`/`AllSafe`
   两种裁决，`values-zh/strings.xml` 也早有 `state_pending`/`state_safe`
   文案（`BackupStatusTest` 还专门锁死了这个映射与文案内容），但
   `HomeScreen.kt` 从未把这层映射接上 UI——空闲态永远只显示通用的
   `idle_auto_hint`（插电+Wi-Fi 时自动进行）。手动点「立即备份」时，如果
   照片早被后台 ContentUriTrigger 自动传完，一轮 Scanning→Hashing→
   AllSafe 走完后文案和点击前一字不差，看起来毫无反应。半成品实现——
   逻辑层写完了，UI 接线漏了。
2. 产品命名债：tab 内容随 MOB-02/UX-03/UX-06 陆续加了开关/规则/版本/
   断开连接，早已不是「备份进度」页，但 tab 名字没跟着改。
3. `PhotosScreen` 的 `timeline.page` 只在 tab 第一次创建时拉一次
   （`LaunchedEffect(Unit)`），零轮询零事件订阅（桌面 IPC-02 的事件订阅
   只接了桌面壳，手机端从未接）。一直停在照片 tab 不切换，新照片确实
   永远不会自己出现——不是缓存脏，是压根没有刷新触发点。

## 修法

1. `HomeScreen.kt`：新增 `idleStatusText(line: StatusLine)`，把
   `Ready`/`Pending`/`AllSafe`/`NoAlbums` 四种裁决分别接到对应字符串
   资源（`idle_auto_hint`/`state_pending`/`state_safe`/`state_no_albums`），
   替换原来恒定的 `idle_auto_hint`。
2. hero 空闲态大按钮「选择相册」删除（用户拍板：低频操作，onboarding
   已经选过一次，设置卡「备份范围」行本来就有这个入口，未删功能，只删
   重复入口）；空出的宽度让状态文案占满整行，`HeroSecondaryButton` 只在
   `busy`（暂停）时出现。
3. `tab_backup` 资源改名 `tab_settings`，中文文案「备份」→「设置」，
   英文「Backup」→「Settings」；`TwoTabs.kt` 与 `HomeScreen.kt` 页头
   标题同步。
4. `PhotosScreen.kt` 新增前台轻量轮询：停留在照片 tab 期间每 15s 悄悄
   重拉首页（`loader.page(null)`），只把没见过的 hash 插到列表最前面
   （timeline 按 `taken_at DESC` 排序，新照片天然落在最前——见
   `asset_repo.rs:221`），不触发 `onTimelineRefreshed`（那是整页替换
   语义，会误逐出已翻页加载的缩略图缓存），只调 `onTimelineAppended`
   （只增不逐，语义匹配）。切走 tab 时 `LaunchedEffect` 自动取消。

## 可执行验收

1. `BackupStatusTest`（映射+文案锁死）+ 全量单测绿，反证：把
   `idleStatusText` 的 `Pending`/`AllSafe` 分支去掉退回 `idle_auto_hint`
   → 语义回归旧 bug（人工核对，非自动化——UI 渲染无 Compose 单测设施）。
2. 真机（挂用户）：①已是最新时点「立即备份」→ 文案变成「照片都存好了」
   而不是原地不动；②还有欠账时点「立即备份」→ 文案说「还有 N 张待
   备份」；③设置卡「备份范围」仍能进相册选择页（功能未丢）；④停留在
   照片 tab 不切换，等后台自动备份完成 → 15s 内新照片自己出现在最前面。

## 收尾
android 全量单测绿（165 test cases，`grep -L 'failures="0"'` 零命中）；
CI 待推 main 后盯 ci-android。

---

## ✅ 验收记录（2026-08-12）

- 实现：见上「修法」四项，均已落地并 `compileDebugKotlin` +
  `testDebugUnitTest` 通过（全量绿）。
- 挂账（真机，用户）：上述验收 1-4 项待用户在真机确认；照片 tab 轮询
  与 hero 改版尤其需要真实使用场景下的主观感受反馈（是否够快/是否
  违和）。
- CI：push `a65f868` → main，ci-android 绿（1m40s）。
- debug 包已 `adb install -r` 装到用户日常用的真机（<测试机>，
  与 MOB-05 同一台、同一签名，覆盖安装不清配对状态），用户自行操作
  验证中。

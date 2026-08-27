# MOB-01 全页面安全区适配　级别 L1　【移动端批次第一张】

## blocker（用户三星真机 2026-08-11）

上下都没有安全区处理——内容被三星底部导航键区遮挡/顶到状态栏。
用户原话「不应该出现这种低级的兼容问题」。连带嫌疑：ScanScreen 底部
的「手动输入」切换按钮（代码在，L83-208）可能正是被导航键区盖住，
被用户判为「功能没了」。

## 修法

- Compose 全页面统一 insets 策略：edge-to-edge + `Scaffold`/
  `Modifier.systemBarsPadding()`（顶部 status bar + 底部 navigation
  bar），一处封装（如 PPScreen 容器）全页面套用，不许逐页手搓。
- 覆盖：HomeScreen / BucketScreen / ScanScreen / 设置 / 时间线 /
  向导 / VideoScreen——**全部页面**，不只用户点名的。
- 手势导航和三键导航两种模式都要对（insets API 天然区分，别写死高度）。

## 可执行验收

1. 模拟器分别开「三键导航」与「手势导航」，逐屏截图：无任何可交互
   元素落在导航区/状态栏下（贴对照截图，全页面）。
2. ScanScreen 的「手动输入」按钮在三键导航下完整可见可点。
3. android 全量测试绿。
4. 真机（三星）逐屏复核挂验收人。

## 反证

去掉 insets 容器 → 模拟器三键导航下底部按钮必被遮（贴截图后还原）。

## 收尾

CI 绿；PROGRESS/NEXT 一行；卡移 done/。

---

## 验收记录（2026-08-11 Salamira）

- 实现：MainActivity `enableEdgeToEdge()` + 新增 `ui/PPScreen.kt`（全应用唯一
  安全区容器：背景铺满 + safeDrawingPadding，status bar/nav bar/cutout/IME
  全让出；系统栏图标深浅随背景亮度自动切换）。全部页面接入：Welcome/Scan/
  Joined/PairStatus + TwoTabs 壳（照片/备份/设置）+ Bucket + PhotoViewer +
  VideoScreen。
- 本地：`./gradlew :app:assembleDebug :app:testDebugUnitTest` BUILD SUCCESSFUL，
  **107/107** 绿（唯一 warning 为既有 LocalLifecycleOwner 弃用，非本次引入）。
- CI：PR Checks run 31366637154 **success**（commit 8d0b4b4）。
- 模拟器项（验收 1/2/反证）未做：本机 VM 无嵌套虚拟化（HVF: HV_UNSUPPORTED），
  TCG 软件模拟冷启动 >10min 未完成；按用户指令「验证不了的话可以先跳过，我来
  验证」挂验收人。
- 反证（待验收人执行）：去掉 insets 容器 → 模拟器三键导航下底部按钮必被遮。


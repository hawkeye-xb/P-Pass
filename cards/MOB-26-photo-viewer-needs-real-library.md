# MOB-26 统一 Android 媒体查看器：翻页、缩放与系统边缘返回

> 🟡 状态：代码已合并（`ddee8ac`），待 Mate 60 真机验收
> 级别：L2 · 阻塞：无（待验收）
> 协同分支：`main`
> 当前节点：MOB-45 已合并；页序快照、Pager、Telephoto 缩放/下拉关闭与 Android 返回 reducer 已进入 `main`
> 下一步：Mate 60 录屏按验收矩阵走边缘返回、内容翻页、缩放拖动、未缩放下拉和视频页

## 问题

Android 端的照片查看器是单张 `Image`，没有翻页、缩放或下拉关闭；更严重的是
查看器没有系统返回处理，真机从屏幕边缘侧滑会退出 App。MOB-45 与本问题共用
同一查看器状态和触摸边界，分卡实施会重复改写同一段 UI。

## 期望行为

- 从任一照片打开统一查看器，内部横滑切换相邻资产；当前页的保存/分享始终作用于当前资产。
- 图片支持成熟手势方案提供的双击/双指缩放；放大后拖动只移动图片，不翻页。
- Android 系统边缘返回优先关闭查看器回到网格，绝不被 Pager 误当作翻页；根页面的系统返回仍由 Android 退出 App。
- 视频仍由现有 Media3 播放器负责播放；它与图片共用查看器入口、页序和关闭语义，但不被当成图片库可解码的资产。

## 验收标准

- [x] 自动化 RED→GREEN：查看器打开时系统返回只关闭查看器；查看器关闭后根页面返回不被吞掉。
- [ ] 自动化 RED→GREEN：从第 N 项打开，Pager 初始为 N；翻页后保存/分享的目标随当前页更新；相邻原图加载中有明确中间态。
- [ ] 自动化 RED→GREEN：缩放态不触发 Pager 翻页；未缩放的图片内容区横滑能翻页。
- [ ] Mate 60 录屏：边缘侧滑返回网格；图片中部横滑翻页；双指/双击缩放后拖动不翻页；下拉关闭仅在未缩放时生效。
- [ ] 反证：临时移除查看器返回处理，焦点用例必须复现「系统返回退出 Activity」；恢复后用例转绿。
- [x] 引入图片手势依赖前后记录 debug APK 体积；`just ci`、Android 非空测试计数均通过。

## 范围

- 只准动：`apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/` 的媒体查看器代码、`MainActivity.kt` 的顶层返回 reducer、其直接测试，以及确有必要的 Android 依赖声明。
- 不准动：原图下载/传输协议、Media3 播放器语义、桌面端查看器、底部保存/分享的业务语义。

## 阻塞与依赖

- 无。MOB-45 已于 2026-09-08 按用户决定并入本卡，历史卡保留为归档索引。
- 图片手势库在实施时按当前兼容性与 APK 体积选择；不因其技术上可包裹 `PlayerView` 而让它承担视频播放。

---

## 实施记录（2026-09-08）

- MOB-45 合并：`MainActivity` 新增 Screen→back-target reducer；根页不拦截系统返回，Scan/Waiting/Trouble/Buckets/Started 返回其上级。手动配对子页和「存储电脑」详情各自先消费返回。
- 查看器：网格打开时冻结过滤后的 `MediaViewerSession`；`HorizontalPager` 统一图片/现有 Media3 视频页；外层 `BackHandler` 先关闭查看器。图片引入 `me.saket.telephoto:zoomable:0.19.0`，下拉关闭只在 `zoomFraction == 0` 且跨过 96dp 阈值时触发。
- RED→GREEN：新增 `MediaViewerStateTest`（页序、返回、下拉缩放门控与接线守卫）及 `MainBackNavigationTest`（全顶层 Screen 返回表）。全量 Android JVM 强制重跑：307 tests / 0 failures / 0 errors / 4 skipped（59 XML，最新 XML 本次生成）。
- debug APK：基线 `48,934,824` bytes → 引入 Telephoto 后 `49,642,264` bytes，增加 `707,440` bytes（1.4457%）；`just ci` 通过。`lintDebug` 在本机 JDK 25 上复现已知 BUILD-01（Android Lint 25.0.1 初始化失败），本机无 JDK 17，非本卡引入。
- 未伪称真机通过：Mate 60 仍须按验收矩阵录屏；桌面视频仍归 MOB-47 的待验收项。

---

## 历史调研（2026-08-19~27，保留原文）

用户实测反馈："照片查看的时候没法左右快速翻页……我觉得照片查看这部分
应该能够有一个比较成熟的一个库才对。"

## 现状

`PhotosScreen.kt` 的大图查看是自己搭的最小实现：一个 `Box` 套
`Image(contentScale = Fit)`，外加顶部「返回 + 尺寸」和底部两个动作按钮。
**没有** `HorizontalPager`、没有缩放、没有双击放大、没有拖拽关闭——
用户从网格点进来之后只能看当前这一张，退出去再点下一张。

（同轮修掉的 MOB-22 是另一个问题：`fillMaxSize()` 把底部按钮顶出屏幕。
那个是布局 bug，已修，与本卡无关。）

## 缺的能力

1. **左右滑动翻页**（用户明确点名）——网格里点第 N 张进来，应能直接
   划到 N±1，而不是退出重进。
2. 双指缩放 / 双击放大。
3. 下拉关闭（现代图库的标准手势）。
4. 翻页时的预加载（当前是点开才去 daemon 取原图，翻页会一顿一顿）。

## 方向

Compose 侧成熟选择（实施时评估，别直接抄）：

- `androidx.compose.foundation.pager.HorizontalPager`（官方，已在
  compose-foundation 里，**不用新增依赖**）负责翻页；
- 缩放手势可以自己用 `transformable` + `graphicsLayer` 做，或引入
  telephoto / zoomable 这类专门库——**注意评估包体积**，本项目是照片备份
  App，ICON-02 那轮已经因为体积否掉了 material-icons-extended。

优先做 1（HorizontalPager，零新依赖、收益最大），2/3/4 看情况。

## 注意

- 翻页要跟现有的取原图管线接好：`PhotoViewer` 现在是单张 `hash` 驱动，
  改成 pager 后要按 index 驱动并处理"相邻张还没下载完"的中间态。
- 底部动作按钮（保存/分享）作用于**当前页**的资产，翻页后要跟着切。
- 别打破 MOB-22 的布局修复（图片区必须 `weight(1f)`，不能回到
  `fillMaxSize()`，否则底部按钮又会被顶出屏幕）。

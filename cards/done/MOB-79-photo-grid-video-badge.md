# MOB-79 照片网格里视频没有播放角标，跟照片长得一模一样（L2）

> ✅ 状态：真机验收通过（2026-09-14，三星 SM-S9210）
> 级别：L2 · 阻塞：无

## 问题

`PhotosScreen.kt` 的 `ThumbCell`（时间线网格每一格）只渲染缩略图本身，
完全没有读 `asset.mediaType` 来标识"这是视频"。`asset.mediaType` 字段
本身在浏览网格时已经传到位了（网格数据结构里就有），只是渲染层没有
消费它——视频和照片在网格里长得一模一样，用户必须点进详情页
（`PhotosScreen.kt:508` 按 `mediaType.startsWith("video")` 分流到
`VideoScreen` vs `PhotoViewer`）才知道刚才点的是不是视频。

用户实机使用时发现：网格里两个视频缩略图（考拉爬树、地图截屏）跟其他
照片没有任何视觉区分，无法一眼判断哪些是可播放内容。

## 期望行为

视频缩略图右下角显示一个半透明深底 + 白色播放三角的角标，跟系统相册/
主流图库的视觉语言一致，用户不点开就能一眼分辨照片和视频。

## 验收标准

- [x] `ThumbCell` 按 `asset.mediaType.startsWith("video")` 判断，视频
      缩略图右下角叠加播放三角角标；照片缩略图保持原样、无角标
- [x] 角标视觉：半透明黑底圆形 + 白色实心三角，位置右下角，与主流图库
      （系统相册等）同一套视觉语言，不使用外部图标库（本仓一贯用
      `Canvas` 手绘几何图标，跟 `TabIcons.kt` 同风格，不新增依赖）
- [x] Android JVM 全量测试绿（真实生成 XML，非退出码判断）
- [x] 真机确认：网格里视频缩略图可见播放角标，照片缩略图无角标，两者
      视觉可区分

## 范围

- 只准动：`apps/android/.../ui/PhotosScreen.kt` 的 `ThumbCell` 与新增
  的 `VideoBadge` 私有 Composable
- 不准动：详情页播放逻辑（`VideoScreen`/`PhotoViewer` 分流，已存在且
  正确工作，不在本卡范围）、缩略图生成/缓存链路（`MOB-74` 范围）

## 阻塞与依赖

无。

---

## 实施记录

2026-09-14 完成（用户对话中发现，非独立开卡讨论）：

- `ThumbCell` 新增：`asset.mediaType.startsWith("video")` 为真时，在
  `Box` 内叠加 `VideoBadge(Modifier.align(Alignment.BottomEnd).padding(6.dp))`。
- 新增私有 `VideoBadge` Composable：`Canvas` 绘制一个半透明黑色圆形
  （alpha 0.45）+ 白色实心三角形路径，22dp 见方，视觉上三角形重心做了
  微调居中（人眼对三角形几何中心的感知比数学中心偏左）。
- 补充 import：`androidx.compose.foundation.layout.size`（此前文件未
  引入这个扩展函数，编译报 `Unresolved reference 'size'`，已修正）。
- 验证：`./gradlew testDebugUnitTest assembleDebug` → **69 类 / 346
  tests / 0 failures / 0 errors / 4 skipped**（真实生成 XML，与改动前
  完全一致——本次改动不影响任何既有测试断言，纯 UI 叠加层）。
- 真机验收（三星 SM-S9210，`adb install -r`覆盖安装）：截图确认
  2026.03（考拉视频）与 2024.08（地图视频）两个缩略图右下角均出现
  半透明黑底白色播放三角，同一屏内的照片缩略图（手表）无角标，视觉
  可清晰区分。
- `just ci` 全绿（Rust 侧不受影响；Android 侧另跑 gradle 验证，同上）。

## 备注

用户同时问及 iPhone Live Photo 与 Android Motion Photo 的兼容性——
讨论结论（非本卡范围，供未来参考）：两者是完全不同的文件格式（Live
Photo = HEIC/JPEG + 独立 HEVC MOV 靠 content identifier 松散配对；
Motion Photo = 单个 JPEG 内嵌 MP4 数据），不能直接互放；现有
`asset` 表是"一 hash 一文件"单文件模型，没有"一张图配一段视频"的
关联字段。若未来支持 iPhone 且要保留 Live Photo 效果，需要新增资产
关联的数据模型，属架构级决策，暂不在本卡处理。

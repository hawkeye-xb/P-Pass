# MOB-26 照片查看页缺基础手势，应改用成熟方案　【2026-08-27 解冻重排】

> ⬜ 状态：未开工（2026-08-19 曾入 backlog「拍板暂不做」；2026-08-27
> 验收人重提，移回待做队列）
> 级别：L2 · 阻塞：无（与 MOB-45 的查看器手势部分有交集，见 MOB-45「范围」）

## 解冻经过（2026-08-27）

验收人再次点名：「有开源的图片查看库吗？能读取更多信息的。」——查看器
体验从「暂不做」变为「要做，且优先用成熟开源库，别自己攒」。原 8-19
的「拍板暂不做」就此作废。

### 「能读取更多信息的」候选库（2026-08-27 调研，实施时复核版本与体积）

查看器/手势层（Compose）：

- **Telephoto**（saket/telephoto）：Compose 专用，`ZoomableImage` +
  手势齐全（双击/双指/拖拽关闭），与 Coil 集成好——最贴本项目栈；
- **ZoomImage**（panpf/ZoomImage）：Compose Multiplatform，支持
  subsampling（大图分块，长图/原图不糊）；
- **SubsamplingScaleImageView**（View 体系）：超大原图分块解码的标杆，
  但需要 interop，Compose 项目优先级靠后；
- 翻页仍用官方 `HorizontalPager`（零新依赖，原方向不变）。

「读取更多信息」（EXIF/元数据层）：

- **metadata-extractor**（drewnoakes/metadata-extractor，JVM）：
  EXIF/IPTC/XMP/GPS/拍摄参数全量读取，Java/Kotlin 直用；
- **androidx ExifInterface**：平台自带、轻量，常用 EXIF 字段够用，
  但覆盖面不如 metadata-extractor。

⚠️ 包体积纪律不变（ICON-02 先例：为体积否掉过 material-icons-extended）
——引入任何库前给出 APK 体积前后对照。

---

## 原卡（2026-08-19，保留原文）

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

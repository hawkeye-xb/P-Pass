# MOB-47 视频资产在查看器中不可预览——桌面破图、Android 仅 MVP，换成熟播放方案

> 🟡 状态：代码已合并，待双端真机验收 · 当前节点：三轮实现/独立 L2 审查均通过，已覆盖 scope、降级与 late-DOM-error generation race · 下一步：按验收标准实测桌面播放与 Android 播放器/释放日志
> 级别：L2 · 阻塞：无（与 MOB-26 的手势层有衔接，见「阻塞与依赖」）

## 问题

验收人实测反馈：相册预览对视频不友好——**点开视频不能预览**。

代码证据（两端各一）：

1. **桌面端（重灾区）**：`apps/desktop/src/App.svelte` 的大图查看器
   （`photoViewer`，1727-1743 行）不分资产类型，一律
   `asset.original` → `data:image/jpeg;base64` → `<img>`（1086-1108 行
   `$effect`）。视频资产走同一分支：mp4 字节被错标成 `image/jpeg`
   塞进 `<img>`，浏览器不渲染 → **点视频缩略图弹窗里是破图/空白**。
   照片墙缩略图本身没问题（▶ 角标也在），问题只在查看器。

2. **Android 端**：`VideoScreen.kt` 是 T-056 的 MVP——先 `loader.download`
   把**整个视频**取回 cacheDir 才能播（`VideoState.Fetching(percent)` 等
   下载），播放用系统 `VideoView`。能播，但：大视频要等下载完、
   无进度条、无 seek、无手势，体验是「能用」不是「可预览」。

## 期望行为

- 两端查看器点开视频资产：**直接可预览播放**，不破图、不黑屏。
- 桌面端：弹窗内 `<video>` 播放，带播放/暂停/进度条（平台默认控件即可），
  有降级路径（原图取不到用缓存/缩略图兜底）。
- Android 端：成熟播放器替代 `VideoView`，带进度/seek/暂停；大文件不必
  等全量下载完才出画面（至少保留下载进度，最好能边下边播）。
- 图片资产行为零变化。

## 验收标准

- [ ] 桌面端：点视频缩略图 → 弹窗内视频直接播放（有画面、有声音、进度条
      可拖），关闭弹窗不残留进程；反证：点图片缩略图仍是原 `<img>` 路径，
      行为与改动前一致
- [ ] Android 端：点视频 → 有播放控制（播放/暂停/进度/seek）；不阻塞主
      线程；退出查看器播放器资源释放（无泄漏，logcat 无
      `MediaCodec`/`ExoPlayer` 泄漏）
- [ ] 报绿纪律：`just ci` 全绿 + 桌面 `pnpm test` 与 `src-tauri cargo test
      --lib` + Android 测试计数（现有基数：320 nextest / 347 android）
- [ ] 包体积纪律（ICON-02 先例）：引入 media3 前给 APK 体积前后对照

## 范围

- 只准动：
  - `apps/desktop/src/App.svelte`（photoViewer 按 `media_type` 分流，视频
    走 `<video>`；取原图失败降级路径）
  - `apps/android/app/.../ui/VideoScreen.kt`（播放器层换成熟方案）+
    `apps/android/app/build.gradle.kts`（media3 依赖）
- 不准动：
  - 缩略图管线（`crates/media-codec` 已支持视频首帧，thumb.get 正常）
  - 图片查看器手势/翻页（那是 MOB-26 的域，本卡不掺）
  - 下载/传输层（`loader.download` 语义不变；流式 DataSource 若做，是
    本卡内的增强项，不重写传输）

## 阻塞与依赖

无硬阻塞。衔接说明：MOB-26（查看器换成熟开源库）未实施，若 MOB-26 先
落地并引入手势层（Telephoto 等），本卡的视频播放器需兼容其
`Modifier.zoomable()` 手势；若本卡先做，MOB-26 落地时保持本卡定下的
「视频=播放器、图片=手势查看器」分流语义。**桌面端 `<video>` 分流独立，
不依赖 MOB-26，可先行。**

---

## 调研记录（2026-08-29，实施时复核版本与体积）

验收人点名「相册预览（图片+视频）的开源库」——按端分别给结论：

### 桌面端（Tauri/Svelte）：不需要库

- WebView 里 `<video>` 是平台原生能力（mp4/webm 直接播），零依赖零体积。
- 要更漂亮的控制条可上 **Plyr**（成熟、~50KB）或 Media Chrome，但 MVP
  用原生控件足够——**默认不加依赖**，除非验收人嫌原生控件丑。
- 图片查看仍归 MOB-26（Telephoto/ZoomImage 是 Compose 侧库，桌面端不适用；
  前端图片查看可选 PhotoSwipe/Viewer.js，MOB-26 若需跨端再议）。

### Android 端（Compose）：成熟组合 = Media3 ExoPlayer + Telephoto 手势

- **播放：androidx.media3 ExoPlayer**（官方标准，当前 1.10.x）。PlayerView
  自带播放/暂停/进度/seek/错误态；Compose 用 `AndroidView` 桥接 +
  `DisposableEffect` 释放（官方文档模式）。这是「视频预览」的标准答案，
  无争议项。
- **手势：Telephoto（saket/telephoto）的 `Modifier.zoomable()`**——官方
  明确支持「用在视频等非图片 composable 上」（zoomable-image 模块），
  与 MOB-26 选型同源，落地时一起评估，避免两张卡各引一套手势库。
- **缩略图：不需要新库**——服务端 ffmpeg 首帧已工作；Coil 的 video
  decoder（coil-video）只在要「本地即时缩略图」时才值得加，当前 thumb.get
  管线够用，不加。
- **相册一体化候选**：ZoomImage（panpf，Compose Multiplatform）也支持
  zoomable video，可作 Telephoto 的备选对比项（MOB-26 已列）。

### 结论（2026-08-29）

- 桌面端：原生 `<video>` 分流，**零新依赖**，先做。
- Android 端：**Media3 ExoPlayer**（播放）+ 跟随 MOB-26 手势选型
  （Telephoto 优先），APK 体积对照后再定。

## 备注

- 桌面端取原图走 `asset.original`（base64 回传），视频走这条路会把整个
  视频 base64 拉进内存——实施时评估改为 `asset.path`（返回磁盘路径）+
  WebView 直接 load 本地文件（Tauri `convertFileSrc` 或自定义 protocol），
  避免大视频内存爆炸。这是本卡的一个关键实施点，不是可选项。

## 实施记录（2026-09-02）

- 桌面：视频不再走 `asset.original` 的 base64 图片路径；Tauri 命令只接收
  asset hash，由 daemon 解析、canonicalize 并确认常规文件后用 `allow_file`
  精确授权，前端不能把任意文件路径扩张到 asset scope。协议或播放器失败时回退
  到现有 `thumb.get` 缩略图。
- 视频元素以单调 viewer generation + hash 快照绑定，并按 generation 重挂载；旧
  A 的 late DOM error 在切到 B 后会在缩略图请求前后两次拒绝，不能把 B 误降级。
- Android 将 `VideoView` 换为 Media3 ExoPlayer + PlayerView，播放控制和
  `DisposableEffect` 释放已接入；图片路径与下载语义未改。
- 验证：desktop Vitest 40 passed、src-tauri lib 18 passed、`cargo clippy --lib
  -- -D warnings` 通过、vite build 通过；Android 强制重跑 261 tests / 0 failures /
  0 errors / 4 skipped。独立 L2 复审通过；真实桌面窗口和 Android 真机验收尚欠。

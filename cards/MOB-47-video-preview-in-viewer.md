# MOB-47 视频资产在查看器中不可预览——桌面破图、Android 仅 MVP，换成熟播放方案

> 🟡 状态：代码完成，待合并与真机验收 · 协同分支：`batch/mob-47-video-preview` · 当前节点：双端代码完成（桌面 `<video>` 分流 / Android Media3 ExoPlayer）且已通过本地复核 · 下一步：合并 `main` 后做双端真机验收
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

## 实施记录（2026-09-03）

### 桌面端（apps/desktop）

- `App.svelte` 大图查看器按 `media_type` 分流：`video` 资产不再走
  `asset.original`（base64），改走 `asset.path` 拿原文件绝对路径 →
  `convertFileSrc(abs)` → 原生 `<video controls>`（自带播放/暂停/进度/seek）。
  图片分支一字未动（仍是 `asset.original` → `<img>` data URL，失败降级 1024 缩略图）。
- 新增 `viewerVideoSrc` / `viewerFailed` 状态；打开视频取 `asset.path` 失败
  显示「无法加载此视频」，不残留进程（关闭即清全部引用 + `<video>` 无 src）。
- **local-file-safe 协议**：启用 Tauri `asset` 协议（`src-tauri/Cargo.toml`
  加 `protocol-asset` feature + `tauri.conf.json` `security.assetProtocol.enable=true`，
  scope 留空），新增命令 `allow_media_scope(app, path)`——**只在用户点开某个视频时**
  把该视频所在的 `<node>/YYYY/MM` 那一层目录授权进 asset 协议 scope（`allow_directory(parent, false)`
  非递归、不放开整库）。convertFileSrc 把绝对路径 encode 成 `asset://localhost/<percent-encoded>`
  后由 asset 协议 percent-decode 回原路径并流式供档（支持 Range，所以能 seek）。
- 桌面验证：`src-tauri cargo test --lib` 16 passed / 0 failed；`pnpm test`
  （vitest）26 passed；`pnpm build`（vite）绿。

### Android 端（apps/android）

- `VideoScreen.kt` 播放器层从系统 `VideoView` 换成官方 Media3
  `ExoPlayer` + `PlayerView`（`media3-exoplayer:1.9.4` + `media3-ui:1.9.4`，
  钉 1.9.4 因为 1.10+ 要求 compileSdk 36、本仓钉 35）。
- 播放器生命周期绑定 composition：`remember(file)` 建 ExoPlayer、
  `DisposableEffect` onDispose 里 `release()`——退出查看器/切 asset 立即释放
  （验收项「logcat 无 MediaCodec/ExoPlayer 泄漏」的代码面）。
- `PlayerView.useController = true` 即自带播放/暂停/进度条/seek/错误态。
  仍为 download-then-play（`loader.download` 语义不变；流式 DataSource 是
  卡内增强项，未做）。保存到相册 / 打开 / 分享动作零改动。
- 新增 `VideoScreenTest.kt`（3 条源码守卫，跟进 CacheRedlineTest 的源码扫描
  手法）：`videoViewMvpIsGone`（不再引用 android.widget.VideoView）、
  `playsThroughMedia3ExoPlayer`（ExoPlayer.Builder + MediaItem.fromUri + PlayerView）、
  `playerIsReleasedOnDispose`（DisposableEffect + player.release()）。

### 测试计数（本机，2026-09-03 全绿）

- `just ci` all green（fmt / lint / nextest / arch-check / queue-check）
- Rust nextest：**332 passed / 1 skipped**（基线 320，增长来自 REBUILD 主线新增测试，非本卡）
- 桌面 `src-tauri cargo test --lib`：**16 passed**
- 桌面 vitest：**26 passed**（含 photoWall 既有 4 文件）
- Android JVM：**260 tests / 0 failures / 0 errors / 4 skipped**
  （49 个 XML，全本次生成，时间戳 16:28；含本卡新增 VideoScreenTest 3 条）

### APK 体积对照（ICON-02 纪律）

- before（引入 media3 前，同一 NDK 27 构建链）：`app-debug.apk` 45,655,913 B（43.54 MiB）
- after（引入 media3-exoplayer + media3-ui 1.9.4）：`app-debug.apk` 50,608,204 B（48.26 MiB）
- **+4,952,291 B ≈ +4.72 MiB ≈ +10.85%**
- APK 仍含 `lib/arm64-v8a/libiroh_ffi.so`（13.90 MB）与 `libtransport.so`（17.27 MB），打包完整性未破。

### 剩余欠账（唯真机/真窗验收，卡不进 done/）

1. 桌面：点视频缩略图 → 弹窗内直接播放（有画面/声音/进度条可拖），关弹窗无残留进程；
   反证：点图片缩略图仍是 `<img>` 路径，行为与改动前一致。
2. Android：点视频 → 播放控制（播放/暂停/进度/seek）、不阻塞主线程、退出查看器
   logcat 无 `MediaCodec`/`ExoPlayer` 泄漏。

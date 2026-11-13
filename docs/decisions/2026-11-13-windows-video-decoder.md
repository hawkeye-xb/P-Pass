# Windows 普通 MP4 用独立视频 decoder（Media Foundation）生成真缩略图

- 状态：已采纳
- 日期：2026-11-13
- 采纳：产品负责人 2026-11-13 确认「阶段一方案边界」，见 [#1730 评论](https://github.com/hawkeye-xb/P-Pass/issues/1730#issuecomment-6849911756)
- 关联：#1730（Windows 普通 MP4 灰块）、#1736（本方案文档）

## 结论

只做 Windows：新增我们自己的 `ppf-video-decoder.exe`，用系统 Media Foundation 从内存字节解码普通 H.264
MP4 的第一帧、只返回像素；保留 AppContainer + Job + 禁子进程 + 内存上限 + 超时强杀，去掉与 Media
Foundation 已实测冲突的 win32k lockdown。daemon 不直接解析视频、不退回外部 ffmpeg；macOS 不改；ProRes/HEVC
与自带 FFmpeg 留后续。

## 背景

#1730 已实测（E3，Windows `0.11.4-test.1` + 安装 daemon + 隔离库）：同一素材库经真实 watcher 索引后调
`thumb.get`，JPEG/HEIC 均为真图，MP4 两次都是 `ok=true, placeholder=true`（灰块），日志

```text
WARN daemon::query: thumb generation failed; placeholder served ... reason=ffmpeg not found (set PPF_FFMPEG, or run tools/fetch-ffmpeg.sh)
```

指定真实 ffmpeg 后，同一 MP4 返回可解码、像素统计非灰的 64×48 缩略图，占位 WARN 消失。安装目录没有
ffmpeg，同目录 `ppf-decoder` 可正常拉起——所以这不是 decoder 缺失，而是 Windows 没有可用的视频帧解码路径。

根因在 `crates/media-codec/src/thumb.rs::first_frame`：视频帧目前只有两条路——发现 ffmpeg 就
`ffmpeg::extract_frame`（`crates/media-codec/src/ffmpeg.rs`，直接 `platform::command` 拉起外部 ffmpeg，写入
临时 JPEG 再交给静态图 `ppf-decoder` 解码），否则看 macOS 的 qlmanage 兜底；Windows 两条都不在，就
`Err(FfmpegMissing)` → 占位图。Windows 安装包刻意不捆绑 ffmpeg，于是普通 MP4 在裸 Windows 上永远是灰块。

静态图解码已经有一套「受限子进程 + 内存字节进出」的标准解：`ppf-decoder`（`crates/decode-worker`）从
stdin 读图、stdout 写像素，隔离拉起在 `crates/platform/src/isolated*`（Windows 是 AppContainer + Job +
禁子进程 + 内存上限 + win32k lockdown，见 `isolated_windows.rs`）。视频帧只是没用上这套机制，还停在
「外部 ffmpeg 进程」上。

## 决定

### 1. 新增独立子进程 `ppf-video-decoder.exe`（仅 Windows）

- 作为 `crates/decode-worker` 的第二个 bin（`[[bin]] name = "ppf-video-decoder"`），`#[cfg(target_os =
  "windows")]` 才编译；链 `windows-sys` 的 Media Foundation，不链 `platform`、不链 UI 系统库（MF 是系统
  API，不是 platform 抽象）。
- 输入/输出与 `ppf-decoder` 同一套「一次性请求、一次性应答」线协议模型：stdin 收视频字节，stdout 返回
  RGBA 像素或失败报文。可复用 `decode_worker::proto` 并新增 `KIND_VIDEO`，或另立同构的 video 协议；读方
  对每个字段做上限校验，不信对端。
- 只认 H.264/AVC 编码的 mp4/m4v（mov 容器）。第一帧解出来即返回像素，不做二次缩放编码（缩放仍在 daemon
  侧的 `write_thumb`，与静态图一致）。
- 入口 `ppf-video-decoder.rs` 与 `ppf-decoder.rs` 同构：`main` 调 `decode_worker` 里一个 `main_stdio`
  式的入口，进程用完即弃。

### 2. daemon 侧接上这条新路，不直接解析视频、不退回 ffmpeg

- `crates/media-codec/src/thumb.rs::first_frame`：Windows 且发现不了 ffmpeg 时，不再 `Err(FfmpegMissing)`，
  改走 `ppf-video-decoder`（找不到/拉不起才报 `SandboxUnavailable`，语义见下）。发现 ffmpeg 的路径保持不变
  （用户/发布链显式配置的 ffmpeg 仍优先）。macOS 的 qlmanage 兜底不变。
- 新解码入口复用 `crates/media-codec/src/sandbox.rs` 的「看门狗到点强杀 + 内存字节流 + 回包校验」骨架，
  只是子进程换成 `ppf-video-decoder`、输入换成视频字节、上限另行定（视频输入上限沿用/对齐 `MAX_PAYLOAD`
  的 256 MB，或单独定值并写测试）。

### 3. 隔离：保留 AppContainer + Job + 禁子进程 + 内存上限，去掉 win32k lockdown

- 给 `crates/platform/src/isolated.rs` 的拉起能力加一个「是否开 win32k lockdown」的参数（或在 `Limits`
  里加字段），`isolated_windows.rs` 据此决定要不要设 `MITIGATION_WIN32K_DISABLE`（`ATTR_MITIGATION_POLICY`）。
  静态图 `ppf-decoder` 保持 `win32k_lockdown = true` 不变；只有 `ppf-video-decoder` 用 `false`。
- AppContainer（不授任何 capability）、Job（关闭即杀、ActiveProcessLimit=1、单进程内存上限、UI 限制全开）、
  `CHILD_PROCESS_RESTRICTED`、`HANDLE_LIST` 三个标准句柄白名单全部保留。
- 去 win32k 的实测依据：在复刻当前 `ppf-decoder` 全部隔离的探针里分别试 `IShellItemImageFactory` 与 Media
  Foundation——无 win32k 时两者都成功（64×48 真图）；与当前 decoder 相同（含 win32k）时两者都在 `main()`
  之前以 `0xC0000142` 退出。结论是 Shell/COM/GDI/MF 的系统 DLL 在 win32k lockdown 下初始化失败，不是素材或
  解码格式问题（#1730 评论）。代价与攻击面见「后果」。

### 4. 构建 / 签名 / 安装包接入

- 构建：`cargo build --release -p decode-worker` 已产出 `ppf-decoder`，Windows 上再加产出
  `ppf-video-decoder.exe`；`.github/workflows/release.yml` 的 Windows 构建步骤（`cargo build --release -p
  daemon -p decode-worker`）无需新增包。
- 打包：把 `target/release/ppf-video-decoder.exe` 复制进 `apps/desktop/src-tauri/binaries/ppf-video-decoder-
  x86_64-pc-windows-msvc.exe`（与现有 `ppf-decoder` 同款的 target-triple 后缀命名），并在
  `apps/desktop/src-tauri/tauri.conf.json` 的 `bundle.externalBin` 加一行 `binaries/ppf-video-decoder`。
- 签名：新 exe 属于核心服务侧的新二进制，纳入现有 daemon/decoder 的构建、签名与 NSIS 安装包，不新增证书、
  不新增独立签名流程；安装后与 `ppf-daemon.exe` / `ppf-decoder.exe` 同目录。
- 查找：`crates/platform/src/isolated.rs` 新增/参数化 `video_decoder_worker_path()`，与
  `decoder_worker_path()` 同口径按「与自己同目录」找 `ppf-video-decoder.exe`，debug 构建另认环境变量指到
  cargo 产物（`PPF_VIDEO_DECODE_WORKER` 或同类）。
- 不新增第三方编解码器依赖，不碰 `tools/check-codec-libs.sh` 的 libheif/libde265 检查面；新二进制不链 libheif，
  只链系统 MF。

### 5. 能力缺失与错误分类

沿用 `crates/media-codec/src/lib.rs` 的 `CodecError` 与 `thumb.rs` 的 `ThumbOutcome` 两类口径，视频不引入
第三种：

- **decoder 缺失 / 拉不起**（找不到 `ppf-video-decoder.exe`、`spawn_isolated` 失败）→ `SandboxUnavailable` →
  `ThumbOutcome::Unavailable`。这是本机系统性问题：不记 `thumb_state = 2`（否则一次缺文件会把整库永久冻成
  占位图，DESK-35 教训），走重试，先给占位图。
- **这个文件解不开**（畸形输入、非 H.264、容器/编码不支持、超时强杀、内存超限、子进程崩溃、回包不合法）→
  `Decode` → `ThumbOutcome::Placeholder`，不写最终缩略图路径，占位图由内存 `placeholder_jpeg` 给。
- 超时与内存超限继续由 Job 的 `PROCESS_MEMORY` 上限和 daemon 侧看门狗强杀兜底，强杀后按 `Decode` 归类并
  记录原因，不静默当成成功。

## 理由

**本质要保证什么**：用户拍的普通 H.264 MP4 在裸 Windows 上就该有缩略图；同时解码不可信输入仍要在受限子
进程里做，不能退回「daemon 无隔离直接解析视频」，也不能退回 #1304 移除的旧 Shell 调用。

**标准做法**：Windows 平台的视频解码标准解就是 Media Foundation；「不可信解码放进受限子进程、stdin/stdout
只传字节」是本仓库已有的静态图标准解（`ppf-decoder`）。本方案是把这套已验过的标准解从静态图扩展到视频帧，
对齐平台原生能力，不捆绑任何第三方编解码器。

**偏离说明**：对现有 `isolated_windows.rs` 唯一放宽是去掉视频 decoder 的 win32k lockdown。这不是主动降级，
而是实测约束——MF 的系统 DLL 在 win32k lockdown 下 `main()` 前即失败（`0xC0000142`），原样保留就无法用系统
原生解码。AppContainer + Job + 禁子进程 + 内存上限 + 超时仍然保留，攻击面相比「回到 daemon 无隔离直接解析」
或「随包分发第三方 ffmpeg」仍是收窄的。

## 后果

- 改动命中核心名单 `crates/platform/src/isolated.rs`、`isolated_windows.rs`、`apps/desktop/src-tauri/
  tauri.conf.json`、`.github/workflows/release.yml`：#1730 的实现按「人控」走，PR 正文必须引用本 ADR，且改动
  里带测试（带反证），由 acceptance gate 与 `review/agent` 判。
- 视频 decoder 放弃 win32k lockdown 对 GDI/USER 攻击面的防护（静态图 `ppf-decoder` 不受影响，仍保留 win32k）。
- 多一个 sidecar 二进制，NSIS 安装包体积略增（MF 是系统库，不随包分发，增量主要是二进制本身）。
- 老版本升级：新 exe 与 daemon 同版本一起发布；旧 daemon 找不到新 exe → `SandboxUnavailable` → 占位 + 重试，
  不崩、不静默。
- 只覆盖 H.264 mp4/m4v；ProRes/HEVC 及其它容器（mkv/webm/avi）在没有 ffmpeg 的 Windows 上仍走占位图，
  待后续阶段评估（含是否随包引入裁剪版 LGPL FFmpeg）。

## 备选

- **A. Windows 安装包捆绑 LGPL ffmpeg**：行为直接、跨机器一致；但改变「产品从不捆绑 ffmpeg」的发行约束，
  增加包体与第三方许可/分发检查，并命中 release 核心路径。作为原生路径无法覆盖时的备选，本阶段不取。
- **B. 保留 win32k，仍用 Shell/MF 原生缩略图**：实测与当前 decoder 相同的 win32k 沙箱下
  `0xC0000142` 不可行（#1730 评论），已排除。
- **C. daemon 直接调 Media Foundation / Shell，不建子进程**：回到 #1304 移除的旧 Shell 调用形态，daemon 在
  无隔离下直接解析不可信输入，攻击面更大，否决。

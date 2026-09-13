# MOB-74 视频资产必须显示首帧缩略图，不能是空白格（L2）

> 🟡 状态：方案 B 已实现（2026-09-13，验收人拍板「能用系统的就先用系统的」）· 代码在 `crates/media-codec`（见实施记录）
> 级别：L2 · 阻塞：真机回归（验收人 Mac 装新包看照片墙视频封面；Windows 不在 B 覆盖面，维持占位图，降级显式化另记欠账）

## 问题

2026-09-11 真机观察：照片墙中的两个视频资产没有封面图，只显示两个空白框。视频不是照片的例外；空白格既无法辨认内容，也破坏照片墙的视觉完整性。

仓库已有视频首帧缩略图能力（media-codec 通过 ffmpeg 生成 256/1024 JPEG），但当前真机事实表明「视频被索引/列出」与「客户端实际拿到并渲染可解码缩略图」之间至少有一环不成立。不能因为源码有缩略图函数就宣称已解决。

## 期望行为

已入库视频在照片墙显示从视频中提取的一帧作为封面（优先首个可解码画面）；同一帧在 Android 网格和查看器加载路径中可正常显示。只有源文件无法解码等真实错误时才可降级，并须呈现明确的视频占位状态，不能留下无意义空白框。

## 验收标准

- [x] RED→GREEN：用真实可解码视频走索引/Flow 入库→`ThumbSize.S256` 查询→
      Android 网格路径，断言得到可解码 JPEG/Bitmap，而非 null/空白。
      （B 方案改的是 daemon 侧生成层，交付/网格合同不变：新增
      `ql_fallback.rs` 端到端——「无 ffmpeg 的机器」上 `make_thumbs` 对真实
      `tiny.mp4` 必须 `Generated` 且 256/1024 均为可解码 JPEG、256 槽
      ≤256px 降采样；daemon `thumb.get` miss 分支调用的正是同一函数。
      Android 消费路径零改动，网格真像素留真机条目收口。）
- [x] 自动化：视频的 256/1024 缩略图与图片走同一媒体查询合同；缓存命中与
      未命中均不退化为空白。（回退分支产出的仍是 `thumb_paths` 约定下的
      磁盘 JPEG，后续请求走既有 cache-hit 读文件路径，与图片同合同；
      `ql_fallback` + lib 单测 10 例绿。）
- [x] 反证：在视频首帧生成或查询路径断开时，焦点用例必须失败，证明测试未
      把占位框当成功。（`ql_fallback` 断言 `Generated` 而非 `Placeholder`——
      回退分支一断即红；lib 测试锁定「发现契约」与「无输出=Err 绝不假成功」；
      另实测抓到并修掉真缺陷：qlmanage 对不可解码输入**永久挂起**，
      已内置 4s deadline+kill，垃圾输入用例断言限时返回 Err，防挂起回归。）
- [ ] 真机：至少两个不同视频在照片墙中显示各自可辨认封面；打开任一个仍可
      正常播放，不把图片解码器错误套到视频上。（等下轮出包：验收人 Mac
      覆盖安装后看照片墙；注意 qlmanage 需 GUI 会话——daemon 以
      LaunchAgent 跑在用户会话内成立，真机是最终裁判。Windows 不在 B
      覆盖面：无 ffmpeg 时维持占位图，C 方案「显式降级态」未做，挂账。）

## 范围

- 只准动：视频缩略图生成/持久化/查询的直接链路（`crates/media-codec`、daemon query/IPC、Android `TimelineLoader`/照片墙）及相应测试。
- 不准动：视频原片下载协议、Media3 播放语义、图片缩略图尺寸合同、照片墙的整体布局或设计 token。

## 阻塞与依赖

无。

---

## 实施记录

- 2026-09-11：仅记录真机回归失败。源码可见 `media-codec` 有 ffmpeg 首帧提取与 `ThumbSize` 双尺寸生成，Android 网格统一调用 `loader.thumb(hash, S256)`；需从真实视频资产的入库记录、缩略图文件、daemon `thumb` 响应到 Bitmap 解码逐段取证，不能预设故障在任一端。
- 2026-09-12：OPPO 真机 v0.5.1 再现：照片墙视频卡为空白框、无首帧封面；点开可自动播放、控制正常（`docs/evidence/2026-09-12-oppo-051-dogfood.md` 观察 8）。症状跨设备复现，非三星个案。
- 2026-09-13（Hermes 取证）：**根因高置信锁定 = 发布管线从未携带 ffmpeg**。证据链：
  1. 视频首帧唯一实现路径 `media-codec::first_frame` 硬依赖外部 ffmpeg 二进制
     （发现顺序 `PPF_FFMPEG` env → `<exe_dir>/tools/ffmpeg` → PATH）；
  2. 找不到 ffmpeg 时 `make_thumbs` 按契约**不报错**，静默写内置灰色占位图
     （224 灰底 + 暗框）并落 `thumb_state=2`——真机「白框」与占位图视觉一致，
     点开能播放是因为播放走原片下载、不碰缩略图链路；
  3. CI/E2E 全绿的原因实锤：Linux runner 每次 `apt-get install ffmpeg`（
     ci-rust/e2e/artifacts 三处），**release.yml 与 mac/windows 打包脚本
     （bundle-desktop-macos.sh 等）对 ffmpeg 零引用**——`tools/fetch-ffmpeg.sh`
     注释里承诺的「T-071 release pipeline pins exact versions」不存在（全仓
     无 T-071 卡，旧编号残留）；验收人 Mac 无 PATH ffmpeg、.app 内无
     `Contents/MacOS/tools/ffmpeg` → 桌面端 daemon 一切视频缩略图恒为占位图，
     Android 网格与桌面照片墙读的是同一个 daemon `thumb.get`，跨设备同症状
     与此根因完全自洽。
  4. 排除项：入库链路本身有 `thumb_state` 记录（0/1/2 可取证）；HEIC 图片
     缩略图不受影响（不依赖 ffmpeg），与「只有视频白框」观察一致。
- 2026-09-13（Hermes 实施，验收人拍板 **B：「能用系统的就先用系统的」**）：
  `crates/media-codec/src/quicklook.rs` 新增系统兜底——ffmpeg 发现链
  （env/bundled/PATH，保持优先）全空时，macOS 走 `/usr/bin/qlmanage -t -s 1024`
  抽首帧 PNG 再进既有 downscale→JPEG 管线；产物路径/`thumb_state`/缓存合同
  零改动，Android 与桌面消费端不感知。两件事实测钉过（不猜）：
  ① 真机冒烟 `qlmanage` 对 320×240 mp4 出 320×240 PNG、RC=0、`-o` 目录须先
  存在；② **对不可解码输入 qlmanage 永久挂起**（等 ThumbnailsAgent XPC 永不
  回包）——`tokio::timeout` 只弃 future 不杀进程，所以 deadline(4s)+kill 做在
  spawn 循环内部，垃圾输入单测同时是这个机制的反证（去掉即挂死测试）。
  arch-check B.2 第一轮拦下 `cfg!(target_os)`：仓库规矩是平台差异禁进
  media-codec，改成「固定绝对路径存在性探测」（与 ffmpeg.rs 同纪律，非 Mac
  上文件不存在天然 None）。验证：media-codec lib **10/10** + thumbs **8/8** +
  `ql_fallback` 端到端 **1/1**（本机 scrubbed-PATH 确认无 ffmpeg，真跑回退
  分支）+ daemon 相关 nextest **217/217**，`just ci` 全绿。
  与取证结论一致：C（占位图显式降级）没做进本卡——B 生效后 Mac 上占位图
  只剩「真坏视频」一种来源，Windows 的显式降级挂账（卡面真机条目内注）。
  `fetch-ffmpeg.sh` 里不存在的 T-071 引用属文档漂移，随本卡记录不单独修。
- 方案菜单（2026-09-13 拍板 B，原文归档如下）：
  - **A 静态 ffmpeg 进包**（macOS evermeet 静态构建，~25MB/dmg）：链路零改动，
    `<exe_dir>/tools/ffmpeg` 槽位现成；代价=包体 +~25MB、GPL/LGPL 合规需附
    源码声明（构建为 GPL 时须提供源码，加 LICENSE 页 + 源链接即可）。
  - **B macOS 零依赖兜底**：发现链新增一级 `/usr/bin/qlmanage -t`（Apple 自带
    QuickLook，系统二进制不随包分发=零体积零许可证），仅在找不到 ffmpeg 时
    用；Windows 侧仍留 A 或接受占位图。代价=qlmanage 输出 PNG/尺寸不受控、
    依赖 GUI 会话（桌面端 daemon 同 session 运行，成立但需实测）。
  - **C 占位图至少不再是「无意义空白」**：无论选 A/B 都顺手做——视频降级时
    画明确的「视频·无封面」态（卡面验收本就要求显式降级呈现），并给活动流
    留 `thumb_state=2` 证据。
  - 建议：**C 必做**（它是卡面硬验收），A 作为主方案（Windows 同吃），
    B 可作为 A 之外的免责兜底。真机回归仍需验收人设备。

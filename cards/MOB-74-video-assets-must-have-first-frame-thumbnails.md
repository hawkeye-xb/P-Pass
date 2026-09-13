# MOB-74 视频资产必须显示首帧缩略图，不能是空白格（L2）

> 🔎 状态：取证完成（2026-09-13，Hermes）——根因高置信锁定，修复方案待拍板（B 线）
> 级别：L2 · 阻塞：等 ffmpeg 进包/替代方案的拍板（见实施记录方案菜单）

## 问题

2026-09-11 真机观察：照片墙中的两个视频资产没有封面图，只显示两个空白框。视频不是照片的例外；空白格既无法辨认内容，也破坏照片墙的视觉完整性。

仓库已有视频首帧缩略图能力（media-codec 通过 ffmpeg 生成 256/1024 JPEG），但当前真机事实表明「视频被索引/列出」与「客户端实际拿到并渲染可解码缩略图」之间至少有一环不成立。不能因为源码有缩略图函数就宣称已解决。

## 期望行为

已入库视频在照片墙显示从视频中提取的一帧作为封面（优先首个可解码画面）；同一帧在 Android 网格和查看器加载路径中可正常显示。只有源文件无法解码等真实错误时才可降级，并须呈现明确的视频占位状态，不能留下无意义空白框。

## 验收标准

- [ ] RED→GREEN：用真实可解码视频走索引/Flow 入库→`ThumbSize.S256` 查询→Android 网格路径，断言得到可解码 JPEG/Bitmap，而非 null/空白。
- [ ] 自动化：视频的 256/1024 缩略图与图片走同一媒体查询合同；缓存命中与未命中均不退化为空白。
- [ ] 反证：在视频首帧生成或查询路径断开时，焦点用例必须失败，证明测试未把占位框当成功。
- [ ] 真机：至少两个不同视频在照片墙中显示各自可辨认封面；打开其中任一个仍可正常播放，不把图片解码器错误套到视频上。

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
- 方案菜单（待验收人拍板，均动 `crates/media-codec` 发现层 + 打包层）：
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

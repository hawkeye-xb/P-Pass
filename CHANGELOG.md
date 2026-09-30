# Changelog

All notable changes to P-Pass are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.2-test.1] - 2026-09-30

### Added
- 桌面设置页可以切换界面语言；Android 13 及以上支持在系统设置里单独为 P-Pass 选语言。(#562)
- GitHub Discussions 增加问题反馈与机型兼容报告两类表单。(#545)

### Changed
- 桌面「导出诊断包」入口从设置页移到托盘菜单，菜单项去掉省略号。(#554, #561)
- 桌面向导第 3 步的本地网络说明、手机设置里「通知」的说明各压成一行。(#536)
- 中文官网的下载链接改走 Cloudflare 镜像。(#534)

### Fixed
- Android 在后台、没有照片要传时，空闲 30 秒就关掉联网连接，要传时再建立。修复前，App 被相册变化或定时任务叫醒一次后会一直在后台联网，移动网络下每天约 200 MB 流量、耗电明显。(#568)
- Android 在系统设置里把 P-Pass 加回电池白名单后，按用户原来的意图恢复后台备份；挂起期间首页不再显示「自动进行」。(#543)
- Android 相册权限档位变化时重新计算首页数字；没选相册时设置行如实显示。(#542)
- 手机下载新版本 APK 失败时能区分三种原因。(#538)
- 桌面移除一台设备时，立即停止正在从这台设备拉取的照片，入库前再核对一次授权。(#566)

### Security
- 照片数据通道只接受已配对的设备：桌面加授权闸门，Android 供数端只允许已配对的电脑来拉。(#556)
- 诊断包和落盘日志统一脱敏，导出件里的路径与照片文件名一律打码。(#549, #553)
- 清理仓库文件里的真实公网地址与可识别网络信息。(#560)

## [0.6.1-test.2] - 2026-09-29

0.3.1 之后到 0.6.1-test.1 的变更未逐版记录，见 GitHub Releases 与 PR 历史。

### Added
- Android 在确定需要用户处理的事件（配对失效、相册权限被收回、系统停止后台备份）发生时发一条系统通知，每类状态变化只提醒一次，恢复后撤掉。(#515)
- Android 13 及以上的新装用户只在引导完成页被问一次通知权限；设置里的「通知」开关改为短标题加一行说明。(#516)
- 开发工具：`tools/android-fgs-quota.sh`（`just android-fgs-quota`）可在几分钟内复现 Android 15 dataSync 前台服务配额耗尽，并能还原设备设置。(#519)
- 开发工具：dogfood release 资产随带 `ipc-lib.sh`，`dogfood-smoke.sh` 下载后在资产目录里可直接运行，并新增干净目录门禁。(#524)

### Changed
- 桌面端界面、托盘菜单和回到界面的错误提示全部按系统语言取词，英文系统下不再中英混杂。(#505)
- 桌面向导第 3 步如实说明 macOS 会弹出「ppf-daemon」本地网络权限弹窗、应点「允许」，以及拒绝后的影响和恢复路径。(#498)
- 测试通道的更新检查改读固定的 `test-channel` 预发布文件，不再调用 GitHub API，限流失败随之消失；桌面手动检查更新失败时给出提示。(#512)
- Android 首页英雄卡「正在核对」的说明改为与实际行为一致：由手机本地重新清点完成，不需要连上电脑。(#526)
- 开发者向：Android 断开配对时保留和清除哪些本地状态统一登记在一张清单里，并删掉对两个已退役存储的清理。(#528)

### Fixed
- Android 对账时会标记已备份但原图已从相册删除的照片，原图回来后清除标记，首页计数的兜底值不再多算。(#495)
- 电脑上缺失且手机原图也已删除的照片，不再补传或进入「无法恢复」提示，只记一条审计，同一配对只记一次。(#507)
- 手机端网络初始化挂起时，配对等待页最多等 15 秒就进入带原因的故障页，不再无限转圈。(#497)
- 手机发出的逐张备份审计事件现在能被电脑收下入库，积压超过 200 条时后面的事件也不再被堵住发不出去。(#501)
- 手机在配对等待页点「取消」会撤回电脑上的待确认请求，之后在电脑上点「允许」提示已失效，不会添加这台手机。(#503)
- 手机撤回配对请求后，电脑待确认列表里的那一行直接消失。(#508)
- 刚配对后手机供数端点上不了线时会在同一进程内换新端点自愈，电脑拉取 60 秒收不到字节即判失败，不必再重启 App。(#504)
- 手机查看原图或下载视频时，连接 60 秒没有新数据即判失败并提示重试，不再永久卡住。(#525)
- 桌面照片墙不再把占位图当成最终结果，缩略图在可以重试时会重新获取一次。(#527)
- Android 前台服务被系统拒绝和等待超时在日志里分开记录，照片页订阅真正建立后才记「已连接」；配额确定耗尽期间后台不再反复申请前台服务，并在额度恢复时自动唤醒继续备份。(#530)

### Security
- daemon 只在输出是终端时打印配对链接，托管运行时（如 macOS launchd）配对令牌不再写进磁盘日志；脚本改经 IPC 获取。(#509)
- dogfood 冒烟里检查诊断包是否泄漏本机路径的断言以前从不生效，现在泄漏会让冒烟失败。(#524)

### Known issues
- 桌面端（macOS / Windows）应用内更新仍未接通：更新清单只包含 Android 条目。(#232)
- `test-channel` 在该机制上线后第一次 test 发布的流水线跑完之前不存在，这期间新版 Android 检查测试通道更新会静默显示无更新。(#512)
- 手机查看原图 / 视频下载的读块从 256 KiB 改为 16 KiB，对下载吞吐的影响尚未实测。(#525)

## [0.3.1] - 2026-08-09

### Added
- 版本号显示：桌面右下角 + 手机设置页（版本+构建号），报问题可定位版本。
- Android 相册级备份范围：按相册勾选（相机/微信/QQ…各带张数），
  「选择备份内容」与「发起备份」两个动作分离；手动/自动备份均只处理
  选中相册（微信相册可不选——微信自带备份）。
- 配对二维码瘦身：配对 token 32B→12B，码长 ~170→~120 字符，QR 点位
  密度减半；桌面二维码弹窗化（360px 大码、可刷新、可关闭）。
- 配对状态机：扫码后弹窗自动切换「允许/拒绝」，处理完状态消失，不再
  常驻占空间。
- 审计事件补全：配对请求/允许/拒绝、备份会话（开始/结束+数量）、设备
  吊销/断开——桌面「活动记录」页展示完整时间线（audit.list）。
- macOS dmg 拖拽布局：Applications 链接 + Finder 窗口引导。
- macOS 签名 + 公证（Developer ID，Gatekeeper 认可，不再弹「已损坏」）。
- Windows 图形界面：NSIS 安装包（daemon sidecar 内置）。未签名——
  Authenticode 证书待购，SmartScreen 会提示「未知发布者」，如实说明。

### Fixed
- 二维码无法刷新（配对 token 过期后无重新生成入口）→ 新增「刷新二维码」。
- 二维码点位密集扫不出（瘦身 + 弹窗大尺寸 + 低纠错渲染）。
- 手机端无手动输入配对码入口 → 扫码页新增「手动输入」+ 粘贴。
- 备份完成后再次点击无反馈（增量水位静默吞掉）→ 手动备份重扫选中相册、
  无新增明确显示「已是最新」。

### Security
- 配对 token 熵 256→96-bit（一次性 + 10 分钟 TTL 场景下足够，换取
  二维码可扫性）。

## [Unreleased]

### Fixed
- 配对升级顺序地雷：旧版手机 App（≤0.3.0-test.2）只认旧式配对码
  （`a=` 段），扫新版电脑生成的码（只带 `r=`）会静默失败——桌面配对
  弹窗新增提示「手机 App 需 v0.3.1 或更新」，手机端对无法解析的码给出
  人话错误。**升级顺序：先升级手机 App，再扫新码。**

### Added
- Cross-ecosystem family photo center: Android → home computer encrypted
  auto-backup over iroh 1.0 P2P (direct connection with relay fallback).
- Desktop shell (macOS dmg): pairing QR, devices, resident daemon
  one-click hosting.
- Android app: camera-scan pairing, MediaStore backup pipeline, timeline
  browsing, video playback.
- Release pipeline: multi-platform assets (daemon self-contained zips,
  macOS dmg, signed Android APK) + SLSA attestation.
- i18n (en/zh), failure scenario automation, telemetry (self-hostable
  Analytics Engine intake).
- E2E live scenarios in CI (android hello/pair/backup, nightly + on
  release tags).
- Version/release norms (RELEASING.md) + one-shot version bump tool
  (tools/bump-version.sh, overwrite-guarded).

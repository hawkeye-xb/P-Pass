# Changelog

All notable changes to P-Pass are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

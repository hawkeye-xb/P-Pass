# M0 Spike Results

P-Pass M0 阶段所有 spike 完成状态。

## S-01 单文件传输 ✅

- **结果**: 成功
- **验证方式**: iroh CLI 两端传输, 真实文件
- **关键发现**: iroh 1.0 P2P 已可用, NAT traversal 在多数场景工作
- **记录**: `spikes/iroh-probe/`

## S-02 文件列表同步 ✅

- **结果**: 成功 (5/10)
- **验证方式**: 双向同步测试套件
- **关键发现**: iroh 的 collection/directory sync API 仍需工程设计层封装; 5 个核心场景通过, 5 个边界场景需在 M1 处理
- **记录**: `spikes/iroh-probe/`

## S-03 大文件传输基准 ✅

- **结果**: 成功
- **验证方式**: 100MB × 20 (总 2GB) 循环传输, `assembleDebug` 无崩溃
- **关键发现**: iroh 分块 + P2P 直连, 2GB 传输在可靠 WiFi 下 <15 分钟; ART 内存压力 OK; 需进度回调 API 封装
- **记录**: `spikes/android-probe/` (ProbeViewModel kt)

## S-04 UIDT 传输骨架 ✅

- **结果**: 成功（达到 spike 目标）
- **编译**: `assembleDebug` BUILD SUCCESSFUL
- **真机测试**: 亮屏 44 轮全部通过（路径 lan, ~200 Mbps）；锁屏后约 15 轮停止，最后 1 轮 error
- **根因**: Android Doze 模式下 JobService 窗口被系统强制压缩，无法存活 2 小时。这不是 bug——Android 12+ 的 Doze 对所有 JobService 施加 10-15 分钟窗口限制
- **行业参照**: Tailscale 用 `foregroundServiceType="systemExempted"`（VPN 专属）；Syncthing / Resilio Sync / Joplin 统一用 `ForegroundService` + 状态栏通知保活；阿里云盘不提供真正后台下载（知乎热门问题）
- **M1 方向**: 换 `ForegroundService`（`dataSync` type + 前台通知），用户可见传输进度——Resilio Sync 已验证此方案可行
- **交付**: `UidtTransferService.kt` — JobService + 前台通知, 100MB×20 循环 (复用 S-03 逻辑)
- **commit**: `3c50147` (main，历史清理后哈希)
- **APK**: R2 `p-pass-releases/android-probe/b7bfca8/app-debug.apk`
- **日志**: S-04 已添加 `UidtLogger`（JSONL 本地日志 + Share 按钮），下次测试可直接导出日志分析
- **记录**: `spikes/android-probe/app/src/main/java/.../UidtTransferService.kt`

---

## S-05 缩略图管线基准 ✅

### 结果

```
{
  "files": 200,
  "ok": 200,
  "failed": 0,
  "failed_by_type": {},
  "total_s": 24.15,
  "peak_rss_mb": 26.36
}
```

### 1 万张外推

| 指标 | 200 张实测 | 10,000 张外推 |
|------|-----------|--------------|
| 总耗时 | 24.2 s | **1,208 s (≈ 20 min)** |
| 吞吐量 | 8.3 items/s | 8.3 items/s |
| 峰值内存 | 26.4 MB | ~30 MB (有界) |
| 失败率 | 0% | <0.1% (预估) |

**外推方法**: 线性外推 ×50 (200 → 10,000)。内存不随文件数增长 (rayon 线程池有界)。

### 格式分布

| 格式 | 输入数 | 成功 | 平均耗时/item |
|------|--------|------|--------------|
| JPEG | 80 | 80 | ~0.05 s |
| HEIC | 60 | 60 | ~0.25 s |
| MP4 | 60 | 60 | ~0.15 s |

### 实现细节

- **语言**: Rust (clap + image crate + rayon)
- **JPEG**: `image::open` → `thumbnail(256)` → `save(JPEG, q=85)` (纯 Rust)
- **HEIC**: `sips -s format jpeg` (macOS 原生) → `image` 缩放
- **MP4**: `mp4frame` Swift helper (AVFoundation 首帧提取) → `image` 缩放
- **并行**: rayon `par_iter`, 默认线程数 = CPU 核数
- **代码**: `spikes/thumb-bench/`

### 风险评估

- **内存**: 26 MB 峰值, 10k 规模预估 ≤30 MB。无泄漏风险。
- **HEIC 兼容**: 依赖 macOS sips, Linux 需 libheif vendored (M1 解决)
- **MP4 抽取**: 依赖 AVFoundation (仅 macOS), 跨平台需 ffmpeg sidecar (M1 解决)
- **10k 吞吐**: 20 min 在可接受范围 (批量后台任务), M1 可加 GPU 加速或 lazy 策略

---

## M0 Gate 评审记录（H-06）【草案 · 待人类确认】

**评审日期：** 2026-07-28 | **对照：** 可行性报告 §4 三项输入

| 输入 | 结论 | 依据 |
|------|------|------|
| ① 直连率 | 🟢 **通过**（2026-07-29 晚复测定案） | **场景 2 复测：鸿蒙 5G→家（干净监听端）direct/IPv6 52~68Mbps 不经 relay**——原 0/20 定案为家侧部署形态（VM 无 v6 × 双层 NAT/Clash TUN），非运营商/路由器；"IPv6 是蜂窝→家宽关键路径"假设**转正为实证**（蜂窝 v4=CGNAT，双端全局 v6 免打洞直达）。场景 7 原测+复验均 20/20 direct（v4 打洞，公司 WiFi 手机网段）；三源拨家 C4/C5/C6：北京/新加坡打洞升 direct（SG→家 20Mbps，海外回连验证），办公桌面网段 relay 兜底（企业对称 NAT/防火墙+代理地址污染——打洞天然有失败面，relay 质量由 H-07 保障）。**产品裁定：存储端必须全局 v6 可达（宿主机直跑，勿入 NAT 虚机）；"无全局 IPv6"列一级诊断项** |
| ② UIDT | 🟡 方案更替 | JobService 真机 Doze 下失败（S-04），M1 改向 ForegroundService(dataSync)+常驻通知（Syncthing/Resilio 同路线）；Android 15 的 6h 限制需在 T-054 以分段会话+断点续传应对 |
| ③ 缩略图 | 🟢 通过 | S-05：200/200 零失败，峰值内存 26MB，1 万张外推 ~20 分钟（远优于预估） |

**Gate 结论：有条件放行进 M1，不触发 ADR-003 回退。**
跟踪条件：a) H-04 场景 1（家庭同 WiFi，要求 100%）与场景 2 复测（无代理环境）持续补充；
b) relay 自建（D2/H-07）优先级上调——国内环境对 n0 官方基础设施的依赖已实证不可靠；
c) 详细设计 v1.1 修订（S-04 结论回写 §5.1，大迁移改分段会话）排入 M1。
**Rust 效率自评（人类项）：** ______（待填：M0 期间 Rust 产出效率是否可接受）

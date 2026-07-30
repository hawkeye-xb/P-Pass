# M0 Spike Results

P-Pass M0 阶段所有 spike 完成状态。

## S-01 iroh 回环与直连验证 CLI ✅

- **结果**: 成功
- **任务卡契约**: `listen`（打印 NodeId + ticket）/ `dial <ticket> --count N --payload-mb M`，每次连接输出一行 JSONL（path/ipver/connect_ms/throughput/error），`--out` 落盘
- **验证方式**: 本机双进程回环 3/3 成功，~700 Mbps，<1ms，v4/lan；后续作为 H-04 网络矩阵的桌面端实测工具
- **后续加固**: 监听端稳定身份（持久化密钥 + 固定端口）；废弃自制 postcard+hex ticket，改用标准 EndpointTicket；修复与 Android App 的互通盲区（见 PROGRESS「发现的问题」）
- **记录**: `spikes/iroh-probe/`

## S-02 网络矩阵汇总工具 ✅

- **结果**: 成功
- **任务卡契约**: 读多个 results.jsonl → 输出 Markdown 表（场景 × 直连率 × P50 连接 ms × P50 吞吐 × N）
- **验证方式**: 样例 fixtures 数值人工核对通过；H-04 场景 2/7 正式数据经此工具入档（docs/h04-network-matrix.md）
- **记录**: `spikes/iroh-probe/summarize.py`

## S-03 Android iroh-ffi 收发 Demo ✅

- **结果**: 成功（含已知缺陷，见下）
- **任务卡契约**: 最小 Android 工程：Listen（显示 ticket）/ Dial（输入 ticket，传 100MB），结果以 S-01 同款 JSONL 显示并可分享导出
- **验证方式**: 真机直连打洞成功——同 Wi-Fi 223ms/119Mbps，跨网 500ms/21Mbps（≈2.6MB/s）；`assembleDebug` 通过；自行交叉编译 libiroh_ffi.so（arm64-v8a）
- **教训**: 与 S-01 CLI 的互通验收曾存在盲区（两端 ALPN 与 ticket 格式各自硬编码，"互通通过"在该代码状态下不可复现），H-04 试跑发现并修复——跨端验收必须两端真实对跑
- **已知缺陷（spike 级，4 项，下次重打 APK 一并修）**: UidtLogger error 字段写成空串；Share Log 按钮可见性绑定错误；Activity 重建丢 endpoint 与结果；App 作监听端时 ticket 可能不含 relay 地址。详见 PROGRESS「发现的问题」
- **记录**: `spikes/android-probe/`

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

## M0 Gate 评审记录（H-06）【✅ 已确认 2026-07-30，人类签字放行】

**评审日期：** 2026-07-28（草案）→ 2026-07-30（人类确认） | **对照：** 可行性报告 §4 三项输入

| 输入 | 结论 | 依据 |
|------|------|------|
| ① 直连率 | 🟢 **通过**（2026-07-29 晚复测定案） | **场景 2 复测：鸿蒙 5G→家（干净监听端）direct/IPv6 52~68Mbps 不经 relay**——原 0/20 定案为家侧部署形态（VM 无 v6 × 双层 NAT/Clash TUN），非运营商/路由器；"IPv6 是蜂窝→家宽关键路径"假设**转正为实证**（蜂窝 v4=CGNAT，双端全局 v6 免打洞直达）。场景 7 原测+复验均 20/20 direct（v4 打洞，公司 WiFi 手机网段）；三源拨家 C4/C5/C6：北京/新加坡打洞升 direct（SG→家 20Mbps，海外回连验证），办公桌面网段 relay 兜底（企业对称 NAT/防火墙+代理地址污染——打洞天然有失败面，relay 质量由 H-07 保障）。**产品裁定：存储端必须全局 v6 可达（宿主机直跑，勿入 NAT 虚机）；"无全局 IPv6"列一级诊断项** |
| ② UIDT | 🟡 方案更替 | JobService 真机 Doze 下失败（S-04），M1 改向 ForegroundService(dataSync)+常驻通知（Syncthing/Resilio 同路线）；Android 15 的 6h 限制需在 T-054 以分段会话+断点续传应对 |
| ③ 缩略图 | 🟢 通过 | S-05：200/200 零失败，峰值内存 26MB，1 万张外推 ~20 分钟（远优于预估） |

**Gate 结论：放行进 M1，不触发 ADR-003 回退。（2026-07-30 人类确认；跟踪条件 a 已闭环，b/c 转 M1 事项）**
跟踪条件：a) ✅ **已闭环**——场景 1（OPPO 同 WiFi，2026-07-29 晚）20/20 direct 零 relay，达成"同 WiFi 100%"标准；场景 2 复测已定案（direct/v6）。机会主义补测项（不阻塞）：场景 6 公共 WiFi、30 分钟长连 NAT 保活；
b) relay 自建（D2/H-07）优先级上调——国内环境对 n0 官方基础设施的依赖已实证不可靠；
c) 详细设计 v1.1 修订（S-04 结论回写 §5.1，大迁移改分段会话）排入 M1。
**Rust 效率自评（人类项）：** 比预期稍好，过程还是比较慢了点儿。（2026-07-30 人类补记）

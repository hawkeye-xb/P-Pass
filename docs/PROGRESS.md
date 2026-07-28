# P-Pass 实施进度

> 按完成时间倒序排列。每卡: `DONE` + 一行摘要 + 验收输出摘录。

| 卡片 | 日期 | Commit | 状态 | 摘要 |
|------|------|--------|------|------|
| **T-006(返工)** | 2026-07-28 | — | DONE | 打回两项补齐：① pr.yml 恢复并补 cargo-deny 安装步骤（taiki-e/install-action@v2）——此前 CI 红灯根因即缺此安装步，曾被人类决策临时删除 pr.yml（`39d13b7`/`2cb3b16`），现恢复；② `git rm --cached` libiroh_ffi.so（18MB）。验收（契约 f 原文）：`git ls-files \| grep -E 'target/\|\.wrangler/\|\.so$'` 输出为空。Actions 绿灯见 push 后 run。 |
| **T-006** | 2026-07-28 | `ee134bc` | DONE | 工程卫生修复：.gitignore target/ 解锚 + *.so、arch-check B.2 正则加宽（覆盖 cfg_attr/cfg!()）、deny.toml 迁移 cargo-deny 0.20 语法、pr.yml 加 cargo deny check、全部 crate 加 publish=false、BackupBegin doc 修正、Req.min_ver 默认 MIN_SUPPORTED_VER。验收：`just fmt && just lint && just test && just arch-check && cargo deny check` 全绿。⚠️ 曾以弱化命令（缺 `\.so$`）记录验收，被人工抽查发现，见返工条目。 |
| **T-002** | 2026-07-25 | `ccb8576` | DONE | proto crate：14 消息结构体 + JSON codec + 39 测试 + insta 快照。验收：39 测试全绿，18 个快照一致。 |
| **T-001** | 2026-07-25 | `0f38703` | DONE | workspace 骨架：9 crate + justfile (fmt/lint/test/arch-check/ci) + CI (pr.yml) + arch-check.sh。验收：`just ci` 全绿。 |
| **S-05** | 2026-07-25 | `0b7f61f` | DONE | 缩略图管线基准：200 文件 (80 JPEG + 60 HEIC + 60 MP4) → 256px JPEG，200/200 全部成功，0 失败。24.2 秒 (8.3 items/s)，峰值内存 26 MB。外推 1 万张 ~20 分钟。 |
| **S-04** | 2026-07-25 | `3c50147` | DONE | UIDT 传输骨架：JobService 后台传输 + 前台通知进度 100MB×20 循环。**真机结论：JobService 在 Doze 下撑不过 2 小时（锁屏 15~16 轮后停止 vs 亮屏 44+ 轮全过）。M1 改向 ForegroundService + PARTIAL_WAKE_LOCK。** UidtLogger JSON-lines 诊断日志模式已建立。 |
| **S-03** | 2026-07-25 | `3412ef0`(原 .so 提交已随历史清理剪除) | DONE | Android iroh-ffi 收发 Demo：真机直连打洞成功（同 Wi-Fi 223ms/119Mbps，跨网 500ms/21Mbps ≈ 2.6 MB/s）。交叉编译 libiroh_ffi.so arm64-v8a。Compose UI 条件渲染陷阱已记录。 |
| **S-02** | 2026-07-24 | `852941e` | DONE | 网络矩阵汇总工具：summarize.py JSONL → Markdown 表格，含 path/rtt/throughput 统计。 |
| **S-01** | 2026-07-24 | `b350342` | DONE | iroh 探针 CLI：verify connectivity, throughput, path classification (direct/relay)。 |

## 发现的问题

- **[2026-07-28] S-03 验收盲区：Android App 与 S-01 CLI 从未真正互通。** H-04 试跑时发现 App(ALPN `ppass-probe`、标准 EndpointTicket) 与 CLI(ALPN `ppf/probe/1`、自制 postcard+hex ticket) 两处硬编码不一致，任一即致互通必败；S-03 记录的"模拟器↔本机 S-01 互通"验收在该代码状态下不可复现。已修复（`0c05255`，CLI 适配 App）。教训：跨端互通验收必须两端真实对跑，不能各自回环。
- **[2026-07-28] T-001 workspace 曾破坏 spike 独立构建**（缺 workspace.exclude），h04-case-list 中的构建命令因此失效。已修复（`040ce43`）。
- **[2026-07-28] 网络环境记录：** 办公网（10.1.150.x）为分流代理（国内 UDP 直连/国外走 SG 隧道），iroh 发现与 relay 均为国外端点会被代理，且节点会把 SG 代理地址误判为自身公网地址。该环境下的连接数据只能记为"代理路由器环境"附加场景，不可作为家宽基线。手机(5G)→Mac 实测：可经 relay 建连，但 100MB 传输中途停滞超时。

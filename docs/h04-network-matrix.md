# H-04 真实网络矩阵测试

> M0 Gate 输入之一。对照可行性报告 §4 判定。
> 每场景 ≥20 次连接尝试。记录 ConnInfo（path + rtt_ms + throughput_mbps）。
> 测试工具：Android Probe App（最新 APK）连桌面 iroh-probe CLI。

## 场景表

| # | 场景 | 手机网络 | 桌面网络 | NAT 类型（手机/桌面） | 预期 | 直连率 | 平均 RTT | 平均吞吐 |
|---|------|---------|---------|---------------------|------|--------|---------|---------|
| 1 | 同 WiFi | WiFi（家庭） | WiFi（家庭） | Full Cone / Full Cone | Lan 直连 | /20 | | |
| 2 | 家宽→4G | 4G/5G 蜂窝 | WiFi（家庭） | Symmetric / Full Cone | Direct 或 Relay | 0/20（见备注*） | connect P50 405ms | relay 11.3 Mbps (P50) |
| 3 | 4G→家宽（反向） | WiFi（家庭） | 4G 热点 | Full Cone / Symmetric | Direct 或 Relay | /20 | | |
| 4 | 双运营商 4G | 4G（运营商 A） | 4G 热点（运营商 B） | Symmetric / Symmetric | Relay（大概率） | /20 | | |
| 5 | 同运营商 4G | 4G（运营商 A） | 4G 热点（运营商 A） | Symmetric / Symmetric | Relay 或 Direct | /20 | | |
| 6 | 咖啡店/酒店 WiFi | 公共 WiFi | WiFi（家庭） | Restricted / Full Cone | Relay 或 Direct | /20 | | |
| 7 | 公司 VPN/企业网 | 公司 WiFi（VPN） | WiFi（家庭） | Enterprise NAT | Relay（大概率） | **20/20** ✅ | connect P50 23ms | 16.9 Mbps (P50) |
| 8 | IPv6-only（如有） | 5G IPv6 | WiFi IPv6 | — | Direct（IPv6打洞更易） | /20 | | |

## 测试步骤（每场景）

1. 桌面端启动 iroh-probe CLI 监听：`cargo run -- listen`
2. 手机端打开 Android Probe App，填入桌面 NodeId
3. 点击「Connect + Send 100MB」执行 20 次
4. 每轮自动记录：path（lan/direct/relay）、rtt_ms、throughput_mbps、error（如有）
5. 用 UidtLogger Share Log 导出 JSONL 文件
6. 汇总填入上表

## 判定标准

- **绿（通过）：** 同 WiFi 直连率 100%；家宽↔蜂窝直连率 ≥70%
- **黄（观望）：** 家宽↔蜂窝直连率 50~70% → relay 兜底可用但需评估体验
- **红（回退）：** 同 WiFi 直连率 <100% 或家宽↔蜂窝直连率 <50% → 排查 iroh 配置/网络环境

## 额外变量（发现即记录，不限场景数）

- 手机锁屏后连接是否中断（ForegroundService 测试，附带）
- 网络切换（WiFi→蜂窝）中传输是否恢复
- NAT 刷新：保持连接 30 分钟不动，能否继续传

## 附加实测记录（2026-07-28，办公分流代理网——不计入正式矩阵）

> 环境：办公网 10.1.x，路由器分流代理（国内 UDP 直连出口北京联通 111.200.27.130；
> 国外目标含 n0 relay/发现走 SG 隧道 Meteverse），桌面节点会把 SG 代理地址误判为自身公网地址。

| 拓扑 | 结果 | 数据 |
|---|---|---|
| 鸿蒙(办公 WiFi) → Mac(办公 WiFi，跨 VLAN) | ✅ 直连 | direct / IPv6 / connect 104ms / 25.8 Mbps |
| Samsung S24(办公 WiFi 10.1.168.x) → Mac(10.1.150.x，跨 VLAN) | ✅ 直连 | 100MB 完整接收 <40s（≥20 Mbps） |
| 模拟器(本机 NAT) → Mac | ✅ | 100MB 完整接收 |
| Mac 本机自拨 | ✅ | lan / 837 Mbps |
| 鸿蒙(5G) → Mac(办公代理网) | ❌ | 可经 SG relay 建连，100MB 传输中途停滞 → QUIC 超时；多轮重试同样模式 |

**结论：** ① App↔CLI 互通链路成立（修复 `0c05255` 后）；② 企业网跨 VLAN 直连可达（本环境未开客户端隔离）；
③ 蜂窝→代理网路径不可用，主因是代理污染桌面节点的公网地址判定 + n0 SG relay 从国内蜂窝的传输质量——
实证 D2（国内自建 relay/发现端点必要性）。正式场景 1/2 数据待干净家宽环境。

## 正式实测记录（2026-07-28，对端=家宽 Mac mini，原始日志见 h04-logs/）

**环境说明：** 家宽侧国外出口有代理（LA 数据中心 IP → iroh 分配 usw1 relay）；办公侧同前述分流代理。
**双端代理只污染 relay 兜底路径的质量（多绕 1~2 跳），direct 打洞走真实物理路径，数据可信。**

- **场景 7（Samsung S24 · 公司 WiFi → 家宽）：20/20 direct，全 IPv6，0 失败。**
  connect P50=23ms（首轮 1272ms 含发现），吞吐 P50=16.9 Mbps（16.6~17.0 极稳）。第 16 轮灭屏完成（短锁屏不触发 Doze）。
- **场景 2（鸿蒙 · 5G → 家宽，完整 20 轮）：0/20 direct，relay 兜底 20/20 完成、0 失败。**
  connect P50=405ms（首轮 1259ms），吞吐 P50=11.3 Mbps（6.0~13.5），2GB 共 26.8 分钟。
  ***判定暂缓（不直接判红）**：家侧 v4 公网地址被代理污染 → v4 打洞路径整体失效，仅剩的 v6 打洞被
  蜂窝入站防火墙拦截 → 全走 relay。裸家宽（无代理）下 v4 CGNAT 打洞是否可用未被本轮覆盖，
  需关代理/加直连白名单后复测，再对照"<50% 红线"下结论。relay 兜底本身：可用性 100%，质量可接受。*
- **IPv6 对照实验（同时刻、同目标）：** 办公 Mac（网段无全局 v6，v4 公网地址被代理污染）→ 家宽：
  **3/3 relay**，5~6.7 Mbps；而同楼手机网段（有全局 v6）→ 同一目标 **20/20 direct** 17 Mbps。
  唯一变量是全局 IPv6 → **IPv6 是国内直连率的决定性因素**（实证 D2"IPv6 红利"与 D9 直连率工程重心）。

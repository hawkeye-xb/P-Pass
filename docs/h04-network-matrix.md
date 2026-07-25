# H-04 真实网络矩阵测试

> M0 Gate 输入之一。对照可行性报告 §4 判定。
> 每场景 ≥20 次连接尝试。记录 ConnInfo（path + rtt_ms + throughput_mbps）。
> 测试工具：Android Probe App（最新 APK）连桌面 iroh-probe CLI。

## 场景表

| # | 场景 | 手机网络 | 桌面网络 | NAT 类型（手机/桌面） | 预期 | 直连率 | 平均 RTT | 平均吞吐 |
|---|------|---------|---------|---------------------|------|--------|---------|---------|
| 1 | 同 WiFi | WiFi（家庭） | WiFi（家庭） | Full Cone / Full Cone | Lan 直连 | /20 | | |
| 2 | 家宽→4G | 4G/5G 蜂窝 | WiFi（家庭） | Symmetric / Full Cone | Direct 或 Relay | /20 | | |
| 3 | 4G→家宽（反向） | WiFi（家庭） | 4G 热点 | Full Cone / Symmetric | Direct 或 Relay | /20 | | |
| 4 | 双运营商 4G | 4G（运营商 A） | 4G 热点（运营商 B） | Symmetric / Symmetric | Relay（大概率） | /20 | | |
| 5 | 同运营商 4G | 4G（运营商 A） | 4G 热点（运营商 A） | Symmetric / Symmetric | Relay 或 Direct | /20 | | |
| 6 | 咖啡店/酒店 WiFi | 公共 WiFi | WiFi（家庭） | Restricted / Full Cone | Relay 或 Direct | /20 | | |
| 7 | 公司 VPN/企业网 | 公司 WiFi（VPN） | WiFi（家庭） | Enterprise NAT | Relay（大概率） | /20 | | |
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

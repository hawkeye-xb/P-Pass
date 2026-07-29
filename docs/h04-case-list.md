# H-04 操作手册 —— 网络矩阵实测

> **你来做，我做不了。** 拿手机+电脑跑场景，每个场景连 20 次。
> **正式数据台账在 [h04-network-matrix.md](h04-network-matrix.md)**（含判定标准与原始日志指引），
> 本文只管"怎么跑"和各场景的当前状态。

---

## 当前进度（2026-07-29）

| # | 场景 | 状态 | 结论一句话 |
|---|------|------|-----------|
| 1 | 同 WiFi（家） | ⏳ **待跑**（优先级最高，到家就跑） | — |
| 2 | 5G → 家宽 | 🟡 **已跑，判定暂缓** | 0/20 direct，relay 兜底 20/20 完成 11.3 Mbps。家侧监听端在 VM 内 + 双端代理，归因未分离，**需按复测清单重跑**（宿主机 + 关代理） |
| 3 | 反向（热点当监听端） | ⏳ 待跑 | 注意：App 当监听端有缺陷④（ticket 不等 relay），v2 已修，用 v2 跑 |
| 4 | 双运营商 4G | ⏸️ 机会主义 | 只有一张 SIM，暂无条件 |
| 5 | 同运营商 4G | ⏸️ 机会主义 | 同上 |
| 6 | 公共 WiFi | ⏳ 出门顺便 | — |
| 7 | 公司网 → 家宽 | ✅ **完成** | **20/20 direct（全 IPv6）**，P50 23ms / 16.9 Mbps，0 失败 |
| 8 | IPv6-only | ✅ **等效完成** | 场景 7 全程即 v6 直连；另有 IPv6 对照实验（有 v6=20/20 direct，无 v6=3/3 relay）已入档 |

数据明细、判定依据、复测清单 → [h04-network-matrix.md](h04-network-matrix.md)；原始 JSONL → [h04-logs/](h04-logs/)。

**对照实验（计划中）**：阿里云公网 IP 跑 iroh-probe listen，鸿蒙 5G 拨入——分离"蜂窝防火墙"变量；
另计划阿里云自建 relay 做国内/SG relay 质量 A/B（H-07 试点）。

---

## 准备工作（一次性）

### 1. 安装 Android Probe App —— **必须用 v2**

v2 APK 位置：`~/Downloads/p-pass-probe-debug-v2.apk`（2026-07-28 构建）。

- **三星 S24**：插线 `adb install -r ~/Downloads/p-pass-probe-debug-v2.apk`
- **鸿蒙**：把 APK 传到手机自装（经卓易通）

⚠️ 旧 release 页上的 `app-debug.apk` 是 v1，有四个已知缺陷（错误信息恒空、Share Log 按钮会消失、
切后台丢状态、监听 ticket 不等 relay），**别再用**。

### 2. 电脑端 iroh-probe CLI

```bash
cd ~/github/P-Pass/spikes/iroh-probe   # 家里 Mac mini 是 agent 的 workspace 路径
cargo run --release -- listen
```

保持终端开着，屏幕会打出 **ticket**（`endpoint…` 开头的一长串）。

**ticket 是固定的，抄一次就行**：密钥持久化在 `iroh-probe.key`、端口钉死 41145，
重启进程 ticket 不变。CLI 会先等 relay 就绪（最多 15s）再打印 ticket，等它打出来再复制。

---

## 测试操作（每场景 5~8 分钟）

1. **电脑**：确认 iroh-probe 还在 listen（重启也没关系，ticket 不变）
2. **手机**：Probe App → 粘贴 ticket → **Bind** → **Start UIDT Stress Test**（20 次 ×100MB）
3. **等**：每轮显示 path（direct/relay）、延迟、速度；**中途别点其他页签**（v2 状态已进程级保持，但少折腾）
4. **导出**：点 **Share Log**（v2 常驻，任何时候都在）→ 把 JSONL 发我
5. 我来汇总回填台账

---

## 顺便观察（边跑边记，不强制）

- 📱 **锁屏影响**：已有一条记录（场景 7 第 16 轮灭屏不断传，短锁屏不触发 Doze）；长锁屏（>15 分钟）还没测
- 🔄 **网络切换**：WiFi ↔ 蜂窝切换后连接能否恢复
- ⏰ **NAT 保活**：连上后放 30 分钟，还能不能继续传

---

## FAQ

**Q: ticket 在哪个终端？**
A: 跑 `listen` 的那个。它固定不变，存备忘录里即可。

**Q: 跑失败了/打不开？**
A: 截图/把 Share Log 的 JSONL 直接扔给我，我来排查。

**Q: 要一次性全跑完？**
A: 不用。剩下的核心就两个：**场景 1（到家 30 分钟）** 和 **场景 2 复测（宿主机+关代理）**。
其余出门/借到 SIM 顺便做。跑几个发几个日志。

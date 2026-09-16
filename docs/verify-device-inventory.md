# 真机欠账盘点 —— `just verify-device` 的设计输入

> **这是一次性盘点，不是队列。** 唯一待办队列仍是 `docs/QUEUE.md`。
> 本文只回答一个问题：分区二「待共享回归」27 张卡里，哪些真机欠账
> 必须验收人亲手操作，哪些是"没人写脚本"。盘点日：2026-09-16。
> 做完 `verify-device` 后本文即可删除。

## 结论

27 张卡的未勾选真机项分三类。**真正必须验收人亲手的只有 C 类 5 条 + B 类 3 条。**
其余全部可由机器判定，缺的不是能力而是 harness。

判定依据（已核实，非推测）：

- `DiscoveryLedger.kt:244` 把账本写成 app 私有目录下的 `discovery-ledger.json`
  落盘文件；同目录另有 `pairing.json`、`auto_backup_prefs.json`、
  `notify_on_failure_prefs.json`。debug 包可用
  `adb exec-out run-as <pkg> cat files/...` 取出。
- 首页/设置的呈现状态一律是账本的**纯函数派生**（`flowAggregateOf`、
  `flowUiStateOf`、`backgroundBackupStateOf`、`lastSuccessOf`），卡内多处
  明写"换源到账本派生"。
- 既有 instrumented 测试 3 个（`DeviceBackupTest`、`SetupPairingTest`、
  `NetProbeTest`），`tools/device-backup.sh` 已实现「向常驻 daemon 取配对 QR
  → adb 真机跑 instrumented → 并行 IPC 自动确认」。

**所以 A 类的断言路径是：adb 拉账本 JSON → JVM 侧跑同一个纯函数 → 断言投影。
不读像素，不新增生产代码，不给 app 加调试接口。**

这个做法在 MOB-53 的验收标准里已经写过一次（"本 agent 用 adb 读取
discovery-ledger.json + UI dump 交叉验证，不强制要求验收人操作"），
本盘点只是把它推广到其余 26 张。

## A 类 —— 可机器判定（拉账本 + 纯函数断言 / logcat / 本地脚本）

| 卡 | 未勾选的真机项 | 断言源 |
|---|---|---|
| UI-09 | 一批照片传完，首页 K 从 N 归零 + 成功文案 | 账本 → `flowAggregateOf`（K/M/lastSuccessAt） |
| MOB-64 | 桌面移除设备后，下次尝试首页出现「连不上客户端」 | 账本/拒绝码 → `pairingLost` 投影 |
| MOB-71 | 关闭 Wi-Fi 限制后暂停/继续期间等待提示不复活 | 账本 + prefs → 等待态投影 |
| MOB-62 | 完整断开→重扫→新一轮传输，无 ANR/崩溃 | logcat（ANR/FATAL 零命中）+ 账本终态 |
| MOB-72 | 取消轮后选第二个相册，不退 App 完成传输；重开不二次传输 | 账本条目序列（入队/终态/无重复） |
| MOB-60 | 取消当前轮后落 Idle | `flowUiStateOf == Idle` |
| MOB-56 | 制造 daemon 无响应，不再出现两条并发失败/成功日志 | logcat 行计数断言 |
| MOB-53 | 「M/N 已回家」与「最近成功」不再同屏矛盾 | 账本 → `lastSuccessOf` 非 `Never`（卡内已指定此法） |
| WATCH-07 | 传一批照片，活动流条目数 = 照片数（非 2 倍） | daemon 审计表行数 |
| UI-10 | 四项（epoch 空提示/重传提示/归属过滤/失联）无异常 | 构造存储状态 + 投影断言 |
| DESK-11 | 连传 20 张，每张完成后 2s 内出现在桌面 | 卡内已写"有测试覆盖事件路径，不依赖真机" |
| DESK-13 | 大文件传输期间桌面墙/暂停/取消不卡顿 | 桌面侧，非手机；事件循环响应延迟可测 |
| DESK-10 | （验收项已全部 [x]，只差归档动作） | 无 |
| E2E-02 | `tools/android-hello.sh` 本地跑通 + 反证 | 纯本地脚本，与真机无关 |
| I18N-01 | 系统语言切英文 → 选相册页无中文 | `adb shell` 可切 locale + UI dump 文本断言 |
| MOB-26 | Pager 初始页/翻页目标/缩放不翻页 | instrumented UI 测试可覆盖（录屏项归 C 类） |
| MOB-76 | 前半支（纯蜂窝零传输 + 等待态）已验证通过 | 已过；后半支见 B 类 |

## B 类 —— 需要真实物理条件（脚本无法制造，但可脚本化前后断言）

| 卡 | 项 | 为什么必须人 |
|---|---|---|
| MOB-76 | 「连上 Wi-Fi 后自动续传」 | 需真实 5G↔Wi-Fi 切换，非关闭限制模拟 |
| NET-14 | 三星热点 288MB 视频跨 relay，日志证明无固定间隔轮询 | 需开热点造跨网路径 |
| NET-12 | 前台服务保护长期存活观察（含 MOB-85 三星 MARs 干扰） | 需真实时间跨度 + 厂商策略 |

MOB-68 首装授权流程（媒体/电池/通知弹窗顺序）介于 A/B 之间：系统弹窗可用
`uiautomator` 点，但跨厂商脆；建议先按 B 类保留人工，harness 只断言
"未出现叠加弹窗"这类可 dump 的部分。

## C 类 —— 只能人眼（harness 只负责抓图归档，不判定）

| 卡 | 项 |
|---|---|
| UI-13 | Material3 图标与手绘版视觉接近度；`NavigationBar` 换与不换的对比截图 |
| UI-12 | 阻断/非阻断两种提示视觉可辨 |
| MOB-57 | 按钮禁用的视觉反馈 |
| DESK-09 | 「一眼看懂版本装反了」 |
| UI-04a | 中断提示在照片页/设置页的走查 |

## 盘点中发现的两个队列缺陷（已实锤，需单独处理）

1. **NET-04 和 NET-05 整张卡没有「验收标准」段**，而 §C.2 写着"缺字段=不受理"。
   两张都挂在分区二「待共享回归」，意味着它们的"待回归"内容无法被任何人
   （人或脚本）判定。harness 无法为它们生成剧本，需先补卡。
2. NET-06、NET-08 已在卡内标注"不再可领"，但仍占据分区三「可接队列」的行。

## 下一步

1. `tools/verify-device.sh` 骨架：复用 `device-backup.sh` 的 QR+IPC+instrumented
   模式，加"拉账本 JSON → JVM 投影断言"这一层。
2. A 类逐条落成剧本函数，输出「剧本名 → 通过/失败 + 证据路径」。
3. C 类只抓图存 `docs/evidence/<日期>-verify-device/`，由验收人看红的那几张。
4. B 类保留人工，但前后状态由脚本断言，人只负责"切网/开热点/等"这个动作。

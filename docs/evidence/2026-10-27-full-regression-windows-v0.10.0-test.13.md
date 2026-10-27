# 全量回归报告：Windows 服务版 + Android v0.10.0-test.13（2026-10-27）

> 按 [full-regression-sop.md](../runbook/full-regression-sop.md) §4 与 §9（Windows 桌面变体）执行。Windows 已改为系统服务形态（#1161 / #1167），这是服务版的第一轮全量回归。除清环境重装时的一次 UAC 外，全部由 agent 完成：手机授权与配对确认用 adb 代点，桌面用 UI Automation 代点。
>
> **结论：不能发版。** 数据路径没有问题：照片完整、取回逐字节一致、断网与崩溃后都能补齐、隐私检索零命中。但有一个阻塞项：G4 的 R4.1b 超时（#1239）。另有一个严重的可用性缺陷：停止服务后，从界面再也启动不回来（#1238）。还有两项没覆盖完：G5 的 daemon 日志（#1236），以及服务版的升级路径。

## 结论摘要

| 保证 | 结果 | 说明 |
|---|---|---|
| G1 照片完整 | ✅ | 累计 483 张测试图逐张 sha256 对账，零缺失、零重复。300 张大批次、断网 30 秒、备份中 `am crash` 都能收敛。随机取回 5 张，与原图逐字节一致 |
| G2 升级不丢 | 未覆盖 | 没有可用的上一个 CI Windows 包当基线，见下文「升级路径」。本轮从清空状态起步 |
| G3 无人值守 | ❌ #1238 | 停止服务后 90 秒内没有被拉起，手机提示平静；重新启动后自动续传。但桌面 App 停止服务后退回首启向导，界面上无法再启动服务 |
| G4 配对可信 | ❌ #1239 | 在线断开、重新配对（手动配对串）、旧照片不重传都通过。服务停着时，手机「断开电脑」要 15 秒才完成，期望 ≤5 秒 |
| G5 隐私 | ⚠️ 部分 | logcat 和两份诊断包两遍检索零命中。服务版的 daemon.log 普通用户读不到，诊断包里也不带本轮日志（#1236） |
| 安装形态 | ✅ | 全新安装：服务 AUTO_START，账户 `NT SERVICE\P-Pass`，失败后 5 秒自动重启。没有计划任务和 Run 值。首次启动不弹控制台窗口 |

## 环境

| 项 | 值 |
|---|---|
| 候选 | `v0.10.0-test.13`（commit `11173ebb`）。Windows 安装包 sha256 `887c935d…`，APK sha256 `54d27e6e…`，都与 Release 清单一致 |
| 电脑 | Windows 11 x64，开发机（测试用），插着电。磁盘紧张：开跑约 5 GB 可用，中途清理测试源图后约 3.5 GB |
| 手机 | 三星 SM-S9210（Galaxy S24），Android 15（API 35），安全补丁 2025-03-01，测试机。开跑前清空 App 数据，装候选 APK |
| 签名 | Windows 未签名（#788，不阻塞） |
| 执行宿主 | Windows 上的 A2A agent（非提权会话）。仓库只读使用回归工具分支 `chore/1063-windows-regression-tools`（已适配服务版：命名管道 IPC、HKLM 安装位置、`sc` 停启） |
| 网络 | 同一局域网。R2.2 恢复 Wi-Fi 后手机自动换到另一个 SSID、跨了 /23 网段，状态仍是 `ONLINE_DIRECT` |

## 开跑前的事件：本地构建 → CI 构建的覆盖升级崩溃（#1237）

这台机器原先装的是本地构建的 `0.10.0-test.1167`（服务版，向导已走完）。覆盖安装 test.13 后，服务陷入崩溃循环：每 5 秒被 SCM 拉起一次，退出码 1067，4 分钟内 54 次。启动日志：

```
{"detail":"migration: migration 1 was previously applied but has been modified","error_key":null}
```

根因已经实测：sqlx 的迁移校验和按 `.sql` 原始字节计算，仓库没有 `.gitattributes`。GitHub Windows runner 的系统 gitconfig 是 `autocrlf=true`，所以 test.13 的 `daemon.exe` 里嵌的 `0001_init.sql` 是 CRLF；本地构建检出的是 LF。数据库里记的是 LF 版的校验和 `41BF24B6…`，与 test.13 的不一致。

影响：CI 包升级到 CI 包时换行一致，目前没事。但只要 CI 的检出配置变一次，已装用户升级后服务就起不来。修法：用 `.gitattributes` 把 `*.sql` 固定为 LF，再加门禁。

处理：保留现场取证后，卸载并清空 ProgramData、库目录、用户 AppData，全新安装 test.13（一次 UAC）。之后服务稳定运行，IPC 返回 `unconfigured:true`，然后开始本轮回归。

## 升级路径（G2）为什么没覆盖

- test 通道只保留每端最新的一份包（#872），test.12 及更早的 Windows CI 包已经删了，本机也没有留存。
- test.12 是计划任务形态，test.13 是服务形态。按 2026-10-22 的口径（不考虑旧用户、不写迁移），这一跳不在回归范围内。
- 同一形态下的覆盖升级，下午已用本地构建实测过（E3）：主人、库、停止或运行状态都能保留。
- 下一轮应在打候选 tag 前先下载 test 通道的 Windows 包留作基线（SOP §9.1），用 test.13 → 下一个 test 做 R1。

## 逐条结果

| ID | 结果 | 证据 / 备注 |
|---|---|---|
| §9.2 预检 | ✅ | 安装包、APK 哈希与 Release 一致。命名管道 IPC 取到 `status` |
| R0.1 | ✅ | 手机 `pm clear` 后 `adb install -r -d` 候选，versionName `0.10.0-test.13` |
| R0.2 | ✅ | 卸载、清数据后 `/S` 静默安装，服务 RUNNING，IPC `unconfigured:true`，20 秒内没有崩溃 |
| R0.3 | ✅ | agent 用 UIA 走完三步向导，默认库目录 `…\Pictures\P-Pass Library` 建出，状态 `ONLINE_DIRECT`。第 3 步「会申请什么」显示服务版文案 |
| R0.4 | ✅ | 扫码配对，桌面设备列表出现 Galaxy S24。手动配对串的路径在 R4.3 覆盖 |
| R0.5 | ✅ | 40/40，约 30 秒全部入库，逐张哈希一致 |
| R1.1 | ✅ | 快照：迁移版本 13，`pairing` 1 行，`device_profile` 1 行，各表行数已记录。本版已无 `device` 表，配对看 `pairing`，离开看 `device_profile.departed_by` |
| R1.2 / R1.3 / R1.6 | 未覆盖 | 见上文「升级路径」 |
| R1.4 | ✅ | 手机 versionName、IPC `version`、HKLM `DisplayVersion`、`p-pass-desktop.exe` ProductVersion 都是 `0.10.0-test.13` |
| R1.5 | ✅ | +8 张，库里恰好 48 张，零重复 |
| R2.1 | ✅ | 300 张约 3 分钟完成。无 ANR，crash 缓冲区无本 App 条目。前台服务跑完后消失 |
| R2.2 | ✅ | 断网 30 秒期间计数停住，恢复后自动续传，60/60，不重不漏 |
| R2.3 | ✅ | `am crash` 后约 2 秒前台服务被系统拉起，不打开 App 也补齐 40/40，零重复。#827 本轮没有复现 |
| R2.4 | ✅ | 手机「保存到相册」取回 5 张（落在 `Pictures/P-Pass/`），与手机源图、桌面原图 sha256 全部一致 |
| R2.5 | ✅ | 手机删 5 张后等 2 分钟：桌面保留，REG 总数不变，不重传 |
| R3.2 | 未覆盖 | daemon 以 `NT SERVICE\P-Pass` 运行，非提权 `taskkill` 返回 Access is denied。自愈靠 SCM 失败动作（`RESTART 5000ms ×2`，重置周期 1 天），开跑前那次崩溃循环里每 5 秒拉起一次，可作旁证 |
| R3.3 | ❌ #1238 | 设置页「停止后台服务」后服务 STOPPED，`wanted-state=stopped`，90 秒内没有被拉起 ✅。手机显示「连不上存储电脑，连上后自动接着备份」✅。**但 App 随即退回首启向导，没有「启动后台服务」；向导「完成」报「等不到内置后台服务的探活结果」，起不来。** 手工把 `wanted-state` 写回 `running` 再 `sc start` 后恢复，20/20 自动续传，不重不漏 |
| R3.4 | 未覆盖 | 手机插着 USB 充电，App 在 deviceidle 白名单里，`force-idle` 期间照常备份完 10 张。条件不成立，不能用来判 Doze 行为 |
| R4.1 | ✅ | 服务在线时手机「断开电脑」，约 3 秒回到欢迎页。桌面 `paired=false`，`departed_by=device` |
| R4.2 | ✅ | `pairing` 行已删除，`device_profile.departed_by=device`，有 `departed_at` |
| R4.3 | ✅ | 手动配对串路径：手机输入串，桌面输入手机的 6 位码并「允许重连」，生成新的 pairing 行。立即备份后 5 分钟内 483 张无一重传。（Windows 会话的剪贴板不可用，配对串改用桌面按钮背后的同一个 `pairing.start` 取得） |
| R4.1b | ❌ #1239 | 服务停着时手机「断开电脑」，**15 秒**后才完成、约 17 秒回到欢迎页，期望 ≤5 秒。只通知一次、不重试 ✅；服务恢复后桌面 pairing 行仍在、没被撤销 ✅ |
| R4.3（二次） | ✅ | 二次重配后 +5 张，483/483，零重复。结束时手机已配对，范围只有 `PPassRegression` |
| R5.1 logcat | ✅ | uid 10424，13,197 行（17:03–20:28）。本轮秘密原文 0 命中：桌面 NodeId、两次配对串的 `t=` 令牌、手机 NodeId、用户名、测试文件名。按形状查 64 位十六进制、公网 IPv4、全局 IPv6 也都是 0。正向对照样本全部命中，证明检索没有空转 |
| R5.1 daemon.log | 阻塞 #1236 | `C:\ProgramData\P-Pass\logs\daemon.log` 非提权 Access is denied。诊断包里的 `daemon.log` 只有 2 行历史行，不含本轮 |
| R5.2 | ✅（不完整） | CLI `diag export` 和托盘「导出诊断包」各 11 个文件，两遍检索加用户名、文件名都是 0 命中。两份都缺本轮 daemon 日志（#1236） |
| R6.1 | ✅ | 总览、照片墙表头、IPC `photo_count`、`originals` 文件数都是 489。大图里「在文件管理器中显示」打开资源管理器，选中的就是该原图 |
| R6.2 / R6.3 | 人工验收 | 需要人看 |
| R6.4 | 未覆盖 | SmartScreen「仍要运行」属系统安全决定 |
| W1 | ✅ | 首次启动 240 秒、停止服务 200 秒两段监视，控制台窗口都是 0 个（只出现过「停止后台服务」确认框） |
| W2 | ✅ | `sc qc`：AUTO_START，`"C:\Program Files\P-Pass\ppf-daemon.exe" --service`，`NT SERVICE\P-Pass`。没有计划任务 `P-Pass`，HKCU/HKLM Run 下都没有 `P-Pass` |
| W3 / W5 | 未覆盖 | 覆盖安装、卸载重装都要 UAC，本轮无人在场。下午的 E3 已在本地构建上实测 |
| W4 | 未覆盖 | 要管理员采样 `powercfg /requests` |
| W6 | ✅ | 19:18 磁盘跌破 5 GB 时触发了一条 toast：「照片库空间不足 / 照片库所在磁盘只剩 5.0 GB（低于约 5 GB）。请清理磁盘或把照片库换到更大的位置。」`wpndatabase.db` 里有记录，文案完整 |

## 新开 / 关联的卡

| 卡 | 级别 | 内容 |
|---|---|---|
| #1239 | 阻塞（G4） | Android：桌面不可达时「断开电脑」要等 15 秒连接超时 |
| #1238 | 严重（G3） | Windows 服务版：「是否配过」读的是用户目录的 `config.toml`，服务一离线 App 就进向导，从界面无法再启动服务 |
| #1237 | 隐患 | 迁移脚本按检出时的换行嵌入，CRLF 构建和 LF 构建互相拒绝对方的数据库 |
| #1236 | G5 缺口 | 服务版诊断包没有本轮 daemon 日志 |

## 本轮对测试机状态的改动

- 清环境：卸载 P-Pass，删除 `C:\ProgramData\P-Pass`、库目录、`%LOCALAPPDATA%\com.hawkeyexb.ppass.desktop`；手机 `pm clear`。
- R3.3 恢复时手工写过一次 `wanted-state=running`；R4 期间为让 App 回到主界面，补写过一份用户侧 `config.toml`（`data_dir`），都是 #1238 的绕行。
- 收尾状态：服务 RUNNING，桌面库 489 张（REG 483 + 6 张既有 png）。手机留在 test.13、已配对、范围只有 `PPassRegression`，可作下一轮起点。Doze 已 `unforce`。
- 测试源图已从 Windows 工作目录删除，只保留 sha256 清单，原因是磁盘紧张。手机相册 `DCIM/PPassRegression/` 和桌面库里的测试图暂留，下一轮清理。

## 证据

都在 Windows 回归机 `C:\Users\ethan\ppcheck\reg\<用例号>\`。秘密原文（配对串、全长 NodeId）只存在 `reg\secrets\`，没有进本报告。

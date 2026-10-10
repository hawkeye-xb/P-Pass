# 全量回归报告：v0.9.12-test.3（2026-10-10）

> 按 [full-regression-sop.md](../runbook/full-regression-sop.md) 执行的第一轮。结论：**不可发版**——R1.6 查出 #828（应用内更新会撤销仍在进行的安装），已修复并合入；修复版的应用内更新一跳与收尾批次（R6）完成后重新下结论。

## 结论摘要

| 保证 | 结果 | 说明 |
|---|---|---|
| G1 照片完整 | ✅ | 累计 765 张测试图逐张 sha256 对账，零缺失、零重复；取回文件与原图逐字节一致 |
| G2 升级不丢 | ❌ → 修复中 | 覆盖安装：桌面 test.1 → test.3、手机 0.9.11 → test.3 数据全部保留，三端版本号一致。应用内更新 test.3 → test.4：点「更新」后安装被 App 自己撤销（#828），修复版待验 |
| G3 无人值守 | ⚠️ 1 个问题 | 进程崩溃后不自动续传，等下次触发（#827，不挡发版） |
| G4 配对可信 | ✅ | 服务停机期间断开，恢复后 75 秒内桌面吊销；重配用新纪元，零重传 |
| G5 隐私 | ✅（界面导出包待补） | 本轮日志与 IPC 诊断包零命中 |

## 环境

| 项 | 值 |
|---|---|
| 候选 | `v0.9.12-test.3`（`3afa88d4`） |
| 上一个正式版 | `v2026.10.3`（Android 0.9.11 / 桌面 0.9.5） |
| 手机 | SM-S9210，Android 15，测试机 |
| 电脑 | macOS 26.2，Apple Silicon，**日常机**（照片库为真实数据，未降级、未重置） |
| 产物校验 | SUMS 两项 OK；dmg 已钉公证票据；`.app` codesign 通过、`spctl` 为 Notarized Developer ID；正式版与候选 APK 证书 SHA-256 相同（`3cceb81e…`） |

## 逐条结果

| ID | 结果 | 证据 / 备注 |
|---|---|---|
| R0.1 | ✅ | 卸载调试包后装正式版 0.9.11（versionCode 64） |
| R0.2 / R0.3 | 未覆盖（日常机） | 桌面不装回正式版 |
| R0.4 | ✅ | 正式版首页即有「手动输入配对串」，无需摄像头；IPC 批准 |
| R0.5 | ✅ | 40/40，零重复 |
| R1.1 | ✅（手机侧改证据） | 桌面快照：identity.key、迁移版本 10、9 张表行数、原图摘要。正式签名包不可 `run-as`，手机侧改用「NodeId 与配对纪元不变 + 范围仍勾选 + 零重复」作证据 |
| R1.2 | ✅（B 格部分覆盖） | test.1 → test.3 覆盖安装：daemon 换代成功，快照全部相同 |
| R1.3 | ✅（改为覆盖安装） | `adb install -r`：无需重配，范围保留，40/40 保留 |
| R1.4 | ✅ | 手机 / daemon / Info.plist 三者均为 `0.9.12-test.3`（#809 在真实发版上生效；test.1 时 Info.plist 仍是 0.9.5） |
| R1.5 | ✅ | +8 恰好 +8 |
| R1.6 | ❌ | test.3 → test.4：授权后返回，App 按 #793 自动拉起安装器；随后 `#793: back in foreground with no install result; back to ready` 与 `Session [300846760] was destroyed because of [Session was abandoned]`，点「更新」没装上，再点一次才装上（19:04:30 装上 test.4）。根因与修复见 #828 / #830；修复版 test.5 → test.6 一跳待验 |
| R2.1 | ✅ | 300 张 87 秒完成，无 ANR，前台服务随后退出 |
| R2.2 | ✅ | 断网 30 秒：进度停在 69/150，恢复后约 40 秒接上，150/150 |
| R2.3 | ⚠️ | `am kill` 被前台服务保护（正确）。`am crash` 后停在 46/120 超过 10 分钟不续；重新打开 App 后 29 秒补完、零重复 |
| R2.4 | ✅（部分覆盖） | 「保存到相册」的文件与原图 sha256 相同；家人设备的照片取回需第二台手机 |
| R2.5 | ✅ | 手机删 5 张，桌面保留；下一轮只传新增 |
| R3.1 | ✅ | 重启后不开 App，5 张 33 秒自动完成。重启后手机停在首次解锁前、USB 不可用，约 1 小时无进展，人工解锁后恢复；此后 SOP 不再做重启类用例 |
| R3.2 | ✅ | `kill -9` 后 launchd 1 秒拉起，壳未断，下一轮 24 秒补完 |
| R3.3 | ✅ | 停服期间手机提示「连不上存储电脑，连上后自动接着备份」；恢复后约 9 分钟补完（重试退避），零重复 |
| R3.4 | ✅ | Doze 期间不跑；退出后 34 秒补完 |
| R4.1 / R4.2 | ✅ | `revoked=1`、`revoked_by=device`、纪元与断开前一致 |
| R4.3 | ✅ | 同身份新纪元重配；760/760 保留，原图文件数不变（827）。配对串提示为 `ppf://pair?node=…`（#739） |
| R5.1 | ✅ | 本轮秘密原文 4 项 + 64 位十六进制 + 公网 IP：logcat 1525 行、daemon.log 本轮 3016 行均零命中。`daemon.log` 文件里留有 2026-09-30 旧版本写下的完整 NodeId（脱敏上线前的历史行） |
| R5.2 | ✅（界面导出包待补） | `ipc logs.export` 只含 audit / diag_events / devices 三份 JSON，零命中；带 daemon.log 的界面导出包待收尾批次 |
| R6.1–R6.4 | ⏳ | 收尾批次 |

## 问题

1. **#828 应用内更新撤销仍在进行的安装**（G2，阻塞）。#793 的「回到前台 1.5 秒无回执 = 没装」会在系统安装流程让 App 短暂回到前台时，撤销仍存活的安装会话。v2026.10.3 不含 #793，线上用户升到下一个正式版不受影响。修复（#830，已合入）：以 `PackageInstaller.getSessionInfo(id)` 为准，会话还在就继续等；「正在安装」弹窗加「立即安装 / 以后再说」两个出口。
2. **#832 发布链 macOS 脚本读错变量名**（发布链，阻塞正式发版）。修复版 test.5 的 macOS 构建里 codesign 挂住，`with-timeout.sh` 打印超时提示时自己崩溃（`name�: unbound variable`），#772 的重试没有发生。macOS `/bin/bash` 3.2 在 UTF-8 下把「$name」的全角字符首字节读进变量名；全仓同类 34 处统一改为 `${name}` 并加门禁（#833）。
3. **#827 进程崩溃后备份不自动续传**（G3，发版人确认不挡发版）。传输循环跑在 `FlowTransferForegroundService`（`START_NOT_STICKY`）里，触发它的 `BackupWorker` 交接后即返回 SUCCESS；进程死后 JobScheduler 里只剩 4 小时周期任务（实测下次 `+4h41m`）与相册内容触发。未传的项保留在账本，下次触发补齐，不丢数据。标准做法是让系统调度器持有这份工作直到完成（WorkManager 长任务自己承载传输循环），与 #417 把传输移出 WorkManager 的设计相关，需单独评估。

## SOP 缺口（已回填到 SOP）

| 位置 | 实测 | 改为 |
|---|---|---|
| §1 / R3.1 | 重启后手机停在首次解锁前，USB 不可用 | 不做任何重启类用例 |
| R1.1 | 正式签名包不可 `run-as` | 手机侧用 NodeId / 纪元 / 范围 / 零重复作证据 |
| R1.3 | 更新通道由版本号推导，无设置开关；正式版收不到 test 包 | 正式版 → 候选用覆盖安装；应用内更新另起一跳（候选 → 下一 test tag） |
| R0.4 | `pairing.confirm` 需要 `node_id`（取自 `pairing.pending`），`device_name` 不生效 | 写明参数 |
| R3.3 / R4.1 | 只 `launchctl bootout` 会被壳在 30 秒内自愈拉回 | 先写 `~/Library/Application Support/P-Pass/desktop-user-stopped` 再 bootout；恢复时删标记再 bootstrap |
| R2.3 | `am kill` 杀不掉跑着前台服务的进程 | 用 `am crash` |
| R5.1 | 重启会清空 logcat 缓冲；`daemon.log` 含历史行 | 按 uid 抓 logcat；daemon.log 只截本轮时间窗 |
| R5.2 | IPC 导出不含 daemon.log | 界面「导出诊断包」进收尾批次 |

## 清理（已执行）

- 桌面：按本轮种子图 sha256 精确匹配到 765 张，移到 `~/.Trash/P-Pass-回归测试图-2026-10-10/`；库里原有 62 张未动。`ppf-logs.zip` 与 `/Applications/P-Pass.app.old`（test.1）移到废纸篓。
- 手机：删掉 `DCIM/PPassRegression/` 剩余 760 张与取回的 1 张；`Pictures/P-Pass/` 原有 39 张未动。
- Release：删掉已测完的 6 个旧 test release（tag 保留）；test.3 – test.6 留到本轮收尾。

# Windows 安装失败后 daemon 限时恢复：真机 E3（2026-11-18）

- 卡：#1817；分支 `ci/1817-windows-daemon-sc-start`，头 `1e749ef2`
- 机器：Windows 11 回归机（perMachine 服务安装，High integrity 会话）
- 候选包：本分支构建的 `P-Pass_0.11.4_x64-setup.exe`；base 包：`v2026.11.3`（ProductVersion 0.11.1）
- 判据出处：`tools/e3/scenarios/win/update-failed-recovery.sh` + `tools/e3/run judge win/update-failed-recovery`

## 主轮：21/21 ok，verdict=PASS

完整判据原文见 `judge-main.txt`（随证据目录归档）。关键几条：

```
ok    用例1 安装失败被识别：update-failed 存在且首行 install-failed
ok    用例1 service=1（用户没停过，安装器起服务或安排恢复）
ok    用例1 失败时刻限时恢复任务已登记
ok    用例1 释放后 daemon 恢复运行（真实进程在跑）
ok    用例1 释放后 IPC 可应答（diag daemon_reachable）
ok    用例1 版本与安装结果一致（失败=仍是 base 0.11.1）
ok    用例1 释放后服务在运行
ok    用例1 恢复后限时恢复任务已自删
ok    用例2 …（用户停过：service=0、不拉起、不登记、无自启，全 ok）
ok    用例3 …（对照组正常安装，全 ok）
```

失败时刻采样：`update-failed` = `install-failed` + `service=1`；`svc_state=Stopped`、`recovery_task` 已登记、`wanted_state=running`。
恢复后：daemon 真实进程在跑、IPC 可应答、服务 Running、限时任务已自删。

## 反证轮：撤销修复后「应恢复」三条重新变红

把候选包换成修复前的 `v0.11.4-test.1`（sha256 `6ba983a0…`，11-16 构建），其余参数不变：

```
FAIL  用例1 失败时刻限时恢复任务已登记
FAIL  用例1 释放后 daemon 恢复运行（真实进程在跑）
FAIL  用例1 释放后 IPC 可应答（diag daemon_reachable）
FAIL  用例1 释放后服务在运行
```

`run.log` 同时记录「用例1 释放后 300s 内 daemon 没恢复（真实进程/服务仍停）」。即：这三条判据在撤销修复后确实能判红，证明主轮的绿来自本次修复。

## 关键实现节点（本轮真机暴露并修掉的）

1. 任务动作里用 `$LASTEXITCODE` 判断服务是否 RUNNING —— 那是 `sc.exe` 的退出码，STOPPED 时也是 0。
2. 动作文本里的裸双引号被 `-Command "…"` 参数解析吃掉，PowerShell 收到的脚本断掉。
3. `New-ScheduledTaskTrigger` 的 `-RepetitionDuration` 在真机上被截断成 `MissingArgument`，任务登记直接失败；窗口改由 `EndBoundary` 控制。
4. 注册命令退出码 0 但任务并未建出 —— 成功判据改为 `schtasks /Query` 查到任务。
5. 最终改法：动作脚本写 `.ps1`、任务定义写 XML、`schtasks /Create /XML` 注册。XML 必须 UTF-16LE + BOM，否则 `schtasks` 报「无法切换编码」。

## 证据文件

原始证据目录（Windows 回归机，随 PR 归档为 zip）：
- `win-update-failed-recovery/judge-main.txt`、`judge-counter.txt`、`verdict.txt`、`run.log`
- `main/case-running/after-fail-state.txt`、`after-fail-update-failed.txt`
- `counter/case-running/*`（旧包反证轮）

judge 原文摘录见本文件上方代码块；完整目录可从 issue #1817 的评论取。

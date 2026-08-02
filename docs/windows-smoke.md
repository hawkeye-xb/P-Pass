# H-09 Windows 真机冒烟 — 执行说明书（给 Win 测试机器代理）

> 目标机器：Windows 测试机（x64）。本机 agent 按此文件执行冒烟并把结果
> 回报到 Discord。所有步骤的输出都应当**原文回贴**（日志行、退出码），
> 不要只贴结论。

## 0. 前置检查（30 秒）

1. `git --version`、`powershell` 可用（Win10/11 自带）
2. 网络可达 github.com
3. 如果杀软/Defender 拦截 daemon.exe —— **按 docs/troubleshooting/blocked-by-av.md
   三步验证**（SHA-256 对照 bin-win-x64 的 SHA256SUMS），确认一致后放行，
   并在回报里注明"被拦截过、已放行"

## 1. 拉取二进制（纯 git 分发，免认证）

```powershell
cd $env:TEMP
git clone --depth 1 --branch bin-win-x64 https://github.com/hawkeye-xb/P-Pass.git ppf-win-bin
cd ppf-win-bin
# 应有: daemon.exe  testclient.exe  win-smoke.ps1  SHA256SUMS  BUILD_INFO
Get-Content SHA256SUMS   # 记录哈希备用
```

## 2. 校验哈希（可选但推荐）

```powershell
Get-FileHash daemon.exe -Algorithm SHA256
Get-FileHash testclient.exe -Algorithm SHA256
# 与 SHA256SUMS 一致才继续
```

## 3. 跑冒烟

```powershell
powershell -ExecutionPolicy Bypass -File win-smoke.ps1
```

期望终态：`WIN SMOKE: ALL GREEN`（工作目录默认 `%TEMP%\ppf-win-dogfood`）。

## 4. 回报模板（贴到 Discord）

```
[H-09 冒烟结果] <PASS/FAIL>
- 机器: <Windows 版本 + 架构>
- 步骤: 0 前置 / 1 拉取 / 2 哈希 / 3 冒烟
- 冒烟输出: <全文或关键行>
- IPC socket 路径探测结果: <脚本打印的那行，Win 上 interprocess 落点待实证>
- 异常/疑问: <如有>
```

## 5. 实证结论（2026-08-02 H-09 首跑，Win x64 / PS 5.1）

| 项 | 结论 |
|---|---|
| IPC socket 路径 | **Windows 命名管道 `\\.\pipe\ppf-<NodeId前8hex>`**（不是 AF_UNIX 文件 socket）。ipc.token 两行：行1 = socket 名（如 `ppf-e4863927`），行2 = 32B 令牌 hex |
| IPC 协议契约 | 客户端**第一行发原始令牌**，随后 newline-delimited JSON（每行一个 Req 对应一行 Resp）；`Req.id` 是**字符串**；方法有 `status/pairing.start/pairing.confirm/devices.list/device.revoke/folder.set/logs.export`（**没有** `pairing.revoke`） |
| PS 5.1 硬坑 ① | **NamedPipeClientStream 必须用裸名** `$sockName`——带 `\\.\pipe\` 全路径前缀会 Connect(5000) 超时抛异常（实测：裸名秒连并拿真实响应） |
| PS 5.1 硬坑 ② | `Start-Process -PassThru` + 重定向输出时 `$pair.ExitCode` **恒为 null**（HasExited=True 也没用，Refresh/WaitForExit() 无参一样）——成功判据必须用 pair.log 文案（显式 UTF-8 读取），退出码仅展示 |
| 中文编码 | **必须 UTF-8 BOM 保存**——PS 5.1 无 BOM 按 GBK 解析中文引号直接 ParserError；修复版脚本已带 BOM（合入/编辑时勿丢失） |
| Defender 拦截 | 实时保护开启但威胁记录 0，未拦截；daemon.exe 未签名（NotSigned）正常执行 |
| daemon 控制台行为 | 无窗口启动（脚本用 Hidden）；stdout 打启动横幅（NodeId → QR 10 分钟有效 → IPC 行）；stderr 走 tracing（UTC+ANSI+模块 target），含 `stdin closed — pairing confirmation is IPC-only from here` |

## 6. 如果 FAIL —— 把这三样东西原文回报

1. `%TEMP%\ppf-win-dogfood\daemon.log` + `daemon.err`（如存在）末尾 30 行
2. 失败步骤的完整输出 + 退出码
3. 你的 Windows 版本号（`winver` 或 `[System.Environment]::OSVersion`）

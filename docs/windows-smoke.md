# H-09 Windows real-box smoke — runbook / Windows 真机冒烟执行说明书

> Target: the Windows test machine (x64). The local agent runs the smoke per
> this file and reports results to Discord. Paste **raw output** (log lines,
> exit codes) for every step — conclusions alone are not enough.
> 目标机器：Windows 测试机（x64）。本机 agent 按此文件执行冒烟并把结果
> 回报到 Discord。所有步骤的输出都应当**原文回贴**（日志行、退出码），
> 不要只贴结论。

## 0. Preflight (30s) / 前置检查

1. `git --version` and `powershell` available (built into Win10/11)
   `git --version`、`powershell` 可用（Win10/11 自带）
2. github.com reachable / 网络可达 github.com
3. If AV/Defender blocks daemon.exe — follow
   `docs/troubleshooting/blocked-by-av.md` three-step verification
   (compare SHA-256 against SHA256SUMS on the dogfood release), allow
   after it matches, and note "blocked once, allowed" in the report
   如果杀软/Defender 拦截 daemon.exe —— **按
   docs/troubleshooting/blocked-by-av.md 三步验证**（SHA-256 对照
   dogfood release 的 SHA256SUMS-win-x64），确认一致后放行，并在回报里注明
   "被拦截过、已放行"

## 1. Fetch binaries (dogfood release, no auth) / 拉取二进制

```powershell
cd $env:TEMP
gh release download dogfood --repo hawkeye-xb/P-Pass --pattern 'daemon.exe' --pattern 'testclient.exe' --pattern 'win-smoke.ps1' --pattern 'SHA256SUMS-win-x64' --pattern 'BUILD_INFO-win-x64' --dir ppf-win-bin
cd ppf-win-bin
# Should contain: daemon.exe  testclient.exe  win-smoke.ps1  SHA256SUMS-win-x64  BUILD_INFO-win-x64
Get-Content SHA256SUMS-win-x64   # record hashes for later / 记录哈希备用
# 无 gh 的机器：浏览器/curl 访问 https://github.com/hawkeye-xb/P-Pass/releases/download/dogfood/ 逐个下载同名资产
```

## 2. Verify hashes (optional but recommended) / 校验哈希

```powershell
Get-FileHash daemon.exe -Algorithm SHA256
Get-FileHash testclient.exe -Algorithm SHA256
# Continue only if they match SHA256SUMS / 与 SHA256SUMS 一致才继续
```

## 3. Run the smoke / 跑冒烟

```powershell
powershell -ExecutionPolicy Bypass -File win-smoke.ps1
```

Expected end state: `WIN SMOKE: ALL GREEN` (workdir default
`%TEMP%\ppf-win-dogfood`).
期望终态：`WIN SMOKE: ALL GREEN`（工作目录默认 `%TEMP%\ppf-win-dogfood`）。

## 4. Report template (paste to Discord) / 回报模板

```
[H-09 冒烟结果] <PASS/FAIL>
- 机器: <Windows 版本 + 架构>
- 步骤: 0 前置 / 1 拉取 / 2 哈希 / 3 冒烟
- 冒烟输出: <全文或关键行>
- IPC socket 路径探测结果: <脚本打印的那行，Win 上 interprocess 落点待实证>
- 异常/疑问: <如有>
```

## 5. Empirical findings (2026-08-02 H-09 first run, Win x64 / PS 5.1) / 实证结论

| Item / 项 | Finding / 结论 |
|---|---|
| IPC socket path / IPC socket 路径 | **Windows named pipe `\\.\pipe\ppf-<NodeId前8hex>`** (not an AF_UNIX file socket). ipc.token has two lines: line 1 = socket name (e.g. `ppf-e4863927`), line 2 = 32-byte token hex / **Windows 命名管道**，ipc.token 两行：行1 = socket 名，行2 = 32B 令牌 hex |
| IPC protocol contract / IPC 协议契约 | Client sends the **raw token as the first line**, then newline-delimited JSON (one Req per line ↔ one Resp); `Req.id` is a **string**; methods: `status/pairing.start/pairing.confirm/devices.list/device.revoke/folder.set/logs.export` (there is **no** `pairing.revoke`) / 客户端**第一行发原始令牌**，随后 newline-delimited JSON（每行一个 Req 对应一行 Resp）；`Req.id` 是**字符串**；方法有 `status/pairing.start/pairing.confirm/devices.list/device.revoke/folder.set/logs.export`（**没有** `pairing.revoke`） |
| NamedPipeClientStream connect (.NET ctor contract, not a PS bug) / 命名管道连接（.NET 构造函数契约，非 PS bug） | `NamedPipeClientStream(serverName, pipeName, …)` takes the **bare name** `$sockName` — the ctor appends the `\\.\pipe\` prefix itself (a long-standing .NET pipe API contract, not PS-5.1-specific). Passing the full `\\.\pipe\` path as `pipeName` makes .NET Framework resolve it to a wrong pipe and `Connect(5000)` times out (measured: bare name connects instantly and returns real responses) / `NamedPipeClientStream(serverName, pipeName, …)` 的 `pipeName` 参数**只传裸名** `$sockName`——构造函数自动拼 `\\.\pipe\` 前缀（这是 .NET 管道 API 的既有契约，不是 PS 5.1 特有的行为）。若把 `\\.\pipe\` 全路径当 `pipeName` 传入，.NET Framework 会把它解析成错误的管道路径，`Connect(5000)` 超时抛异常（实测：裸名秒连并拿真实响应） |
| Child-process ExitCode (H-09b: fixed, handle-cache) / 子进程 ExitCode（H-09b 已修，handle-cache 方案） | `Start-Process -PassThru` + redirected output: `$pair.ExitCode` read directly gives no reliable value; the standard fix is `$null = $proc.Handle` before `WaitForExit` to cache the handle, after which ExitCode is readable (win-smoke.ps1 now uses this; the old match-on-pair.log-text heuristic is gone) / `Start-Process -PassThru` + 重定向输出时 `$pair.ExitCode` 若直接读会拿不到可靠值；标准修法是在 `WaitForExit` 前先 `$null = $proc.Handle` 缓存句柄，之后 `ExitCode` 可读（win-smoke.ps1 已按此实现；不再匹配 pair.log 中文文案） |
| Chinese encoding / 中文编码 | **Must save as UTF-8 with BOM** — PS 5.1 parses BOM-less files as GBK and Chinese quotes cause ParserError; the fixed script ships with BOM (don't lose it when editing) / **必须 UTF-8 BOM 保存**——PS 5.1 无 BOM 按 GBK 解析中文引号直接 ParserError；修复版脚本已带 BOM（合入/编辑时勿丢失） |
| Defender interference / Defender 拦截 | Realtime protection on, threat history 0, nothing blocked; daemon.exe unsigned (NotSigned) runs fine / 实时保护开启但威胁记录 0，未拦截；daemon.exe 未签名（NotSigned）正常执行 |
| daemon console behaviour / 控制台行为 | Starts windowless (script uses Hidden); stdout prints the banner (NodeId → QR valid 10 min → IPC line); stderr goes through tracing (UTC+ANSI+module target), including `stdin closed — pairing confirmation is IPC-only from here` / 无窗口启动（脚本用 Hidden）；stdout 打启动横幅（NodeId → QR 10 分钟有效 → IPC 行）；stderr 走 tracing（UTC+ANSI+模块 target），含 `stdin closed — pairing confirmation is IPC-only from here` |

## 6. If FAIL — report these three verbatim / 如果 FAIL

1. `%TEMP%\ppf-win-dogfood\daemon.log` + `daemon.err` (if present) last 30 lines
   `daemon.log` + `daemon.err`（如存在）末尾 30 行
2. Full output + exit code of the failing step / 失败步骤的完整输出 + 退出码
3. Your Windows version (`winver` or `[System.Environment]::OSVersion`)
   你的 Windows 版本号

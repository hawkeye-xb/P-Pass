# H-09 Windows 真机冒烟（win-smoke.ps1）—— 与 dogfood-smoke.sh 同剧本：
# 起 daemon → 配对(QR+IPC确认) → backup 50 → 幂等重跑 → browse →
# IPC 吊销 → revoke-check → logs.export。全部通过输出
# "WIN SMOKE: ALL GREEN"，任一步失败退出非零。
#
# 用法（在下载了 dogfood release win-x64 资产的机器上）:
#   gh release download dogfood --pattern '*.exe' --pattern 'win-smoke.ps1' \
#     --pattern 'SHA256SUMS-win-x64' --repo hawkeye-xb/P-Pass
#   powershell -ExecutionPolicy Bypass -File win-smoke.ps1 [-WorkDir <dir>]
#
# 已知实证结论（2026-08-02 H-09 首跑，Win x64 / PS 5.1）:
#   - interprocess GenericNamespaced 在 Windows 的落点 = 命名管道
#     \\.\pipe\ppf-<NodeId前8hex>（不是 AF_UNIX 文件 socket）
#   - ipc.token 两行：行1 = socket 名，行2 = 32B 令牌 hex
#   - IPC 协议契约（crates/daemon/src/ipc.rs）: 客户端第一行发原始令牌，
#     随后 newline-delimited JSON（每行一个 Req 对应一行 Resp）,
#     Req.id 是字符串；方法: status / pairing.start / pairing.confirm /
#     devices.list / device.revoke / folder.set / logs.export（无 pairing.revoke）
#   - 本脚本必须以 UTF-8 BOM 保存（PS 5.1 无 BOM 按 GBK 解析中文引号会
#     ParserError）。写文件/合入时务必保留 BOM。
#
# T-062b 无关，H-09b 修正（2026-08-03）：
#   - 幂等判据恒真式：`-match "缺 0|0 个"` 会被 "清单 50 个文件" 的 "0 个"
#     命中（永远绿）→ 改精确匹配 "缺 0 个"。
#   - 吊销 soft-fail：吊销未生效只打印 "人工核对" 仍 ALL GREEN——安全语义
#     不许软，改 hard-fail。
#   - pairing.confirm / device.revoke / logs.export 的 Resp 之前直接丢弃
#     （$null = Invoke-Ipc）→ 现在检查 Resp 的 ok 字段，失败即退出。
#   - daemon 清理：之前只有成功路径 Stop-Process，中途 Write-Error 会泄漏
#     daemon 进程占住命名管道 → try/finally 保证任何路径都杀。
#   - $pair.ExitCode 恒 null：标准修法 $null = $proc.Handle 缓存句柄
#     （替代之前匹配中文日志文案的做法）。

param([string]$WorkDir = "")

$ErrorActionPreference = "Stop"
# PS 5.1 控制台默认 GBK——设 UTF-8 输出编码，避免中文文案匹配（step 3 幂等）乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Work = if ($WorkDir) { $WorkDir } else { Join-Path $env:TEMP "ppf-win-dogfood" }
$script:Bin = Split-Path -Parent $MyInvocation.MyCommand.Path
$DAEMON = Join-Path $Bin "daemon.exe"
$TC = Join-Path $Bin "testclient.exe"

if (-not (Test-Path $DAEMON)) { Write-Error "daemon.exe 不在 $Bin —— 先 gh release download dogfood --pattern '*.exe' --pattern 'win-smoke.ps1'（见 docs/windows-smoke.md §1）"; exit 1 }
if (-not (Test-Path $TC)) { Write-Error "testclient.exe 不在 $Bin"; exit 1 }

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$env:PPF_DATA_DIR = Join-Path $Work "library"
$env:PPF_RELAY_URLS = ""
$env:PPF_TELEMETRY_ENABLED = "false"

$script:DAEMON_PID = $null
$daemonLog = Join-Path $Work "daemon.log"
$daemonErr = Join-Path $Work "daemon.err"

function Stop-Daemon {
    if ($script:DAEMON_PID) {
        Stop-Process -Id $script:DAEMON_PID -Force -ErrorAction SilentlyContinue
        $script:DAEMON_PID = $null
    }
}

# ── IPC 客户端（Windows 命名管道 + 令牌认证 + newline-delimited JSON）──
# 契约见 crates/daemon/src/ipc.rs 顶部注释。每次调用新建连接：
#   连接 \\.\pipe\$sockName → 第一行发原始令牌 → 每行一个 Req（id 为字符串）
#   → 读一行 Resp。无超时选项会永久挂起，故 Connect 带 5s 超时。
#   ⚠️ NamedPipeClientStream 的 pipeName 参数只传裸名 $sockName：构造函数
#   自动拼 \\.\pipe\ 前缀（.NET 管道 API 既有契约，非 PS 5.1 bug）；把
#   全路径当 pipeName 传入会让 .NET Framework 解析出错误的管道，
#   Connect(5000) 超时抛异常（H-09b 实测）。
function Invoke-Ipc([string]$method, [string]$paramsJson) {
    $payload = '{"id":"smoke","method":"' + $method + '","params":' + $paramsJson + '}'
    $pipePath = $sockName   # 裸名！pipeName 参数不带 \\.\pipe\ 前缀（构造函数自动拼；见上注释）
    $client = New-Object System.IO.Pipes.NamedPipeClientStream(".", $pipePath, [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $client.Connect(5000)   # PS 5.1 无超时则永久挂起——必须显式
        $writer = New-Object System.IO.StreamWriter($client)
        $writer.AutoFlush = $true
        $writer.WriteLine($token)      # 第一行：原始令牌（缺了会被静默断连）
        $writer.WriteLine($payload)    # 之后每行：Req（newline-delimited）
        $reader = New-Object System.IO.StreamReader($client)
        $resp = $reader.ReadLine()     # 一行 Resp
        Write-Host "    (ipc 端点: $pipePath)"
        return $resp
    } catch {
        throw "IPC 调用失败（$method @ $pipePath）: $($_.Exception.Message)"
    } finally {
        $client.Dispose()
    }
}

# H-09b：Resp 必须是 {"ok":true,...}，否则退出（之前直接丢弃，错误被吞）。
# 注意 daemon 对合法方法返回 {"id":..,"ok":true,"result":..}；
# 对错误返回 {"id":..,"ok":false,"error":..}。
function Assert-IpcOk([string]$method, [string]$resp) {
    if (-not $resp) { Write-Error "$method 无 Resp（连接被断？）"; exit 1 }
    try {
        $obj = $resp | ConvertFrom-Json
    } catch {
        Write-Error "$method Resp 不是 JSON: $resp"; exit 1
    }
    if (-not $obj.ok) {
        Write-Error "$method 失败: $resp"; exit 1
    }
    return $obj
}

try {
    Write-Host "── 0. 启动 daemon（$env:PPF_DATA_DIR）"
    $proc = Start-Process -FilePath $DAEMON -RedirectStandardOutput $daemonLog -RedirectStandardError $daemonErr -PassThru -WindowStyle Hidden
    $null = $proc.Handle   # H-09b：缓存句柄，之后 $proc.ExitCode 才可读（PS 5.1 标准修法）
    $script:DAEMON_PID = $proc.Id

    # 等 QR 出现
    $qr = $null
    for ($i = 0; $i -lt 100; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $daemonLog) {
            $m = Select-String -Path $daemonLog -Pattern "ppf://pair" | Select-Object -First 1
            if ($m) { $qr = ($m.Line -split " " | Where-Object { $_ -like "ppf://pair*" } | Select-Object -First 1); break }
        }
        if ($proc.HasExited) { Write-Error "daemon 提前退出，日志: $(Get-Content $daemonErr -ErrorAction SilentlyContinue | Select-Object -Last 5)"; exit 1 }
    }
    if (-not $qr) { Write-Error "20 秒内未见配对 QR —— daemon 启动异常（看 $daemonErr）"; exit 1 }

    $node = $null
    $m = Select-String -Path $daemonLog -Pattern "NodeId: ([0-9a-fA-F]{64})" | Select-Object -First 1
    if ($m) { $node = $m.Matches[0].Groups[1].Value }
    if (-not $node) { Write-Error "日志中未找到 NodeId"; exit 1 }

    $ipcToken = Join-Path $env:PPF_DATA_DIR "ipc.token"
    if (-not (Test-Path $ipcToken)) { Write-Error "ipc.token 未生成"; exit 1 }
    # H-09b：@() 包一层——单行文件时 $lines[1] 会取到第 2 个字符
    $tokenLines = @(Get-Content $ipcToken)
    $sockName = $tokenLines[0].Trim()
    $token = $tokenLines[1].Trim()
    if (-not $token) { Write-Error "ipc.token 缺少令牌行（行2 应为 32B hex）"; exit 1 }
    Write-Host "daemon up: $node (ipc: $sockName)"

    Write-Host "── 1. 配对（QR + IPC owner 确认）"
    $pairLog = Join-Path $Work "pair.log"
    $pair = Start-Process -FilePath $TC -ArgumentList @("pair", "--token", $qr, "--name", "win-agent") -RedirectStandardOutput $pairLog -RedirectStandardError (Join-Path $Work "pair.err") -PassThru -WindowStyle Hidden
    $null = $pair.Handle   # H-09b：缓存句柄，ExitCode 才可读（替代匹配中文日志）
    Start-Sleep -Seconds 3
    $resp = Invoke-Ipc "pairing.confirm" '{"accept": true}'
    $null = Assert-IpcOk "pairing.confirm" $resp   # H-09b：Resp 不许丢弃
    $null = $pair.WaitForExit(15000)
    $pairExit = $pair.ExitCode   # 缓存句柄后此值可靠（之前恒 null）
    if ($pairExit -ne 0) {
        Write-Error "配对失败（exit=$pairExit），日志: $(Get-Content $pairLog -ErrorAction SilentlyContinue | Select-Object -Last 3)"; exit 1
    }
    Write-Host "    配对成功（exit=$pairExit）"

    Write-Host "── 2. backup 50 个混合文件"
    & $TC backup --files 50 --node $node | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "backup 失败 exit=$LASTEXITCODE"; exit 1 }

    Write-Host "── 3. 幂等重跑（期望缺 0）"
    $idem = & $TC backup --files 50 --node $node 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Error "幂等重跑失败 exit=$LASTEXITCODE"; exit 1 }
    # H-09b：精确匹配 "缺 0 个"——旧判据 "缺 0|0 个" 会被 "清单 50 个文件" 命中（恒真式）
    if ($idem -match "缺 0 个") { Write-Host "    幂等 OK" }
    else { Write-Error "幂等失败（未见精确'缺 0 个'）: $($idem.Trim())"; exit 1 }

    Write-Host "── 4. browse 校验"
    $br = & $TC browse --node $node 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Error "browse 失败 exit=$LASTEXITCODE"; exit 1 }
    Write-Host "    browse 输出行数: $((($br -split "`n") | Where-Object { $_ }).Count)"

    Write-Host "── 5. IPC 吊销 + revoke-check"
    # 吊销目标 = 配对设备（testclient 本机）的 NodeId，从 pair.log 提取；
    # 方法真名 device.revoke（不存在 pairing.revoke），params 用 node_id。
    $dm = Select-String -Path $pairLog -Pattern "本机 NodeId: ([0-9a-fA-F]{64})" | Select-Object -First 1
    $deviceNode = if ($dm) { $dm.Matches[0].Groups[1].Value } else { $null }
    if (-not $deviceNode) { Write-Error "pair.log 未找到配对设备 NodeId，无法吊销"; exit 1 }
    $resp = Invoke-Ipc "device.revoke" ("{`"node_id`":`"$deviceNode`"}")
    $null = Assert-IpcOk "device.revoke" $resp   # H-09b：Resp 不许丢弃
    # revoke-check 复用配对身份（默认 testclient.key，cwd 一致）连 daemon，
    # 期望 NOT_AUTHORIZED —— 吊销后仍放行 = 检查点失守。
    $rv = & $TC revoke-check --node $node 2>&1 | Out-String
    Write-Host "    revoke-check: $($rv.Trim())"
    # H-09b：hard-fail——吊销未生效（revoke-check 未报拒绝）必须红，不许 ALL GREEN
    if ($rv -match "拒绝|not_authorized|NOT_AUTHORIZED") { Write-Host "    吊销生效" }
    else { Write-Error "吊销未生效（revoke-check 未报拒绝）: $($rv.Trim())"; exit 1 }

    Write-Host "── 6. logs.export 脱敏抽查"
    $resp = Invoke-Ipc "logs.export" '{}'
    $null = Assert-IpcOk "logs.export" $resp   # H-09b：Resp 不许丢弃

    Write-Host ""
    Write-Host "════════════════════════════════════════════"
    Write-Host "  WIN SMOKE: ALL GREEN"
    Write-Host "════════════════════════════════════════════"
} finally {
    Stop-Daemon   # H-09b：任何路径（成功或 Write-Error）都杀 daemon，防泄漏占管道
}
exit 0

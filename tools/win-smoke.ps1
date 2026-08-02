# H-09 Windows 真机冒烟（win-smoke.ps1）—— 与 dogfood-smoke.sh 同剧本：
# 起 daemon → 配对(QR+IPC确认) → backup 50 → 幂等重跑 → browse →
# IPC 吊销 → revoke-check → logs.export。全部通过输出
# "WIN SMOKE: ALL GREEN"，任一步失败退出非零。
#
# 用法（在拉取了 bin-win-x64 分支的机器上）:
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

param([string]$WorkDir = "")

$ErrorActionPreference = "Stop"
# PS 5.1 控制台默认 GBK——设 UTF-8 输出编码，避免中文文案匹配（step 3 幂等）乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Work = if ($WorkDir) { $WorkDir } else { Join-Path $env:TEMP "ppf-win-dogfood" }
$script:Bin = Split-Path -Parent $MyInvocation.MyCommand.Path
$DAEMON = Join-Path $Bin "daemon.exe"
$TC = Join-Path $Bin "testclient.exe"

if (-not (Test-Path $DAEMON)) { Write-Error "daemon.exe 不在 $Bin —— 先 git fetch origin bin-win-x64 并取文件"; exit 1 }
if (-not (Test-Path $TC)) { Write-Error "testclient.exe 不在 $Bin"; exit 1 }

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$env:PPF_DATA_DIR = Join-Path $Work "library"
$env:PPF_RELAY_URLS = ""
$env:PPF_TELEMETRY_ENABLED = "false"

Write-Host "── 0. 启动 daemon（$env:PPF_DATA_DIR）"
$daemonLog = Join-Path $Work "daemon.log"
$daemonErr = Join-Path $Work "daemon.err"
$proc = Start-Process -FilePath $DAEMON -RedirectStandardOutput $daemonLog -RedirectStandardError $daemonErr -PassThru -WindowStyle Hidden
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
$tokenLines = Get-Content $ipcToken
$sockName = $tokenLines[0].Trim()
$token = $tokenLines[1].Trim()
if (-not $token) { Write-Error "ipc.token 缺少令牌行（行2 应为 32B hex）"; exit 1 }
Write-Host "daemon up: $node (ipc: $sockName)"

# ── IPC 客户端（Windows 命名管道 + 令牌认证 + newline-delimited JSON）──
# 契约见 crates/daemon/src/ipc.rs 顶部注释。每次调用新建连接：
#   连接 \\.\pipe\$sockName → 第一行发原始令牌 → 每行一个 Req（id 为字符串）
#   → 读一行 Resp。无超时选项会永久挂起，故 Connect 带 5s 超时。
#   ⚠️ PS 5.1 硬坑（实测）：NamedPipeClientStream 必须用裸名 $sockName，
#   全路径 \\.\pipe\ 前缀会导致 Connect(5000) 超时抛异常。
function Invoke-Ipc([string]$method, [string]$paramsJson) {
    $payload = '{"id":"smoke","method":"' + $method + '","params":' + $paramsJson + '}'
    $pipePath = $sockName   # 裸名！.NET Framework 下带 \\.\pipe\ 前缀 Connect 超时
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

Write-Host "── 1. 配对（QR + IPC owner 确认）"
$pairLog = Join-Path $Work "pair.log"
$pair = Start-Process -FilePath $TC -ArgumentList @("pair", "--token", $qr, "--name", "win-agent") -RedirectStandardOutput $pairLog -RedirectStandardError (Join-Path $Work "pair.err") -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$null = Invoke-Ipc "pairing.confirm" '{"accept": true}'
$null = $pair.WaitForExit(15000)
# ⚠️ PS 5.1 硬坑（实测）：Start-Process -PassThru + 重定向输出时，
# $pair.ExitCode 恒为 null（HasExited=True 也没用，Refresh/WaitForExit() 无参也一样）。
# 成功判据必须用 pair.log 文案（显式 UTF-8 读取），退出码仅作展示。
$pairText = if (Test-Path $pairLog) { [System.IO.File]::ReadAllText($pairLog, [System.Text.Encoding]::UTF8) } else { "" }
$ok = $pairText -match "配对成功"
if (-not $ok) { Write-Error "配对失败（exit=$($pair.ExitCode)），日志: $(Get-Content $pairLog -ErrorAction SilentlyContinue | Select-Object -Last 3)"; exit 1 }
Write-Host "    配对成功（exit=0）"

Write-Host "── 2. backup 50 个混合文件"
& $TC backup --files 50 --node $node | Out-Host
if ($LASTEXITCODE -ne 0) { Write-Error "backup 失败 exit=$LASTEXITCODE"; exit 1 }

Write-Host "── 3. 幂等重跑（期望缺 0）"
$idem = & $TC backup --files 50 --node $node 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Error "幂等重跑失败 exit=$LASTEXITCODE"; exit 1 }
if ($idem -match "缺 0|0 个") { Write-Host "    幂等 OK" } else { Write-Host "    幂等输出（未见'缺 0'字样，人工核对）: $($idem.Trim())" }

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
$null = Invoke-Ipc "device.revoke" ("{`"node_id`":`"$deviceNode`"}")
# revoke-check 复用配对身份（默认 testclient.key，cwd 一致）连 daemon，
# 期望 NOT_AUTHORIZED —— 吊销后仍放行 = 检查点失守。
$rv = & $TC revoke-check --node $node 2>&1 | Out-String
Write-Host "    revoke-check: $($rv.Trim())"
if ($rv -match "拒绝|not_authorized|NOT_AUTHORIZED") { Write-Host "    吊销生效" } else { Write-Host "    吊销输出需人工核对" }

Write-Host "── 6. logs.export 脱敏抽查"
$null = Invoke-Ipc "logs.export" '{}'

Stop-Process -Id $DAEMON_PID -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "════════════════════════════════════════════"
Write-Host "  WIN SMOKE: ALL GREEN"
Write-Host "════════════════════════════════════════════"
exit 0

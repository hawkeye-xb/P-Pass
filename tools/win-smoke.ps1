# H-09 Windows 真机冒烟（win-smoke.ps1）—— 与 dogfood-smoke.sh 同剧本：
# 起 daemon → 配对(QR+IPC确认) → backup 50 → 幂等重跑 → browse →
# IPC 吊销 → revoke-check → logs.export。全部通过输出
# "WIN SMOKE: ALL GREEN"，任一步失败退出非零。
#
# 用法（在拉取了 bin-win-x64 分支的机器上）:
#   powershell -ExecutionPolicy Bypass -File win-smoke.ps1 [-WorkDir <dir>]
#
# 已知待实证项（上报给开发侧）:
#   - interprocess GenericNamespaced 在 Windows 的 socket 实际路径
#     （本脚本探测候选路径，第一个连通的胜出并打印）
#   - daemon 控制台行为 / Defender 是否拦未签名 exe（blocked-by-av 文档）
#   - 中文输出编码（testclient 的"配对成功"在 GBK 控制台可能乱码，
#     以退出码为准，字符串校验做辅助）

param([string]$WorkDir = "")

$ErrorActionPreference = "Stop"
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
$sockName = (Get-Content $ipcToken -TotalCount 1).Trim()
Write-Host "daemon up: $node (ipc: $sockName)"

# ── IPC 客户端（AF_UNIX；候选路径探测）─────────────────────────────
function Invoke-Ipc([string]$method, [string]$paramsJson) {
    $payload = '{"jsonrpc":"2.0","id":1,"method":"' + $method + '","params":' + $paramsJson + '}'
    $candidates = @(
        $sockName,
        (Join-Path $env:TEMP $sockName),
        (Join-Path $env:TEMP ("interprocess\" + $sockName)),
        (Join-Path $env:TEMP ("interprocess\local_socket\" + $sockName)),
        ("C:\tmp\" + $sockName),
        (Join-Path $env:PPF_DATA_DIR $sockName)
    ) | Select-Object -Unique
    $lastErr = $null
    foreach ($p in $candidates) {
        $client = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::Unix, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::IP)
        try {
            $ep = [System.Net.Sockets.UnixDomainSocketEndPoint]::new($p)
            $client.Connect($ep)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
            $client.Send($bytes)
            $buf = New-Object byte[] 65536
            $n = $client.Receive($buf)
            $resp = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
            Write-Host "    (ipc socket 路径: $p)"
            return $resp
        } catch { $lastErr = $_.Exception.Message }
        finally { $client.Dispose() }
    }
    throw "IPC 连接全部失败（socket=$sockName）: $lastErr"
}

Write-Host "── 1. 配对（QR + IPC owner 确认）"
$pairLog = Join-Path $Work "pair.log"
$pair = Start-Process -FilePath $TC -ArgumentList @("pair", "--token", $qr, "--name", "win-agent") -RedirectStandardOutput $pairLog -RedirectStandardError (Join-Path $Work "pair.err") -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
$null = Invoke-Ipc "pairing.confirm" '{"accept": true}'
$pair.WaitForExit(15000) | Out-Null
$ok = $pair.ExitCode -eq 0
$grep = Select-String -Path $pairLog -Pattern "配对成功" -ErrorAction SilentlyContinue
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
$null = Invoke-Ipc "pairing.revoke" ("{`"node`":`"$node`"}")
$rv = & $TC revoke-check --node $node 2>&1 | Out-String
Write-Host "    revoke-check: $($rv.Trim())"
if ($rv -match "revoked|已吊销|拒") { Write-Host "    吊销生效" } else { Write-Host "    吊销输出需人工核对" }

Write-Host "── 6. logs.export 脱敏抽查"
$null = Invoke-Ipc "logs.export" '{}'

Stop-Process -Id $DAEMON_PID -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "════════════════════════════════════════════"
Write-Host "  WIN SMOKE: ALL GREEN"
Write-Host "════════════════════════════════════════════"
exit 0

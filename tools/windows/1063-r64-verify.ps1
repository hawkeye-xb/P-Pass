#Requires -Version 5.1
# 1063-r64-verify.ps1 - Verify the R6.4 end state independently of how the
# installer was driven. Writes R6.4\result.txt with PASS / PARTIAL / FAIL.
#
# PASS needs both: the SmartScreen evidence captured a dialog naming
# "Windows 已保护你的电脑" / "Windows protected your PC", and the test.10 install
# is healthy (DisplayVersion, daemon, pairing).
param(
    [string]$WorkRoot = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10'),
    [string]$Setup = (Join-Path $env:USERPROFILE 'ppcheck\1063-test10\assets\P-Pass_0.10.0-test.10_x64-setup.exe')
)

$ErrorActionPreference = 'Stop'
$caseDir = Join-Path $WorkRoot 'R6.4'
New-Item -ItemType Directory -Force $caseDir | Out-Null
$lines = New-Object System.Collections.Generic.List[string]
function Log([string]$s) { Write-Output $s; $lines.Add($s) }

$dst = Join-Path $env:USERPROFILE 'Downloads\P-Pass_0.10.0-test.10_x64-setup.exe'
$exe = Join-Path $env:LOCALAPPDATA 'P-Pass\p-pass-desktop.exe'
$srcHash = if (Test-Path -LiteralPath $Setup) { (Get-FileHash -LiteralPath $Setup -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$dstHash = if (Test-Path -LiteralPath $dst) { (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
$zone = @()
if (Test-Path -LiteralPath $dst) {
    $zone = @(Get-Content -LiteralPath ($dst + ':Zone.Identifier') -Encoding ASCII -ErrorAction SilentlyContinue)
}
$motwEvidence = @()
$motwFile = Join-Path $caseDir 'motw.txt'
if (Test-Path -LiteralPath $motwFile) { $motwEvidence = @(Get-Content -LiteralPath $motwFile -Encoding UTF8) }
# The ADS is often consumed once the installer is allowed to run, so the
# pre-launch motw.txt capture is the durable evidence.
$motwText = ($zone + $motwEvidence) -join "`n"
$motwOk = ($motwText -match 'ZoneId=3') -and ($motwText -match 'ReferrerUrl=https://github.com/')

$version = ''
$display = ''
try { $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion } catch { }
try { $display = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass' -ErrorAction Stop).DisplayVersion } catch { }
$daemon = Get-Process -Name 'ppf-daemon' -ErrorAction SilentlyContinue | Select-Object -First 1
$ipc = $null
try {
    $bash = 'C:\Program Files\Git\bin\bash.exe'
    $out = & $bash (Join-Path $PSScriptRoot '1063-ipc-status.sh') 2>&1
    if ($LASTEXITCODE -eq 0) { $ipc = (($out | Out-String).Trim()) | ConvertFrom-Json }
} catch { }

$smartText = ''
foreach ($f in @('smartscreen-win32.txt', 'smartscreen.txt', 'smartscreen-last.txt')) {
    $p = Join-Path $caseDir $f
    if (Test-Path -LiteralPath $p) { $smartText += (Get-Content -LiteralPath $p -Raw -Encoding UTF8) }
}
$smartSeen = $smartText -match '保护你的电脑|Windows protected your PC'
$webEval = $null
try { $webEval = (Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\AppHost' -Name EnableWebContentEvaluation -ErrorAction Stop).EnableWebContentEvaluation } catch { }

$installOk = ($srcHash -ne '' -and $srcHash -eq $dstHash -and $motwOk -and
    $version -eq '0.10.0-test.10' -and $display -eq '0.10.0-test.10' -and
    $null -ne $daemon -and $null -ne $ipc -and [int]$ipc.result.paired_devices -ge 1)

Log "=== #1063 R6.4 verification $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Log "source_sha256=$srcHash"
Log "downloads_sha256=$dstHash"
Log "motw_ok=$motwOk"
foreach ($z in $zone) { Log "  $z" }
Log "enable_web_content_evaluation=$webEval"
Log "product_version=$version"
Log "display_version=$display"
if ($daemon) { Log "ppf_daemon_pid=$($daemon.Id)" } else { Log 'ppf_daemon=MISSING' }
if ($ipc) {
    Log ("ipc state={0} version={1} paired_devices={2} devices={3} photo_count={4}" -f `
        $ipc.result.state, $ipc.result.version, $ipc.result.paired_devices, $ipc.result.devices, $ipc.result.photo_count)
} else { Log 'ipc=DOWN' }
Log "smartscreen_evidence=$smartSeen"

if ($installOk -and $smartSeen) {
    Log 'RESULT=PASS SmartScreen dialog observed; test.10 installed; daemon up; pairing intact'
    $result = 'PASS'
} elseif ($installOk) {
    Log 'RESULT=PARTIAL test.10 installed and pairing intact, but no SmartScreen dialog text was captured'
    $result = 'PARTIAL'
} else {
    Log 'RESULT=FAIL install or pairing verification failed'
    $result = 'FAIL'
}
[IO.File]::WriteAllLines((Join-Path $caseDir 'result.txt'), $lines, (New-Object Text.UTF8Encoding($false)))
if ($result -eq 'PASS') { exit 0 }
if ($result -eq 'PARTIAL') { exit 2 }
exit 1

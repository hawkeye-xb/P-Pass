# Windows 回归场景：程序生成测试照片（等价于 tools/e3/lib/gen-photos.py）。
#
# gen-photos.py 用 macOS 的 sips 转 JPEG，Windows 上没有；这里用 Windows 自带的
# System.Drawing 画随机色块并另存 JPEG。内容各不相同（桌面按 sha256 判重），
# 文件名与 gen-photos.py 一致：PPR_<前缀>_<序号>.jpg。
#
# 用法: powershell -File gen-photos.ps1 -Out <目录> -Count <张数> -Prefix <前缀>
param(
    [Parameter(Mandatory = $true)][string]$Out,
    [int]$Count = 40,
    [string]$Prefix = 'PPR'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$seedBase = [Environment]::TickCount
for ($i = 0; $i -lt $Count; $i++) {
    $rnd = New-Object System.Random ($seedBase + $i * 7919)
    $bmp = New-Object System.Drawing.Bitmap 800, 600
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb($rnd.Next(256), $rnd.Next(256), $rnd.Next(256)))
    for ($k = 0; $k -lt 30; $k++) {
        $color = [System.Drawing.Color]::FromArgb($rnd.Next(256), $rnd.Next(256), $rnd.Next(256))
        $brush = [System.Drawing.SolidBrush]::new($color)
        $g.FillRectangle($brush, $rnd.Next(800), $rnd.Next(600), $rnd.Next(20, 300), $rnd.Next(20, 200))
        $brush.Dispose()
    }
    # 再画 1 个只与序号有关的标记，保证不同批次的前缀/序号组合内容不同。
    $markColor = [System.Drawing.Color]::FromArgb(($i * 37) % 256, ($i * 91) % 256, ($i * 53) % 256)
    $mark = [System.Drawing.SolidBrush]::new($markColor)
    $g.FillRectangle($mark, 10, 10, 20 + $i, 20 + $i)
    $mark.Dispose()
    $path = Join-Path $Out ('PPR_{0}_{1:D3}.jpg' -f $Prefix, $i)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $g.Dispose()
    $bmp.Dispose()
}
Write-Output "generated $Count jpegs in $Out"

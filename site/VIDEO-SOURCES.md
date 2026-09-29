# 宣传片素材来源

30 秒宣传片，全部由代码生成（HTML/SVG 逐帧渲染 + 程序合成配乐）。画面里的照片是风格化插画，不含真人照片；图标用 Lucide（ISC 许可）。

四个成片来自私仓 hawkeye-xb/P-Pass-promo 的 `versions/v6-site-copy/`（分支 `feat/v6-site-copy` @ `647c1b4`），画面文案对齐中文官网 #514 与英文官网 #518。

| 文件 | 规格 | 页面 |
|---|---|---|
| `promo-16x9.mp4` / `.webp` | 1920×1080，30fps，30.0s，H.264 + AAC | `/zh/` 桌面 |
| `promo-3x4.mp4` / `.webp` | 1080×1440，30fps，30.0s | `/zh/` 手机（≤760px） |
| `promo-16x9-en.mp4` / `.webp` | 1920×1080，30fps，30.0s | `/` 桌面 |
| `promo-3x4-en.mp4` / `.webp` | 1080×1440，30fps，30.0s | `/` 手机（≤760px） |

封面取第 7 秒。所有 mp4 都做了 faststart（`moov` 在前），可以边下边播。

## sha256

```
f672fbf8c41067607c201f685732b33cec288b906a4fc712972fe3192b3b3908  promo-16x9-en.mp4
e82fc79eb2a34bcefeaedf10ac8e308e41d84ad7ba6aaee1c8c3d7d99fb6a69c  promo-16x9-en.webp
565df56ac14f3000cdf526a7ed71bba55d9939fe4863c2d814fdd29a4965348f  promo-16x9.mp4
943916a25ea0e4a8b1dfb238004aac649c9d5c67d4ecf2168fc8a237fc887076  promo-16x9.webp
2536865a087e013580a10366b32c4e09e86f6163cf8f7f189146751e9cb6dc93  promo-3x4-en.mp4
fb5bf03b12b4ad340763f28b93c76b47b5d4efa9bb5c852ba8886f8a87cebbfa  promo-3x4-en.webp
3233d55c7568131fc93d8495a24ac6af82cece18ba6cfc04924e81230cc5b4bd  promo-3x4.mp4
7e83b8623501a710780dffdfa8115a90910accaa058aa5ca9be078f2ac811085  promo-3x4.webp
```

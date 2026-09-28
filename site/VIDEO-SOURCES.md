# 宣传片素材来源

30 秒宣传片，全部由代码生成（HTML/SVG 逐帧渲染 + 程序合成配乐）。画面里的照片是风格化插画，不含真人照片；图标用 Lucide（ISC 许可）。

| 文件 | 来源（私仓 hawkeye-xb/P-Pass-promo） | 规格 |
|---|---|---|
| `promo-16x9.mp4` | `versions/v4-claude/final-audio.mp4` @ `db0a1de` | 1920×1080，30fps，30.0s，H.264 + AAC |
| `promo-3x4.mp4` | `versions/v5-mobile/promo-3x4.mp4` @ `b930485` | 1080×1440，30fps，30.0s，H.264 + AAC |
| `promo-16x9.webp` / `promo-3x4.webp` | 对应视频第 7 秒的一帧 | 与视频同尺寸 |

## 导出命令

```bash
ffmpeg -i <源 mp4> -c copy -movflags +faststart promo-<画幅>.mp4   # 只重封装，不重新编码
ffmpeg -ss 7 -i promo-<画幅>.mp4 -frames:v 1 frame.png
cwebp -q 80 frame.png -o promo-<画幅>.webp
```

## sha256

```
563025dcd979d953334ed64fcb54c9622b920656b528884f63699165bf60a6a4  promo-16x9.mp4
10387a344877cea4984e053e9cad7b0b713c540e308d2da16efd01405744ee4f  promo-16x9.webp
aca827caf2b269fdc8541165f66e3f0bf31d100229a71ffd51d554456de70c1c  promo-3x4.mp4
82f042e9b78def4675af474373423f1c690968101c54280e57b4026baa96ee4c  promo-3x4.webp
```

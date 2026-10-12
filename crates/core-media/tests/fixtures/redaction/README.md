# 抹地点样本（#851）

`*.original.*` 是带 GPS 的原文件，`*.redacted.*` 是同一文件在三星 S9210 / Android 15 上，用**没有** `ACCESS_MEDIA_LOCATION` 的 App 经 MediaStore 读出的字节（2026-10-12 真机取样）。

- 两份长度相同；
- 不同的字节在 redacted 里全部为 0。
- JPEG 的差异在 EXIF GPS 段，HEIC 的差异在 `iloc` 指向的 Exif 条目，MP4 的差异在 `moov/udta/loci`。

# ICON-01 图标接入双端构建　级别 L1（2026-08-11 出卡，排在 DEV-01 之后）

**目标**：把 docs/design/2026-08-11-icon-v1/ 的 SVG 定稿变成双端正式构建资产——
macOS .icns + 托盘模板图标、Android 自适应分层图标（分密度 PNG）、Windows .ico；
tauri.conf / AndroidManifest 接线；生成脚本幂等、产物入库。

**唯一基准**：`docs/design/2026-08-11-icon-v1/` 的 SVG 源文件（README.md 是规格）。
**范围**：
- `scripts/icons/`（新）：生成脚本（幂等——重复跑输出字节一致）
- `apps/desktop/src-tauri/icons/`（替换现 tauri 默认图标）
- `apps/desktop/src-tauri/tauri.conf.json`（icon 清单）
- `apps/desktop/src-tauri/src/lib.rs`（托盘模板图标）
- `apps/android/app/src/main/res/`（mipmap 分层图标 + manifest 接线）
- README.md 头图（可选，docs/design 目录内不新增设计文件）

**版本分工（用户钦定）**：
- 主图标 = 碳纹版 `icon-carbon.svg`（macOS/Android/Windows App 图标、启动页）
- ≤40px / 托盘 / 通知小图标 = **beast 全实线版** `icon-beast.svg`（碳纹小尺寸会糊成半灰）
- Android 前景层用**分密度 PNG**（VectorDrawable 不支持 pattern，别踩坑）
- macOS 托盘 = **模板图标**（纯黑 + alpha，`icon-beast.svg` 重描墨色，不渲染颜色）
- 夜间变体（-night）仅用于深色托盘场景评估，默认不用

**可执行验收**：
1. `scripts/icons/generate.sh` 幂等：连续跑两次，产物目录 `git status` 无新增
   （shasum 比对全量产物）。
2. macOS：`icon.icns` 含 16/32/64/128/256/512/1024 档；托盘模板 PNG 32×32
   纯黑+alpha（`sips -g` 检查像素格式）；`cargo check -p ppf-desktop` 绿。
3. Android：`mipmap-anydpi-v26/ic_launcher.xml` 引分密度前景 PNG + 背景色；
   `AndroidManifest.xml` 有 `android:icon`；`./gradlew :app:assembleDebug` 绿，
   APK 内 `aapt dump badging` 显示图标资源。
4. 视觉核对：64px 主图标（碳纹清晰）+ 16px（beast 版不糊），截图给验收人。

**收尾**：just 全绿（Rust 全量 + Android 单测）；PROGRESS 一行 + NEXT 队列 +
ROADMAP 状态行；卡移 done/。产出包 v0.3.2-test.1 时随 MOB/DEV-01 一起上真机。

---
## 验收记录（2026-08-11 Salamira）

**幂等**：`scripts/icons/generate.sh` 连跑两次 → 67 个产物文件（icns/ico/png/xml）shasum 逐字节一致 ✓（bash 3.2 无关联数组坑已绕过：并行数组）
**macOS**：`icon.icns` iconutil 反解全档位（16/32/128/256/512 + @2x + 1024）✓；托盘 `tray-icon.png` 32×32 RGBA（beast 纯黑+alpha）+ `icon_as_template(true)` 编译通过 ✓；`cargo check`（desktop）绿 ✓
**Android**：5 密度前景 PNG 入库 + anydpi-v26 adaptive-icon + Manifest icon/roundIcon；assembleDebug 绿；aapt badging `application-icon-*:'res/mipmap-anydpi-v26/ic_launcher.xml'` ✓
**Windows**：icon.ico 6 档（16/32/48/64/128/256，PNG-compressed ICO）file 确认 ✓
**视觉核对**：64px 碳纹纹理清晰 / 16px 碳纹糊成灰（验证用户判断）/ 16px beast 轮廓清楚 / 双版本同造型 ✓
**挂账（验收人）**：64px 碳纹 vs 16px beast 视觉图；macOS 托盘深浅色模板观感；三星真机桌面图标观感。

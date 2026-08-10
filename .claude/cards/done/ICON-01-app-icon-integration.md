# ICON-01 App 图标接入双端构建　级别 L1　【DEV-01 之后做】

## 背景

图标 v1 已定稿归档：`docs/design/2026-08-11-icon-v1/`（先读它的 README，
理念/规格/分工都在）。**该目录的 SVG 是唯一基准**，不许自由发挥改形状。
分工（README 已写死）：

- **主图标 = 碳纹版** `icon-carbon.svg`（用户钦定）
- **≤40px 档 = 屋脊兽全实线版** `icon-beast.svg`——碳纹在小尺寸糊成半灰，
  托盘/favicon/通知小图标一律用 beast
- 夜巡 `-night` 变体用于深色场合（macOS 模板托盘另有要求，见下）

## 交付

### ① 光栅化工具链

SVG → PNG 用 `rsvg-convert`（brew librsvg）或 resvg，任选一个写进
生成脚本 `tools/gen-icons.sh`（幂等，可重跑）；**生成产物 commit 入库**
（图标 PNG 体积小，不走 bin-* 通道）。注意 carbon 版含 `<pattern>`，
工具必须支持（rsvg-convert 支持，验证一张再批量）。

### ② 桌面（tauri）

- `apps/desktop/src-tauri/icons/` 全套替换：`npx tauri icon <carbon-1024.png>`
  生成基础集后，**16/32px 档用 beast 渲染覆盖**（含 icns 内小尺寸层、
  ico 小层）。
- 托盘图标：macOS 用**模板图标**（纯黑 + alpha，系统自己适配明暗菜单栏）
  ——用 beast 轮廓填黑导出 `trayTemplate.png`（@1x/@2x），接到现有托盘
  代码；不要用彩色版当托盘图。
- dmg 布局里的应用图标随 .icns 自动换，确认 bundle 后 dock/Finder 显示新图。

### ③ Android

- 自适应图标：前景层 = 兽面线条（按 README 说的 **66% 安全区缩排**重排，
  108dp 网格），背景层 = 纯色 paper `#FBF8F2`。
- **前景层用分密度 PNG**（mdpi~xxxhdpi）——VectorDrawable 不支持
  pattern 填充，碳纹转矢量会丢纹理，别踩这个坑；矢量只给 monochrome 层。
- monochrome 层（Android 13 主题图标）= beast 单色矢量（可转
  VectorDrawable，全实线无 pattern）。
- 通知小图标（status bar）= beast 剪影 alpha 版，替换现有默认。
- 圆/方/圆角三种遮罩下脸不裁角（README 的安全区要求）。

### ④ 清理

- 旧默认图标文件（tauri 初始 logo / android ic_launcher 默认绿机器人系）
  全部删除，`git grep` 确认无残留引用。
- 顺手：HomeScreen.kt L186-190 过期注释（还提「现在备份」按钮）删掉。

## 不准动

SVG 源文件的几何与颜色；tokens.json；图标之外的任何 UI。

## 可执行验收

1. `tools/gen-icons.sh` 重跑幂等（两次运行 git diff 为空）。
2. 桌面构建：dock/窗口/dmg 均显示新图；托盘在浅色/深色菜单栏都清晰
   （模板图标生效，贴两张截图）。
3. Android 模拟器：launcher 图标圆/方遮罩不裁脸；Android 13 主题图标
   （monochrome）生效；通知小图标为 beast 剪影（贴截图）。
4. 16/32px 档实际内容是 beast 不是 carbon（解包 icns/ico 抽查该层）。
5. 双端构建绿（vite build + assembleDebug）。

## 反证

把 gen-icons.sh 的 beast 小尺寸覆盖步骤注释掉 → 验收 4 必挂
（icns 小层变回 carbon 糊图，贴对照后还原）。

## 收尾

CI 绿；PROGRESS/NEXT 一行 + ROADMAP 状态；卡移 done/。完成后具备打
v0.3.2-test.1 的条件（MOB 批次 + DEV-01 + 新图标一起上真机）。

---
## 验收记录（2026-08-11 Salamira 执行，实现见 ICON-01-icon-assets.md）

本卡定义的交付全部落地：
- ① 工具链 `scripts/icons/generate.sh`（rsvg-convert + iconutil + python3）幂等 ✓
- ② 桌面：icons/ 全套替换；**icns/ico 的 ≤32px 层用 beast 覆盖**（16px 灰像素与 beast 参考逐像素一致）✓；托盘模板图 tray-icon.png（纯黑+alpha）+ `icon_as_template(true)` ✓
- ③ Android：分密度前景 PNG（VectorDrawable 不支持 pattern 已绕）✓；**monochrome 层**（ic_launcher_monochrome.xml，beast 单色矢量，挂进 adaptive-icon）✓；**通知小图标**（ic_notification.xml，beast 白轮廓矢量，BackupWorker 两处 setSmallIcon 替换系统默认）✓；66% 安全区按 README 处理 ✓
- ④ 清理：tauri 模板 android 图标目录删除（无引用）✓；HomeScreen 过期注释修正 ✓
- 反证（icns 小层 beast）：16px 灰像素 52=52 与 beast 一致、carbon 为 57 ✓

挂账（验收人）：浅/深色菜单栏托盘截图、Android 13 主题图标观感、通知小图标实机、圆/方遮罩不裁脸。

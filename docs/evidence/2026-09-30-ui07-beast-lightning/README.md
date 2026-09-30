# UI-07 (#131)：beast 退化档加回闪电——资产对照实证（2026-09-30）

**关联**：PR #567 · issue #131 · 设计档 `docs/design/2026-08-11-icon-v1/`

修法：验收人指示「把闪电加回 beast 全实线版」。闪电几何与碳纹版完全同源
（`452,768 → 496,706 → 512,768 → 528,830 → 572,768`，中段过画布几何中心），
全实线单色，接缝 butt 端帽（与碳纹版分色接缝同款做法）。下游资产全部由
`scripts/icons/generate.sh` 重生成，管线代码零改动。

## 证据（E3：逐像素对照 origin/main 旧资产）

### 1. `menu-bar-compare.png` — 菜单栏模拟 + 放大对照

上下两条菜单栏分别为深色态 / 浅色态（macOS 模板图标由系统按 alpha 反色，
这里按模板渲染规则模拟）；左侧两个 = 改前 origin/main，右侧两个 = 改后本 PR
（16px 与 32px 各一）。底部为 6× 像素原样放大对照 + 未改动的主图标 app-icon.png。

### 2. `lightning-zoom.png` — 嘴部区域 28× 放大（关键判据）

左边 BEFORE：嘴线是平直一条。右边 AFTER（红框内）：嘴线中段出现闪电折线——
一个向上的尖峰 (496,706) 接 (512,768)，再一个向下的尾针到 (528,830) 回到
(572,768)。这是本 PR 唯一的视觉改动。

> ⚠️ 整图缩略看时闪电只有 1~2px 宽，肉眼易忽略——请看本图的 28× 放大，
> 或在 macOS 菜单栏真环境上看（见 PR 描述的验收提示）。

### 3. 主图标零影响（反证）

碳纹版各档与 origin/main 逐像素 diff=0：

```
apps/desktop/src-tauri/icons/128x128.png  sampled maxdiff: 0
apps/desktop/src-tauri/icons/256x256.png  sampled maxdiff: 0
apps/desktop/src-tauri/icons/app-icon.png sampled maxdiff: 0
icon.icns ≥128px 层 diffpx=0（iconutil 解包逐层比对，10 层全查）
icon.ico  ≥48px  层 diffpx=0（struct 解包逐层比对，6 层全查）
```

只有 beast 消费的小尺寸层有 diff，且 diff 量 = 闪电笔画本身：

```
icns icon_16x16.png      16x16   diffpx=6
icns icon_16x16@2x.png   32x32   diffpx=13
icns icon_32x32.png      32x32   diffpx=13
icns icon_32x32@2x.png   64x64   diffpx=30
ico  16px                diffpx=6
ico  32px                diffpx=13
```

### 4. 幂等 + 格式

`bash scripts/icons/generate.sh` 重跑无新增 diff（脚本自证 `✅ 图标资产已生成（幂等）`）；
4 个 SVG + 2 个 Android VectorDrawable 全部 well-formed parse 通过；`just ci-docs` 绿。

## 未验证（L3 真环境，归验收人）

macOS 菜单栏真环境观感：深浅色两态各看一眼。**16px 档闪电是否「认得出但不糊」
是本次唯一的审美判断点**——糊了就 revert 本 PR 退回无闪电 beast 版，主图标不受牵连。

# DESK-03 桌面已备份照片预览（终结 Finder 对账）　级别 L2（用户点名 2026-08-12）

## 背景

用户原话：「desktop 没有图片预览，我只能去翻 Finder。」备份工具的
存储端看不到自己存了什么，用户对账只能翻文件夹——不可接受。手机端
早有时间线（T-033 起 daemon 就提供 query.timeline / thumb），桌面壳
一直没消费。

## 修法

侧边栏新增「照片」页（或并入总览）：
- 缩略图墙：daemon `query.timeline` 分页 + thumb 拉取（与手机同一数据
  源，天然一致）；按时间分组（今天/本月/更早）。
- 点击 = 大图快速查看（拉原图临时展示，**不长期落盘**）+「在 Finder
  中显示」按钮（跳到 originals 里的原文件）。
- 顶部一行事实数字：「共 N 张 · 来自 M 台设备」（photo_count 已有）。
- 设计基准照 layout-v1 的密度与留白；新页面进侧边栏图标与文案 i18n。

## 依赖/联动

SYNC-01 合并后，被外删的照片自然从墙上消失——两卡各自独立可验，
但联调验收（删文件→墙上消失）写在 SYNC-01。

## 可执行验收

1. 模拟器/本机联调：墙上照片数 == IPC photo_count == sqlite 直查
   （三方对照贴输出）。
2. 缩略图墙滚动流畅（500 张不卡，thumb 按需加载）。
3. 「在 Finder 中显示」正确选中原文件。
4. 大图查看关闭后无临时文件残留（ls 临时目录贴输出）。
5. vite build 绿 + UI 走查截图（全页面对照设计稿密度）。

## 收尾
CI 绿；PROGRESS/NEXT 一行 + ROADMAP 状态；卡移 done/。

## 验收记录（2026-08-12 队列卫生补录；代码于 2026-08-11 完成，PROGRESS 行 71a34da）

**实现**：桌面照片墙（L2，与手机同一数据源——终结 Finder 对账）。
daemon 本地 IPC 查询平面落地（timeline.page/thumb.get/asset.meta 与
网络平面逐字段一致）+ asset.path（Finder 揭示用）+ asset.original
（原图内存展示不落盘，>12MiB 降级 1024，video 拒）。桌面壳照片页：
缩略图墙（IntersectionObserver 视口懒加载 + 200px 预载）、今天/本月/
更早分组、哨兵分页（60/页）、大图内存查看 + 在 Finder 中显示。

**验证**：Rust 149/149 + clippy 0 + arch-check 绿；desk_flow 三方对照
（墙上数==IPC photo_count==sqlite 直查 + thumb 可解码 JPEG + asset.path
指真实原文件 + original 字节校验 + 未注入回归）；vite build 绿。

**挂账（验收人）**：真窗口 500 张滚动流畅度、大图/Finder 揭示走查。

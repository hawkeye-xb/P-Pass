# SITE-03 为什么重建备份核心：从批处理到有账本的单张流程（L1）

> ✅ 状态：代码已合并（`40917dc`），2026-09-07 归档
> 级别：L1 · 阻塞：无
> 结论：中文文章、sitemap 与 RSS 已由 Pages 发布并在线核对。

## 问题

P-Pass 的备份核心已从旧 `scan → hash → manifest → push → commit → watermark` 批处理路径，切换为以手机本地逻辑账本、增量发现与严格单张消费为中心的新 Flow。这个改变会直接影响用户对暂停、条件等待、取消、完成和外部缺失的理解，但当前对外 blog 尚未解释为什么不能继续给旧批次模型打补丁。

## 期望行为

发布一篇中文工程复盘，解释旧模型不能回答哪些用户问题、新模型把哪些事实持久化为可验证状态、为何先从失败 case matrix 约束语义再切生产路径。文章只引用已公开的 ARCH-01 设计档、REBUILD 卡和实现记录；主路径已切换的事实与仍在持续真机回归的边界都如实说明。

## 验收标准

- [x] `site/src/content/blog/` 新增一篇 `draft: false` 的中文文章，标题、日期、标签与现有集合格式一致。
- [x] 文章正确区分：用户 Pause 与条件等待、完成凭据与开始传输、取消本轮与逐文件取消、外部缺失事实与自动恢复意图。
- [x] 不宣称未完成的真机/发布验证，不暴露本机路径、设备标识或任何照片内容。
- [x] `npm run build` 成功，产物包含新文章路由与 RSS 项。
- [x] `just queue-check` 通过；`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md` 同步。

## 范围

- 只准动：`site/src/content/blog/`、`site/public/sitemap.xml`、本卡、`docs/QUEUE.md`、`docs/PROGRESS.md`、`docs/ROADMAP.md`。
- 不准动：Android/Rust/Desktop 生产代码、ARCH-01 既定设计、旧批次实现、站点视觉与部署配置。

## 阻塞与依赖

无。用户已明确要求将本次核心重建的“为什么”写入 blog；公开素材仅取仓内 ARCH-01 / REBUILD 归档。

## 实施记录

- 文章：`site/src/content/blog/why-we-rebuilt-backup-core.md`；静态 sitemap 已登记其中文 URL。
- 本地验证：`npm ci && npm run build` 成功；新文章静态页、RSS 项、sitemap URL 均在 `dist/` 中存在。
- 发布：`40917dc` 触发的 Pages workflow `34102057353` 为 `completed/success`；线上文章、sitemap、RSS 均返回 HTTP 200。

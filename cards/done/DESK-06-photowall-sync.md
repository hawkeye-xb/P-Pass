# DESK-06 照片墙同步补漏（L1）
> ## ✅ 状态：代码已合并（commit `983483e`），2026-08-20 归档
>
> 三条修法逐条核对，全部在位：
> 1. `App.svelte:645` — `onDaemonEvent` 已含 `name === "timeline.invalidated"`
> 2. `App.svelte:656` — `resetPhotosWall()` 已抽出，照片墙「刷新」按钮已接
> 3. `auditText` — `backup.finished` 解析 `ingested=N duplicates=M` 人话化，
>    `asset.removed_external` / `backup.commit` 走 `shortName()` 去长路径
>
> ⚠️ **本卡曾造成一次误报**：2026-08-20 我盘点上线阻塞时，因为卡还躺在待办
> 目录里就把它列成 P0，让用户以为一个修过的问题又回来了。教训：**卡的位置
> 不是事实，代码才是**——回答"还差什么"必须先 grep 代码。


> 2026-08-13，xixi 在 #p-pass 反馈「移动端订阅状态有了，我们 desktop 照片反而
> 没有同步？？？我本地 finder 删除了照片，移动端都体现出来了，我们桌面端反而没有」
> ——直接催修，非队列派卡。

## 现象

- Finder 删照片 → 移动端时间线实时消失（SYNC-03/06 订阅生效）
- 桌面端照片墙不更新，停在首次加载快照，无手动刷新入口
- 活动记录页出现 `asset.removed_external originals missing: <长路径>`、
  `备份完成（ingested=2 duplicates=0）` 等机器可读原文，用户看不懂

## 根因

- SYNC-01（启动+每小时对账）与 WATCH-01（秒级监听）的删除/新增都发
  `timeline.invalidated` 事件；桌面 `onDaemonEvent` 只对
  `activity.appended` / `device.changed` 重置照片墙缓存（photosLoaded/
  photos/photosNext），**漏了 `timeline.invalidated`** → 照片墙永不失效重拉
- 60s 兜底轮询 `refresh()` 不重拉照片墙（懒加载，photosLoaded 为 true 后不拉）
- 活动记录 auditText 的 default 分支把机器 detail 原样显示

## 修法（apps/desktop/src/App.svelte）

1. `onDaemonEvent` 把 `timeline.invalidated` 加入照片墙失效重置；
   重置逻辑抽 `resetPhotosWall()`（事件失效 + 手动刷新共用，防漂移）
2. 照片墙 lede 右侧加「刷新」按钮（flex 布局），点击 resetPhotosWall →
   `$effect` 自动重拉第一页（photosLoading 时显示「刷新中…」）
3. 活动记录人话化：
   - `backup.finished`：detail `ingested=N duplicates=M` 正则解析 →
     「备份完成：新增 N 张，去重 M 张」，解析失败回退原文（绝不吞）
   - `asset.removed_external` / `external.delete` / `backup.commit`：
     `shortName()` 只留文件名（全路径噪音，DESK-05 ingest.* 过滤同款原则）

## 验收

- [x] vite build 绿（176 modules）
- [ ] 用户真机/桌面：Finder 删一张照片 → 桌面照片墙秒级消失（不点刷新）
- [ ] 用户：桌面照片墙点「刷新」→ 重拉
- [ ] 用户：活动记录显示「备份完成：新增 N 张，去重 M 张」/「外部删除（文件名）」

## 边界

- 移动端不受影响（本来就在订阅 timeline.invalidated）
- daemon 零改动——事件早已发出，纯桌面壳消费端补漏
- i18n：跟随 auditText/活动记录页硬编码先例，不做迁移（范围外）

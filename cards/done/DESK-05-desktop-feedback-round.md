## 卡号 DESK-05  级别 L1
**目标**：用户（xixi）桌面走查三项反馈一次收口——
①向导第一步默认填充路径（不再要求先点「用默认位置」才能继续）+ 路径后带「回到默认」刷新按钮；
②活动记录页改真正的表格设计（设备/事件/时间列），不再把 ingest.* 逐文件全路径倒出来；
③修复照片墙 staleness——备份落地后（activity.appended/device.changed）照片库不刷新，新照片显示不出来。
**范围**：`apps/desktop/src/Wizard.svelte`（第一步）+ `apps/desktop/src/App.svelte`（活动表格 + 照片墙失效重拉）。
**不准动**：daemon/Rust 侧 audit 数据面（ingest.* 逐文件审计行保留在数据层，仅 UI 过滤）；Android；i18n 字典结构。

**可执行验收**：
- `cd apps/desktop && npm run build` → vite build 绿，无 TS/svelte 编译错
- 向导第一步：`libraryDir` 初始 = `configuredLibraryDir ?? defaultDir`（新装直接显示默认路径，下一步可点）；
  路径 ≠ 默认时路径后出现「回到默认」按钮，点击恢复默认；路径 = 默认时不显示该按钮
- 活动记录页：渲染为 `<table>`（thead: 设备/事件/时间），`ingest.new/ingest.duplicate` 逐文件行不出现，
  `backup.finished` 汇总行（「备份完成（ingested=…）」）保留
- 照片墙：daemon 事件 activity.appended / device.changed 到达 → `photosLoaded=false; photos=[]; photosNext=null`，
  效果函数重跑重拉第一页（备份后进照片页能看到新照片）
**证据要求**：build 输出摘要 + 三处改动的 git diff 摘录。
**收尾**：just 相关测试绿 + PROGRESS.md 一行 + NEXT.md 队列状态 + ROADMAP 状态行 + 卡移 done/。

## 验收记录（2026-08-12 Salamira）

- `cd apps/desktop && npm run build` → ✅ vite build 绿（176 modules transformed, built in 675ms）
- ① 向导：`libraryDir = $state(configuredLibraryDir || defaultDir)`——新装即默认填充；
  `{#if libraryDir !== defaultDir}<button class="reset-default">↺ 回到默认</button>{/if}`——
  路径 ≠ 默认才显示，= 默认不显示；「选一个文件夹…」更新后按钮自然出现
- ② 活动记录：`<table class="log-table">`（thead 设备/事件/时间）；
  `auditLine` 拆成 `auditWho(e)` + `auditText(e)`（配对类 detail 兜底设备名）；
  `visibleAudit = $derived(auditEvents.filter(e => !e.action.startsWith("ingest.")))`——
  ingest.* 全路径行不进表格，backup.finished 汇总行保留
- ③ 照片墙：`onDaemonEvent` 里 `activity.appended`/`device.changed` 到达时
  `photosLoaded=false; photos=[]; photosNext=null` → 照片页 $effect 重跑重拉第一页
- diff 摘录见 commit message；挂账（真机）：向导第一步默认填充观感、活动表格布局、
  备份后照片墙自动刷新

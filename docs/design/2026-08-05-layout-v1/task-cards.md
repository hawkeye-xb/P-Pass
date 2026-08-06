# 布局 v1 落地任务卡（2026-08-06 出卡）

> 依据 [AGENT_PROTOCOL.md §C](../../AGENT_PROTOCOL.md)。设计规范 = 本目录
> `P-Pass 布局与交互.dc.html`（浏览器打开可交互）+ `README.md` 裁决摘要。

## 卡号 T-080  级别 L2 — Android 端对齐布局 v1

**目标**：手机端 UI 对齐设计稿 v1——照片 tab = 统一时间线 + 轻过滤器；备份 tab =
恒真三元组（手机 N 张 · 已备份 M · 待备份 K）+ 可暂停 + 失败才说话；顺带修掉
两个真机已确认的缺陷：(a) 顶部横幅在待备份 > 0 时仍显示「照片都存好了」；
(b) 从未成功备份时「最后成功」显示 epoch 0（01-01 08:00）。

**范围**：只准动 `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/**`、
`i18n/DiagText.kt`、必要的字符串资源。

**不准动**：`transport/`、`proto/`、`backup/` 逻辑层；`crates/`；`apps/desktop/`；
已有测试。

**可执行验收**：
  - 跑 `./gradlew :app:assembleDebug` → 期望 `BUILD SUCCESSFUL`
  - 状态条逻辑：待备份 > 0 时不得出现「都存好了」类文案（单测或可复现说明）
  - 反证：把「最后成功」传入 0 时间戳 → UI 必须显示「还没有成功备份过」类文案而非日期
  - 真机截图 = L3，由验收人（指挥端 adb）完成，不在本卡内

**证据要求**：报绿附命令 + 输出摘要。

**收尾**：分支提交，PR 描述列出与设计稿逐屏对照，停下等 review。

## 卡号 T-081  级别 L2 — 桌面端侧边栏四页

**目标**：桌面端由单页长滚动改为侧边栏四页（总览 / 家人与设备 / 活动记录 / 设置，
照片库并入设置）；顶部徽章只表示服务状态；连接状态下沉到每台设备行；危险操作
只出现在桌面端。

**范围**：只准动 `apps/desktop/src/**`、`apps/desktop/index.html`。

**不准动**：`apps/desktop/src-tauri/`；`crates/`；`apps/android/`；已有测试。

**可执行验收**：
  - 跑 `pnpm --dir apps/desktop build` → 期望 vite build 成功、无错误退出
  - 四页路由可达、默认落在「总览」（可复现说明或组件测试）

**证据要求**：报绿附命令 + 输出摘要。

**收尾**：分支提交，PR 描述列出与设计稿逐屏对照，停下等 review。

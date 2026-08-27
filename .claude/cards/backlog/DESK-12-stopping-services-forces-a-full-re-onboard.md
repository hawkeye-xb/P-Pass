# DESK-12 停一次服务就被打回完整 onboard 流程（backlog · L3）

**状态**：⬜ 未开工 · backlog（验收人 2026-08-26 家中真机点名：「这里需要记
一个 backlog 吧，反复 onboard」）

## 问题

家中真机流程第 7 步：「desktop 重新停止所有服务，然后重启，重新走 onboard
流程」。用户的意图只是**重启后台服务**，得到的是**完整的首启向导**——选库
目录、装服务、扫码那一整套。

同一晚他已经因为版本问题走过一次（第 2 步：「启动后发现版本不对，停止后台
服务后，重新 move，重新启动」）。一晚两次 onboard。

## 机制（已定位，未修）

`apps/desktop/src/App.svelte:1121` 的向导门：

```svelte
{#if wizard && (!wizard.configured || !wizard.installed) && !online}
```

`installed` 的判据在 `apps/desktop/src-tauri/src/lib.rs:73`：

```rust
let installed = platform::adapter().autostart_installed().unwrap_or(false);
```

= **launchd agent 是否注册**。而「停止所有服务」这个动作（无论走 UI 还是
`launchctl bootout`）如果把 agent 卸载了，`installed` 就变 false，下次开
App 必然落进向导。

**这不是缺陷代码，是判据选错了层次。** 「服务没在跑」和「这台机器从没配置
过」被同一个布尔表达，而向导是按后者写的——它要重新问库目录、重新装服务、
重新扫码，用户已经答过的问题全部再答一遍。

## 期望行为

区分三种状态，而不是两种：

| 状态 | 判据 | 该给什么 |
|---|---|---|
| 从没配置过 | `config.toml` 不存在 | 完整向导（现状正确） |
| 配过、服务未注册 | config 在 + `!installed` | **一个按钮：重新安装后台服务**。库目录/配对不再询问 |
| 配过、服务注册了但没跑 | config 在 + installed + `!online` | 现有的 self-heal 恢复路径（`App.svelte:246`） |

中间那一档现在不存在，被并进了第一档。

## 验收标准

- [ ] 配置存在、launchd agent 被 `bootout` 后重开 App → **不出现选库目录/
      扫码步骤**，只出现「重新安装后台服务」这一步
- [ ] 装完后直接回主界面，已有配对不需要重扫（`ipc.token` / identity 未变
      即证）
- [ ] 首次安装（`config.toml` 不存在）的完整向导路径行为不变——不许为了修
      这条把新机器的引导也跳过
- [ ] 源码断言钉不变量：向导门的条件里 `configured` 与 `installed` 不许再
      并进同一个 `||`

## 范围

`apps/desktop/src/App.svelte`（向导门 + 新的轻量恢复态）、
`apps/desktop/src-tauri/src/lib.rs`（`wizard_state` 已经分别返回
`configured` / `installed`，后端大概不用动）。

**不准动**：`Wizard.svelte` / `WizardWindows.svelte` 的首启文案与步骤（那是
第一档的东西，本卡只加中间档）。

## 阻塞与依赖

无。可独立做。

## 与家中故障的关系（勿混淆）

这一卡是 2026-08-26 家中故障排查中**顺手记下的 UX 缺陷**，不是那次「照片
只传了一部分」的根因候选。但两件事有一个共同的取证需求：**重新 onboard 时
`data_dir` 有没有被清掉**（identity 换了会导致配对失效）。取证清单见
`docs/evidence/2026-08-26-home-partial-upload.md`。

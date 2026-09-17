# SITE-04 site lane 红了一周没人管——tokens.json 改了文案但生成物没跟上　级别 L1

状态：🟡 代码完成待你过目
级别：L1（一行生成物 + 一条本地 recipe）
关联：与 DESK-15 建的 `token-check` 相邻但**不是同一件事**——DESK-15 管 `assets/design/tokens.css`（只比数值），本卡是 `site/src/styles/tokens.css`（连文案一起生成）。两个判据覆盖面不同，这正是漏掉的原因。

## 挂号段

- 现象：`site` workflow 自 2026-09-11 起**连续失败至今（6 天）**，main 上、5 个 dependabot 分支上、每个 PR 上都红。失败步骤恒为第 5 步 `npm run tokens:check`：`tokens.css is STALE`。因为 build 失败，后面的 `icons:check` / `astro build` / 「零第三方请求」/ `Upload Pages artifact` **四步连续 6 天没有执行过**，`deploy` 也一直 skipped。
- 发现场景：2026-09-17 看 SEC-02 的 PR 检查列表时撞见，误以为是新引入的，查 run 历史才发现早就红着。
- 严重度猜测：中。单看症状只是一行注释不同步；真正的问题是**红灯常态化**——红了一周没人处理，等于 site 这条 lane 已经失去信号价值，后面真出问题也不会有人信。

## 可接段

context:
  - **根因提交**：`5abb8acb`（2026-09-10「feat(desktop): use themed Sonner notifications」）改了 `assets/design/tokens.json`，但没重新生成任何派生文件。site 从 09-11 的第一次 run 开始红，时间完全吻合。
  - **为什么根门禁没抓到，而且它没坏**：`5abb8acb` 只改了**文案**（`principle` 描述、`safe.use` 说明、那句 Green 语义），色值一个没动（`#2E6B4F` 原封不动）。`tools/check-token-drift.py` 按设计只断言「tokens.json 里的数值/色值逐字出现在 assets/design/tokens.css 里」——文案漂移它看不见，这是**判据范围的正确边界**，不是 bug。
  - **而 site 的生成器把文案嵌进产物**：`site/scripts/generate-tokens.mjs` 会把 tokens.json 的说明文字写进 `site/src/styles/tokens.css` 的头部注释，所以同一次改动对它就是 STALE。
  - **本地 `just ci` 覆盖不到 site**：`ci` 与 `ci-docs` 都不含任何 site 侧检查，所以「本地全绿 / 远端 site 红」可以长期共存而没人察觉。

问题:
  `site/src/styles/tokens.css` 的头部注释停留在 `5abb8acb` 之前的旧文案，与 `assets/design/tokens.json` 不一致，`npm run tokens:check` 判红并卡死后续全部步骤。

期望行为:
  site lane 全绿；且同类漂移下次能在本地被发现，而不是推上去才知道。

验收标准:
  - [x] [E1] `npm run tokens:check` → `tokens.css matches tokens.json ✓`
  - [x] [E1] 被卡死的后四步**逐个在本地补跑**（它们已经 6 天没执行过，不能假设还能过）：
        `icons:check` ✓ / `astro build` 11 页成功 ✓ / 零第三方请求 ✓
  - [x] [E1] 生成后工作区只有预期的一行改动，没有别的副产物
  - [ ] [E1] 真实 PR 上 `site / build` 变绿、`site / deploy` 不再 skipped
  - [x] [E2] 反证：改动前 `npm run tokens:check` 本地必红（`tokens.css is STALE`），已实测

范围:
  只准动：`site/src/styles/tokens.css`（生成物）、`justfile`、本卡、`docs/QUEUE.md`。
  **不准动**：`assets/design/tokens.json`（源，本卡不改设计）、`tools/check-token-drift.py`（它的边界是对的）、`.github/workflows/site.yml`。

阻塞与依赖:
  - 新增的 `just site-check` **刻意没有挂进 `just ci`**，原因见下方留白，需要你拍板。

## 实施记录

- `site/src/styles/tokens.css`：`npm run tokens` 重新生成，实际差异一行——头部注释里 Green 的语义说明，从「只在照片确实存好时出现」更新为「只表示已确认成功或数据已安全存好，绝不表示进行中」。这行文案本身是 `5abb8acb` 在源文件里定的，本卡只是让生成物追上，**没有做任何设计决策**。
- `justfile`：新增 `site-check`，跑 site 自己的 `tokens:check` + `icons:check`。

**验收证据**

改动前（反证，E2）：

```
$ npm run tokens:check
tokens.css is STALE (site/src/styles/tokens.css). Run `npm run tokens` and commit the result.
```

改动后，被卡死的四步逐个补跑：

```
$ npm run tokens:check
tokens.css matches tokens.json ✓
$ npm run icons:check
icons match docs/design source ✓
$ npm run build
[build] 11 page(s) built in 841ms
[build] Complete!
$ <site.yml 第 8 步的脚本原样跑>
✓ no third-party requests
```

## 留白 / 挂号

- **`just site-check` 要不要挂进 `just ci`——待你拍板。** 挂进去，本地就能拦住同类漂移；代价是 `just ci` 从此需要 `site/node_modules` 就位，没装 node 的环境会直接红。不挂，就还是只能靠远端发现。我倾向挂进 `ci` 但不挂 `ci-docs`（文档快车道本来就是为了不碰重型依赖），但这条会改变每个人跑 `just ci` 的前置条件，不该我替你定。
- **真正的问题不是这一行。** 红灯挂了一周、四个步骤 6 天没执行、没有任何人处理——这说明 site lane 现在没有被当成信号。修完这一行只是让它回绿，**如果下次红了还是没人看，同样的事会再发生一遍**。这属于流程问题，技术上修不掉，单独提出来让你知道。

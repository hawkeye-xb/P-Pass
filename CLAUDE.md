# P-Pass 执行 agent 工作规范（仓库级）

> 读这个文件的你多半是执行 agent（Hermes/macOS 或云端）。先读
> `docs/AGENT_PROTOCOL.md`（架构铁律 + 任务卡协议），再读本文件（流程纪律）。

## 工作入口

- **任务队列**：`.claude/cards/*.md`，一卡一文件，做完移 `done/` 并附验收记录。
- **交接件**：`docs/NEXT.md`——每轮收口更新「当前状态/等用户」。
- 卡外的活不做；发现新问题写成卡（按 §C.2 模板）放进队列，不顺手修。

## 推送纪律（2026-08-10 用户特批：速度优先阶段）

允许直推 main / 自 merge，**不用等 review**。代价是三条底线，破一条视为事故：

1. **CI 绿不过夜**：push 后必须盯**受影响域**的 CI 到结论（CI-01 分块后：
   改 crates/** 看 ci-rust，改 apps/android/** 看 ci-android，改
   apps/desktop/** 或 assets/** 看 ci-desktop；纯 docs/.claude 提交零
   CI）；红了立刻修或 revert（8/7 的 fmt 红是反面教材——push 前本地过
   `cargo fmt --check`）。**nightly 红次日第一优先修**（e2e.yml 的
   nightly + tag 门禁跑全量 nextest + scenarios，不是每推——它红了
   代表真 bug，别拖）。
2. **每批交付必更文档**：PROGRESS.md 每卡一行 + NEXT.md 队列状态 +
   ROADMAP.md 状态行 + **docs/CHECKLIST.md**（用户对照着做事的动作清单：
   真机验收项、等拍板的决定、待做 to-do）。零记录 = 事故。
   ⚠️ ROADMAP 是**历史账本**（4000 行，只增不减），CHECKLIST 是**待办清单**
   （只写跟"现在"有关的）。两者混在一个文件里的时候，用户想"对照着做点事"
   就得自己从一千行里挑——那本身就是个可用性问题。
3. **验收人事后抽检有 revert 权**：内容被打回就返工，不争辩已合并事实。

速度优先阶段到有外部用户/第二个贡献者为止，届时恢复走 PR。

## 凭据与构建归属（2026-08-21 用户定调）

> 「我们构建的任务和需要的账号证书，都只在 GitHub，其它本地不保留，
> 你也不用保留，本地能跑的就跑就好了。」

- **账号 / 证书 / 签名密钥只以 GitHub Secrets 形式存在。** 不在开发机上装证书、
  导密钥、配 keystore；不用 debug key 去签 release 产物凑数。
- **本地只做跑得动的**：`just ci`、Android debug APK + 单测、桌面 dev 壳 +
  vitest。**本地 release 构建不是目标**——macOS 缺
  `TAURI_SIGNING_PRIVATE_KEY`、Android release APK 未签名，这些是"无凭据
  路径"的**预期行为，不是待修的 bug**，别去修它。
- 要可安装的正式产物 → `gh workflow run release.yml -f platforms=android,macos`，
  由 CI 签名产出。
- 当前槽位实况：`ANDROID_KEYSTORE_*` ✅、`UPDATE_SIGNING_KEY` ✅、
  `APPLE_CERT_P12` / `APPLE_NOTARY_*` / `APPLE_TEAM_ID` ❌（补需用户本人操作，
  操作单 `docs/runbook/h02-apple-signing.md`；没有 Apple 会员就先不做，
  家人「右键→打开」过 Gatekeeper 完全可行）。

## 工具链纪律（2026-08-21 事故后加）

- **版本只许有一个真相**：Rust 看 `rust-toolchain.toml`（已钉 `1.98.0`，
  **不要写回 `stable`**），Android 的 JDK 看 CI 的 `java-version`。
  两侧都从那一处取，绝不在第二个地方抄同一个数。
- **`just ci` 绿不等于 CI 会绿**——除非本地工具链与 CI 同版本。事故实例：
  本地 stable 停在 1.91、CI 在 1.98，1.98 新增的
  `chunks_exact_to_as_chunks` 本地扫不出来，`just ci` 全绿而 CI 直接红
  （全仓 7 处同形，CI 只报了第一处）。反方向也出过：本地 JDK 25 让
  Android release 的 lint 炸而 CI 钉 17 没事（`BUILD-01`）。
- 升级工具链是**一次显式提交**：改钉住的那一行 → 更新本地 → `just ci` →
  修新版本顶出来的 lint，标题写明升到哪个版本。

## 提交与构建纪律

- **纯文档/卡片提交（只动 docs/ 或 .claude/）**：CI-01 已做路径过滤——
  不匹配任何域 paths 的提交零 CI 触发，无需再写 `[skip ci]`。
- 小步提交本地攒，**一张卡一次 push**，别按保存键式碎推。

## tag 纪律

- 调发布管线用 **workflow_dispatch**（release.yml 已支持），不许拿正式
  tag 试错（8/9 一个周末烧了 test.3~test.10 八个 tag，是反面教材）。
- tag 只打给准备真发的版本；已打的 tag 绝不覆盖/挪动。

## 仓库卫生

- **绝不把构建产物 commit 进 main**。bin-* 孤儿分支是唯一例外通道
  （artifacts.yml 管理，带 paths 过滤）。
- 开发机排除产物分支：`git config --add remote.origin.fetch '^refs/heads/bin-*'`
  （2026-08-10 教训：不排除的话 .git 会膨胀到 GB 级）。

## 语言与文档

- 面向用户/贡献者的文档英文为主 + zh 姊妹篇（docs/ 既有惯例）。
- UI 文案进 assets/i18n 字典（en/zh 对称测试兜底），不写死在组件里。
- 设计基准：`docs/design/2026-08-05-layout-v1/` 是 UI 唯一基准；UI 卡
  验收必须含双端全页面走查（还原/走样/未实现三定性 + 截图）。

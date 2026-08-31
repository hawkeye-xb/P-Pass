# P-Pass 执行 agent 工作规范（仓库级，模型无关）

> 不管你是 Claude Code、Kimi、Codex 还是别的 agent，这份文件是你的规范，
> 品牌专属文件（如 `CLAUDE.md`）只是指回这里的指针，不重复内容。
> 先读 `docs/AGENT_PROTOCOL.md`（架构铁律 + 任务卡协议），再读本文件（流程纪律）。

## 工作入口

- **任务队列**：`cards/*.md`，一卡一文件，做完移 `done/` 并附验收记录。
- **唯一待办队列**：[`docs/QUEUE.md`](docs/QUEUE.md)——可接队列 / 待真机验收 /
  待拍板 / backlog 都在这一处，按优先级排序。派任务前先看这里；不要去翻
  `docs/NEXT.md` 或历史记录找"现在该干什么"。
- **交接背景**（历史诊断、教训、已知坑，只读不是待办来源）：`docs/NEXT.md`。
- 卡外的活不做；发现新问题写成卡（按 §C.2 模板）放进队列，不顺手修。
- **开卡/关卡/挪卡之后必须跑 `just queue-check`**（已并入 `just ci`）——它
  强制检查 `cards/` 根目录下每张卡都在 `docs/QUEUE.md` 里能被找到、
  `docs/QUEUE.md` 里的卡链接没有指向不存在的文件。2026-08-27 审计发现过
  两次"开了卡但索引没更新"（MOB-42、MOB-43/NET-02），这条检查就是防
  这个复发的，不是可选项。

### 派活姿势（2026-08-26 验收人定调）

**小卡（成本在做，不在知道）**：把事实（根因/文件/行号/已知坑/测试基线）直接
内联进派活指令，只让 agent 读那张卡本身，不要求它先通读整套协议文档——仪式
成本不能比改动本身大。

**L2+ / 架构类的卡**：走标准入口链（本文件 → AGENT_PROTOCOL.md → 卡）。

## 协同状态与远端同步（2026-08-31 用户定调）

**跨 Claude / Hermes / Kimi 的唯一协同事实在远端 Git。** 对话上下文、IDE
任务面板、agent session todo 都只是临时执行工具，不能作为项目状态或交接依据。

1. **进仓先同步**：任何 agent 接活前必须 `git fetch origin --prune`，检查
   `git status --short --branch`，再读 `AGENTS.md`、`docs/QUEUE.md` 和目标卡。
   未 fetch 的本地视图不能用来判断任务是否可接。
2. **认领即上云**：认领 / 暂停 / 恢复 / 阻塞 / 拆分 / 改优先级等会影响其他
   agent 选择的状态，必须先更新卡片横幅（含当前节点、下一步、协同分支）和
   `docs/QUEUE.md` 的对应分区，**立即 commit + push**；未上云的认领等于未认领。
   `进行中` 的卡必须从“可接队列”移出，其他 agent 不得重复接。
3. **代码也不长期滞留本地**：一个连续、短暂的 RED→GREEN 循环可以本地进行，
   但一旦形成可编译/可验证的检查点、要向用户汇报、要暂停或要交接，就必须
   commit + push。若必须在红测状态停下，推到 `wip/<卡号>` 远端分支（**红测
   不许进 main**），并在卡片写明分支和下一步。
4. **离开前清账**：任何 agent 结束本轮前不得留下未推送的、会影响协作的代码、
   测试、证据或任务状态；构建产物、日志和凭据仍不得提交。下一个 agent 只需
   fetch 后按卡片和队列继续，不需要复述聊天历史。

`just queue-check` 负责卡与队列链接完整性；上述规则负责“谁正在做什么”和
“最新代码在哪”的实时一致性，两者缺一不可。

### 架构重定义后的测试纪律

当已确认的架构卡重定义了核心状态、边界或流程时，旧实现的测试**不自动成为
新实现的门禁**。先逐条标记为“仍属产品不变量 / 已被新设计取代 / 需要重新
表述”；被取代的测试与其旧卡冻结，不得靠它们把新设计拉回旧管线。新实现从
新架构的 case matrix 写失败用例，再写生产代码；不许为了让旧测试绿而保留
旧机制或做兼容补丁。

## 推送纪律（2026-08-10 用户特批：速度优先阶段）

允许直推 main / 自 merge，**不用等 review**。代价是三条底线，破一条视为事故：

1. **CI 绿不过夜**：push 后必须盯**受影响域**的 CI 到结论（CI-01 分块后：
   改 crates/** 看 ci-rust，改 apps/android/** 看 ci-android，改
   apps/desktop/** 或 assets/** 看 ci-desktop；纯 docs/.claude 提交零
   CI）；红了立刻修或 revert（8/7 的 fmt 红是反面教材——push 前本地过
   `cargo fmt --check`）。**nightly 红次日第一优先修**（e2e.yml 的
   nightly + tag 门禁跑全量 nextest + scenarios，不是每推——它红了
   代表真 bug，别拖）。
2. **每批交付必更文档**：PROGRESS.md 每卡一行 + `docs/QUEUE.md` 队列状态 +
   ROADMAP.md 状态行。零记录 = 事故。
   ⚠️ ROADMAP 是**历史账本**（只增不减），`docs/QUEUE.md` 是**唯一待办清单**
   （只写跟"现在"有关的，且只能从卡片横幅读出，不加人工新判断）。两者混在
   一起时，用户想"对照着做点事"就得自己从一千行里挑——那本身就是个可用性
   问题。
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
- **当前槽位实况（2026-08-25 逐个核实，勿照搬旧记录）**：
  `ANDROID_KEYSTORE_ALIAS/BASE64/PASSWORD` ✅、`UPDATE_SIGNING_KEY` ✅、
  `APPLE_CERT_P12` + `APPLE_CERT_PASSWORD` ✅、
  `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` + `APPLE_TEAM_ID` ✅、
  `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` ✅。
  **所以 macOS 签名 + 公证、Android 签名在 release.yml 里都会真的执行**
  （门控 `HAS_APPLE_CERT` = `APPLE_CERT_P12 != ''`；`HAS_NOTARY` =
  `APPLE_NOTARY_KEY != '' || APPLE_ID != ''`，走 Apple ID + 专用密码那条
  分支）。未就位的只剩 `VT_API_KEY`（VirusTotal 提交步跳过）和 `GH_TOKEN`
  （update worker 的 API 限额提升跳过），两者都不影响可分发产物。
  ⚠️ gated 步骤在 secret 缺失时是**静默跳过**的——改动签名相关步骤后，
  务必看 run 里那一步是 skipped 还是真跑了，别看 workflow 绿就当签了。

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
- ⚠️ **`./gradlew` 找不到 Java 时退出码是 0**（2026-08-25 实测：非交互 shell
  里没有 `JAVA_HOME`，只打印 "Unable to locate a Java Runtime" 就以 0 退出）。
  于是「跑了 Android 单测、退出码 0」会被当成全绿，而一个测试都没跑。
  **报 Android 测试绿必须给出测试计数**（从
  `apps/android/app/build/test-results/testDebugUnitTest/*.xml` 数，
  并核对 XML 时间戳是本次生成的），不许只凭退出码。
  本机跑法：`export JAVA_HOME=/opt/homebrew/opt/openjdk`（当前是 JDK 25，
  单测无碍；release lint 会挂，那是 `BUILD-01`，CI 钉的版本不受影响）。

## 提交与构建纪律

- **纯文档/卡片提交（只动 docs/ 或 .claude/）**：CI-01 已做路径过滤——
  不匹配任何域 paths 的提交零 CI 触发，无需再写 `[skip ci]`。
- 小步提交只可在一个连续、短暂的 RED→GREEN 循环内本地攒；**协同状态、可验证
  检查点和交接优先于“一张卡一次 push”**，按「协同状态与远端同步」立即上云，
  不得让协作信息或代码长期只留本地。

## tag 纪律

- 调发布管线用 **workflow_dispatch**（release.yml 已支持），不许拿正式
  tag 试错（8/9 一个周末烧了 test.3~test.10 八个 tag，是反面教材）。
- tag 只打给准备真发的版本；已打的 tag 绝不覆盖/挪动。

## 仓库卫生

- **绝不把构建产物 commit 进 main**。产物走固定 `dogfood` release
  （artifacts.yml 管理，带 paths 过滤，tag 只建一次、资产 clobber）；
  旧的 bin-* 孤儿分支已废弃保留（不删），开发机的
  `git config --add remote.origin.fetch '^refs/heads/bin-*'` 排除配置
  留作无害残留（2026-08-10 教训：不排除的话 .git 会膨胀到 GB 级）。

## 语言与文档

- 面向用户/贡献者的文档英文为主 + zh 姊妹篇（docs/ 既有惯例）。
- UI 文案进 assets/i18n 字典（en/zh 对称测试兜底），不写死在组件里。
- 设计基准：`docs/design/2026-08-05-layout-v1/` 是 UI 唯一基准；UI 卡
  验收必须含双端全页面走查（还原/走样/未实现三定性 + 截图）。

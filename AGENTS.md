# P-Pass 研发工作规范

唯一必读，适用于任何 agent 与任何外壳。读完就开工；规则只在这里和门禁脚本里，
不在任何人的私有记忆里。

## 角色

| 角色 | 职责 | 不做 |
|---|---|---|
| 产品负责人（人） | 提产品诉求、方向判断、优先级；test 版体验回归；凭据与付费 | 不写、不审代码，不批 PR，不排查 |
| owner（研发负责人会话） | 把诉求拆成卡、写范围与验收、派活、攒批、全量验证、开批 PR、合入、发 test 版 | 不自己写大块功能 |
| worker（每卡一个会话） | 在 issue 范围内改代码、本地验证、推分支交卡 | 不碰范围外、不碰核心、不开 PR |
| QA（每批一个回归会话） | 按 `docs/runbook/full-regression-sop.md` 跑全量回归，出报告 | 不修代码 |

技术问题 owner 自己定并记录；碰到产品取向（用户感知的行为、隐私、数据去留）的，
用产品语言写两个选项，打 `needs:product` 交产品负责人拍板，然后接着做别的卡，不干等。

## 看板：GitHub Issues + 标签

一张卡同一时间只有一个状态标签：

`status:inbox`（新诉求，待 owner 拆）→ `status:ready`（范围、验收场景已写好）→
`status:doing`（已派给某个会话）→ `status:batched`（进了某个 batch 分支）→ 关闭（合入 main）

旁路：`status:blocked`（卡住，issue 里写明原因）；`needs:product`（等产品负责人拍板）。
问进度、下一个做什么，只看 Issues 与 milestone，仓库里没有任何状态文件。
**想法不进 Issues**：还没决定做的功能放 Discussions 的 Ideas 分类；产品负责人说「要做」后，
owner 用「Create issue from discussion」转成 issue（类型 Feature，大功能拆子 issue，挂 milestone）。
agent 只领 Issues，不碰 Discussions。issue 类型：Feature（新能力）/ Bug（行为与预期不符）/ Task（其它）。
开卡用 issue 模板「任务卡」，字段缺了不受理。

## 交付流程

**worker：一卡一 worktree，不开 PR。**

1. `git fetch origin --prune && git worktree add <目录> -b <type>/<issue号>-<slug> origin/main`
   （type ∈ feat/fix/docs/test/ci）。读该 issue 即全部上下文。
2. 只改 issue「范围」段列出的路径。确需扩大：先改 issue，再改代码。
3. 每个提交 `git commit -s`（DCO 门禁）。提交身份必须在 `.github/allowed-identities.txt` 里。
4. 本地过门禁：动了代码 `just ci`，纯文档 `just ci-docs`；再跑 `just verify <issue号>` 做真机验证
   （按改动路径决定涉及哪几端，跑冒烟 + 卡上点名的场景，最后一行 PASS/FAIL；见 `docs/runbook/e3.md`）。
5. `git diff --stat origin/main...` 核对改动清单只含本卡文件，然后推分支。
   在 issue 里回贴：分支名、自验命令与真实输出（标证据等级）。**不开 PR。**
6. 必须停下上报的四种情况：命中核心、需要改范围外文件、没有可用的验收场景、同一处连红 3 次。
   在 issue 里写清楚停在哪、剩什么，打 `status:blocked`，接着做下一张卡。

**owner：多卡攒一批，一批一个 PR。**

1. 从最新 `origin/main` 开 `batch/<日期>-<主题>`，把多张卡的分支合进来，卡打 `status:batched`。
2. 本地全量验证（`just ci` + 全部 `tools/test-*.sh` + 受影响端真机回归）。
3. 开一个 PR，正文逐卡列出 `closes #N` 与验证证据；盯全部 lane（不只看必需检查）到结论，
   红了在 batch 分支上修。CI 全绿后 squash 合入。
4. PR 落后 main：无冲突用 `gh pr update-branch`；有冲突从最新 main 新开分支重放改动，
   关旧 PR。压缩提交只能 `reset --soft $(git merge-base HEAD origin/main)`，
   **绝不 `reset --soft origin/main`**（会把旧工作区当新内容提交，撤回别人刚合入的改动）。
5. 合入后清理：`just cleanup-local`（默认预览，删除要 `--apply`）。squash 合并下判断分支能否删
   看上游 `: gone]`，删用 `-D`。

## 红线（违反 = 事故）

1. **issue 外的活不做。** 发现新问题开新 issue（`status:inbox`），继续当前活，不顺手修。
2. **范围即边界。** 只动 issue「范围」段的路径。产品红线：只做图片，不做文件备份/同步；
   **不做任何遥测 / 使用统计上报**，诊断只写本机日志
   （[决策记录](docs/product/2026-10-13-telemetry-removal.md)）。改这条红线须产品负责人拍板。
3. **不捏造。** 报绿必须附命令 + 真实输出；故障/安全类判据必须带反证（去掉故障条件必须变红）。
   「CI 绿」不等于验收。
4. **凭据只在 GitHub Secrets。** 不进代码、issue、文档。凭据类方案先 `gh secret list`，
   优先用现有 secret 的标准解；确需新增，先说清现有的为什么不够。
   本机路径、设备序列号、机器状态只写本机 `local-state.md`（不进 git）。
5. **红测不进 main。** 红的停在自己分支上，在 issue 里写明停在哪。
6. **核心改动先讨论。** `.github/core-paths.txt` 圈住的路径（门禁、配对/身份/加密/协议、
   存储与迁移、更新链、依赖锁）：worker 只写复现、根因和两个修法，不改代码；
   由 owner 定或交产品负责人拍板后再实现；批 PR 上的 `core review` 由 owner 批准，worker 不批。

## 产品硬规矩（写卡、改代码、验收都按这些判）

- **占盘 1x**：照片库总占盘 ≈ 照片本身。隔离区、回收站、缓存、staging 只增不删都算违规，
  不是可选策略。写盘类改动的验收必须 `du -sh` 实测各子目录，不能只数文件。
- **尊重用户停掉的服务**：自愈、对账、自启、更新恢复时，「用户停过」永远优先于「服务该在」。
  拿不准是不是用户意图，按「用户停的」处理，只在 App 里给显式开启入口。
- **读现状初始化，不写迁移**：新开关/偏好没有存值时，按当前真实状态算初值（已授权、已选过
  的就算开），之后以存值为准。「不写迁移」只针对数据格式，不能让用户已开的功能升级后悄悄停掉。
- **iOS 没有对外用户**：iOS 本地数据格式直接改，不写旧数据迁移，不考虑升级代价，也不拿这个去问人。
- **隐私优先**：不采任何敏感信息；对隐私有侵害的，哪怕排查更难也不采。
- **品牌语言**：组件可以按平台原生，颜色、字体、明暗外观一律以 `assets/design/tokens.json`
  与 Android 实现为准。偏离品牌语言的提案单独提 `needs:product`，不夹在「原生化」里。
- **iOS 先对齐 Android**：两端小功能同步迭代，iOS 多出/少掉的按 Android 改；要加就两端一起加。
  平台惯例（原生导航、下拉刷新等）可以保留。尺寸偏离登记进 `tokens.json` 的 `platforms.ios`
  并写理由，不在代码里写死。
- **桌面只改 i18n 副本**（同步 `assets/i18n` 在 Android/iOS 的逐字节副本）可以直接做；
  任何影响手机行为、协议、真机表现的改动都要在卡上写明并经 owner 确认。
- **界面文案**：先找行业标准（Android 权限规范、NN/g、Google、Microsoft 写作指南）。提示说现状，
  不事事给操作建议；每句话只服务这一屏的作用；把已有功能说全，不替用户选；流程能省一屏就省；
  说后果要准；状态类不提内部组件（写「备份已停止」，不写「后台服务未运行」）。
  按钮名、词名先 grep 核对实物。

## 验收

- **证据分级**：E1 编译 + `just ci`（永远可信）｜E2 针对当前架构的 contract 测试（可信）｜
  E3 真机/真环境实证输出（用户看得到的行为必需）｜E4 legacy 测试（仅参考，不能单独作数）。
  报绿时每条结论标出自哪一级。
- **真机为准**：用户看得到的行为以真机为准；只有真机造不出来的（写盘失败、系统错误码等）
  才用单测，并在卡里写明原因。每张卡写明「日志里出现哪一行算通过」，成功路径也要打日志。
- **只验未知**：先问这一步能证明什么现在不知道的事；能从已有实测推出来的不重测，写明推理依据。
- **写给人照做的 SOP**：先 grep 界面的显示条件，不凭印象写入口；判定脚本只把真正必需的步骤设成失败项。
- **删 UI 元素前**先核对它显示的是固定文案还是状态。
- **界面改动先在本地预览**（桌面：vite dev + mock 在浏览器里把流程点一遍），自己核过再打包给人看。
- **重复验证写成脚本**，判定交给脚本，不靠反复手动操作。

## 工程纪律

- **删接口 / 升依赖扫全 lane**：`git grep` 覆盖全仓所有语言；每份 `Cargo.lock` 都改到；
  本地除 `just ci` 外跑全部 `tools/test-*.sh`。细节见 [CI lane](docs/runbook/ci-lanes.md)。
- **job 的 name 不许随手改**；进必需检查的 job 名必须写死，不许用 `matrix` 现算。
  理由见 [CI lane](docs/runbook/ci-lanes.md)。
- **发版按端判定**：Android / macOS / Windows 谁改了才构建谁；test 与正式版走同一套机制。
  汇报时说「按端判定」，不说「跳过某端」。细则见 `docs/RELEASING.md`。
- **磁盘**：worktree 里跑 cargo 带 `CARGO_INCREMENTAL=0`，编完删 `target/`。剩余空间
  低于 15G 先停下报告。清理任何 worktree 前用 `lsof +D <目录>` 核实无人在用；
  有未推送提交或未提交改动的 worktree 不动。
- **撞到 bug 被写进测试**：改断言、保意图，不删测试，并在提交说明里登记为什么改了测试。
- **真机取证**：装完核对运行中的实际二进制版本，同版号的旧进程不会被自动替换；
  Android debug 包用 `adb shell run-as` 直读私有目录里的账本判定手机侧状态；
  `adb push` 造的素材要先清 `is_pending`，否则 App 查不到。
- **改 `assets/i18n/*.json`** 要同步全部消费者（diag 键注册表与计数、手机端副本），
  清单见 `apps/ios/PPass/I18n/DiagText.swift`，`just mobile-static-check` 兜底。
- **shell 脚本**：macOS 自带 bash 3.2 下失败的裸 `[[ ]]` 不触发 `set -e`，断言写成 `[[ ... ]] || fail`。
- 平台分叉只许在 `crates/platform/`，iroh 只在 `crates/transport/`：`just arch-check` 会挡，
  规则全文见 `tools/arch-check.sh`。工具链版本唯一真相：`rust-toolchain.toml`、`.java-version`。
- 构建产物、日志、证据不进 main。

## 发版

- tag 只给真发版本。调管线不发版走 Actions → Release → Run workflow。
- release 正文 = 面向用户的 changelog：以该版本用户可见变更开头（对应 `CHANGELOG.md`
  该版本段），签名、SHA-256、资产清单往后放。changelog 在提交阶段写进 `[Unreleased]`。
- 应用内更新弹窗说明是手写文件：版本号涨了的每一端写 `release/notes/<端>/<版本>.<zh|en>.txt`，
  合入后再打 tag。规则见 `docs/release-notes-rules.md`，步骤见 `docs/RELEASING.md`。

## 索引（需要时才打开）

| 要做什么 | 去哪 |
|---|---|
| 开卡 | issue 模板「任务卡」 |
| 本地命令 | `just --list` |
| CI lane、必需检查、核心路径 | `docs/runbook/ci-lanes.md` |
| 真机/模拟器、配对、本机 daemon IPC | 本机 `local-state.md`（不进 git，先读它再说「做不到」） |
| 本地真机验证、写场景 | `docs/runbook/e3.md` |
| 全量回归 | `docs/runbook/full-regression-sop.md` |
| 发版、签名、版本纪律 | `docs/RELEASING.md` |
| 架构规则、验收抽检、自举类改动 | `docs/AGENT_PROTOCOL.md` |
| 业务规则 | `docs/desktop/business-rules.zh-CN.md` |
| 历史事故与教训 | `docs/lessons/` |

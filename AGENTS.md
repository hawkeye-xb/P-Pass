# P-Pass 研发工作规范

唯一必读，适用于任何 agent 与任何外壳。读完就开工；规则只在这里和门禁脚本里，
不在任何人的私有记忆里。

**开工先跑 `just doctor`，不过就停。** 它在你自己的外壳里检查主副本 / 卡 worktree、
bash 能否真执行、本地提交拦截、gh 能否读 issue、提交身份、磁盘与私仓模式；
任一必需项不满足就非 0 退出并打印怎么修，修好再开工，不带病继续。

## 角色

方向归人，判定归机器。

| 谁 | 做什么 |
|---|---|
| 产品负责人（人） | 定 milestone 与优先级；回答产品取向问题；在盯梢节点放行；体验 test 包；发正式版；凭据与付费 |
| agent（任何模型，按会话分工） | 领卡、写代码、开 PR、修到 CI 全绿；到盯梢节点停下等人，等的时候做别的卡 |
| CI | 判定能不能合入：格式、lint、测试、范围、核心方案引用、网络出口、占盘 |

文字规则只写 CI 管不到的事；能写成检查的，一律写成检查。
技术问题 agent 自己定并记录；碰到产品取向（用户感知的行为、隐私、数据去留）的，
用产品语言写两个选项，打 `needs:product` 交产品负责人拍板，然后接着做别的卡，不干等。

### 任务分三级：级别决定人在哪里介入

| 级别 | 什么卡 | 人在哪里介入 | 合入条件 |
|---|---|---|---|
| 自动 | 文档、内部重构、测试、工具，用户看不到的修复 | 不介入 | CI 全绿 |
| 盯梢 | 用户看得到的行为：界面、文案、备份行为、权限流程 | **开 PR 之前**：agent 把改动装到真机，产品负责人本地验收（agent 在回执里贴截图或录屏、日志里的通过行）；验收通过再推分支开 PR，PR 上 CI 跑一次，放行即合。验收前只推分支、不开 PR | 产品负责人本地验收通过 + CI 全绿 + 放行 |
| 人控 | 核心路径（配对、加密、协议、存储迁移、更新链），以及产品负责人点名要把控的卡 | 开工前：agent 先在 issue 里写方案（做法 + 两个选项 + 风险），产品负责人点头才写代码；之后同「盯梢」：本地验收通过再开 PR | CI 全绿 + 已采纳方案 + 产品负责人放行 |

- 级别按范围路径判：界面路径 → 盯梢，核心路径（`.github/core-paths.txt`）→ 人控；产品负责人可以调高，agent 不能调低。
- 「人控」只包括配对、加密、通信协议、数据存储与迁移、更新链，加产品负责人点名的卡；范围就是 `.github/core-paths.txt`
  （只列具体文件或目录，新文件默认不算）。CI 配置与门禁脚本、App 普通界面与业务代码不在其中。
- 「放行」= 产品负责人在 PR 上评论「放行」。盯梢、人控级的 PR 在验收通过后才开；开好后在 PR 上留一条
  「等产品负责人放行」，转去做别的卡；看到「放行」评论才合入，不自己批准、不替人做决定。
- 现状：agent 与人共用同一个 GitHub 账号，GitHub 不允许给自己的 PR 批准，所以这一条只能靠规则约束，CI 拦不住
  （产品负责人 2026-11-03 定：先靠自觉，暂不开独立身份；出现 agent 自己合入盯梢级 PR 再开）。

## 看板：GitHub Issues + 标签

issue、PR、milestone 就是全部状态，仓库里没有任何状态文件。问进度、下一个做什么，只看 Issues 与 milestone；
换会话、换模型，读 issue 与 PR 就能接着干。

一张卡的状态标签：`status:inbox`（新诉求，待定范围）→ `status:ready`（范围、验收场景已写好）→
`status:doing`（已领）→ `status:review`（已交卡并开了 PR，等 CI 与放行）→ 合入后关闭。
旁路：`status:blocked`（卡住，issue 里写明原因）；`needs:product`（等产品负责人拍板）。
**想法不进 Issues**：还没决定做的功能放 Discussions 的 Ideas 分类；产品负责人说「要做」后，
用「Create issue from discussion」转成 issue（类型 Feature，大功能拆子 issue，挂 milestone）。
agent 只领 Issues，除 `just idea` 记想法外不碰 Discussions。issue 类型：Feature（新能力）/ Bug（行为与预期不符）/ Task（其它）。
开卡用 issue 模板「任务卡」，字段缺了不受理。

## 收到想法怎么办

任何会话听到人类提出新想法，都用 `just idea "<原话>"` 记进 Discussions 的 Ideas，不顺手开工、不进看板。
人类明确说「要做、但要先定方案」时加 `--discuss`，建一张 `status:inbox` 的 Feature issue。
之后用 `just triage <号> <方案文件>` 定方案和去向，见 [owner 流程](docs/runbook/owner.md)。

## 交付流程

**一张卡一个 PR，PR 上的一次 CI 是合入的唯一门槛。** 合入不等于发版：真机全量回归在发版车次做
（见「发版」与 `docs/runbook/full-regression-sop.md`）。

```
just start <issue号>          领卡：建 worktree 与分支，ready→doing，打印下一步
（cd 进它给的目录，改代码，git add + git commit -s）
just done                     交卡：过门禁与验收，全绿才推送、贴回执，doing→review
（自动级：开 PR，正文 closes #N、改了什么、证据与证据等级，CI 红了就修到绿；
  盯梢、人控级：先装真机让产品负责人本地验收，通过后再开 PR）
just stuck <号> "<原因>"      卡住：写评论，打 status:blocked，去做下一张
```

- `just start` 只领 open、`status:ready`、有「范围」代码块的卡；核心卡（`core` 标签）正文引用了
  `origin/main` 上「已采纳」的方案就按方案实现，没有引用就只写复现、根因和两个修法，不改代码。
- 只改 issue「范围」段列出的路径。确需扩大：先改 issue，再改代码。本地 hook 会挡范围外文件、
  没有范围的卡、主仓工作区里的卡分支，`git commit` 直接被拒，见 `tools/hooks/` 与
  [本地提交拦截](docs/runbook/local-hooks.md)。
- 每个提交 `git commit -s`（DCO 门禁），提交身份必须在 `.github/allowed-identities.txt` 里。
- 本地只做快检查：提交前钩子拦格式与范围；开发时只跑改动涉及的测试，不在本地跑全量。
- `just done` 依次：门禁（动了代码 `just ci`，纯文档 `just ci-docs`）→ `just verify <号>`（命令存在才跑）
  → 核对 `git diff origin/main...` 只含范围内文件 → 推分支 → 在 issue 贴回执（分支、提交、门禁与验收输出末尾、
  证据等级、证据目录）。任何一步红：不推送、issue 写明停在哪、打 `status:blocked`，修好重跑即可。
  分支落后 `origin/main` 时只报错不打 blocked：先 `git rebase origin/main` 再重跑。
- 自动级的 PR：CI 全绿就合（squash）。盯梢、人控级：验收前只推分支、不开 PR；验收通过、开 PR、CI 全绿后等产品负责人放行再合。
- 必须用 `just stuck` 停下的四种情况：命中核心且没有已采纳方案、需要改范围外文件、没有可用的验收场景、
  同一处连红 3 次。
- 用户看得到的行为还需按卡上的验收场景做真机验证（E3）；验证环境开工时探测（见「验收」）；`just done` 的回执会写明哪些证据等级已自动取得。
- 防发散：一个 PR 只关联一个 issue；改到范围外文件就是红；新增网络出口、遥测依赖、自启点、落盘目录由 `just ci` 挡
  （现有适应度检查）。PR 大小上限、同时打开的 PR 数上限、「盯梢 / 人控级没有放行不许合」的必需检查尚未建，
  目前靠自觉：PR 尽量小，同时不开超过 3 个。
- 压缩提交只能 `reset --soft $(git merge-base HEAD origin/main)`，**绝不 `reset --soft origin/main`**
  （会把旧工作区当新内容提交，撤回别人刚合入的改动）。
- 分拣、出 test 包、停下、记想法的命令见 [owner 流程](docs/runbook/owner.md)：
  `just triage <号> <方案文件>` 给 `status:inbox` 的卡定范围并分流
  （纯技术非核心 → `status:ready`；碰用户可见行为、隐私、数据 → `needs:product`，除非 `**产品定案**` 引用已采纳、
  产品负责人确认过的方案；核心无已采纳方案 → `status:blocked`）；
  `just release-test <端...>` 出 test 包（端以 plan-builds 判定为准，正式版只由产品负责人发布）；
  `just owner-stuck "<问题>" --product "<选项一>" "<选项二>"` 交产品取向的问题；
  `just cleanup-local`（默认预览，删除要 `--apply`）清本机构建产物，squash 合并下判断分支能否删
  看上游 `: gone]`，删用 `-D`。命令自带判定，红了或判定不了就写 issue 并停下，不绕过、不改判定。

## 红线（违反 = 事故）

1. **issue 外的活不做。** 发现新问题开新 issue（`status:inbox`），继续当前活，不顺手修。
2. **范围即边界。** 只动 issue「范围」段的路径。产品红线：只做图片，不做文件备份/同步；
   **不做任何遥测 / 使用统计上报**，诊断只写本机日志
   （[决策记录](docs/product/2026-10-13-telemetry-removal.md)）。改这条红线须产品负责人拍板。新增网络出口、遥测类依赖由 `just ci` 会挡（`tools/check-egress.py`，例外登记见 [适应度门禁](docs/runbook/fitness.md)）。
3. **不捏造。** 报绿必须附命令 + 真实输出；故障/安全类判据必须带反证（去掉故障条件必须变红）；普通界面改动有单测即可，不要求反证。
   「CI 绿」不等于验收。
4. **凭据只在 GitHub Secrets。** 不进代码、issue、文档。凭据类方案先 `gh secret list`，
   优先用现有 secret 的标准解；确需新增，先说清现有的为什么不够。
   本机路径、设备序列号、机器状态只写本机 `local-state.md`（不进 git）。
5. **红测不进 main。** 红的停在自己分支上，在 issue 里写明停在哪。
6. **核心改动先讨论。** `.github/core-paths.txt` 圈住的路径（门禁、配对/身份/加密/协议、
   存储与迁移、更新链）：没有已采纳方案时只写复现、根因和两个修法，不改代码；
   由产品负责人拍板方案后再实现，PR 阶段同样要产品负责人放行。
7. **不公开的内容只进私仓。** 安全细节（漏洞利用、攻击面）、商业、竞品、运营内容不写进本仓库，
   也不写进 issue、PR、提交说明；只写进主副本旁边的 `../private`，issue 里只留
   「细节已存私仓」。「主副本旁边」是相对主仓根说的，不是相对当前目录，也不是环境变量。
   没有 `../private` 就是协作者模式：一律不写，`just stuck <号> "需要写私仓，本机是协作者模式"` 停下。

## 产品硬规矩（写卡、改代码、验收都按这些判）

- **占盘 1x**：照片库总占盘 ≈ 照片本身。隔离区、回收站、缓存、staging 只增不删都算违规，
  不是可选策略。写盘类改动的验收必须 `du -sh` 实测各子目录，不能只数文件。
  新增落盘目录必须登记清理触发条件（`just ci` 会挡，`tools/check-disk-growth.py`）。
- **尊重用户停掉的服务**：自愈、对账、自启、更新恢复时，「用户停过」永远优先于「服务该在」。
  拿不准是不是用户意图，按「用户停的」处理，只在 App 里给显式开启入口。
  新增自启 / 拉起调用点必须登记「先检查用户停过」的判断函数或 contract 测试（`just ci` 会挡，`tools/check-autostart.py`）。
- **读现状初始化，不写迁移**：新开关/偏好没有存值时，按当前真实状态算初值（已授权、已选过
  的就算开），之后以存值为准。「不写迁移」只针对数据格式，不能让用户已开的功能升级后悄悄停掉。
- **iOS 没有对外用户**：iOS 本地数据格式直接改，不写旧数据迁移，不考虑升级代价，也不拿这个去问人。
- **隐私优先**：不采任何敏感信息；对隐私有侵害的，哪怕排查更难也不采。
- **品牌语言**：组件可以按平台原生，颜色、字体、明暗外观一律以 `assets/design/tokens.json`
  与 Android 实现为准（iOS 的 token 由 `tools/ios/gen-tokens.py --check` 逐字节比对、颜色字面量由 `check-no-color-literals.sh` 拦，`just ci` 会挡）。偏离品牌语言的提案单独提 `needs:product`，不夹在「原生化」里。
- **iOS 先对齐 Android**：两端小功能同步迭代，iOS 多出/少掉的按 Android 改；要加就两端一起加。
  平台惯例（原生导航、下拉刷新等）可以保留。尺寸偏离登记进 `tokens.json` 的 `platforms.ios`
  并写理由，不在代码里写死。
- **桌面只改 i18n 副本**（同步 `assets/i18n` 在 Android/iOS 的逐字节副本）可以直接做；
  任何影响手机行为、协议、真机表现的改动都要在卡上写明并经产品负责人确认。
  副本逐字节一致由 `just mobile-static-check` 兜底（`just ci` 会挡）。
- **界面文案**：先找行业标准（Android 权限规范、NN/g、Google、Microsoft 写作指南）。提示说现状，
  不事事给操作建议；每句话只服务这一屏的作用；把已有功能说全，不替用户选；流程能省一屏就省；
  说后果要准；状态类不提内部组件（写「备份已停止」，不写「后台服务未运行」）。
  按钮名、词名先 grep 核对实物。

## 验收

- **证据分级**：E1 编译 + `just ci`（永远可信）｜E2 针对当前架构的 contract 测试（可信）｜
  E3 真机/真环境实证输出（用户看得到的行为必需）｜E4 legacy 测试（仅参考，不能单独作数）。
  报绿时每条结论标出自哪一级。
- **验证环境开工时探测，不写死设备**：先探测当前有什么——`adb devices`、`xcrun devicectl list devices`、
  `xcrun simctl list devices booted`、桌面端是否在跑——按探测结果决定这张卡能验到哪一级（E1–E3），
  并在回执里写明缺什么（例如「没有在线 iPhone，iOS 只到 E2」）。设备序列号、机器状态只写本机 `local-state.md`，不写进仓库。
- **真机为准**：用户看得到的行为以真机为准；只有真机造不出来的（写盘失败、系统错误码等）
  才用单测，并在卡里写明原因。每张卡写明「日志里出现哪一行算通过」，成功路径也要打日志。
- **只验未知**：先问这一步能证明什么现在不知道的事；能从已有实测推出来的不重测，写明推理依据。
- **写给人照做的 SOP**：先 grep 界面的显示条件，不凭印象写入口；判定脚本只把真正必需的步骤设成失败项。
- **派活、写卡时，已核实的事实标「已核实」**（写明核实用的命令或文件）：接手的人直接按它改，只查卡上没写的，不重复核实。
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
| 全量回归 | `docs/runbook/full-regression-sop.md` |
| 发版、签名、版本纪律 | `docs/RELEASING.md` |
| 架构规则、验收抽检、自举类改动 | `docs/AGENT_PROTOCOL.md` |
| 业务规则 | `docs/desktop/business-rules.zh-CN.md` |
| 历史事故与教训 | `docs/lessons/` |

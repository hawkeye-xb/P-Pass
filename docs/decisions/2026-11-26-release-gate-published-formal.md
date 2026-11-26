# 发版闸与 CHANGELOG 以「已 Publish 的正式 Release」为基准

- 状态：已采纳（产品负责人 2026-11-26 拍板方案 A）
- 日期：2026-11-26
- 采纳：产品负责人 2026-11-26 拍板方案 A（[方案评论](https://github.com/hawkeye-xb/P-Pass/issues/1636#issuecomment-7182620219)）；规则口径见 2026-11-10 [产品补充](https://github.com/hawkeye-xb/P-Pass/issues/1636#issuecomment-6761023050)
- 关联：#1636（本方案与后续实现）、#1471（按版本验收）、#1486（发版闸）、#773（CHANGELOG 组装）

## 结论

验收范围（`tools/flow/release-scope.sh`）与 `CHANGELOG.md` 校验（`tools/release/changelog-section.sh`）统一以**真正 Publish 过的正式 Release** 为基准，不再将「仅有 git tag 但 Release 仍为 Draft」的草稿版当作已发布版本；草稿版本的 `CHANGELOG.md` 条目必须去向明确（并入下一个正式版，或显式标注不发布/未发布），否则在 CI 与发版预检拦红。

## 背景

1. **草稿 tag 截断验收范围（#1636）**：`release.yml` 的 `create-draft` 在建草稿 Release 时即创建 git tag 锚定提交。`tools/flow/release-scope.sh` 的 `last_formal()` 目前仅调用 `git describe --tags --abbrev=0 --match 'v*' --exclude '*-*'`，只看 git tag 是否存在而不核对 GitHub Release 的 `isDraft` / `isPrerelease` 状态。`v2026.11.1` 自 2026-11-05 起一直处于 Draft 未发布，推 `v2026.11.2` 时却被当成「上一个正式版」，导致台账 #1543 漏算了从实际线上最新版 `v2026.10.7` 至今的 21 项用户可见改动。
2. **已有台账起点偏移无提醒**：`release-scope.sh --ledger` 保留台账中已记录的 `LEDGER_SINCE`，但当它与当前最新已 Publish 的正式版不一致时没有任何提示。
3. **滞留草稿 CHANGELOG 小节无门禁**：`tools/release/changelog-section.sh` 目前只按单个 `<tag>` 抽取 `## [<batch>]` 小节并在缺失时发 `::warning::`；对于「已有非 test 的正式 git tag，但对应 Release 仍为 Draft」的遗留小节（如曾留驻在 `CHANGELOG.md` 里的草稿段），既没有检查它是否已并入当前发布段或显式标注未发布，也没有接入 PR CI（`ci-docs.yml`）与 `release.yml` 预检。
4. `tools/release/changelog-section.sh` 与 `.github/workflows/release.yml` 均命中 `.github/core-paths.txt`，按红线 6 须先合入本已采纳方案，再开卡实施代码改动。

## 决定

### 1. `tools/flow/release-scope.sh`：按已 Publish 正式 Release 算起点并告警起点偏差

- **`last_formal <ref>` 改按 GitHub Release 过滤**：
  - 查询 `gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases`（或等价 `gh api` 分页接口，确保不受默认分页条数截断），仅保留 `isDraft == false`、`isPrerelease == false` 且 tag 名匹配 `^v` 并排除预发布后缀（不含 `-`）的正式 Release tag；
  - 对候选 tag 逐个用 `git merge-base --is-ancestor "$tag" "$ref"` 验证祖先关系，取距 `<ref>` 最近（按提交拓扑 / 创建顺序最近）的一个已 Publish 正式 tag；
  - `gh` 查询失败或鉴权异常时 **fail-closed** 退出非 0，绝不静默回退到未过滤的 `git describe`。
- **已有台账 `LEDGER_SINCE` 只告警不自动改写**：
  - 保留既有约束：已有台账中的 `since=` 不自动篡改；
  - 在 `release-scope.sh --ledger` 读取到 `LEDGER_SINCE` 后，顺带比对 `last_formal "$PKG"` 算出的最新已 Publish 正式版；若两者不一致，向 stderr 输出明确警告（提示当前台账起点与最新已发布正式版不一致，供人工核对或显式 `--since` 另建台账），不阻塞原有更新或改写 `LEDGER_SINCE`。

### 2. `tools/release/changelog-section.sh`：新增 `--check` 模式并接入 CI 与发版预检

- **保持既有正文抽取行为不变**：`changelog-section.sh <tag> <输出文件> [CHANGELOG 路径]` 继续原样组装 `## 本版更新（<批次号>）` 与正文。
- **新增 `--check [CHANGELOG 路径，默认 CHANGELOG.md]` 模式**：
  - 查询 GitHub Releases（排除 `-test.` tag，涵盖 `isDraft == true` 的草稿 Release）并结合仓库内已存在的非 `-test.` 正式形状 git tag（`v*` 且不含 `-`），识别所有「存在 git tag 但对应 Release 仍为草稿（尚未 Publish）」的批次号 `<batch>`；
  - 逐个检查 `CHANGELOG.md` 中是否存在 `## [<batch>]` 小节：
    - 若不存在该小节（条目已并入当前发布段或 `[Unreleased]` 并移除旧草稿头）→ 通过；
    - 若仍保留 `## [<batch>]` 标题，则其小节正文必须显式标注去向（对齐既有写法如 `本版本未发布，内容已并入 [2026.11.2]。`，或明确标注「本版本未发布 / 不发布 / 已并入」），且不得滞留独立的未归并变更列表（`### Added` / `### Changed` / `### Fixed` / `### Security` 或条目列表）；
    - 任一草稿小节既未移除/并入、又未按约定显式标注去向，或 `gh` 查询失败（fail-closed）→ 退出码 `1`。
- **双处门禁接入**：
  - `.github/workflows/ci-docs.yml`：在文档 / 发布链门禁中运行 `changelog-section.sh --check`（及配套单测），PR 改到 `CHANGELOG.md`、`tools/release/**` 或发布相关文档时即拦截滞留草稿段；
  - `.github/workflows/release.yml`：在 `plan-builds`（正式版 `release=true` 预检，构建任何平台之前）调用 `tools/release/changelog-section.sh --check`，红了立即终止构建；`tools/release/dry_run.py` / `gha_sim.py` 的 `gh` 桩同步兼容该调用。

### 3. 文档同步

- 更新 `docs/RELEASING.md` 与 `docs/release-notes-rules.md`：
  - 写明验收范围（`release-scope`）与 `CHANGELOG.md` 均以**真正 Publish 过的正式版**为基准；
  - 写明中间产生的 Draft Release 若未发布，其条目在 `CHANGELOG.md` 中必须去向明确：并入下一个正式版本段（可删去草稿标题，或仅保留「本版本未发布，内容已并入 [x.y.z]」占位说明），或明确标注不发布；不能滞留独立变更条目或因上一版是草稿而漏进下一版的更新说明。

### 4. 带反证的自动化测试

- **`tools/test-release-scope.sh`**：扩展 `gh` 桩支持 `gh release list` / `gh api`，补充用例与反证：
  1. 造一个「`v1.1.0` tag 存在但 Release 为 Draft，`v1.0.0` 为已 Publish Release」的仓库：旧逻辑（不过滤草稿）取到 `v1.1.0` 判红，新逻辑跳过草稿取到 `v1.0.0` 判绿；
  2. `v1.1.0-test.1` 等 `-test.` 与 Prerelease 不干扰正式起点判定；
  3. 已有台账记着旧 `since=` 且与最新已 Publish 版不一致时，保持 `since=` 不被改写并输出不一致警告；
  4. `gh` 查询失败时 fail-closed 退出非 0。
- **`tools/test-changelog-section.sh`**（接入 `justfile` / `ci-docs.yml`）：覆盖正文提取与 `--check` 门禁及反证：
  1. 造一个「存在非 test tag 且 Release 为 Draft、但 `CHANGELOG.md` 仍滞留该段正式条目」的夹具 → `--check` 必红（退出 `1`）；
  2. 将该草稿段条目并入当前段并删掉旧头，或改为约定去向标注（如 `本版本未发布，内容已并入 [2026.11.2]。`） → `--check` 必绿（退出 `0`）；
  3. 反证：撤掉或绕过 `--check` 校验后，上述滞留草稿段夹具错误放行（判红）。

## 理由

- **本质保证**：用户实际经历的是「已 Publish 的正式版 → 下一个已 Publish 的正式版」之间的状态跳变。仓库里的 git tag 只是构建锚点（`create-draft` 即建 tag），Release 是否 Publish 才是版本是否真的触达用户的唯一真相源。
- **标准对齐**：以制品发布注册态（已发布的 Release）而非内部构建 tag 作为变更日志与验收范围的起点，并在文档与发布流水线前置阶段做 fail-closed 静态校验，避免问题拖到人工 Publish 前夜才靠肉眼发现。
- **与既有结构同源**：`tools/release/changelog-section.sh` 本身已负责从 `CHANGELOG.md` 解析 `## [<batch>]` 小节；将草稿滞留检查收口到同一脚本的 `--check` 模式，使正文提取与去向校验共用同一套段落解析规则，避免两套脚本长期漂移。

## 后果

- **正面**：彻底堵住「未 Publish 的 Draft tag 截断验收范围」与「草稿版本 CHANGELOG 条目滞留或整段漏进正式版」两类发布事故路径。
- **代价与约束**：
  - `release-scope.sh` 与 `changelog-section.sh --check` 均依赖 `gh` 读取仓库 Release 列表，在无网络或 `gh` 未鉴权环境下会 fail-closed 报错，无法离线猜测已发布状态；
  - `ci-docs.yml` 新增对 GitHub Releases 的只读查询（使用 `GITHUB_TOKEN`，`contents: read` 即可）；测试套件与 `dry-run` 需通过 `gh` 测试桩隔离网络。
- **边界**：本阶段 PR 仅合入本 ADR 文档，不修改任何代码或脚本；待本方案合入 `origin/main` 后，由实现阶段按本方案修改脚本、workflow、文档与反证单测。

## 备选

- **备选方案 B：不动 `tools/release/changelog-section.sh`，另建非核心检查脚本（如 `tools/check-changelog-drafts.sh`）**：不采纳。虽然可绕开 `.github/core-paths.txt` 核心门禁，但与 #1636 既定落点不一致，且使 `CHANGELOG.md` 段落解析与滞留检查分裂在两个脚本中，后续维护容易产生解析口径漂移，也容易遗漏 `release.yml` 发版前预检。

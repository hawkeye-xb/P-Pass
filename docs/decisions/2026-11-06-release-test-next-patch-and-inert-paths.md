# test 版本号自动补丁与发版路径惰性登记

- 状态：已采纳
- 日期：2026-11-06
- 采纳：产品负责人 2026-11-06 通过 owner 转达「选修法一」（就地小改）
- 关联：#1532（实现）、#1503（同一脚本 release-test 的另一个判定缺口）、#1396（同一脚本 main CI 判定的前一次修复）

## 结论

1. `just release-test` 在不带 `--base`、且最新 test 基线版本不高于 `release/versions.json` 的最高正式版本时，自动取该正式版本的下一个补丁号、`-test.1`；否则维持原来的 `-test.N+1`。`--base` 只做显式覆盖与校验，不参与自动推算。正式发版的版本号纪律不变。
2. `tools/release/plan-builds.sh` 的 `classify()` 把 `.coderabbit.yaml`、`.github/ISSUE_TEMPLATE/*` 归为「不影响安装包」，不再触发四端构建；未登记路径继续走 `all` 的保守兜底。

## 背景

2026-11-06 出 test 包 `v0.11.1-test.1` 时实测两个问题（#1532）：

- `release/versions.json` 三端已经是 0.11.0，远端最新 test tag 是 `v0.11.0-test.4`。`just release-test --dry-run android` 直接拒绝，要求手工补 `--base 0.11.1`；脚本自己已经能从正式版本线算出这个号。
- 只改 `.coderabbit.yaml`（或 `.github/ISSUE_TEMPLATE/config.yml`）时，`plan-builds.sh` 判四端全 `build`；只改 `docs/*` 时四端全 `skip`。两类都是不进安装包的文件，行为却不一致。

原因：

- `tools/flow/owner-release-test.sh` 第 92-121 行：不带 `--base` 时把最新 test 的 `X.Y.Z` 原样当 `BASE_VER`，只把 `N` 加一；随后要求 `BASE_VER > maxv`，不满足就拒绝。补丁 +1 只写在拒绝提示里，没有回填到 `BASE_VER`。
- `tools/release/plan-builds.sh` 的 `classify()` 第 99-115 行是反向 allowlist：只有 `docs/*`、`.claude/*`、`*.md` → `none`，其余落到 `*) echo all`。`.coderabbit.yaml` 和 `.github/ISSUE_TEMPLATE/*.yml` 没有被任何 case 命中；`.github/ISSUE_TEMPLATE/*.md` 本来已被 `*.md` 判成 `none`，真正漏的是 YAML 模板和仓库根的评审工具配置。

## 决定

### 1. test 版本号：正式线已占用时自动取下一个补丁号

改 `tools/flow/owner-release-test.sh`：

- 先取远端最新 `v<X.Y.Z>-test.N`，`LATEST_BASE = X.Y.Z`、`LATEST_N = N`（现状）。
- 不带 `--base`：
  - 若 `LATEST_BASE` 不高于 `maxv`：`BASE_VER = maxv 的下一个补丁号`，`N = 1`。
  - 否则：`BASE_VER = LATEST_BASE`，`N = LATEST_N + 1`（现状）。
- 带 `--base`：维持现状——必须高于最新 test 基线，且最终 `BASE_VER > maxv`；`N = 1`。只校验、只覆盖，不自动算。
- 不写 `release/versions.json`、不推 tag、不触发正式发布；正式发版仍由产品负责人在网页上做。
- 远端一个 test tag 都没有时仍按现状 `die_stuck`（判定不了，不猜）。

`maxv` 仍取 `release/versions.json` 里 `desktop` / `android` / `ios` 的最高版本，与现有拒绝提示同口径。

### 2. plan-builds：登记不进安装包的工具/文档路径

改 `tools/release/plan-builds.sh` 的 `classify()` `none` 分支：

- 新增 `.coderabbit.yaml`；
- 新增 `.github/ISSUE_TEMPLATE/*`；
- 保留 `docs/*`、`.claude/*`、`*.md`；
- `*) echo all` 不动，未登记路径仍按四端全量。

已核实：`git grep -n "coderabbit\|ISSUE_TEMPLATE"` 只在配置文件本身、流程说明和流程测试里命中，构建入口（`release.yml`、`apps/`、`crates/`、打包脚本）没有读取；`tools/ci-needs-full-lane.sh` 第 120 行已经把 `.github/ISSUE_TEMPLATE/*` 登记为惰性路径，是同一口径的先例。两者分别是 CodeRabbit 配置和 GitHub issue 表单，不随任何安装包分发。

同时更新 `plan-builds.sh` 文件头的路径分类表、`docs/RELEASING.md` 的按端判定说明、`docs/runbook/owner.md` 的 release-test 说明，保持文字与判定一致。

### 测试与反证

- `tools/test-flow-owner.sh` 第 6 节：
  - 正式线 0.10.3、最新 test `v0.10.3-test.2`，不带 `--base` → 算出 `v0.10.4-test.1`；
  - 正式线 0.11.0、最新 test `v0.10.4-test.2`（正式线高于 test 基线）→ 算出 `v0.11.1-test.1`；
  - 最新 test 基线已高于正式线（`v0.10.4-test.2` / 正式 0.10.3）→ 仍是 `v0.10.4-test.3`（不跳号）；
  - `--base 0.10.3`（不高于正式线）拒绝；`--base 0.10.5` → `v0.10.5-test.1`。
  - 反证：去掉自动补丁版本那一段，前两条新用例必须变红（脚本以退出码 2 拒绝），其余用例保持绿。
- `tools/test-release-plan.sh` 的 #852 一节：
  - 只改 `.coderabbit.yaml` → 四端全 `skip`，脚本按「没有可发布的东西」退出 1；
  - 只改 `.github/ISSUE_TEMPLATE/config.yml` → 同上；
  - `.coderabbit.yaml` 与 `apps/android/...` 混改 → 只 Android `build`；
  - 未登记路径（如 `release/x`）仍四端全 `build`。
  - 反证：删掉新增的 `none` 分支，前两条新用例必须变红（四端 `build`），原有兜底用例保持绿。

## 理由

- **版本号**：test 包只需要让测试设备能从正式版升级上去；正式版本线已经占用的号不能再用，补丁号是唯一确定、单调、不需要猜的下一号。把这个推算留在脚本里，减少一次人工输入和一次可能的填错；`--base` 保留为人工覆盖，供产品负责人明确指定某个号时使用。
- **为什么不在 `LATEST_BASE` 已经高于 `maxv` 时也取 `maxv+1`**：那会把已经领先正式线的 test 线（例如正式 0.10.3、test 已到 0.10.4-test.2）重置成 `0.10.4-test.1`，比测试设备上正装着的版本低，破坏 test 通道的单调升级。因此只有基线不高于正式线时才补丁 +1。
- **路径**：`plan-builds` 的默认 `all` 是 fail-closed，必须保留。`.coderabbit.yaml` 与 issue 模板只服务 GitHub/评审工具，不进入任何安装包；`ci-needs-full-lane.sh` 已经把 `.github/ISSUE_TEMPLATE/*` 登记为惰性，发版判定与 CI lane 用同一口径。只登记已核实的两条，不顺手放宽 `tools/`、`.github/` 整目录。

## 后果

- 正式版之后第一次出 test 包不再需要手工 `--base`；test 设备仍能收到更高版本。
- 只改评审/文档工具的文件时，test 包会明确报「没有可发布的东西」，不再白跑四端构建；要发版仍需至少改一个端的输入。
- 未登记的新工具/文档路径仍会四端构建（保守兜底），需要时再逐条核实登记。
- 正式发版的版本号仍由产品负责人在 `release/versions.json` 决定，本方案不改这条纪律。

## 备选

- **修法二：抽共享的「不进安装包」清单 + 匹配器**，让 `plan-builds` 与 `ci-needs-full-lane` 共用。不选：要新增文件、改两个消费方；两个 lane 的语义并不完全相同（CI 是为了省编译，发版是决定构建哪端），合并清单必须逐条证明，范围与风险都更大。产品负责人 2026-11-06 选一。
- **只改拒绝提示、继续要求手填 `--base`**：不选，问题 1 的诉求就是不再手填。
- **把 `tools/`、`.github/` 整目录判 `none`**：不选，里面可能有进入安装包的构建脚本与配置，违反保守兜底。

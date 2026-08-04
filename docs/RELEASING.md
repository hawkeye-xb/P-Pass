# RELEASING — P-Pass versioning & release norms (REL-01)

> 规范源：REL-01 卡（2026-08-04）。Trunk-based development: **main is
> always releasable**. Tag = release (SemVer). Hotfix only opens a
> `release/vX.Y` branch. Draft → human publish. Bump + changelog before
> every release.

## 1. Versioning model

- **SemVer** (`MAJOR.MINOR.PATCH[-prerelease]`) is the only version format.
  Pre-release suffixes: `-test.N` (pipeline acceptance), `-beta.N`, `-rc.N`.
- **One source of truth for the code version**: `Cargo.toml` workspace
  `version`. `tools/bump-version.sh` syncs it with Android
  `versionName`/`versionCode` — never edit them by hand separately.
- **Tag = release**. `v<version>` tags exactly the released commit.
  `v0.2.0-test.7` is a pre-release tag; `v0.2.0` is the eventual stable tag.
- **Never overwrite or move an existing tag** (user ruling 2026-08-04:
  "每个版本的问题都是独一无二的"). A failed acceptance tag stays in history
  as its own record; bump to `-test.N+1` and re-run. `bump-version.sh`
  refuses to reuse a tag that already exists.

## 2. Branching

- **main**: always releasable. All features land via PR to main
  (branch protection: no force-push, no deletion).
- **Short-lived PR branches**: `feat/<card>` / `fix/<card>`, < 3 days.
- **`release/vX.Y`**: only for hotfixes to a shipped minor line.
  Cherry-pick the fix, tag `vX.Y.Z+1`, then merge back to main. No other
  branch types.

## 3. Release flow (normal)

1. **Bump**: `tools/bump-version.sh <new-version>` — updates Cargo.toml +
   Android versionName/versionCode in one shot (versionCode monotonic +1).
   Refuses already-tagged versions and non-increasing versions.
2. **Changelog**: move `[Unreleased]` → new version section in
   `CHANGELOG.md` (keep-a-changelog format, user-visible changes only).
3. **PR** → merge to main (main must be green: PR Checks).
4. **Tag**: `git tag v<version>` + push. Tag pushes run the Release
   workflow (release.yml) → draft Release with platform assets.
5. **Human publish**: review the draft (signing status, asset list,
   E2E live scenarios result if the tag ran one), then
   `gh release edit <tag> --draft=false`.

## 4. Release flow (pipeline acceptance / test tags)

- Acceptance tags: `v<X.Y.Z>-test.N` (increment N, never reuse).
- They exercise the full Release workflow against a draft; publish
  only when the acceptance passes and the version is intended for users.

## 5. Version-overwrite guards (remember)

- `git tag -l "v<ver>"` exists → that version number is **taken**.
  Bump higher or use a pre-release suffix.
- Old tags are never deleted or moved (even "by mistake" — a moved tag
  breaks reproducibility of the shipped artifact).
- `CHANGELOG.md` sections are append-only: past releases are never
  rewritten after publish.

---

# RELEASING — 版本与发布规范（中文版）

> Trunk-based 流程成文：main 永远可发布；tag = release（SemVer）；
> hotfix 才开 `release/vX.Y` 分支；draft → 人工 publish；每 release 前
> bump + changelog。

## 1. 版本模型

- 只有 SemVer（`MAJOR.MINOR.PATCH[-预发布]`）。预发布后缀：
  `-test.N`（流水线验收）、`-beta.N`、`-rc.N`。
- **代码版本唯一事实来源**：`Cargo.toml` workspace `version`。
  `tools/bump-version.sh` 一次同步 Android `versionName`/`versionCode`，
  不要手工分开改。
- **tag = release**。`v<version>` 精确打在发布 commit 上。
  `v0.2.0-test.7` 是预发布 tag，`v0.2.0` 才是最终稳定 tag。
- **绝不覆盖/挪动已有 tag**（2026-08-04 用户裁决："每个版本的问题都是
  独一无二的"）。验收失败的 tag 留在历史当独立记录，bump 到
  `-test.N+1` 重跑。`bump-version.sh` 拒绝复用已存在的 tag。

## 2. 分支

- **main**：永远可发布。功能一律 PR 合入（分支保护：禁 force-push、禁删除）。
- **短命 PR 分支**：`feat/<卡>` / `fix/<卡>`，< 3 天。
- **`release/vX.Y`**：只给已发布小版本的 hotfix。cherry-pick 修复 →
  打 `vX.Y.Z+1` → 合并回 main。没有其他分支类型。

## 3. 发布流程（常规）

1. **bump**：`tools/bump-version.sh <新版本>`——一次改 Cargo.toml +
   Android 版本（versionCode 单调 +1）。拒绝已打过 tag 的版本号和
   不递增的版本号。
2. **changelog**：`CHANGELOG.md` 里 `[Unreleased]` 段挪成新版本段
   （keep-a-changelog 格式，只记用户可见变更）。
3. **PR** → 合入 main（main 必须绿：PR Checks）。
4. **打 tag**：`git tag v<版本>` + push。tag 触发 Release workflow →
   draft Release（三平台资产）。
5. **人工 publish**：核对 draft（签名状态、资产清单、e2e 结果若本次
   tag 跑了），然后 `gh release edit <tag> --draft=false`。

## 4. 发布流程（流水线验收 / 测试 tag）

- 验收 tag：`v<X.Y.Z>-test.N`（N 递增，不复用）。
- 全链跑 Release workflow 出 draft；验收通过且版本面向用户才 publish。

## 5. 版本覆盖禁令（记住）

- `git tag -l "v<ver>"` 存在 = 该版本号**已占用**。往高 bump 或用预发布
  后缀。
- 旧 tag 永不删除/挪动（挪 tag 会破坏已发产物的可复现性）。
- `CHANGELOG.md` 段落只追加：发布后不再重写过去版本。

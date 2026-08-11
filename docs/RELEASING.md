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

## 3.5 Update channel (UPD-01) — current scope & known gaps

- Every release emits **`manifest.json`** as a release asset
  (`tools/make-update-manifest.mjs`; tauri-plugin-updater style, sha256
  per platform + Ed25519 signature gated on `UPDATE_SIGNING_KEY`).
  Clients resolve it via `releases/latest/download/manifest.json`.
- **404 semantics**: while the latest release is a *draft* (or none
  exists), that URL 404s — clients must treat it as "no update",
  **silently** (no error banner; a test tag you forgot to publish must
  never alarm users).
- **Current manifest scope: `android-arm64` only.** Desktop auto-update
  is wired (tauri-plugin-updater + pubkey) but has no artifact yet:
  - **darwin 挂账 (H-10c 衔接)**: the macOS updater artifact is a
    `.app.tar.gz` (not the dmg), and it must include `lib/` (daemon
    dylibs) — `createUpdaterArtifacts` alone does not; producing the
    tar.gz from the bundle output is still open.
  - **windows 挂账**: desktop shell on Windows pending (H-09 lane).
- Signing: `UPDATE_SIGNING_KEY` (tauri signer, minisign hashed format).
  Without it the manifest ships with empty signatures and the release
  notes say "unsigned".

## 3.6 Update channels (REL-02) — test / stable

Two channels, explicit switch in settings, **stable is always the
default** (family devices are never touched by test builds):

- **stable** (family devices): clients keep hitting GitHub
  `releases/latest/download/manifest.json` directly — URL and semantics
  unchanged (locked by a unit test; do not touch). GitHub `latest` only
  ever points at a *published* release, so **publishing manually IS the
  release action** after acceptance.
- **test** (dev/dogfood devices): CI auto-publishes any tag containing
  `-test.` as a **GitHub prerelease** (release.yml; GitHub `latest`
  ignores prereleases by design, so it can never leak into stable).
  Clients on the test channel fetch
  `https://update.p-pass.hawkeye-xb.com/manifest?channel=test` — a
  Cloudflare Worker (`infra/workers/update`) that resolves the latest
  prerelease's manifest and caches it 300s. Clients never call the
  GitHub API directly (unauthenticated limit 60/h/IP). Worker deployment
  config lives in ppf-ops; DNS: `update.p-pass.hawkeye-xb.com`.
- **404 semantics unchanged**: a test tag left as draft (not published)
  → no prerelease → Worker 404 → clients stay silent ("no update").
- Desktop note: tauri updater's endpoint is baked at build time and
  `Update` has no public constructor, so the test-channel **install**
  path on desktop is currently "check → dialog → open download page"
  (in-shell fetch of the Worker manifest + `plugin-opener`). Full
  auto-install on the test channel would require reimplementing the
  updater install logic (dmg mount/NSIS silent) — deferred until the
  desktop updater artifact (3.5 gaps) lands.

## 4. Release flow (pipeline acceptance / test tags)

- Acceptance tags: `v<X.Y.Z>-test.N` (increment N, never reuse).
- They exercise the full Release workflow against a draft; publish
  only when the acceptance passes and the version is intended for users.

## 4.1 CI split by domain (CI-01, 2026-08-12)

The old `pr.yml` (every push ran all four jobs) is replaced by per-domain
workflows, each gated on its own `paths` (pure docs/cards commits → zero CI):

- `ci-rust.yml` — `crates/** Cargo.* config/** assets/i18n/** tools/arch-check.sh`
  → lint + test + arch-check + deny. Scenarios (T-070) moved to e2e.yml's
  nightly + tag gate.
- `ci-android.yml` — `apps/android/** assets/i18n/**` → unit tests + APK.
- `ci-desktop.yml` — `apps/desktop/** assets/**` → src-tauri lib tests + vite build.
- `ci-workers.yml` — `infra/workers/**` → wrangler deploy (gated on
  `CLOUDFLARE_API_TOKEN`; skipped cleanly when absent).
- Every workflow has `concurrency: cancel-in-progress`.
- `release.yml` gained a `platforms` dispatch input (`android`/`macos`/
  `windows` comma list; empty = all). Tag pushes always build everything.
- R2 mirror: assets are mirrored to `ppf-dl` bucket
  (`dl.p-pass.hawkeye-xb.com/releases/<tag>/`) when `CLOUDFLARE_API_TOKEN`
  is set; the update manifest's `--asset-base` switches to the mirror
  domain (signatures are over asset bytes, so changing the download URL
  never invalidates verification).
- Nightly (e2e.yml schedule) runs full nextest + scenarios — a red nightly
  is a real bug and is top priority next day.

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

## 3.6 更新通道（REL-02）— test / stable

两条通道，设置页显式切换，**默认永远 stable**（家人设备绝不被 test
构建波及）：

- **stable**（家人设备）：客户端保持直连 GitHub
  `releases/latest/download/manifest.json`——URL 与语义原样不动（单测
  锁死，不许碰）。GitHub latest 只认已发布的正式 release，**人工
  publish 就是验收后的发布动作**。
- **test**（开发/狗粮设备）：CI 把含 `-test.` 的 tag 自动 publish 为
  **GitHub prerelease**（release.yml；GitHub latest 设计上忽略
  prerelease，绝不会漏进 stable）。test 通道客户端 fetch
  `https://update.p-pass.hawkeye-xb.com/manifest?channel=test`——这是
  Cloudflare Worker（`infra/workers/update`），Worker 端解析最新
  prerelease 的 manifest 并缓存 300s。客户端不直连 GitHub API（未认证
  限流 60 次/小时/IP）。Worker 生产配置在 ppf-ops；DNS：
  `update.p-pass.hawkeye-xb.com`。
- **404 语义不变**：test tag 留 draft 不 publish → 无 prerelease →
  Worker 404 → 客户端静默（「无更新」）。
- 桌面注：tauri updater endpoint 构建期写死、`Update` 无公开构造器，
  test 通道**安装**路径当前形态是「检查 → 弹窗 → 打开下载页」（壳内
  fetch Worker manifest + plugin-opener）。test 通道全自动安装需要重写
  updater 安装逻辑（dmg 挂载/NSIS 静默）——等桌面更新产物（3.5 挂账）
  落地后再议。

## 4. 发布流程（流水线验收 / 测试 tag）

- 验收 tag：`v<X.Y.Z>-test.N`（N 递增，不复用）。
- 全链跑 Release workflow 出 draft；验收通过且版本面向用户才 publish。

## 4.1 CI 按域分块（CI-01，2026-08-12）

旧 pr.yml（每次 push 全量跑四 job）拆成按 paths 门控的域 workflow，
纯 docs/卡片提交零 CI：

- `ci-rust.yml`（crates/** Cargo.* config/** assets/i18n/** tools/arch-check.sh）
  → lint + test + arch-check + deny；T-070 scenarios 挪到 e2e.yml 的
  nightly + tag 门禁。
- `ci-android.yml`（apps/android/** assets/i18n/**）→ 单测 + APK。
- `ci-desktop.yml`（apps/desktop/** assets/**）→ src-tauri lib tests + vite build。
- `ci-workers.yml`（infra/workers/**）→ wrangler deploy（CLOUDFLARE_API_TOKEN
  门控，缺 secret 干净跳过）。
- 每个 workflow 带 `concurrency: cancel-in-progress`（连续 push 取消旧 run）。
- release.yml 加 `platforms` dispatch 输入（android/macos/windows 逗号
  组合，留空=all）；tag push 恒全量（发布完整性不许分块）。
- R2 镜像：CLOUDFLARE_API_TOKEN 在位时资产镜像到 ppf-dl bucket
  （dl.p-pass.hawkeye-xb.com/releases/<tag>/）；update manifest 的
  asset-base 切镜像域（签名针对资产字节，换下载域名验签零变化）。
- nightly（e2e.yml schedule）跑全量 nextest + scenarios——nightly 红
  是实打实的 bug，次日第一优先修。

## 5. 版本覆盖禁令（记住）

- `git tag -l "v<ver>"` 存在 = 该版本号**已占用**。往高 bump 或用预发布
  后缀。
- 旧 tag 永不删除/挪动（挪 tag 会破坏已发产物的可复现性）。
- `CHANGELOG.md` 段落只追加：发布后不再重写过去版本。

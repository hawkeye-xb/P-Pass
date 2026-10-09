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
- **UPD-13（#660，2026-10-04 起）：批次号与「每端版本号」是两条线。**
  - **批次号 = tag**，用日期形式 `vYYYY.MM.N`（年.月.当月第几版，如
    `v2026.10.1`）。⚠️ **不要**写 `v2026.10.1-2`：在 SemVer 里 `-2` 是预发布
    后缀、比 `2026.10.1` **小**，客户端的版本比较会判错。
  - **每端版本号**存在 `release/versions.json`（`desktop` / `android` /
    `androidVersionCode`）：只有该端**真的改了**才涨，另一端的文件一个字节都
    不动。`tools/bump-version.sh --platform desktop|android|both <ver>` 维护它；
    `tools/release-version.sh <platform>` 是 CI 读取它的唯一入口（正式 tag 取
    该端号；`-test.` tag 仍取 tag 名 —— 那是 test 通道判据，且连续的 test tag
    必须能互相升级）。
  - 后果：同一个 tag 下两端可以印不同的版本号（tag `v2026.10.3` 里 macOS
    0.9.1 / Android 0.9.4 是正常的）。用户报版本号时要带上平台。
- **老格式 `manifest.json` 冻结在 0.9.0**（`release/legacy-manifest.json`）：
  正式版发布时把它**原样**作为 release 资产上传，其 URL 指向 R2 上
  `releases/<tag>/…` 的**不可变副本**（mirror-latest 每次发布都会写这些副本）。
  它只服务「还装着 0.9.0 之前版本」的客户端、给它们一次性升级。**不要**把它改成
  动态清单：两端版本线分化后，动态清单的 version 会高于某端包内版本，客户端会
  陷入「提示更新 → 装上还是旧号 → 再提示」的死循环。

## 2. Branching

- **main**: always releasable. All features land via PR to main
  (branch protection: no force-push, no deletion).
- **Short-lived PR branches**: `feat/<card>` / `fix/<card>`, < 3 days.
- **`release/vX.Y`**: only for hotfixes to a shipped minor line.
  Cherry-pick the fix, tag `vX.Y.Z+1`, then merge back to main. No other
  branch types.

## 3. Release flow (normal)

1. **Bump（只涨本端）**: `tools/bump-version.sh --platform android 0.9.4`
   （两条线一起走时省略 `--platform`）。它维护真相源
   `release/versions.json`，并同步该端的文件（desktop 线 = 根 workspace +
   桌面四件套；android 线 = `build.gradle.kts` 的 versionName 回退串 +
   versionCode 单调 +1）。拒绝已打过 tag 的版本号、非递增版本，以及
   「真相源与文件不一致」（drift）。
2. **Changelog**: move `[Unreleased]` → new version section in
   `CHANGELOG.md` (keep-a-changelog format, user-visible changes only).
   **This section becomes the opening of the release body** (see step 5) —
   maintain it during commit/PR, not the night before tagging.
   Keep the platform prefixes (`Android 端：` / `macOS 端：` / `Windows 端：` /
   `桌面端：`) on entries that concern one platform — they are the input for
   step 2b. **CHANGELOG no longer feeds the in-app update dialog** (`#741`;
   the old per-platform filtering `#737` / `#743` was removed).
2b. **User update notes (`#741`)**: for every platform whose version went up,
   write `release/notes/<platform>/<version>.zh.txt` + `.en.txt` (plain text,
   one item per line, ≤ 3 items / ≤ 200 chars each language). The release
   pipeline copies them verbatim into that platform's manifest (`notes` = zh
   for old clients, `notes_i18n` = {zh, en}); no file ⇒ empty notes ⇒ the
   client shows its default text. An agent drafts them **only from merged PR
   titles and CHANGELOG entries of that platform**, submits them as a PR, and
   they count only after the reviewer approves and merges. Rules, CI lint and
   drafting flow: [`docs/release-notes-rules.md`](release-notes-rules.md).
   A formal tag whose platform version went up without a notes file gets a
   `::warning::` in `create-draft` (not blocking).
3. **PR** → merge to main (main must be green: PR Checks).
4. **Tag**: `git tag v<version>` + push. Tag pushes run the Release
   workflow (release.yml) → draft Release with platform assets.
   > **UPD-13 门禁**：`create-draft` 第一步跑 `tools/check-version-bump.sh` ——
   > 改了 `crates/**` / `apps/desktop/**` / `assets/**` / `Cargo.*` 却没涨
   > `desktop` 号，或改了 `apps/android/**` 却没涨 `android` 号，**直接红**
   > （漏判门禁，只对正式 tag 生效；test tag 的版本号就是 tag 名）。
5. **Human publish**: review the draft, then publish it from the
   GitHub web UI (Releases → the draft → Publish release). Two checks:
   - **the body must open with this version's user-visible changelog**;
     signing status / SHA-256 / asset list belong in later sections (§3.5)
   - the signing status + asset list + E2E live scenarios result (if the
     tag ran one) are consistent with the commit you tagged
   > **Do not use the local `gh` CLI for this repo** — it is not bound to
   > this repo's account. Triggering workflows, reading CI results and
   > publishing releases all happen in the browser; git goes over the
   > personal SSH remote only. (`gh` *inside* `.github/workflows/` runs on
   > the runner with `GITHUB_TOKEN` and is unaffected.)

## 3.5 Update channel (UPD-01) — current scope & known gaps

- Every release emits **`manifest.json`** as a release asset
  (`tools/make-update-manifest.mjs`; tauri-plugin-updater style, sha256
  per platform + Ed25519 signature gated on `UPDATE_SIGNING_KEY`).
- **UPD-13（#660）起，正式版同时产出分端清单** `manifest-android.json` /
  `manifest-macos.json`（顶层 `version` = **该端自己的**版本号，只含该端条目）：
  两端客户端各读自己那份（R2 优先、GitHub 兜底），所以「只有一端变更」的版本
  不会去打扰另一端。老格式 `manifest.json` 只服务旧客户端（已冻结，见 §1）；
  test tag 不走冻结件，`manifest.json` 仍是 tag 版本的动态清单（test-channel 指针）。
  Clients resolve it through an **ordered candidate list** (UPD-12/`#650`):
  1. `https://p-pass-dl.hawkeye-xb.com/manifest.json` — the R2 mirror. The
     mirror workflow rebases the android entry to the mirror's own download
     path, so mainland devices never touch GitHub for check *or* download.
  2. `releases/latest/download/manifest.json` — GitHub, kept as the fallback
     (every already-installed client points here).
  A source is skipped only when it answers 404 (that source has nothing) or
  fails; the first source returning a parseable manifest decides. Both URLs
  are pinned by `UpdateCheckerTest` — changing order or URLs requires touching
  that test.
  **R2 carries stable only (UPD-18 `#706`)**: `mirror-latest.yml` never
  mirrors a `-test.` tag, whatever triggered it (dispatch included), and
  judges "newest" among non-test releases only. Test builds reach devices
  solely through the GitHub `test-channel` pointer. The decision lives in
  `tools/mirror-resolve-tag.sh` and is tested by
  `tools/test-mirror-resolve-tag.sh` (CI Docs lane).
- **`notes` / `notes_i18n` are the hand-written user notes (`#741`)**, not the
  release body: `release/notes/<platform>/<version>.<zh|en>.txt`, copied
  verbatim by `make-update-manifest.mjs --notes-dir release/notes` (§3 step 2b,
  rules in [`docs/release-notes-rules.md`](release-notes-rules.md)). The Android
  dialog picks the app's language, rejects text containing links / emails /
  phone-like numbers / bidi or zero-width characters, and otherwise falls back
  to its default text. The release body still **opens with the version's
  user-visible changelog** (REL-08/`#626`) for people reading the Release page;
  signing status, SHA-256 sums and asset lists belong in later sections.
  Every path that produces a manifest uses the same source (`#740`): the manual
  `repair-manifests.yml` also composes with `--notes-dir release/notes`, taking
  `release/` (versions, notes, frozen legacy manifest) from the tag it repairs,
  so a repaired manifest carries the same notes the release run produced. No
  workflow feeds the release body into `notes`; `tools/release-notes.test.mjs`
  scans all workflows and fails if one does.
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
  **Test-channel pointer (REL-07):** after a test release is
  auto-published, release.yml overwrites
  `releases/download/test-channel/manifest.json` — a fixed, rolling
  prerelease tagged `test-channel` (created on the first test release,
  marked prerelease, never latest; do not delete it) — with that
  release's signed manifest. Download URLs inside still point at the
  versioned release. Re-running an older tag's workflow never moves the
  pointer backwards. Nothing calls the GitHub API, so there is no
  anonymous rate limit and no `GH_TOKEN` to manage.
  Android reads that file directly. The desktop shell and older Android
  builds read `https://update.p-pass.hawkeye-xb.com/manifest?channel=test`
  — the Cloudflare Worker (`infra/workers/update`), now a thin proxy of
  the same file (300s cache, adds `Access-Control-Allow-Origin`, which the
  desktop webview needs and GitHub downloads lack). Worker deployment
  config lives in ppf-ops; DNS: `update.p-pass.hawkeye-xb.com`.
- **404 semantics unchanged**: a test tag left as draft (not published)
  → no prerelease → Worker 404 → clients stay silent ("no update").
  (A draft tag never reaches the pointer step.) Before the very first
  test release after REL-07, `test-channel` does not exist → the file
  404s → Worker 404 → same silent "no update". Worker 404 means *only*
  that upstream said 404; any other upstream failure (5xx, 403/429,
  network) → **502** (with `Retry-After` when upstream sent one),
  `no-store`, never cached. Clients log 5xx as a *failed check*, not
  "up to date".
- Desktop note: tauri updater's endpoint is baked at build time and
  `Update` has no public constructor, so the test-channel **install**
  path on desktop is currently "check → dialog → open download page"
  (in-shell fetch of the Worker manifest + `plugin-opener`). Full
  auto-install on the test channel would require reimplementing the
  updater install logic (dmg mount/NSIS silent) — deferred until the
  desktop updater artifact (3.5 gaps) lands.

## 3.7 Desktop auto-update regression (UPD-06/07, 2026-10-03)

**Bootstrap property**: an update fix is only exercised by the *next* hop — `N → N+1` runs N's
code. So ship two builds: the **fix carrier** (all changes) and a **stub carrier** (bump-only,
its sole purpose is to offer an update). The starting version is installed **manually** from the dmg.

Publish order matters: publish the start version **first** (while the target is still a draft,
`releases/latest/download/manifest.json` 404s and clients correctly answer "no update"), then publish the target.

1. Publish the start version → install its dmg into `/Applications` → quit fully and reopen →
   `defaults read /Applications/P-Pass.app/Contents/Info.plist CFBundleShortVersionString` = start version
2. **Log out and back in (or reboot)** — so launchd owns the shell. Without this, `kickstart -k`
   has nothing to kill and you only exercise the fallback path.
3. Publish the target version.
4. In the app: Check for updates → progress → install → the app restarts itself.
5. **Pass** = Info.plist shows the target version, footer/settings show shell == service (no
   mismatch), and a second check answers "up to date". **Allowed degradation** = falling back to
   the in-process relaunch (the `#616:` log line says why) — record which path ran.
   **Blocking** = a manual Cmd+Q is required, the version stays old, or a mismatched state never clears.

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
- `ci-workers.yml` — `infra/workers/**` → `test` job (update Worker
  `node --test`, also on PRs) → wrangler deploy (push/dispatch only,
  behind the `workers-prod` approval gate; gated on
  `CLOUDFLARE_API_TOKEN`, skipped cleanly when absent).
- Every workflow has `concurrency: cancel-in-progress`.
- `release.yml` gained a `platforms` dispatch input (`android`/`macos`/
  `windows` comma list; empty = all). Tag pushes always build everything.
- R2 mirror: **removed 2026-08-25**. Assets are served from GitHub
  release downloads only; the update manifest always points there.
  Re-enabling it requires fixing the coupling first (see `REL-04`).

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
   （keep-a-changelog 格式，只记用户可见变更）。**这一段就是 release 正文的开头**
   （见第 5 步）——在 commit/PR 阶段就维护它，别等打 tag 前一晚才补。
   只涉及一端的条目继续以「Android 端：」「macOS 端：」「Windows 端：」「桌面端：」
   开头——它们是 2b 起草说明的输入。**CHANGELOG 不再进入应用内更新弹窗**（#741；
   原 #737 / #743 的按端过滤推导已删除）。
2b. **用户更新说明**（#741）：本次版本号涨了的每一端，写
   `release/notes/<platform>/<version>.zh.txt` 与 `.en.txt`（纯文本、每行一条、
   每种语言 ≤ 3 条 / ≤ 200 字）。发版流水线把它们原样放进该端清单（`notes` = 中文，
   给旧客户端；`notes_i18n` = {zh, en}）；没有文件 ⇒ 说明为空 ⇒ 客户端显示默认文案。
   agent 起草，输入**只限本端已合入 PR 的标题与 CHANGELOG 条目**，草稿以 PR 提交，
   验收人审过合入才算数。规则、CI lint 与起草流程见
   [`docs/release-notes-rules.md`](release-notes-rules.md)。正式 tag 某端版本号涨了
   却没有说明文件 ⇒ `create-draft` 告警（不阻断）。
3. **PR** → 合入 main（main 必须绿：PR Checks）。
4. **打 tag**：`git tag v<版本>` + push。tag 触发 Release workflow →
   draft Release（三平台资产）。
5. **人工 publish**：核对 draft，然后在 GitHub 网页上发布（Releases → 该 draft →
   Publish release）。两项核对：
   - **正文必须以本版本的用户可见 changelog 开头**；签名状态 / SHA-256 / 资产清单
     放后面的段落
   - 签名状态 + 资产清单 + e2e 结果（若本次 tag 跑了）与你打的那个 commit 一致
   > 更新清单的说明**不取自 release 正文**（UPD-03 #580 起），#741 起取自第 2b 步的
   > 手写说明文件；正文仍以用户可见 changelog 开头，是给在网页上看 Release 的人读的。
   > 所有生成清单的路径同一口径（#740）：手动补跑的 `repair-manifests.yml` 同样用
   > `--notes-dir release/notes`，且 `release/`（版本号、说明、冻结件）取自被修复的 tag，
   > 修出来的清单与当次发布产出的说明一致。没有任何 workflow 把 release 正文写进 `notes`，
   > `tools/release-notes.test.mjs` 扫全部 workflow 把关。
   > **本仓不用本机 `gh` CLI**（未绑定本仓账号）：触发 workflow、看 CI
   > 结论、发 Release 一律在浏览器里做，git 只走个人 SSH remote。
   > （`.github/workflows/` 里的 `gh` 跑在 runner 上用 `GITHUB_TOKEN`，
   > 不在此列。）

## 3.6 更新通道（REL-02）— test / stable

两条通道，设置页显式切换，**默认永远 stable**（家人设备绝不被 test
构建波及）：

- **stable**（家人设备）：客户端按**有序候选列表**解析（UPD-12 #650）——
  ① R2 镜像 `https://p-pass-dl.hawkeye-xb.com/manifest.json`（镜像侧已把
  android 条目的下载 URL 改写成本域直链，国内设备**检查与下载都不走
  GitHub**）② GitHub `releases/latest/download/manifest.json`（兜底；
  老客户端一直打的就是它）。只有 404（该源没有）或失败才落到下一项，
  **第一个能解析出 manifest 的源说了算**；两个 URL 与顺序都由
  `UpdateCheckerTest` 锁死，改它必须同时改测试。
  GitHub latest 只认已发布的正式 release，**人工 publish 就是验收后的发布动作**。
  **R2 只承载 stable**（UPD-18 #706）：`mirror-latest.yml` 不镜像任何
  `-test.` tag（含手动 dispatch），「最新」也只在非 test 的 release 里比。
  test 构建只经 GitHub `test-channel` 指针到达设备。判定在
  `tools/mirror-resolve-tag.sh`，测试是 `tools/test-mirror-resolve-tag.sh`（CI Docs lane）。
- **test**（开发/狗粮设备）：CI 把含 `-test.` 的 tag 自动 publish 为
  **GitHub prerelease**（release.yml；GitHub latest 设计上忽略
  prerelease，绝不会漏进 stable）。
  **test 通道指针（REL-07）**：test release 自动 publish 之后，
  release.yml 把该版本已签名的 manifest 覆盖进
  `releases/download/test-channel/manifest.json`——固定的滚动
  prerelease（tag `test-channel`，首次 test 发布时自动创建，标记
  prerelease、永不是 latest，勿删）。manifest 里的下载链接仍指向版本化
  release。重跑旧 tag 的 workflow 不会把指针往回拨。全程不调 GitHub
  API → 没有匿名限流，也没有 `GH_TOKEN` 要管。
  Android 直读这个文件；桌面壳和旧版 Android 读
  `https://update.p-pass.hawkeye-xb.com/manifest?channel=test`——Cloudflare
  Worker（`infra/workers/update`），现在只是同一文件的薄代理（缓存 300s，
  补上桌面 webview 需要、GitHub 下载链接没有的
  `Access-Control-Allow-Origin`）。Worker 生产配置在 ppf-ops；DNS：
  `update.p-pass.hawkeye-xb.com`。
- **404 语义不变**：test tag 留 draft 不 publish → 无 prerelease →
  Worker 404 → 客户端静默（「无更新」）（draft 走不到指针那一步）。
  REL-07 合入后、第一次 test 发布之前，`test-channel` 还不存在 → 文件
  404 → Worker 404 → 同样静默无更新。Worker 的 404 **只**表示上游答
  404；其它上游故障（5xx、403/429、网络异常）→ **502**（上游给了
  `Retry-After` 就透传），`no-store`，绝不缓存。客户端把 5xx 记为「检查
  失败」，不当「已是最新」。
- 桌面注：tauri updater endpoint 构建期写死、`Update` 无公开构造器，
  test 通道**安装**路径当前形态是「检查 → 弹窗 → 打开下载页」（壳内
  fetch Worker manifest + plugin-opener）。test 通道全自动安装需要重写
  updater 安装逻辑（dmg 挂载/NSIS 静默）——等桌面更新产物（3.5 挂账）
  落地后再议。

## 3.7 桌面自动更新回归（UPD-06/07，2026-10-03）

**自举性质**：更新类修复只能被**下一跳**用到——`N → N+1` 跑的是 N 的代码。所以要出**两个包**：
**修复载体**（功能全在这一版）+ **stub 载体**（纯 bump，唯一用途是"提供一个可更新到的新版本"）。
起点版本由验收人**手动**从 dmg 装。

**发布顺序不能反**：先发布起点版（目标版还是 draft 时 `releases/latest/download/manifest.json`
是 404，客户端答"没有更新"是**正确行为**），再发布目标版。

1. 发布起点版 → dmg 装进 `/Applications` → 完全退出重开 → 确认
   `defaults read /Applications/P-Pass.app/Contents/Info.plist CFBundleShortVersionString` = 起点版
2. **登出再登录（或重启）** —— 让 launchd 接管壳。不做这步，`kickstart -k` 无物可杀，
   只会验到退化路径
3. 发布目标版
4. App 内点「检查更新」→ 看进度 → 安装 → **App 应自动重启**
5. **通过** = Info.plist 是目标版 ＋ 页脚/设置页显示壳 == 服务（无"版本不一致"）＋ 再检查更新答"已是最新"。
   **允许的降级** = 退化成壳内自重启（日志 `#616:` 会写明原因）——记录走的是哪条路。
   **阻断** = 需要手动 Cmd+Q / 版本停在旧版 / "混版本"状态永不收敛

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
- `ci-workers.yml`（infra/workers/**）→ `test` job（update Worker
  `node --test`，PR 上也跑）→ wrangler deploy（仅 push/dispatch，停在
  `workers-prod` 审批门；CLOUDFLARE_API_TOKEN 门控，缺 secret 干净跳过）。
- 每个 workflow 带 `concurrency: cancel-in-progress`（连续 push 取消旧 run）。
- release.yml 加 `platforms` dispatch 输入（android/macos/windows 逗号
  组合，留空=all）；tag push 恒全量（发布完整性不许分块）。
- R2 镜像：**2026-08-25 已撤除**。资产只从 GitHub release 下载提供，
  update manifest 恒指 GitHub 直链。撤除原因是耦合方向错（manifest 在
  镜像之前就写死镜像地址，镜像失败则带着坏 manifest 出门且签名无法手改），
  要重开必须先修 `REL-04`。

## 5. 版本覆盖禁令（记住）

- `git tag -l "v<ver>"` 存在 = 该版本号**已占用**。往高 bump 或用预发布
  后缀。
- 旧 tag 永不删除/挪动（挪 tag 会破坏已发产物的可复现性）。
- `CHANGELOG.md` 段落只追加：发布后不再重写过去版本。

---

## 附录：发版实况（2026-09-16 从 QUEUE.md 迁入）

- 正式产物走 CI：GitHub 网页 Actions → Release → Run workflow，`platforms`
  填 `android,macos`（Android 出签名 APK；macOS 未签名，「右键 → 打开」
  过 Gatekeeper）。**不用本机 `gh`**，理由同 §3 步骤 5。
- 调管线只用 workflow_dispatch，不打测试 tag（tag 纪律见 `AGENTS.md`）。
- **Secrets 实况（2026-08-25 核实）**：`CLOUDFLARE_API_TOKEN` /
  `CLOUDFLARE_ACCOUNT_ID` / `ANDROID_KEYSTORE_*` / `UPDATE_SIGNING_KEY` /
  `APPLE_*` 全部在位。
- **触发节奏**：ci-rust/ci-android/ci-desktop/site build 随 push（paths 门控）；
  e2e 走 nightly 03:30 + tag + PR 标签，也可 dispatch；artifacts（dogfood
  裸二进制）仅 Linux 自动，macOS/Windows 只手动；release 走 tag `v*` 或
  dispatch；ci-workers 随 infra/workers/** push 或 dispatch。
- **ci-workers 审批门**：`environment: workers-prod` 让部署 job 停在
  Waiting，不占 runner、不计费，挂 30 天自动作废。

# P-Pass justfile — single-person project task runner
# Run `just` for a list of available commands.

# QA-08：Windows 上 just 默认去找 POSIX `sh`，而 Git for Windows 只把 Git 的
# cmd 目录放进 PATH —— sh.exe / bash.exe 在它的 bin 目录里，默认不在 PATH 上。
# 于是在 PowerShell 里任何一条配方都以 "could not find the shell sh" 失败，
# 而那句话指向「shell 找不到」，第一反应会是仓库坏了。
#
# 改用 bash：本仓的配方本来就是 POSIX 写的，而且已有配方直接调 bash
# （cleanup-local），所以「要求 bash 可用」是既成事实、不是新约束。只要
# bash 在 PATH 上，PowerShell 里也能直接跑 just。bash 不在 PATH 时仍会失败，
# 但 tools/windows/env-check.ps1 会明确报出来并给出修法（见 #179）。
#
# 只影响 Windows：其余平台仍用 just 默认的 `sh -cu`。
set windows-shell := ["bash", "-cu"]

default:
  @just --list

# ── Setup ───────────────────────────────────────────

# Install toolchain checks + git hooks.
#
# 工具链部分：rustup 钉的 toolchain（见 rust-toolchain.toml）+ cargo-nextest
# / cargo-deny。git hooks 部分：用 pre-commit 把仓内 .pre-commit-config.yaml
# 的门禁（当前是 gitleaks）装进 .git/hooks/pre-commit。
#
# QA-10：pre-commit 可执行文件不一定在 PATH 上（比如装在用户级 Python 的
# Scripts 目录），PATH 上那个还可能是坏的（装了包但环境坏了）。所以按
# pre-commit（要求存在且 --version 能跑通）→ python3 -m pre_commit →
# python -m pre_commit 的顺序探测，三者皆不可用就报错退出——装不上不许
# 静默跳过。
# gitleaks 是 language: system 的本机可执行文件，必须在 PATH 上 hook 才跑
# 得动；它缺了不挡 hook 安装，但会让每次提交都硬失败，所以装完 hook 后单独
# loud-check 一次，缺了打 WARNING 并给出安装指引。
setup:
  @echo "==> Checking Rust toolchain..."
  rustup show
  @echo "==> Installing cargo-nextest..."
  cargo install cargo-nextest --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing cargo-deny..."
  cargo install cargo-deny --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing just..."
  @echo "  (just is already running this file — you have it! 🎉)"
  @echo "==> Installing git hooks (pre-commit)..."
  @if command -v pre-commit >/dev/null 2>&1 && pre-commit --version >/dev/null 2>&1; then \
    pre-commit install; \
  elif python3 -m pre_commit --version >/dev/null 2>&1; then \
    python3 -m pre_commit install; \
  elif python -m pre_commit --version >/dev/null 2>&1; then \
    python -m pre_commit install; \
  else \
    echo "ERROR: pre-commit not found — git hooks were NOT installed." >&2; \
    echo "  Tried: pre-commit on PATH (exists AND --version works), python3 -m pre_commit, python -m pre_commit." >&2; \
    echo "  Fix: pip install pre-commit   then re-run: just setup" >&2; \
    exit 1; \
  fi
  @if command -v gitleaks >/dev/null 2>&1; then \
    echo "  gitleaks found in PATH ($(command -v gitleaks))"; \
  else \
    echo "WARNING: gitleaks not found in PATH." >&2; \
    echo "  The installed hook (gitleaks protect --staged) will FAIL on every commit." >&2; \
    echo "  Install it: https://github.com/gitleaks/gitleaks#installing" >&2; \
  fi

# ── Format & Lint ───────────────────────────────────

# Format all Rust code
fmt:
  cargo fmt --all -- --check

# Lint all Rust code (clippy with deny warnings)
#
# BUILD-06: 刻意**不用** `--all-features`。本仓只有两个 feature，两个都是特殊
# 构建模式，不该被默认打开：
#   - `transport/mobile-ffi` —— 只给两端手机的绑定用（启用处是
#     tools/build-android-iroh-blobs-bridge.sh 与 tools/build-ios-transport-xcframework.sh）。
#     它的代码用 `std::os::fd`（#1126 起 Android 的描述符导入在这里），在 Windows 上
#     直接编不过（E0432/E0599）⇒ `--all-features` 等于把这个刻意做出来的平台闸门又强行
#     打开。手机那条路径见下方 lint-mobile。
#   - `media-codec/vendored` —— 从源码编 libheif。该 crate 自己的注释就写着
#     「Default stays on the system library for fast dev/CI builds」。
# 远端 ci-rust.yml 仍用 `--all-features`（Linux 上两者都编得过），所以覆盖没丢；
# 本地这条的目标是三个平台都能真的跑起来。
lint:
  cargo clippy --all-targets -- -D warnings

# CI-16 (#369)：把「只在别的平台上成立」的 lint 拉到本地。
#
# `lint` 只检查本机这个平台编译进来的代码：Windows 上跑全绿，推上去 Linux 的
# clippy 却可能红（PR #368：data_migration 在非 Windows 上没有调用方 ⇒
# dead_code），Mac 上的人也看不到 Windows 的问题。
#
# 为什么只查 `platform` 一个 crate 就够：arch-check B.2 规定平台 cfg **只许**
# 出现在 crates/platform/，所以「换个目标结论不同」只可能发生在这里。它是纯
# Rust，clippy 只做检查不链接，不需要各平台的 SDK 或 libheif，哪台机器上都能
# 跑三个目标。`--features test-support` 把只给测试用的那块也一起查到。
#
# 编译目标按需安装，已装过时 `rustup target add` 立即返回。刻意不写进
# rust-toolchain.toml：CI 不跑 just，写进去会让每个 CI job 多下两套标准库。
#
# platform crate 按 Windows / Linux / macOS 三个目标各跑一遍 clippy
lint-cross:
  for t in x86_64-pc-windows-msvc x86_64-unknown-linux-gnu x86_64-apple-darwin; do rustup target add "$t" >/dev/null 2>&1 && echo "==> clippy -p platform --target $t" && cargo clippy -p platform --all-targets --features test-support --target "$t" -- -D warnings || exit 1; done

# BUILD-06 / #1126: 手机绑定（mobile-ffi，原 android-jni 已并入）的专项 lint。**只能在 unix
# 上跑**——该 feature 的代码用 `std::os::fd`，Windows 上必然 E0432。所以刻意没挂进 `ci`：
# 挂进去等于让 Windows 的 `just ci` 永远红（Linux CI 的 `--all-features` clippy 覆盖它）。
lint-mobile:
  cargo clippy -p transport --all-targets --features mobile-ffi -- -D warnings

# ── Test ────────────────────────────────────────────

# Run all tests (nextest if available, fallback to cargo test)
# BUILD-06: 同 lint，不用 `--all-features`（否则 Windows 上连编译都过不去）。
#
# QA-11：nextest 在的时候输出一眼不吞——它的进度、失败清单、超时报告全走
# stderr，`2>/dev/null` 会一并扔掉——退出码如实透传，失败绝不退化成
# `cargo test` 全量重跑（cargo test 没有单测超时，挂着不动的测试能让配方
# 永不返回）。「nextest 没装」和「测试失败」分两路：没装才退回 cargo test
# 并明说；在但坏了（--version 跑不通，QA-10 实测过这种活死 shim）按没装处理。
test:
  @if command -v cargo-nextest >/dev/null 2>&1 && cargo-nextest --version >/dev/null 2>&1; then \
    cargo nextest run; \
  else \
    echo "cargo-nextest not found or not runnable — falling back to 'cargo test' (no per-test timeout)." >&2; \
    echo "Install nextest for the real gate: just setup   (or: cargo install cargo-nextest --locked)" >&2; \
    cargo test; \
  fi

# T-070 故障剧本（进程内集成测试三件套：大文件 / 崩溃恢复 / 磁盘满）
# 安全卡 #1115 后常驻 daemon 不再读 PPF_DATA_DIR，原 shell 剧本已改写为
# crates/daemon/tests/scenarios/process_failures.rs。磁盘满剧本只在设了
# PPF_SCENARIO_SMALL_FS（指向小文件系统上的目录，CI 挂 6MB tmpfs）时运行，
# 否则打印 SKIP。
scenarios:
  cargo test --release -p daemon --test scenarios -- --ignored --test-threads=1

# ── Code Generation ─────────────────────────────────

# Generate code: proto → Kotlin types + schema snapshot
gen:
  @echo "==> gen: placeholder (T-002 will implement proto → Kotlin generation)"
  @echo "    For now: no generated code needed."

# ── Architecture Enforcement ────────────────────────

# Architecture check: enforce isolation rules
# #1040：先跑门禁自测（违规样例必须红、合规样例必须过），再判真实代码。
# 想只看 G1/G5 现状而不判红：ARCH_REPORT_ONLY=1 ./tools/arch-check.sh
arch-check:
  @./tools/test-arch-check.sh
  @./tools/arch-check.sh

# ci-rust.yml「fmt + actionlint」job 里的同一条：每个跑 cargo 的 CI job 都必须
# 用 rust-toolchain.toml 锁定的版本（脚本自带反证）。
toolchain-check:
  @tools/check-rust-toolchain-ci.sh

# Markdown tables in docs/ and cards/ must not be split by a stray blank line
#
# QA-07: 解释器不能硬写 `python3`。Windows 上 `python3` 常解析到 Microsoft Store
# 的应用执行别名占位程序——它**存在于 PATH**、但零输出、非零退出（本机实测
# exit 49），所以 `command -v python3` 这类探测会被它骗过，必须真跑一次才判得出
# 活死。反过来也不能一律改写成 `python`：Debian 系只保证有 `python3`。
# 故：依次试 python3 / python / py，第一个能自报 major == 3 的胜出。
#
# 用 shebang 配方是刻意的——它绕开 just 的 shell 设置，将来若为 Windows 配上
# `set windows-shell`（QA-08）这两条不会跟着坏。
md-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-markdown-tables.py
    fi
  done
  echo "md-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# DESK-15: assets/design/tokens.css must not drift from tokens.json
# 解释器探测同 md-check（理由见上方 QA-07 注释）。
token-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-token-drift.py
    fi
  done
  echo "token-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# SITE-04: site 有自己一套生成物（tokens.css / icons），由 site/scripts/*.mjs
# 从 assets/design/ 生成，**不在 token-check 的覆盖范围内**——后者只比数值，
# 而 site 的生成器连文案一起嵌进产物。漏掉的后果实测过：一次只改文案的提交
# 让 site lane 红了 6 天没人发现。
#
# 需要 site/node_modules 就位，所以刻意**没有**挂进 ci / ci-docs（见 SITE-04
# 卡的留白）。动了 assets/design/ 或 site/ 就手动跑一次。
site-check:
  @cd site && npm run tokens:check && npm run icons:check

# SEC-02: 提交身份必须在 .github/allowed-identities.txt 白名单内。
# 第二行是反证（证明门禁在该红时真的红），跟门禁同生共死。
# 本地跑的是 origin/main..HEAD；远端 ci-identity.yml 按 PR/push 各自算区间。
# shell 变量紧挨非 ASCII 字符必须写成 ${name}：macOS /bin/bash 3.2 会把多字节字符的首字节读进变量名
# （v0.9.12-test.5 的 macOS 构建因此没能重试 codesign）。先跑自测，再扫全仓。
shell-vars-check:
  @python3 tools/check-shell-vars.py --self-test
  @python3 tools/check-shell-vars.py

identity-check:
  @./tools/test-commit-identity-gate.sh
  @./tools/check-commit-identity.sh

# SEC-09 (#371): pnpm 的 minimumReleaseAgeExclude 不许自己长出来。
# 任何条目都要在 tools/release-age-exclude-allowlist.txt 显式登记；先跑变异反证再扫全仓。
supply-chain-check:
  @bash tools/test-release-age-exclude.sh
  @python3 tools/check-release-age-exclude.py

# ── Development ─────────────────────────────────────

# Start daemon in development mode
# #1115：开发用测试沙盒（--ephemeral）：库在 stdout 的 SANDBOX: 那一行，IPC 用令牌。
# 不带 --ephemeral 的未签名 daemon 读不了钥匙串，会拒绝启动。
dev-daemon:
  cargo run -p daemon -- --ephemeral

# ── CI ──────────────────────────────────────────────

# Full CI pipeline (same as GitHub Actions pr.yml)
ci: fmt toolchain-check lint lint-cross test arch-check md-check token-check shell-vars-check identity-check supply-chain-check mobile-static-check lockfile-check
  @echo "==> CI pipeline: all green ✅"

# 两个 Rust workspace 的 Cargo.lock 都得和实际依赖一致（src-tauri 是独立 workspace，
# 改了 crates/* 的依赖却没刷它的锁，本地编译会悄悄改锁、CI 不带 --locked 也不红）。
lockfile-check:
  cargo metadata --locked --format-version 1 > /dev/null
  cargo metadata --locked --format-version 1 --manifest-path apps/desktop/src-tauri/Cargo.toml > /dev/null
  @echo "ok: Cargo.lock（根 + src-tauri）与依赖一致"

# ci-ios 里不需要模拟器的文字级门禁 + 手机端 i18n 副本，本地几秒跑完。
# 为什么要这条：改了 assets/i18n 却没同步副本，本地 `ci` 全绿、要等远端 iOS lane 才红。
mobile-static-check:
  python3 tools/ios/gen-tokens.py --check
  tools/ios/sync-i18n.sh --check
  tools/ios/test-stamp-version.sh > /dev/null
  tools/ios/check-testflight-signing.sh --self-test > /dev/null
  tools/ios/check-testflight-signing.sh
  python3 tools/ios/gen-strings.py --check
  tools/ios/check-no-color-literals.sh --self-test > /dev/null
  tools/ios/check-no-color-literals.sh
  @for l in en zh; do cmp -s assets/i18n/$l.json apps/android/app/src/main/assets/i18n/$l.json || { echo "✗ apps/android/app/src/main/assets/i18n/$l.json 与 assets/i18n 不一致——从 assets/i18n 复制过去"; exit 1; }; done
  @echo "ok: Android i18n 副本与 assets/i18n 逐字节一致"

# QA-03 文档快车道：只跑文档域的门禁，不编 Rust。
#
# 为什么要这条：`ci` 里的 fmt/lint/test 是全量 Rust 构建 + clippy + nextest，
# 而改一个字的卡也要跑一遍——远端 CI 反倒早就按 paths 分好了 lane
# （纯文档提交只点起 ci-docs）。本地缺的就是同一件事。
#
# ⚠️ 只在这次改动**一行 Rust/Kotlin/前端都没动**时用它。碰了代码就跑 `just ci`，
# 别拿这条快车道当省事的借口——`ci` 的依赖列表一个都没减。
ci-docs: md-check token-check shell-vars-check identity-check supply-chain-check
  @echo "==> docs lane: green ✅（注意：本条不含 fmt/lint/test，动了代码必须跑 just ci）"

# T-040 人工验收：自启/防睡眠/密钥仓 真机冒烟（H-09 双平台各跑一次）
platform-smoke:
    cargo run -p platform --example smoke

# T-041 桌面壳开发模式（Tauri dev = 前端热更 + 托盘）
# #1115：debug 构建的壳只能经令牌连测试沙盒——先 `just dev-daemon`，再
#   PPF_SANDBOX_DIR=<它 stdout 上 SANDBOX: 后面那个目录> just dev-desktop
# 常驻 daemon（签名 socket）只接受签名的窗口程序，未签名的开发壳连不上它。
dev-desktop:
    cd apps/desktop && npx tauri dev

# macOS 日常开发循环（Xcode 式：每个 debug 构建都组装成 .app、用团队 Developer ID 签名）。
# 窗口连本机真实的签名 daemon，签名校验与正式包一字不差。前端改动走 vite HMR；外壳 Rust
# 改动由 tauri dev 自动重编、签名、拉起；daemon Rust 改动跑 `just mac-dev daemon`。
# 开发版装在 ~/Applications/P-Pass.app（与正式包同 bundle id / LaunchAgent，互斥）：那里是正式包
# （正在运行或只是装着）时一律拒绝，不替换、不备份——先自己退出并移走正式版。退出开发模式：
# Ctrl+C，再装回正式 dmg。
#   just mac-dev            启动 tauri dev（首次需 PPF_DAEMON_PROVISIONPROFILE）
#   just mac-dev daemon     daemon 增量编译 + 签名 + kickstart + 重拉外壳（重拉这步尚未实测）
#   just mac-dev status     只读：看现在装的是哪一版
# 详见 tools/mac-dev.sh 文件头。
# macOS 开发循环：HMR + 签名的 debug 构建，连本机真实 daemon（up|daemon|status）
mac-dev *args:
    tools/mac-dev.sh {{args}}

# #1110：把本地构建的 daemon 组装成签过名的 helper（个人团队 Developer ID + 授权文件）。
# 需 PPF_DAEMON_PROVISIONPROFILE=<授权文件路径>。用途：本机验钥匙串读写、签名形状；
# #1115 起开发壳不连它（见 dev-desktop），要连得用签名的窗口程序。
dev-daemon-helper *daemon_bin:
    tools/daemon-helper-macos.sh dev {{daemon_bin}}

# M1 总验收（手册 E 表）：全仓测试 + 接口全剧本 + 桌面产物
#
# BUILD-09：这里以前直接 `npx tauri build --bundles app`，出来的 .app 缺
# daemon 旁边的 lib/ —— daemon 的 rpath 是 @executable_path/lib，Tauri 的
# externalBin 只搬那一个二进制，不搬它旁边那包 dylib。构建全绿、装上才炸。
# #1110 起 daemon 是嵌套 helper（Contents/Helpers/ppf-daemon.app），只有这条链路组装得出。
# 正确链路只有一条（release.yml 一直走的那条），现在本地也走它，而且
# bundle-desktop-macos.sh 第 5b 步会真的跑一遍 sidecar 才放行。
# 本地 ad-hoc 身份默认不出 dmg（BUILD-05 定调），要 dmg 设 PPF_BUNDLE_DMG=1。
verify-m1:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    cargo nextest run
    tools/dogfood-smoke.sh /tmp/ppf-verify-m1
    # #809：daemon 与外壳版本同源（bundle-desktop-macos.sh 第 5c 步核对）
    PPF_BUILD_VERSION="$(tools/release-version.sh desktop)" cargo build --release -p daemon -p testclient -p decode-worker
    rm -rf /tmp/ppf-rel && mkdir -p /tmp/ppf-rel
    TARGET="${CARGO_TARGET_DIR:-target}"
    tools/bundle-macos.sh /tmp/ppf-rel "$TARGET/release/daemon" "$TARGET/release/testclient" "$TARGET/release/ppf-decoder"
    tools/bundle-desktop-macos.sh /tmp/ppf-rel /tmp/ppf-rel

# Android unit tests (proto golden drift check included)
android-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ justfile_directory() }}/scripts/java-home.sh"
    cd "{{ justfile_directory() }}/apps/android"
    ./gradlew -q :app:testDebugUnitTest

# T-051 live check: Kotlin iroh-ffi client speaks hello to a real daemon
android-hello:
  tools/android-hello.sh

# T-052 live check: full pairing flow (Kotlin phone + IPC owner confirm)
android-pair:
  tools/android-pair.sh

# Android 15 dataSync FGS 配额压缩（#409 #397 #414）：set <秒> / status / reset。
# 多台设备时先 export ANDROID_SERIAL。用法与判据见 docs/runbook/android-fgs-quota.md。
android-fgs-quota *args:
  bash tools/android-fgs-quota.sh {{args}}

# iOS（#887）：apps/ios/project.yml → XcodeGen 生成 PPass.xcodeproj（不入库）。
# 需要 macOS + Xcode + xcodegen（brew install xcodegen）+ jq。
ios-gen:
  cd apps/ios && xcodegen generate

# iOS i18n（#316）：assets/i18n/*.json 逐字节拷进 apps/ios/PPass/Resources/i18n/。
# 改 i18n 要同步四个消费者（清单见 apps/ios/PPass/I18n/DiagText.swift）；--check 只比较不拷。
ios-sync-i18n *args:
  bash tools/ios/sync-i18n.sh {{args}}

# iOS 设计 token（#344）：assets/design/tokens.json → apps/ios/PPass/Design/Tokens.generated.swift。
# 改了 tokens.json 就跑一次并提交生成物；ci-ios 用 --check 逐字节比对，不同步就红。
ios-tokens:
  python3 tools/ios/gen-tokens.py

# iOS App 图标三态 + 启动屏图标（#941）：docs/design/2026-08-11-icon-v1 的定稿 SVG → Assets.xcassets。需要 rsvg-convert + Pillow。
ios-icons:
  python3 tools/ios/gen-app-icon.py

# iOS 界面文案（#315）：Android strings.xml → apps/ios/PPass/Resources/{en,zh-Hans}.lproj/Localizable.*。
# Android 改了文案就跑一次并提交；ci-ios 用 --check 逐字节比对。iOS 独有说法写在同目录的 IOS.strings。
ios-strings *args:
  python3 tools/ios/gen-strings.py {{args}}

# iOS 逐屏截图（#315）：演示数据，按「场景 × 路由」冷启动截图，输出 apps/ios/build/screenshots（不入库）。
ios-screenshots *args:
  bash tools/ios/screenshots.sh {{args}}

# iOS 单元测试：生成工程 → 模拟器上 xcodebuild test。模拟器选法见 tools/ios/sim.sh
# （默认 iPhone 17，IOS_SIM_NAME 可改；不写死 runtime 版本）。本配方启动的模拟器跑完即关。
ios-test:
  bash tools/ios/test.sh
  bash tools/ios/privacy-manifest-local.sh

# iOS 本地 SwiftPM 包（apps/ios/Packages/*/Package.swift）逐个在模拟器上测（#345）。没有包时直接通过。
ios-test-packages:
  bash tools/ios/test-packages.sh

# M2 total acceptance: Rust suite + Android suite + APK build +
# live wire scripts (hello/pair) against a throwaway daemon
verify-m2:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    cargo nextest run
    source scripts/java-home.sh
    cd apps/android
    ./gradlew -q :app:testDebugUnitTest :app:assembleDebug
    cd ..
    tools/android-hello.sh
    tools/android-pair.sh

# Local disk recovery. No arguments only previews; deletion needs --apply plus a scope.
cleanup-local *args:
    bash tools/clean-local-builds.sh {{args}}

# QA-13: fetch + automatic reclamation, the moment the info is freshest.
# GitHub deletes a PR's head branch on merge, so right after --prune the
# merged-and-done worktrees are exactly the ones whose upstream vanished;
# removal still passes every existing guard (current worktree / uncommitted
# changes / not-merged / active build / fail-closed probe). Local-only by
# construction: fetch is read-only, deletion touches local dirs only.
# Scope note: `--worktrees`, not `--all` — auto-deleting the CURRENT
# worktree's target/ would force a full rebuild on every pull; cache
# reclamation for kept worktrees stays manual (`just cleanup-local
# --apply --targets`), which is a deliberate cost choice, not an oversight.
sync:
    git fetch --prune origin
    bash tools/clean-local-builds.sh --apply --worktrees

# Safety integration test; it creates and destroys only a temporary Git repository.
test-cleanup-local:
    bash tools/test-clean-local-builds.sh

# REL-12 (#711): 发布链 dry-run——不花真 tag，用假产物 + stub gh + 临时签名密钥，把
# release.yml 的「正式 tag」与「test tag」两条路径（组装清单 → 说明 / 缺失告警 → 签名 →
# 校验 → 镜像判定）按 runner 语义各跑一遍。--keep 保留临时目录排查。
release-dry-run *args:
    tools/release/dry-run.sh {{args}}

# 先跑变异反证，再跑门禁本身；PPF_SMOKE_BIN_DIR=<bundle 目录> 时加跑完整冒烟。
# REL-08 (#510): release 资产里的 .sh 在只含资产的干净目录里必须自足
test-dogfood-assets:
    bash tools/test-dogfood-assets.sh --self-test
    bash tools/test-dogfood-assets.sh

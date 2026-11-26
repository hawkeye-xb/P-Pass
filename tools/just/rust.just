# Rust 工作区格式化、lint、测试、daemon 与里程碑总验收配方

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

# Run all tests (nextest if available, fallback to cargo test)
# BUILD-06: 同 lint，不用 `--all-features`（否则 Windows 上连编译都过不去）。
#
# QA-11：nextest 在的时候输出一眼不吞——它的进度、失败清单、超时报告全走
# stderr，`2>/dev/null` 会一并扔掉——退出码如实透传，失败绝不退化成
# `cargo test` 全量重跑（cargo test 没有单测超时，挂着不动的测试能让配方
# 永不返回）。「nextest 没装」和「测试失败」分两路：没装才退回 cargo test
# 并明说；在但坏了（--version 跑不通，QA-10 实测过这种活死 shim）按没装处理。
test:
  # daemon 的缩略图测试经 platform::decoder_worker_path 找 target/debug/ppf-decoder；
  # cargo 不会替别的包的 bin 构建，干净 target 下不先建它，这些测试会拿到占位图而红。
  # 视频首帧（#1730）同理要 ppf-video-decoder，它在 crates/media-codec（平台无关 bin）。
  cargo build -p decode-worker --bin ppf-decoder -p media-codec --bin ppf-video-decoder
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

# Generate code: proto → Kotlin types + schema snapshot
gen:
  @echo "==> gen: placeholder (T-002 will implement proto → Kotlin generation)"
  @echo "    For now: no generated code needed."

# ci-rust.yml「fmt + actionlint」job 里的同一条：每个跑 cargo 的 CI job 都必须
# 用 rust-toolchain.toml 锁定的版本（脚本自带反证）。
toolchain-check:
  @tools/check-rust-toolchain-ci.sh

# 两个 Rust workspace 的 Cargo.lock 都得和实际依赖一致（src-tauri 是独立 workspace，
# 改了 crates/* 的依赖却没刷它的锁，本地编译会悄悄改锁、CI 不带 --locked 也不红）。
lockfile-check:
  cargo metadata --locked --format-version 1 > /dev/null
  cargo metadata --locked --format-version 1 --manifest-path apps/desktop/src-tauri/Cargo.toml > /dev/null
  @echo "ok: Cargo.lock（根 + src-tauri）与依赖一致"

# Start daemon in development mode
# #1115：开发用测试沙盒（--ephemeral）：库在 stdout 的 SANDBOX: 那一行，IPC 用令牌。
# 不带 --ephemeral 的未签名 daemon 读不了钥匙串，会拒绝启动。
dev-daemon:
  cargo run -p daemon -- --ephemeral

# T-040 人工验收：自启/防睡眠/密钥仓 真机冒烟（H-09 双平台各跑一次）
platform-smoke:
    cargo run -p platform --example smoke

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

# M2 total acceptance: Rust suite + Android suite + APK build +
# live wire scripts (hello/pair) against a throwaway daemon
verify-m2:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    cargo nextest run
    source tools/java-home.sh
    cd apps/android
    ./gradlew -q :app:testDebugUnitTest :app:assembleDebug
    cd ..
    tools/android-hello.sh
    tools/android-pair.sh

# Roadmap / 里程碑看板

> Single source of truth for milestone status. Updated with every card.
> 里程碑状态的唯一权威来源，每张卡完成即更新。
> Detail per card: [PROGRESS.md](PROGRESS.md).

**Now / 当前位置**: **M1 closed** (verify-m1: 167 tests + dogfood
ALL GREEN + desktop bundle, 2026-07-31) → next is M2 Android toward
family dogfood. **M1 已收官**（总验收三连全绿）→ 下一步 M2 手机端，
直奔自家狗粮。

## M0 — Feasibility spikes / 可行性验证 ✅ (gate signed 2026-07-30)

- [x] S-01 iroh loopback & direct-connect probe CLI
- [x] S-02 network matrix summarizer
- [x] S-03 Android iroh-ffi demo (real-device hole punching)
- [x] S-04 UIDT background transfer — **verdict: replaced by
      ForegroundService segmented sessions** (real-device Doze test)
- [x] S-05 thumbnail pipeline benchmark (200/200, 26 MB peak)
- [x] H-04 network matrix: same-WiFi 100 %, cellular→home direct/IPv6,
      overseas return path verified
- [x] **Gate: pass into M1, no ADR-003 fallback** (human-signed)

## M1 — Storage daemon / 存储端 ✅ (closed 2026-07-31)

P0 foundations / 地基
- [x] T-001 workspace + CI + arch-check
- [x] T-002 proto crate (39 tests, golden snapshots)
- [x] T-003 diag state machine + msg_key dictionary (en/zh)
- [x] T-004 daemon config (3-layer precedence)
- [x] T-005 testclient skeleton
- [x] T-006 engineering hygiene (+rework)

P1 index / 索引
- [x] T-010 storage: SQLite schema v1.1 + audit log
- [x] T-011 core-index: ingest / dedup / timeline (85 % line coverage)
- [x] T-012 rebuild guard test (ADR-006 made executable)
- [x] T-013 thumbnails: core-media + media-codec (S-05 sweep 200/200)

P2 transport / 传输
- [x] T-020 Transport trait + iroh impl (1000-message loopback)
- [x] T-021 iroh-blobs + disconnect injection (5× zero-flake)

P3 daemon
- [x] T-030 ALPN router + whitelist authz checkpoint
- [x] T-031 pairing (one-time QR token, owner confirmation)
- [x] T-032 backup intake (manifest→missing→pull→ingest→watermark)
- [x] T-033 timeline / thumbnails / blob tickets serving
- [x] T-034 local IPC (7 methods) + diag aggregation + sanitized log export
- [x] T-035 telemetry client (zero network calls when off)

Real-world validation / 真机验证
- [x] Dogfood smoke #1: production-shape single-machine run — 5 real
      bugs found & fixed; agent-runnable scenario script
- [x] **Cross-internet two-machine run**: Aliyun daemon × office Mac,
      full scenario green (200 files in 5.9 s, NAT hole-punch pull)
- [x] Home-Mac dogfood deployment (self-contained bundle, zero deps):
      local smoke ALL GREEN + **cross-internet office→home full scenario**
      (pairing, 149-blob backup with cross-device dedup, browse, revoke;
      path = relay fallback exactly as the H-04 matrix predicted)

P4 desktop shell / 桌面壳
- [x] T-040 platform trait + windows/macos impls (macOS smoke ALL GREEN;
      Windows cross-checked in CI, live smoke → H-09)
- [x] T-041 Tauri tray shell (pairing QR, devices, status) — human
      walkthrough passed; 4 real issues found & fixed incl. the
      revoked-device-can-never-rejoin product bug
- [x] T-042 first-run wizard (folder + power check + resident service);
      user-verified: pkill → launchd revives in 3 s. Follow-up from user
      review: graceful stop (tray '停止后台服务' unregisters autostart
      first — resident AND stoppable)
- [x] `just verify-m1`: 167 tests + dogfood ALL GREEN + P-Pass.app
      bundle. Found & fixed on the way: CGNAT (Tailscale) address
      pollution filtered from announcements, provider waits online
      before announcing, backup.commit auto-retries (idempotent resume)

## M2 — Android app / 手机端 ⬜

- [x] T-050 Gradle skeleton + proto Kotlin mirror, drift-checked against
      the same insta snapshots the Rust suite asserts (24 JVM tests +
      debug APK in CI)
- [x] T-051 iroh-ffi transport wrapper: DaemonClient (ctrl-plane call
      per bi-stream), frame codec + PeerAddr/QR parsing drift-checked
      vs Rust snapshots; **live hello vs a real daemon green on the
      desktop natives** (`just android-hello`)
- [x] T-052 pairing by camera scan: CameraX+ZXing (GMS-free, HarmonyOS
      compatible), persistent device identity, design-system onboarding
      (welcome/scan/joined); wire-level pairing proven live against a
      real daemon (`just android-pair` → PAIR OK); real-device walkthrough
      pending user test
- [x] T-053 MediaStore enumeration + generation watermark (API 30+
      GENERATION_MODIFIED, DATE_ADDED fallback); BLAKE3 in Kotlin
      pinned bit-for-bit to Rust vectors (tests/blake3-vectors.json)
- [x] T-054 upload pipeline: authz-gated push plane (ppf/upload/1),
      BackupRunner scan→hash→manifest→push→commit→watermark; live
      BACKUP OK 12/12 + idempotent rerun 0 pushed (`just
      android-backup`); **real-device PASS 2026-07-31**: Samsung S24 UI
      flow scan→pair→Back-up-now, 15 real photos landed on the Mac
      (screen: "All photos are backed up / 新存 15 张"); HarmonyOS phone
      paired too. **T-054b auto-backup PASS**: periodic work (charging+
      WiFi, 4h) + catch-up run on every app open, dataSync FGS while a
      batch runs; real-device proof — 3 photos adb-pushed into the
      gallery arrived on the Mac with no button pressed (15→18)
- [x] T-055 core: two-tab shell (Photos/Backup), timeline grid +
      1024 viewer over timeline.page/thumb.get, reconnect entry;
      **real-device grid PASS** (Samsung shows the Mac library, 20
      items). Polish pass pending: single-language UI (user ruling),
      month sections, width/height in ingest, entry styling
- [x] T-056 video playback: download plane (ppf/download/1, viewer+,
      bit-identical round-trip tested) → cache → VideoView; timeline
      routes video taps to the player. Streaming DataSource → M3.
      **Real-device PASS 2026-08-03**: the tap-to-play last mile caught
      a real routing bug (wire media_type is normalized "video"/"photo",
      Kotlin matched "video/" — every video opened the photo viewer);
      fixed, Samsung now plays the user's own 7/31 recording pulled
      from the Mac library. Known debt: video thumbs fail on the daemon
      (thumb_state=2 → gray placeholder tiles)
- [x] `just verify-m2` ALL GREEN 2026-08-03: 185 Rust tests + Android
      unit suite + debug APK + live hello/pair/backup scripts
      (BACKUP OK 12/12, idempotent rerun 0). Fixed on the way: the
      throwaway-daemon scripts inherited the user config's fixed port
      41145 and collided with the resident daemon — scripts now pin
      PPF_BIND_ADDR=0.0.0.0:0
- [ ] **Gate: one week of real family dogfood, 100 % backup completion**

## M3 — Hardening / 硬化 🔶 (code landed 2026-08-01~02; acceptance
gated on review-fix cards — see [m3-review-fixes.md](m3-review-fixes.md))

- [~] T-070 failure scenarios automated — code landed, acceptance
      pending **T-070b**; **T-070b code landed 2026-08-03** (disk_full
      proves ENOSPC + payload > tmpfs, crash_recovery polls blob
      landing instead of sleep + cleanup trap, clock_jump asserts the
      production TOKEN_TTL_MS + param-safe QR parse, revoke renamed
      revoke_before_commit, testclient prev-read scoped to small-file
      branch, shared tools/ipc-lib.sh) — 2 in-process scenarios green
      locally; disk_full CI green + fault-inversion proof pending
- [~] T-060..T-064 cloud workers + self-host compose + relay scripts —
      workers landed; **T-060b code landed 2026-08-03** (alarm
      starvation fixed via getAlarm check + re-arm, duplicate live-hash
      POST → 409, honest threat model in README/comments, 4 new tests —
      11/11 vitest + typecheck green); **T-063b DONE 2026-08-03** (real
      VPS closed loop: .env bootstrap, Manual certs via certbot,
      CMD-SHELL healthcheck on /healthz, glibc relay image — official
      musl image panics on QUIC, now fetched+sha256-pinned at build
      time; ufw actually enabled; dogfood-smoke green via self-hosted
      relay)
- [ ] H-07 self-hosted relay A/B (**priority raised** — unshipped relay
      domains proven harmful in dogfood smoke); merge T-063b into this
- [~] T-071 release workflow + attestation — pipeline runs end-to-end
      (draft v0.2.0-test.1), acceptance pending **T-071b** supply-chain
      hardening; **T-071b code landed 2026-08-03** (job-scope secrets
      dropped to the two signing steps, every action SHA-pinned,
      per-job minimal permissions, VT gate hoisted to job env, release
      assets via create-then-upload with SHA256SUMS as asset,
      signed=yes reflects notarization, actionlint in pr.yml) —
      actionlint green locally; tag-build end-to-end acceptance pending
      (CI); no user-facing release before T-071b green
- [~] T-072 i18n completeness + AV-block guide — landed; **T-072b
      docs DONE 2026-08-03** (blocked-by-av + windows-smoke now bilingual
      en-primary, phantom exe ref removed, executable `gh attestation
      verify` step added; relay README drift already fixed in T-063b —
      merged 2026-08-03); desktop badge regressions landed in
      **T-042b 2026-08-03** (desktop-perspective diag keys,
      placeholder-free badge, full-screen i18n, wizard prefills existing
      config, token discovery via platform data_dir for Windows,
      src-tauri tests in temp dir + wired into CI, StringsSymmetryTest
      real XML parser — vite build + src-tauri 2/2 + diag 8/8 + Android
      strings green; three-state walkthrough pending user pass)
- [x] T-061b telemetry fixes — **DONE 2026-08-03** (doubles fixed
      per-event columns so double2 has stable meaning; only POST /ingest
      accepts batches; 14/14 vitest) — **T-061b-fix** closes the
      deployment gap: compiled-in default telemetry URL now carries
      `/ingest` (asserted in config tests), toDataPoint switch is
      exhaustiveness-guarded with assertNever (negative-tested), stale
      header comment fixed — review PASS (claims independently re-run)
- [x] T-062b update artifact verification + pinned pubkey — **DONE
      2026-08-03** (verify_artifact hash+sig enforcement; sha256 64-hex
      parse check; signature required non-empty; OFFICIAL_PUBLIC_KEY
      constant + existence test; tamper test rewritten; manifest example
      covers all 5 platforms; 19/19 tests green — review PASS, two
      non-blocking notes on the T-071 real-key follow-up)
- [x] H-09 Windows smoke — **DONE 2026-08-03**: H-09b code (tautology
      idempotency check fixed, revoke hard-fails, IPC Resp asserted,
      try/finally daemon cleanup, ExitCode handle cache; attribution
      corrected: bare pipe name = .NET ctor contract) + **H-09b-verify
      real-box PASS** (Win10 22H2 / PS 5.1: full run ALL GREEN, then
      two fault-inversions both red — idempotency pattern falsified →
      step 3 red, revoke call removed → step 5 red — restored
      byte-identical). Follow-up: bin-win-x64 branch re-syncs
      win-smoke.ps1 on next artifacts run
- [ ] H-10 naive-user onboarding line (quickstart docs → cold-start
      walkthrough → human-grade release assets) — **H-10a quickstart
      reworked 2026-08-06 (PR #26)**: README en+zh "Get started in 10
      minutes" now references real v0.2.1-test.2 assets by name
      (P-Pass-macos-arm64.dmg / app-release.apk), Windows section honestly
      states GUI is in development (CLI-only exes today), draft-release
      visibility caveat added — no promises about things that don't exist;
      **H-10c human-facing release assets DONE 2026-08-04 (PR #27)**:
      P-Pass-macos-arm64.dmg (.app + self-contained daemon sidecar +
      lib/) via tools/bundle-desktop-macos.sh + signed app-release.apk
      (CN=HawkeyeXbOrg), both added to Release draft assets; H-10b
      naive-user test pending tag-build acceptance
- [ ] H-10b T1–T7 + fix 批次 — **全部代码已合并 2026-08-08/09（13
      commits，0.3.1 正式发布 `9c66c76`）**：QR 密度瘦身（`&a=`→`&r=` +
      手机手动输入 + QR 刷新 + dmg 拖拽布局）、T1 版本号显示、T3 配对
      token 32B→12B、T4 配对状态机（QR 弹窗化）、T5 审计事件流 +
      activity 页、T6 相册级备份范围、T7 Windows NSIS 图形安装包进
      管线；macOS 签名公证已通（Developer ID）。真机验收待验收（见
      PROGRESS h10b 行）。⚠️ review 实锤问题 → 见下行
- [ ] H-10b review fixes (2026-08-10 巡检轮) — ✅ **PERF-01 hash cache
      DONE 2026-08-10**（android 99/99；千张库分钟级→秒级）；✅
      **FIX-SC1 testclient 解析器跟上 &r= DONE 2026-08-10**（scenarios
      CI 自 8/8 起 15+ run 全红的根因，已修 + 本地 scenarios ALL
      GREEN）；✅ **FIX-T3 QR 升级提示 DONE**（桌面弹窗版本提示 +
      Android 人话错误）；✅ **FIX-T6 范围语义 DONE**（空集=一个都不备
      + 三元组 N/M 同口径，android 107/107）；✅ **IPC-02 事件订阅
      DONE 2026-08-11**（桌面壳告别 3s 轮询）；✅ **SYNC-01 外部删除
      对账 DONE 2026-08-11**；✅ **PRES-01 在线状态三档 DONE
      2026-08-11**（前台 30s 心跳 + 三档在线态 + hello 进活动流 10 分钟
      去重，哨兵 >5 天口径不动）；✅ **DESK-03 桌面照片墙 DONE
      2026-08-11**（本地 IPC 查询平面 + 缩略图墙 + 大图不落盘 + Finder
      揭示，三方对照测试）；✅ **FIX-SC2 DONE 2026-08-11**（本地复现
      restart stall 卡点锁定 Blobs::open → 栈实证 iroh-blobs 0.103
      RtWrapper::drop 错误路径自锁 + harness 锁竞态触发；修复=文件锁
      释放轮询，40/40 压力验证 + 反证完备，卡移 done/）。**v0.3.3-test.1
      prerelease 已 publish**（test 通道返回新 manifest，stable 隔离
      正确）。
- [ ] UPD-01 self-update channel — **code landed 2026-08-04 (PR #30),
      rework 2026-08-05**: release.yml emits tauri-style manifest.json
      (compose via tools/make-update-manifest.mjs — sha256 + Ed25519
      signatures, gated on UPDATE_SIGNING_KEY, uploaded as release
      asset; notes mark unsigned when key absent) + android self-update
      flow (fetch manifest from release latest/download → semver
      compare → dialog → download → FileProvider → system
      PackageInstaller same-signature check; no embedded pubkey needed
      — system enforces it). **Key done (2026-08-04, user authorized)**:
      UPDATE_SIGNING_KEY secret set (tauri signer rsign format),
      update.rs OFFICIAL_PUBLIC_KEY real-key swap (tamper-rejected
      tests green), desktop tauri-plugin-updater wired (pubkey =
      .pub full content, createUpdaterArtifacts, updater:default
      capability, Svelte check dialog). **UPD-01 rework items**:
      i18n bundle drift fixed (ui.update_* keys synced to Android
      assets, zero-drift test green), android downloadAndInstall now
      suspend+IO (was main-thread network swallowed), App.svelte 404
      now silent (check errors never surface; only install errors
      show), npx @tauri-apps/cli pinned to 2.11.4, RELEASING.md §3.5
      documents update channel + darwin/windows gaps, ROADMAP wording
      updated. Tests: UpdateCheckerTest 6/6 + android suite green.
      **UPD-01c rework 2026-08-05** (i18n registration blocker): the
      ui.update_* keys were in all four dictionaries but never
      registered in crates/diag/src/keys.rs — diag test panicked
      "unregistered key". Registered UI_UPDATE_AVAILABLE /
      UI_UPDATE_INSTALLED / UI_UPDATE_FAILED into ALL (len 61→64);
      all four jsons (root en/zh + android copies) now match ALL
      byte-for-byte. Counterproof: deleting ui.update_failed from
      en.json → all_keys_translated_in_en_and_zh FAILED (lib.rs:32),
      restored → green. diag 8/8, android 55/55, workspace 200/200.
      Branch CI green (pr.yml all jobs) after push. Drive-by: same
      ipc_flow.rs harness race fix as DOG-01c (flake on main's tree).
- [ ] E2E-01 android live scenarios in CI — **code landed 2026-08-04
      (PR #28)**: .github/workflows/e2e.yml — nightly cron (03:30 UTC) +
      release tag 时并行跑（**2026-08-04 用户裁决：自动化测试不前置**——
      原 release 构建前门禁撤掉，tag 触发与 release.yml 并行、产物照出，
      e2e 结果供发布前人工核对）+ PR e2e label / manual dispatch;
      every-commit never triggers. android hello/pair/backup scripts
      tightened to PPF_BIND_ADDR=127.0.0.1:0; iroh Maven jar
      confirmed to carry linux-x86-64 natives (JVM tests need no
      simulator). **acceptance PASS 2026-08-04**: run 30886819356
      all-green — HELLO OK / PAIR OK / BACKUP OK (pushed=12 ingested=12
      rerun dup=12) in logs; negative: hello capabilities broken
      (thumbnail.v1→v9) → AssertionError DaemonHelloTest:28, run
      30887278528 red, reverted. CI-found fixes: JDK 21 (iroh uniffi
      classes are major-65 bytecode), Linux abstract-namespace IPC in
      DaemonPair/DaemonBackupTest, PID-exact daemon cleanup in scripts.
      Known pitfalls (JDK17 必炸 / GenericNamespaced 平台差异) →
      references/desktop-build.md 与本文档
- [ ] DOG-01 backup triplet + per-device watermarks — **code landed 2026-08-04 (PR #33)**:
      android TripletStore persists last-success {N photos, M backed up,
      K to go, last_success_at} (crash-safe tmp+rename, survives app kill;
      shown from cache when offline — K=N-M, never negative); daemon
      `device.watermarks` IPC + sqlx view (name/last_backup_at/asset_count
      from device+backup_watermark+asset.src_device). Tests: storage 2 +
      TripletStore 6 (incl. counterproof all-missing → K=N), android
      55/55, workspace 195/195. Device-side acceptance (Samsung kill+reopen,
      offline reopen, dumpsys-style sqlite cross-check) pending real phone.
      **DOG-01b rework 2026-08-05** (incremental-as-total blocker): N/M no
      longer come from the single-run report — ConfirmedStore state cache
      key=(hash, remote_id) in per-remote dir (backup-state/<nodeId>/,
      crash-safe, survives app kill), M = confirmed count, N =
      MediaScanner.countAll() (MediaStore COUNT(*) over the scan scope,
      scope constant in one place), K = N-M clamp; manifest-missing
      calibration (BackupReport.missing) removes drifted hashes from the
      cache, confirmed candidates added — wired in both manual and
      WorkManager paths. Regression test: full 100 → incremental 5 two-run
      sequence ⇒ N=105 M=105 (not N=5); counterproof cleared-cache all-
      missing ⇒ M=0 K=N. android 55/55, storage 12/12 (watermarks
      retained-item re-verified).
      **DOG-01c rework 2026-08-05** (missing 时序错位 blocker): recordRun
      no longer subtracts report.missing — it is the **pre-upload**
      manifest answer, so after a successful commit every candidate is
      confirmed (confirmedAfterCommit; regression test first-run 100 all-
      missing ⇒ M=100, counterproof reverted old semantics ⇒ red).
      Drift calibration decoupled from backup runs into a read-only
      exist-check (BackupRunner.existCheck: begin+manifest, no push/commit)
      removing daemon-side-deleted hashes (removeMissing; cache 100 → 30
      missing ⇒ M=70). Wired in BackupUiStateHolder (app-open + before
      manual backup) and BackupWorker (before run). android 56/56,
      workspace 200/200. Device acceptance (Samsung) still pending real
      phone. Drive-by: ipc_flow.rs harness race fix (token file written
      before socket bind ⇒ ENOENT under parallel load; poll the connect).
      **DOG-01d hotfix 2026-08-06** (Samsung first-launch FATAL, blocks
      dogfood): countAll's `COUNT(*)` projection is rejected by the real
      MediaStore provider (Invalid column count(*) — scoped storage
      forbids SQL functions in projections); refreshTriplet runs at
      startup with no guard ⇒ every device with photos crashed on open.
      Fix: projection narrowed to [_ID] + cursor.count; Throwable-level
      guard in the production function computeTripletSafe (what
      refreshTriplet calls — tests go through the call chain) degrades
      any media/confirm-store failure to "triplet hidden" (null), never
      crash. Counterproof test: failing query ⇒ null triplet, no throw.
      android 74/74. Real-device startup acceptance pending reviewer.
- [ ] REL-01 versioning & release norms — **code landed 2026-08-04
      (PR #29)**: docs/RELEASING.md (en primary + zh; trunk-based:
      main always releasable, tag=SemVer release, hotfix-only
      release/vX.Y, draft→human publish, bump+changelog per release,
      never overwrite/move tags) + CHANGELOG.md init (keep-a-changelog,
      all-unreleased until first formal release) + tools/bump-version.sh
      (one-shot Cargo.toml workspace version ↔ Android
      versionName/versionCode; versionCode monotonic +1; overwrite
      guards: rejects already-tagged versions, non-strictly-increasing
      versions, invalid SemVer) — five-state test PASS: bump 0.3.0 ok
      (diff touches version lines only), v0.2.0-test.7 rejected, 0.3.0
      equal rejected, 0.1.0 downgrade rejected, "1.2" rejected; **BUMP-01
      (2026-08-06, fix/bump-01-lock-sync)**: script now runs
      `cargo update -w -q` after editing Cargo.toml (workspace-member
      versions in Cargo.lock stay in sync — TAG-01 0.2.1 had to be fixed
      by hand in 6bb3239) + asserts `git status` is clean except the
      version files (Cargo.toml / build.gradle.kts / Cargo.lock / the
      script itself), failing the bump otherwise — counter-proof: with
      the sync step removed, the first cargo command after a bump dirties
      the lock (10 member version rows 0.2.1→0.2.2)
- [ ] DOG-02 battery-whitelist onboarding — **code landed 2026-08-04 (PR #31)**:
      PowerManager.isIgnoringBatteryOptimizations detect + backup-tab
      guidance card (disappears once whitelisted, ON_RESUME refresh) +
      vendor intent fallback chain (REQUEST dialog → Samsung Smart
      Manager → Huawei phone manager → generic list). strings en/zh
      symmetric (StringsSymmetryTest enforced), 49/49 unit tests green.
      Device-side acceptance (dumpsys whitelist before/after + adb
      whitelist-removal counterproof) pending real phone
- [ ] DAE-01 daemon resident discipline — **code landed 2026-08-04 (PR #32)**:
      single-instance claim replaces unlink-before-bind (probe → version
      handshake, newest wins; equal/older stands down, newer takes over +
      re-installs autostart), status() now reports version/pid/started_at/
      exe_path, install_autostart rejects /target//tmp/ paths. version_cmp
      unit tests + dae_flow integration (3 tests: takeover/stand-down/dead
      socket) + counterproof (reversed compare → 2/3 red, reverted).
      workspace 197/197 green. **DAE-01b rework 2026-08-05**: claim reads
      the predecessor's token from data_dir/ipc.token (never probes with
      its own fresh token); raw-connect pre-check + unauthenticated live
      peer ⇒ StandDown (never unlink a live socket); tag-injected
      PPF_BUILD_VERSION via build.rs + version_cmp pre-release numeric
      segments (test.8 > test.7) so dogfood test packages can take over;
      daemon_version() single source for handshake/status/telemetry
- [ ] DAE-02 daemon residency follow-up — **code landed 2026-08-06 (PR #44)**:
      defect① KeepAlive churn — plist `KeepAlive=<true/>` relaunches a
      stepped-down instance (exit 0) every ~10s forever; switched to
      `<dict><key>SuccessfulExit</key><false/></dict>` (clean exit not
      relaunched, crash/signal still revived — pkill regression kept).
      defect② QUIC bind before version handshake — a fixed-port config
      makes the newer instance die on bind while the incumbent holds the
      port, so the takeover never runs; claim moved BEFORE transport bind,
      node id pre-derived from identity.key via transport::
      node_id_from_secret_key (no endpoint needed), then bind + drift
      check. Tests: fixed-port takeover integration (claim without bind
      while port held → TookOver → incumbent exits → rebind same port
      succeeds), node-id-from-secret == bound endpoint, plist
      SuccessfulExit assertion; dae_flow 5/5 + workspace 209/209 green.
- [x] DAE-03 daemon CLI discipline + humanized errors — **code landed
      2026-08-13**: 8/6 `daemon --help` mis-takeover incident's 3 gaps —
      ① `--help`/`-h`/`--version`/`-V` parsed first and short-circuit
      (exit 0) before any daemon machinery (logs/config/db/identity/
      claim/bind); unknown args → error + usage, exit 2 — never silently
      ignored (the incident root cause). ② autostart install decision
      extracted to pure fn `cli::autostart_install_required` (TookOver
      only; fresh start / stand-down never touch launchd/registry) +
      unit test. ③ fixed-port bind failure humanized: address-in-use →
      Chinese guidance (another P-Pass identity or third-party holds the
      port; change config.toml bind_addr or close the holder), raw error
      kept in logs; non-in-use errors pass through untranslated. New
      crates/daemon/src/cli.rs (pure fns, 8 unit tests) + tests/
      cli_flow.rs (binary smoke: --help exits 0 with no IPC/identity
      side effects, --version prints version, --bogus exits 2 with
      usage). Counterproofs: silent-ignore → daemon actually starts on
      --bogus (incident reproduced, test hangs/red); constant-true
      autostart → red; loose "use" substring → red. workspace 286/286 +
      arch-check + clippy zero warnings + fmt clean.
- [ ] **Gate: 5–10 household private beta, 2 weeks**

## M4 — Launch / 发布 ⬜

- [ ] T-073 one-page site + README polish
- [ ] r/selfhosted post, open-source announcement
- [ ] **Kill line: no exponential signal in 3 months → stop** (pre-agreed)

## MOB 移动端批次（2026-08-11 三星真机反馈驱动，队列按 MOB-01 → MOB-02 → UX-08 → REL-02 → DEV-01）

- [x] MOB-06 查看页右上角「分享」 — **2026-08-12（用户询问「分享 vs 用其他
      应用打开是不是一回事」，待推 main）**: 不是一回事——分享=`ACTION_SEND`
      （文件作为内容/附件发给目标 app，分享面板：微信/邮件/云盘）；
      打开=`ACTION_VIEW`（目标 app 以打开模式处理文件，打开方式选择器）。
      底层共用 FileProvider + FLAG_GRANT_READ_URI_PERMISSION + 临时文件即用
      即清。实现：`AssetActions.shareIntent` + 自绘 ic_share.xml + 照片/视频
      查看页右上角分享图标 + 动作枚举化（三动作共享下载管线）。android
      166/166 绿。挂账：真机分享到微信收到原图 + share 目录零残留（用户）。
- [x] UX-11 daemon 请求无超时（真死机永久卡 loading） — **2026-08-12
      （用户真机反馈，L1 严重，待推 main）**: `DaemonClient.call`/
      `connectRaw` 加 15s 超时（自定义 `DaemonUnreachableException`，
      故意不继承 `CancellationException` 避免被暂停语义误吞）。
      android 全量单测绿。挂账：真机确认（用户，该机当前正好桌面服务
      已停）。
- [x] UX-12 设置页规则卡行高/间距统一 — **2026-08-12（用户走查反馈，
      待推 main）**: Switch 行与文字行统一 `heightIn(min=56dp)`，
      规则卡整列加 8dp 上下 padding。android 全量单测绿。挂账：真机
      视觉确认（用户）。
- [x] UX-10 相册选择页封面缩略图 — **2026-08-12（用户产品反馈，待推 main）**:
      `MediaScanner.Bucket` 加 `coverUri`，`BucketScreen` 每行加 48dp
      封面（API 29+ `loadThumbnail`）；复用 `PhotosScreen.thumbCache`
      而非新开缓存（撞过一次 CacheRedlineTest 红线，改代码不改测试）。
      android 全量单测绿。挂账：真机视觉确认（用户）。
- [x] UX-09 备份/照片 tab 三处走查反馈 — **2026-08-12（用户真机反馈，待推 main）**:
      「立即备份」点了没反应（statusLineOf 早算好的 Pending/AllSafe
      裁决从未接上 UI）+ hero「选择相册」大按钮降权（设置卡已有等价
      入口）+「备份」tab 改名「设置」+ 照片 tab 前台轻量轮询（停留期间
      每 15s 补新照片，之前零刷新触发点）。android 全量单测绿。
      挂账：真机四项验收（用户）。
- [x] MOB-05 部分授权误判死循环修复 — **2026-08-12（用户真机报告，待推 main）**:
      MOB-02 的 `isPartialMediaAccess` 判定式写反——真机上
      `READ_MEDIA_VISUAL_USER_SELECTED` 授予后不随升级到完整授权被撤销，
      旧式 `imagesGranted && visualSelectedGranted` 几乎恒真，把完整授权
      误判成部分授权，用户永远进不了相册选择页、选择被静默丢弃。改为
      `!imagesGranted && visualSelectedGranted`（与官方检测顺序一致）。
      android 全量绿（TriggerPolicyTest 11/11）。挂账：真机确认死循环解除
      （用户）。
- [x] MOB-01 全页面安全区适配 — **merged 2026-08-11 (8d0b4b4)**:
      三星真机内容被导航键遮挡/顶到状态栏。根因 targetSdk 35 强制
      edge-to-edge 但零 insets 处理。enableEdgeToEdge + PPScreen 统一
      容器（safeDrawingPadding 一处封装全页面套用，手势/三键导航天然
      区分），系统栏图标深浅随背景亮度切换。android 107/107 + CI 绿。
      挂账：模拟器三键/手势逐屏截图 + 三星真机复核（验收人）。
- [x] MOB-02 备份触发模型重构 — **merged 2026-08-11 (e3931ba)**:
      用户定稿（L2）：事件驱动替代手动按钮——首页主按钮删除、四触发事件
      （选完范围/新照片 ContentUriTrigger 连拍聚合/周期 6h 兜底/进前台
      >24h）、两档条件（用户在场只查 Wi-Fi/后台全查）、部分授权引导不落
      死局、失败短退避重试 2 次后放弃、新相册默认不包含+「新」徽标。
      android 121/121 + CI 绿。挂账：模拟器 onboarding 截图 + 三星真机
      全流程/连拍 20 张只触发一次/部分授权观感（验收人）。
- [x] UX-08 配对确认列表化 — **merged 2026-08-11 (07cd1b9)**:
      多台同时扫码 → pending 全量列表一屏列出，逐行允许/拒绝，全清后
      关闭无残留（daemon 只读 pairing.pending + confirm 带 device_name）；
      提示条 5s 自动消失 + × 手动关闭。ipc_flow 8/8 + vite build 绿。
      挂账：3 台同时扫码真窗口逐行处理截图 + 提示条实机观感（验收人）。
- [x] REL-02 更新双通道 — **merged 2026-08-11 (96c61ae + 8b5362c)**:
      test tag 自动 publish 为 prerelease（latest 天然忽略，不漏 stable）；
      Worker 代理 test 通道 manifest（GitHub API 限流 60/h/IP，客户端不
      直连，300s 缓存）；Android 设置页通道切换（默认 stable，stable 原
      URL 单测锁死）；桌面设置页通道 + 壳内检查 + 下载页（tauri updater
      静态 endpoint 硬约束）。android 124/124 + vite build 绿。
      挂账：Worker 部署（ppf-ops）+ 发 prerelease/正式 release 双端对照
      + 篡改签名拒绝（验收人）。
- [x] DEV-01 身份保全+重配对合并（A 档）— **merged 2026-08-11（本 commit）**:
      重装/清数据后旧设备变僵尸行的根治。两段：①pair.request 加可选
      device_hint（SHA-256(Build.MODEL+ANDROID_ID) 前 8 字节 hex，免权限、
      不进 QR、不作凭据；Android 设置页「重装识别」开关默认开，关掉不
      发 hint 行为回到现状）；②owner 确认框发现存量同 hint 设备 → 多一组
      选项默认「替换旧的 <名字>」（继承名字/备份记录/水位，asset 归属
      迁移 + watermark 取 max + 旧行删除 + 审计 device.merged），另一项
      「作为新设备」= 与现状一致。反证：合并后旧 NodeId backup.begin 被拒。
      proto 金样本新旧帧互解（旧帧无 hint 字节不变）。daemon/storage/proto
      全量绿（含 3 个新集成测试）。
- [x] ICON-01 图标接入双端构建 — **merged 2026-08-11（本 commit）**:
      屋脊兽图标从设计归档变正式构建资产。版本分工（用户钦定）：主图标=
      碳纹版（macOS .icns 全档位/Windows .ico 6 档/Android 自适应前景）；
      ≤40px/托盘/通知=beast 全实线版（16px 碳纹糊成灰已视觉实证）；macOS
      托盘=模板图标（纯黑+alpha + icon_as_template）。Android 前景层分密度
      PNG（VectorDrawable 不支持 pattern），Manifest 接 android:icon。
      生成脚本 scripts/icons/generate.sh 幂等（67 产物两次跑字节一致）。
      桌面 cargo check 绿 + Android assembleDebug 绿（验收中）。

## SYNC 批次（2026-08-11 三星真机反馈驱动：Finder 删文件 ≠ 手机时间线消失）

- [x] **REV-01 SYNC-03/04 review 遗留 5 项 — merged 2026-08-13（本 commit）**:
      另一 agent review SYNC-03（QUIC 订阅登记表）/SYNC-04（Android 前台
      订阅）代码时发现的 5 项 backlog，用户当时本地无手机直连改排本卡。
      ①`serve_subscription` register 提到 ack/initial push 之前，吊销
      窗口覆盖整个订阅生命周期；②**真 bug**——60s 兜底轮询误用整页覆盖
      语义打断翻页/逐出已翻页缩略图缓存，改回旧版「仅追加」语义，订阅
      信号（整页覆盖，删除可见性核心）与兜底轮询（仅追加，只防丢事件）
      两职责分开；③新增 `device_revoke_over_ipc_closes_the_quic_subscription`
      （Router+IpcServer 共用同一份登记表，走完整 IPC JSON 链路，反证
      已跑确认变红）；④订阅 effect 两处补 `CancellationException` 前置
      重抛；⑤`wasLive` 计时起点从 effect 开始改为连接真正建立那一刻。
      daemon 全量绿 + arch-check + clippy 零警告 + fmt 干净，android
      166/166 绿。不涉及真机验收，SYNC-04 五条真机剧本挂账状态不变。
- [x] **WATCH-01 本地目录监听 + 增量同步 — merged 2026-08-12（本 commit）**:
      metadata 秒级更新的第一跳（此前本地新增只有 backup 协议入口、
      删除靠每小时 reconcile——用户实测 metadata 不及时踩坑）。notify
      监听 `originals/` 树 + 500ms 防抖（静默窗口 Reset）+ 父路径合并
      （旧版 filterParentPaths 平移）+ 增量扫描：新文件 ingest
      （src_device=本机 node_id，审计记本地导入；hash dedup 幂等——
      ingest 自产事件二次扫描 = Duplicate 跳过）；删除走局部对账
      （`list_asset_paths_under` SQL prefix + `Reconcile::remove_asset`
      复用，thumb/审计口径只此一份）；变化经 `Throttle` 合并 emit
      `timeline.invalidated`（SYNC-02/03/04 链路全通）。每小时全量
      reconcile 保留兜底。事件风暴策略：防抖吸收批量、.ppf 在监听树外
      天然排除、ingest 并发 Semaphore(4)、单文件失败不中断整批、
      watcher 启动失败降级对账。macOS 坑两则：FSEvents 返回真实路径
      （/var→/private/var），监听根必须 canonicalize；同批次 Create+
      Remove 合并成无事件（测试显式等批次 flush）。watcher 6 单测 +
      watch_flow 4 集成测试（真实 notify）全绿，daemon/proto/core-index
      全量绿 + arch-check 绿 + clippy 零警告。挂账（真机）：Finder 放
      照片→手机时间线秒级出现；Finder 删照片→手机时间线秒级消失。
- [x] SYNC-01 外部删除对账 — **merged 2026-08-11（本 commit）**:
      幽灵照片根治。daemon 启动 + 每小时 re-diff 磁盘 originals ↔ asset
      索引：磁盘上没了的条目清 asset 行 + thumb 文件 + 审计
      asset.removed_external（actor=NULL 如实记，不背锅给文件系统）。
      低频轮询论证在 reconcile.rs 模块注释（vs FSEvents/inotify 双平台
      复杂度）；blob 不删（iroh-blobs 0.103 无公开 delete API，孤儿 blob
      内容寻址惰性无害，空间回收另立卡）。storage 只增两方法不改既有
      语义；集成测试走真实 upload 链路 5 入 2 删 3 剩（干净盘 no-op 反证
      + 对账前索引仍 5 反证 + 索引/thumb/audit/timeline 四断言）。
      Rust 全量 234/234 + arch-check 绿。挂账：三星真机对账后时间线
      收敛 + 手机 exist-check 回落链（验收人）。

## IPC 批次（2026-08-11 用户裁决：轮询是「体验、实现、内存都不友好」）

- [x] IPC-02 IPC 事件订阅 — **merged 2026-08-11（本 commit）**:
      桌面壳告别 3s 轮询。daemon 事件总线（broadcast，4 事件）+ IPC
      `events.subscribe` 长连接（newline JSON 事件帧，types 过滤，
      unsubscribe/断开即关）；触发点接真实变化处（pending 入队/出队、
      backup commit、unpair、revoke、配对落定）。桌面壳 setup 启动
      订阅线程（2s 退避自动重连，老 daemon 静默降级）+ 前端事件驱动
      刷新；轮询降级 60s 兜底对账。ipc_flow +3：订阅后配对请求 →
      pending_changed <100ms（实测 36ms）；类型过滤反证；unsubscribe
      反证。Rust 全量 237/237 + vite build 绿。挂账：扫码即时切弹窗/
      断线重连恢复/兜底轮询可用（验收人）。

## UX micro-cards（NEXT.md 第四节尽量项；产品输入 docs/product/2026-08-04-experience-gaps.md）

- [x] T-080 Android 两 tab 对齐布局 v1 — **merged 2026-08-06 (4bc62071)**:
      照片页=统一时间线头部+全部/仅本机/家人的过滤胶囊；备份页=恒真三元组
      英雄卡+备份规则卡+失败才说话+底部红字断开。修两个真机实锤缺陷：
      ①待备份>0 时横幅仍说「照片都存好了」（裁决纯函数 statusLineOf 锁死，
      「都存好了」文案 state_safe 独占）②从未成功备份渲染 epoch 0 假日期
      （ts≤0→「还没有成功备份过」）。BackupStatusTest 6/6+反证红过；
      模拟器视觉验收过（设计规范 docs/design/2026-08-05-layout-v1/）。
      挂账：按人过滤需 proto owner 字段；网格 ↑/↓ 角标需本地×远端时间线
      合并；新文案待收编 assets/i18n。
- [x] T-090/T-091/T-092 链1数据面（daemon IPC + 桌面接线） — **merged 2026-08-06**:
      daemon 暴露 photo_count/磁盘水位（statvfs）/activity.list（asset 表
      窗口函数聚合，不建新表）/devices.list.connection（iroh 路径状态在
      transport 内包成中性 enum，B.1 门禁绿）；桌面接 watermarks/last_seen/
      connection/活动批次/照片总数/磁盘条，哨兵>5天亮红（红>连接态）。
      三卡 22+28 断言脚本+82 rust 测试全绿，各带反证红；常驻 daemon 已
      升级 v0.2.1（launchd 稳定路径受监护，NodeId/配对未变），真数据实测
      photo_count=51、SM-S9210 批次上屏。挂账：设备行机型前缀（daemon 未
      暴露机型）、活动页周统计胶囊、90 天保留策略。
- [x] T-082 桌面 UI 还原走查修复 — **merged 2026-08-06 (6f4efb97)**:
      真窗口走查后修 7 项走样：窗口 1140×720+min 920×600、两卡等高
      (stretch)、QR 148×148 居中 2x、:focus-visible 墨色描边（灭系统蓝圈）、
      设备行两行结构（role 字串不再渲染）、已移除设备折叠（划线规则删除）、
      水位卡文案补全。DOM 断言+反证红过；验收人重建+diff 抽检过。
- [x] T-083 Android UI 还原走查修复 — **merged 2026-08-06**:
      全态走查（含假配对逼出的失败态）后修 5 项：删「已连接存储端」副标题、
      hero 底部按设计重构（灭「立即备份」黑按钮，空闲=弱文案+白底描边
      「现在备份」）、红卡去代码化（原始 IrohError 只进默认收起的「查看
      技术详情」+Log.e 诊断路径，正文单语先说「照片一张没丢」）、哨兵态
      主按钮「重新扫码连接」、失败卡主按钮「再试一次」断点续传。
      89 tests 0 fail+反证红过；模拟器视觉复核（空闲/失败/详情折叠）通过。
      范围偏差已审：BackupUiStateHolder catch 块仅文案装配改 raw-only。
- [x] T-081 桌面端侧边栏四页 — **merged 2026-08-06 (e56b1ec5)**:
      单页长滚动→侧栏四页（总览/家人与设备/活动记录/设置，照片库并入
      设置），hash 路由默认总览；徽章只说服务状态，连接状态下沉设备行；
      危险操作只在桌面。纯 UI 重排，IPC 调用集合逐字未变（验收 diff 比
      对过）。挂账：设备行连接事实/活动记录流/照片总数/磁盘水位需 daemon
      IPC 扩展；新文案硬编码待 i18n 收编。

- [ ] UX-07 daemon --ephemeral — **code landed 2026-08-05 (PR #41)**:
      test/script mode: stdin EOF exits the whole daemon in <3s (oneshot
      from the stdin reader loop, tokio::select! vs router.serve, explicit
      endpoint close to flush frames — drop cleanup alone is ~6s). No
      flag = unchanged (EOF still only drops console confirm to IPC-only,
      launchd residency intact). dogfood-smoke.sh switched to --ephemeral
      + FIFO stdin (cleanup closes write end → self-exit + wait, replaces
      kill). EOF→exit 2.37s measured; full dogfood-smoke ALL GREEN with
      zero daemons left after run; fmt/clippy clean.
- [ ] UX-01 备份中可暂停 — **code landed 2026-08-05 (PR #35)**: backup
      button becomes 暂停 while busy and stays clickable — tap cancels the
      current batch (BackupUiStateHolder tracks the job; BackupRunner push
      loop got a cooperative ensureActive() cancel point). Idempotent
      pipeline makes interruption safe: no commit, watermark not advanced,
      next run re-offers everything and dedups. strings en/zh symmetric
      (backing_up → backup_pause). android 49/49. Device acceptance
      (Samsung pause→resume converges to 0 missing; counterproof: sqlite
      has no half-written asset rows — guaranteed by ingest-at-commit)
      pending real phone.
- [ ] UX-02 失败通知，成功沉默 — **code landed 2026-08-05 (PR #36)**:
      auto backup (BackupWorker) posts a system notification only when a
      batch fails ("N 张照片没备份成功，打开看看", N = batch offered
      count, tap opens MainActivity); success stays silent (FGS
      notification auto-dismissed on completion). Dedicated channel
      ppass.backup.failed; strings en/zh symmetric. android 49/49.
      Device acceptance (mock failure → notification appears; all-success
      → zero notifications via dumpsys) pending real phone.
- [ ] UX-03 后台规则一行+极简设置 — **code landed 2026-08-05 (PR #37)**:
      backup page gets one rule line ("插电+WiFi 时自动备份，无需打开
      App") + two switches (仅充电 / 仅 WiFi). BackupSettings persists
      to filesDir JSON (tmp+rename, corrupt→defaults, JVM-tested);
      WorkManager constraints are built from the settings; flipping a
      switch saves + rescheduleAutoBackup (REPLACE — KEEP never updates
      existing constraints). android 52/52. Device acceptance (dumpsys
      jobscheduler constraints follow the switches) pending real phone.
- [ ] UX-04 「已直连」徽章降级 — **code landed 2026-08-05 (PR #38)**:
      desktop header badge now shows service state only (运行中 /
      后台服务未运行) — the connection state (直连/中继) is gone from the
      badge: ONLINE_DIRECT is the state machine's default, showing it as
      a fact was a lie (product file §二 fact-check). New key
      ui.service_running (keys.rs + all four dictionaries synced);
      STATE_KEYS mapping removed from the badge path (device rows will
      restore it later). diag 8/8, android 49/49, workspace 198/198,
      vite build green. Drive-by: ipc_flow harness race fix (same as
      DOG-01c/UPD-01c — flake on main's tree).
- [ ] UX-05 folder.set 诚实化 — **code landed 2026-08-05 (PR #39)**:
      change-library-location confirmation now states both facts:
      takes effect after the service restarts + existing photos won't
      migrate (new location starts empty; phones back up there from now
      on). Previously "restart" only appeared in the post-save toast.
      ui.change_body reworded en/zh, all four dicts byte-identical
      (zero-drift tests cover). diag 8/8, android 49/49, vite build
      green. Screenshot acceptance pending human.
- [ ] UX-06 暂停自动备份 + 断开连接 — **code landed 2026-08-05 (PR #40)**:
      pause switch cancels the periodic WorkManager job + persists the
      pause (AutoBackupPrefs JSON, tmp+rename, corrupt→defaults);
      app-start schedule/catch-up respects it; manual backup
      unaffected. Disconnect: warning dialog (progress resets, album
      switches storage computer, local photos stay, old computer photos
      stay) → device revokes ITSELF via new wire method device.unpair
      (authz: any paired role, unpaired/revoked denied; router marks
      caller revoked + audit device.unpaired) → hello denied → fresh
      token rejoins (T-041 door) → clear pairing/watermark → Welcome.
      Workspace 202/202, android 55/55, clippy/fmt clean. Device
      acceptance (re-pair after disconnect, jobscheduler pause) pending
      real phone.
- [ ] UX-06b 断开清确认缓存 — **code landed 2026-08-05 (PR #42)**:
      disconnect now also clears the DOG-01 confirmed-cache directory
      for that remote only (filesDir/backup-state/<daemonNodeId>/,
      production fn clearConfirmedCacheForRemote shared with tests),
      so re-pairing to the same computer starts M from 0 instead of
      showing a stale high count after the computer's library was
      deleted. android 73/73. Counterproof: comment out the delete →
      disconnect_clears test red (restored). Acceptance pending review.

## Standing debts / 挂账

- [ ] PPF_ADVERTISE_ADDR (QR carries LAN IP at boot on cloud boxes)
- [ ] blob-store GC (originals currently duplicated in the blob store)
- [ ] background thumbnail batch generation after ingest
- [ ] Windows smoke (T-040 will carry it)

## 链 2 取回/哨兵批次（2026-08-12 实施；语义基准 docs/product/2026-08-11-chain2-decisions.md ①③④⑤⑥）

- [x] RET-01 单张照片取回=使用动作 — **merged 2026-08-12 (4a92aae)**: 查看页「保存到相册」（MediaStore 29+ RELATIVE_PATH/26-28 DATA+扫描广播）+「用其他应用打开」（FileProvider+ACTION_VIEW）；原图按需下载 cacheDir/share 即用即清（MOB-04 红线）；文件头魔数嗅探真实 MIME（纯函数 JVM 可测）；防循环钉子显式断言（存回→再备份→ingested=0 duplicates=12）。android 140/140。挂账（真机）：家人照片保存到相册可见+时间元数据、打开面板+临时目录零残留、断网人话错误。
- [x] SENT-01 手机盯电脑哨兵 — **merged 2026-08-12 (29af0ff)**: 搭后台任务便车（非心跳）记 daemon 可达性；判定纯函数四条件（确认可达过/距今>72h/期间有失败尝试/去重窗口 72h）；「3 天没连上电脑了——照片没丢」走 UX-02 通道 id 2028。android 150/150。挂账（真机）：mock 全失败跨阈值→通知一次不重复、恢复可达清零。
- [x] DOG-02b 契机式白名单提醒 — **merged 2026-08-12 (a0792fe)**: 独立 store + 纯函数五条件（未加白/有失败/≤2天/失败后无成功/去重 72h）；成功一轮清零；通知进 App 见 DOG-02 Home 引导条。android 161/161。挂账（真机）：mock 条件满足→通知+点开引导、加白后不再通知。
- [x] DESK-04 桌面向导低成本对齐 — **merged 2026-08-12 (9072735)**: 文案按产品语言过一遍（去「常驻服务/访达」等词）；step3 接 T4 新配对流（daemon-event 事件驱动 + 3s 轮询兜底，pending 出现即时切确认列表）；全 token 化。vite build 绿。挂账（真机）：三步截图对照、走完向导→扫码→确认列表即时出现。
- [x] CI-01 流水线分块重构 — **merged 2026-08-12 (5b8cb88)**: pr.yml 拆三域 workflow（ci-rust/ci-android/ci-desktop，paths 门控+concurrency 取消，纯 docs 零 CI）；release.yml platforms dispatch 输入（tag 恒全量）；T-070 scenarios 并轨 e2e nightly+tag；CF 联动门控（R2 镜像 ppf-dl/dl.p-pass.hawkeye-xb.com + ci-workers 自动部署，CLOUDFLARE_API_TOKEN 未就位跳过）；CLAUDE.md 底线①口径更新。actionlint 8 workflow 零告警。等用户：GitHub Secrets 加 CLOUDFLARE_API_TOKEN。
- [x] DESK-05 桌面走查反馈三项 — **merged 2026-08-12**: ①向导第一步默认填充路径（`configuredLibraryDir || defaultDir`）+ 路径 ≠ 默认时旁挂「↺ 回到默认」；②活动记录改真表格（设备/事件/时间三列，ingest.* 逐文件行过滤，auditLine 拆 auditWho/auditText）；③照片墙 staleness 修复（activity.appended/device.changed 事件重置 photos 强制重拉——备份落地后照片库立刻出新照片）。vite build 绿。挂账（真机）：向导第一步默认填充观感、活动表格布局、备份后照片墙自动刷新。
- [ ] NAME-01 设备改名（L0 排队尾，可砍）
- [ ] 恢复向导（换机整库恢复）— 后置

## SITE 站点线（2026-08-11 启动；架构档案 docs/product/2026-08-11-site-architecture.md）

> Landing + blog 对外阵地，与 app 主线并行。内容 zh 先行，en 随开源节奏补。

- [x] SITE-01 站点脚手架（landing v1 + blog 骨架 + RSS + GH Pages 部署）— **code landed 2026-08-11**: Astro 5 纯静态，tokens.css 构建期从 tokens.json 生成（脚本断言一致），图标从 docs/design/2026-08-11-icon-v1/ 同步，零 tracker（CI 断言）。site.yml paths 过滤 `site/**` 与主 CI 隔离。挂账：Pages 部署三路由 200 + Lighthouse ≥90 + DNS CNAME 改指 hawkeye-xb.github.io（当前指向旧 p-pass-landing.pages.dev 占位）。
- [ ] SITE-02 首批三篇博文（定位故事 / 图标九轮 / IPC-02 重构）— 草稿完成待用户审稿，审后去 draft 发布
- [ ] DNS: p-pass.hawkeye-xb.com CNAME → hawkeye-xb.github.io（CF zone 65dec62bc61b00e5d22fedc40b774bdc）
- [ ] T-073 one-page site + README polish（M4 原条目，站点线落地后待并轨）

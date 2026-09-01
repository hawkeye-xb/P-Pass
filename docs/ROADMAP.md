# Roadmap / 里程碑看板

> Single source of truth for milestone status. Updated with every card.
> 里程碑状态的唯一权威来源，每张卡完成即更新。
> Detail per card: [PROGRESS.md](PROGRESS.md).

**Now / 当前位置**（2026-08-25）: M0/M1 closed; M2 Android shipped and
in real-device dogfood; M3 hardening code all landed. Launch blockers
cleared (`BLOB-01` disk 2.05x→1.00x, `MOB-19`, `E2E-02`). The critical
path is now **real-device acceptance** — dozens of cards sit at "code
green, owner verification owed". `just ci` green (316 tests, 2026-08-25).
**当前位置**：M0/M1 已收官；M2 手机端已上真机狗粮；M3 硬化代码全部落地。
上线三件必做已清完。**主路径已从「写代码」转为「真机验收」**——几十张卡
停在「代码绿、欠验收人一条」。

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
- [ ] DAE-04 desktop restart button for stale daemon after shell update —
      **code landed 2026-08-13**: after `downloadAndInstall()` replaces the
      .app bundle, the old sidecar daemon keeps running (launchd task
      unchanged, never killed) until reboot — real gap found 2026-08-13
      when the user asked "can auto-update also update the resident
      service?"; no industry shortcut exists (Docker vmnetd / tailscaled /
      Clash Verge Rev all hit the same wall) → manual button, minimal
      scope. Desktop shell adds `restart_daemon_process` Tauri command:
      kill via the same pkill/taskkill as stop_daemon **but never touches
      autostart registration** (uninstall would block respawn; clean
      exit(0) also wouldn't respawn under `SuccessfulExit=false`, so a
      real signal kill is required — step_down/claim machinery explicitly
      not used), Windows has no KeepAlive semantics → explicit one-shot
      respawn after taskkill; then poll status every 500ms up to 12s
      (measured signal-kill respawn is 4–5s), verify the version actually
      changed — silent fake-success forbidden (Clash Verge Rev #5451
      lesson). Button shows in Settings only when the shell's version and
      the daemon's status.version are different releases (core-triplet
      compare, ignoring `v` prefix and `-test.N` suffix so a fresh test
      install never false-positives), hidden otherwise. 4 unit tests for
      the outcome-assembly pure fn + desktop lib 6/6 + diag i18n
      symmetry 8/8 (10 new ui.restart_service_* keys registered) + vite
      build green. Cross-version manual acceptance (stale-daemon
      simulation, broken-sidecar counterproof, normal-scene no-op) hangs
      on the user.
- [ ] **Gate: 5–10 household private beta, 2 weeks**

## M4 — Launch / 发布 ⬜

- [ ] T-073 one-page site + README polish
- [ ] r/selfhosted post, open-source announcement
- [ ] **Kill line: no exponential signal in 3 months → stop** (pre-agreed)

## MOB 移动端批次（2026-08-11 三星真机反馈驱动，队列按 MOB-01 → MOB-02 → UX-08 → REL-02 → DEV-01）

- [x] MOB-19 备份只有一条管线（手动 = 又一种触发方式） — **2026-08-20（代码完成，真机验收 owed）**:
      卡面原方案"照搬 MOB-09 的错误隔离到手动链路"被用户否掉——"你为什么这里
      弄了两条路径去做备份呢？"两份实现必然漂移，MOB-09 只修一份就是证据。
      改为**删掉第二条**：`triggerManualBackup` 入 BackupWorker 与既有五种触发
      并列，手动专属语义靠新增的 `BackupTier.MANUAL`（零约束，唯一不读 settings
      的档——用户定稿"手动能不能在检测-发起之间直接人工点击-发起"）+
      `KEY_FULL_RESCAN`（忽略水位全量重扫）表达。`BackupUiStateHolder` 298→199 行，
      界面状态改由 `uiStateOf(WorkInfo)` 纯函数从 work 的 progress/output 派生
      （worker 新增 `setProgressAsync` 三阶段上报 + `ProgressThrottle` 首末必发）。
      顺带收益：自动备份第一次有了实时进度。MOB-13 那个"全已确认早退+补齐"的
      特例分支随之消失（全量重扫下正常路径就会 recordRun）。
      ⚠️ 真机核实：设置页**早就没有「立即备份」**，`onBackupNow` 只剩「暂停」
      与失败红卡「再试一次」两个触点，`manual_backup_entry` 是死文案——所以本卡
      真正修的是"在失败红卡上反复点再试一次而永远好不了"。
      247/247 + 27 条反证全红。
- [ ] **ARCH-01 备份核心流程：发现队列与严格单张消费** — **2026-08-29 设计收口，待拆实施卡**：单文件是最小交付单位；发现器用复合 DiscoveryCursor 按 500 项窗口原子入队，上传消费者用严格 UploadCursor 单张消费。传输统一为原生 iroh-blobs fetch/resume：Pause 立即停止 fetch、保留有主 partial、只由 Continue 恢复；Wi-Fi/电量/Desktop 等条件进入自动等待，恢复时从队头续传且不消耗失败预算。范围增加延后完整补扫；范围减少经确认替换 ScopeRevision，已获 Desktop 完整保存凭据的项仍确认完成，其他旧未确认项取消并重新发现。Cancel Current Round 在 Pause 后逐页取消本轮全部待传项，取消进行中入队的项也取消；结束后才入队的照片属于下一轮，恢复必须由用户显式重新准入。远端对账独立低频分页，Desktop 外部缺失默认待用户决定，不自动补传或删除手机。下一步按 ARCH-01 拆手机账本、发现器、消费者、原生传输 adapter、partial 生命周期和 UI 卡；中英文设计档、SVG/PNG 图及失败 Case Matrix 已归档于 `docs/design/2026-08-29-arch01-backup-core/`。
- [x] **ARCH-01 旧实现卡/测试冻结** — **2026-08-31**：`MOB-39`、`MOB-42`、`MOB-48` 的旧 TriggerSpec / WorkManager 通道模型已从可接队列移出，禁止按旧卡或旧测试实施；后续仅从 ARCH-01 Case Matrix 重拆并先写新失败用例。旧测试不再把新架构拉回旧管线。
- [x] **ARCH-01 首批 P0 实施卡** — **2026-09-01 ARCH-02～ARCH-05 已完成**：D 账本/发现、C 严格消费者、E 完成凭据/范围竞争、X 取消本轮均已按失败测试落地。ARCH-05 将活动轮次、轮次归属、原子结束、Restore 与 Discard 写入手机账本；目标 10/10、全量 Android JVM 371 tests / 0 failures / 4 skipped、`just ci` 全绿。后续只能按 ARCH-01 已定边界继续拆卡，不重开产品语义。
- [x] DESK-10 「导出日志」不含 daemon 日志，且 daemon 挂了它自己也不工作 — **2026-08-25（commit 1e1359f + 0e0521f，真机确认 owed）· 2026-08-26 真机验收打回脱敏一处、当日补齐（🟡 其余项仍等真机复验）**:
      验收人误装 0.3.0 的包，daemon 因迁移降级反复启动失败，按「导出日志」发来
      求助的 zip **只有 489 字节、一条四天前的 diag 事件**，而真实错误
      （`migration 2 was previously applied but is missing in the resolved migrations`）
      一直躺在 LaunchAgent 的 `.err` 里、重复了 8 次。根因两层：①包里只有
      `diag_events.json` + `devices.json`，没有 daemon 的进程日志、没有版本号、
      没有配置；②`export_logs` 是 **daemon 的 IPC 方法**，daemon 起不来时这个
      按钮压根不工作——而那正是最需要日志的场景。
      修法：新增 `export_logs_bundle`（桌面壳本地组装），收集与落盘拆出
      `assemble_export`，daemon 那部分以 `Result` 传入——**Err 不是失败路径**，
      只是少三份文件、多一份 `daemon-unreachable.txt`，zip 照出。日志路径只认
      plist 的 `StandardOutPath`/`StandardErrorPath`（不硬编码 `~/Library/Logs`）；
      daemon 不可达时版本号问内置服务 `--version`（真机事故里正是这一句拿到真相）；
      daemon 侧 `export_logs` 补 `audit.json`；脱敏加长 hex 掩码（NodeId/配对令牌
      只出前缀），新加的文件全过同一道 scrub。文件名与落盘位置不变
      （`<库目录>/ppf-logs.zip`——验收人已经习惯了）。
      nextest 319/319 + src-tauri 14/14 + vitest 24/24 + vite build 207 modules；
      反证（把不可达分支改回 `return Err`）真跑变红。
      ⚠️ LaunchAgent 是 macOS 专属，本轮只把 macOS 做对，不为未定平台预留抽象。
      ⚠️ 同一场事故的另一面（向导把真实启动错误吞成「没有在 10 秒内就绪」）
      = `DESK-09`，**2026-08-25 撤出批次、推后**（不挡回归），卡为 ⬜ 未开工。
      **2026-08-26 补漏（脱敏按值的形状做）**：真机验收 9 份文件齐、真日志在、
      版本号对、家目录脱敏全过，**只有「NodeId 仍只出前缀」这条没达到**——
      `audit.json` 里出了完整 64 位 NodeId。根因是**掩码按字段名做**：`actor`
      有前缀掩码，`detail` 只过 `sanitize()`，而库布局是
      `originals/<nodeid>/YYYY/MM/<file>`，`detail` 里嵌的 `rel_path` 本身就以
      全长 NodeId 开头。改成按值的形状：daemon 侧 `mask_long_hex()`（≥24 位连续
      hex → 前 8 位）+ `scrub()`，三个出包字段全过；`diag_events.json` 的
      `detail` 经自查是同一个洞的另一半，一起修。桌面壳的 `build_bundle` 也不再
      「原样搬」daemon 的 JSON——新壳配旧 daemon 会再漏一次，保证做在 bundle
      边界上。既有那条 audit 测试的 fixture 里 `detail` 一个 hex 都没有，断言
      空转；判据已换成「扫整个包里最长连续 hex 串，超 24 位就红」。
      nextest 320 passed / src-tauri 15 passed，两侧反证真跑。
- [x] DESK-08 活动流用时间戳当 each key，同毫秒的审计撞键把整块打挂 — **2026-08-21（真机确认 owed）**:
      用户控制台刷屏 `each_key_duplicate: 1787292449250:asset.removed_external`。
      一次在 Finder 删 5 张 → WATCH-02 的对账把 5 条 `asset.removed_external`
      写在**同一毫秒** → `{#each visibleAudit as e (e.ts + ":" + e.action)}` 撞键
      → **整个活动流渲染不出来**。**时间戳不是身份，主键才是**：`audit_log` 有
      自增主键、`AuditRecord` 一直带着 `id`，只是 `ipc.rs` 的 `audit.list` 没往
      外传。改法：IPC 每行加 `"id": r.id`，前端两处 each key + `backupDuration`
      查表全换成 `e.id`。
      ⚠️ **这个 bug 是 WATCH-02 的修复踩响的**——WATCH-02 修好之前整棵子树的删除
      对账一行都查不出来，所以从来不会有 N 条同毫秒的删除审计。
      **修好一个 bug 会让下游的 bug 第一次有机会发生。**
      ⚠️ 按 E2E-02 的教训查了「还有几个同形的」：全文只有 3 处 keyed each，
      另两处是 `g.key`（按月分组）和 `item.hash`（asset 主键），都唯一，没有第四处。
      反证 3/3 全红。⚠️ D2 当场抓到我自己写窄的守卫：只断言了读侧
      `backupDuration[e.ts`，写侧 `out[...]` 改回去照样绿 → 改成夹出函数体、
      读写两侧一起断言（「函数级断言必须夹出函数体」第三次复发）。
      `just ci` 全绿，Rust 314/314，前端 vitest 18/18（桌面端测试从 8 条涨到 18）。
      挂账：真机删 N 张后活动记录页 N 条都在、控制台无报错（用户）。
- [ ] BUILD-01 本地 JDK 25 让 Android release 构建挂在 lint — **⛔ 未实施（L3，不影响 CI）**:
      `brew --prefix openjdk` = openjdk 25.0.1，AGP 的 lint 吃不下，异常里只吐
      一个 `> 25.0.1`——**看着完全不像版本问题**（我第一眼当成签名配置缺失）。
      CI 钉 `java-version: "17"` 不受影响；debug 构建与单测在 25 上也正常，
      只有 release 的 `lintVital` 会炸。`justfile` 的 `android-test` 写死
      `JAVA_HOME=$(brew --prefix openjdk)`，等于本地工具链跟着 brew 最新版漂。
      倾向改法：钉 `/usr/libexec/java_home -v 17` + 加前置检查报人话。
- [ ] MOB-34 库里删掉的**老**照片永远不会被重传（水位把它们挡在扫描之外），「待备份 K」永远归不了零 — **🟡 2026-08-25 代码已合并（commit d592639），等真机验收**（MOB-29 的后半截：存储端报缺是对的，手机端断在增量扫描按水位只看新照片。落地：`ReuploadQueue` 定向补偿——校准算出 `lost` 后按 MOB-13 的文件级记录反查 fileKey 入队，下一轮 `MediaScanner.itemsByKeys` 按 `_ID` **定向**取回那几条记录进候选；查无此行/范围外/打不开一律出队，**不退化成每轮全量重扫**。两条校准门（`BackupWorker` + `BackupUiStateHolder`）都接了队列。已知边界：MOB-13 之前的存量条目没有文件级记录，反查够不着——见卡）。
- [ ] UX-14 传一半自己「暂停」了——失败重试被渲染成被暂停 — **🟡 2026-08-26 代码已合并，等真机验收**（验收人原话「怎么传一半自己暂停了，你查看下日志，是否是我误触了，按道理我没碰到」。**没有误触**：logcat 17:12:48 `CANCELLED_BY_APP(1)` 是他主动按的暂停 → 点继续 → 续传那一轮传到 `sending 54/198` 时 `IrohError ConnectionLost(TimedOut)` → `Result.retry()`，而 **WorkManager 的 retry 结构上拿不到 outputData** → 不盖 `KEY_FINISHED_AT` → UX-13 的判据认为那次暂停「还没被后来的运行覆盖」→ 又冒出「继续」；17:18:31 有一轮跑成功盖戳才自愈。修法：判据锚点从「最新完成时刻」扩到「最新**开跑**时刻」——新增 `RunStartPrefs`，worker 在**抢到互斥门之后**（空转轮不算开跑）、**扫描之前**（失败重试留不下终态戳，开跑是唯一一定能落下的事实）落盘。**教训：UX-13 卡面那句「时刻不需要清除时机就能自证过期」假设每一轮都会留下终态戳，而 retry 这条路结构上留不下——被自己写下的前提坑了。** 顺带记账：这是本仓**第五次**「源码断言钉字面形状」误伤（`uiStateOf(infos, pausedAt)` 被加参数顶红），已改钉不变量。）
- [ ] MOB-40 还没选相册就把整库传了——「从未选过」被当成「全量备份」 — **🔴 2026-08-26 真机实锤（L0，验收人原话「我就选择了一个 11 张的相册，你给我同步几百个？我都不用往下测试了」）→ ✅ 当天修完，**test.8 真机通过**（只选 11 张的相册 → 全程只传 11 张，配对到选完相册之间零传输）**（logcat 铁证：15:53:05 全新安装 → 15:54:14 那一轮 `scanning 254/254` 把整库都传了，此刻用户还没进选相册页；15:55:13 用户手动按暂停；15:55:26 选完相册后才是正确的 `offered=11`。根因是**一条语义**：`selectedBucketIds() == null` 表示「从未选过」，全链路却解释成「全量备份」——T6 给升级用户留的兼容。触发时机有两条路都不带「已选范围」这道门：配对成功当场调 `scheduleAutoBackup`，而 `PeriodicWorkRequest` 没有 initialDelay、首轮立即跑；以及 MOB-38 的 `foregroundCatchup` 门控只有「已配对 + 未暂停」。**修在管线咽喉不在触发通道**——五条通道各加一道门就是把同一判断写五遍，MOB-33/34/35/38 四个 bug 全是「漏接一处」，那个形状不能再复制（触发侧收拢归 MOB-39）。null 与空集行为相同、盖戳分开（`KEY_NO_SCOPE` / `KEY_NO_ALBUMS`），UI 文案共用。**教训：一个备份产品最不该做的默认动作,就是在拿到用户选择之前把整个相册库传出去——「我还不知道你要备什么」不等于「那就全备」。** 顺带修掉一条自钉字面的旧测试:它断言 `contains("if (bucketIds != null && bucketIds.isEmpty())")`,理由写着「null = 全量语义」——把缺陷钉住了,什么也没守住。）
- [ ] UX-13 暂停之后英雄区按钮整个消失，首页没有续传入口 — **🟡 2026-08-26 代码已合并（commit 2315259），等真机验收**（验收人真机原话「暂停之后，没有重新开始的按钮？」。按钮只在 `busy` 时渲染，一暂停 `busy` 变 false 就整块不渲染，续传入口只剩设置页的「立即备份」——**与 UX-01 卡面自己写的「再点一次 = 续传」冲突**；不是 MOB-33 改出来的，是既有缺陷。根因：「用户主动暂停」与「本来就没事干」都映射到 `Idle`，界面分不出来。落地：新增 `BackupUiState.Paused`，判据 = 落盘的「按下暂停的时刻」（新 `backup/PausePrefs.kt`，tmp+rename，随配对清）与 work 真实状态合成的纯函数 `pausedAfterOf`。**刻意不看那条 CANCELLED 记录**——取消拿不到 `outputData` → 无戳 → 在 MOB-31 的「按戳取最大」里恒被当上古记录；**也没破 MOB-33 的「界面不许自己编状态」**——合成要求「没有 work 在跑」，点完暂停而字节还在传的那几帧照旧显示进行中。英雄区按钮改由纯函数 `heroActionOf` 裁决，同一位置换文案、两分支共用同一个 `onClick`（MOB-19 红线）。**教训：记「时刻」而不是「布尔」——时刻不需要清除时机就能自证过期，布尔要有人负责清，而这里的「谁来清」得跟五条触发通道各自的开跑时机打交道。**）
- [ ] MOB-37 重传告知只发一条系统通知，发失败就永久静默 — **🟡 2026-08-26 代码已合并（commit 94574b1），等真机验收**（MOB-29 的告知天然一次性：算出 `lost` → 发通知 → `removeMissing` 剔除 → 下一轮算不出同一批，于是**那一次发失败就永久静默**（权限没授/渠道被关/锁屏没看见）。真机现场：删 3 张，重传真的发生了，验收人什么提示都没看到。落地：新 `ReuploadNotice.kt` 把告知**落盘**（hash 并集，不累加——MOB-33 并发双发不许把 3 张记成 6 张），`noteReuploadNotice` **先落盘再发通知且吞掉通知异常**，两条校准门（`BackupWorker` 含收尾补校准 + `BackupUiStateHolder` 的 App 打开那次）都落盘，App 内一条可 acknowledge 的提示读的是盘上状态。**不重试通知**——只在 acknowledged→unacknowledged 的跃变时发一条。顺带给 `UI-04` 搭了提示优先级骨架 `ui/HomeNotices.kt`（`HomeNotice` + `topNotice` + `NoticeCard`，既有提示未迁移，那是 UI-04 的活）。**教训：「天然一次性，连去重窗口都不用做」是把缺陷说成了优雅——省掉一套机制之前先问它本来在防什么，这里防的是投递失败，而通知投递是最不可靠的一环。**）
- [ ] MOB-36 移进备份范围的照片永远不会被扫到（水位挡住了它） — **🟡 2026-08-26 代码已合并（commit 55f8c43），等真机验收**（与 MOB-34 同族根因：相册之间移动照片不改 `_ID`/`date_added`/`date_modified`，只改 `bucket_id`，于是移进已选相册的老照片水位值远在水位之下、增量扫描永远看不见——真机现象是「触发了但什么也没传」。落地：选卡面 A 路（按 bucket 定向查）——新 `ScopeBackfill.kt` + `MediaScanner.scanScopeBelow`，每轮多一次「已选 bucket 里、水位之下」的元数据查询（一个 collection 一次，范围为 null 或水位为 0 时 0 次），返回集靠 `ConfirmedState.files` ∪ `HashCache` 两张现成的表筛掉已确认的那些，**已备份过的不开流不哈希、不重复上传**；稳态零候选零哈希，开销 ∝ 变化量而非库大小。不新增落盘状态（这是不选 B 路快照表的理由），不动水位推进规则。顺带治好「新勾选相册里的存量照片自动备份够不着」——代价是勾选大相册后第一轮会一次 offer 整个存量，属预期行为。测试 39 类/302 tests/0 failures，反证 4 条真跑）。
- [ ] MOB-29 库里删掉的照片被静默传回来 + 「已备份」在两次备份之间说谎 — **🟡 2026-08-25 代码已合并（commit 95f3c4f），等真机验收**（落地：手机端「资源在客户端丢失，正在重传」通知 + 桌面端总览页删除警告 + 校准搭 `doWork` finally 的便车；`manifest`/`missing` 与 proto 零改动，反墓碑判据 `deleted_asset_is_still_reported_missing_no_tombstone` 钉死「删掉的 hash 下一轮仍在 missing」）。原记录：**⛔ 未实施，但 2026-08-25 已解除阻塞**（墓碑方案整条撤销，改为「不拦重传，只告知 + 教『先删手机原图、再删库』的顺序」；不加 proto 字段、不做内置垃圾桶、不做恢复入口——访达废纸篓已是这三样。数字口径 A/B 那道裁决随墓碑一起消失。竞品对照：Immich `#4282`/`#22507`/`#23897` 同病未解，其回收站事实上是 30 天隐式墓碑）。原记录：
      桌面端删掉手机备份的照片后，手机仍报「已备份」，下一轮又原样传回来。
      ⚠️ **2026-08-21 真机证实**：14:07 手动删 5 张 → 14:08 那轮 `ingested=11
      duplicates=7`，逐个查文件名，5 张在索引里**每个都回来了 1 行**。
      方向已定（用户 2026-08-21）：墓碑 + 客户端常驻提示「如果你删除了某个设备
      里面的照片，请同时先在该设备删除，要不然它会重复备份回来」，**不封禁设备**。
      **等拍板**：「已备份」数字口径——只数库里真有的（诚实，会从 188 掉到 3，
      配一句「另有 N 张已按你的要求删除」），还是数「已交代过的」= 库里有的 +
      墓碑里的（稳定但仍误导）。卡里倾向前者。
- [x] WATCH-07 每批备份后活动流被 N 条 `ingest.duplicate` 刷屏 — **2026-08-22 已修（方案 2），等真机验收**:
      根因证实：备份管线 `place()` 进 `originals/` 后 FSEvents 立刻报告，
      watcher 对同一文件再 ingest 一遍，全判 `Duplicate` 各写一条审计
      （12 张 → 12 条）。修法：Duplicate 分支加 `is_recorded_file()` 判定
      ——被 ingest 的路径 == 索引记录路径（canonicalize 双侧）→ 是复检，
      不写审计；不同路径的同内容文件仍记（用户真实拷贝）。审计设计规矩
      同批定稿（审计只记数据层面事件、语义稳定因为业务会读、防「展示对
      实际错」靠对账不靠更详细审计），见卡内备注。反证：去掉判定测试即红。
- [ ] SYNC-05 AssetMeta 补 `src_device`，消灭客户端影子状态 — **⛔ 未实施，无依赖可随时做（L1）**
- [x] E2E-02 DaemonHelloTest 断言一个废弃契约，e2e 门禁常红 — **2026-08-20 已修**:
      ⚠️ 全仓**四处**同形（DaemonHello / DaemonBackup / NetProbe / DeviceBackup），
      上一轮只修一处就宣布"解红"。已抽成共用 `addrOf(qr)`。
      **教训：「这个测试挂了」要先问「还有几个同形的」。**
- [x] MOB-09 一条坏 MediaStore 记录让整批备份永久失败 — **2026-08-20（真机部分验过）**:
      `buildCandidates()` 逐条隔离 + 探针 open 已在 `BackupWorker.kt`。真机实测到
      `skipped 1/1 unreadable media record(s)` 且无 ENOENT 导致的 RETRY。
      **未做**：坏记录与好记录同批的对照（卡面原验收要 `skipped 1/2`）。
- [x] MOB-13 「待备份 K」永远归不了零（M 按 hash、N 按文件计数）— **2026-08-20（真机复验 owed）**:
      `fileEntriesOf` / `ConfirmedFile` / 混合计数已在 `ConfirmedStore.kt`。复验有
      前置：升级后先手动按一次备份补齐文件级记录，再验「复制一张已备份照片 →
      待备份归零」。
- [ ] MOB-07 部分授权全局提示（tab 红点 + 哨兵通知）— **⏸ backlog 不排期**（用户 2026-08-14：「现在先不做」）
- [x] UI-03 手机端删掉照片页/设置页的顶部大标题 — **2026-08-21（真机验收 owed）**:
      用户真机裁决「顶部有必要有几个大字吗？【全家的照片】【设置】…占位置还没有
      什么意义」。底部 tab 已经写着「照片」「设置」，30sp/28sp serif 大标题是同一
      句话说第二遍，还吃掉手机首屏最金贵的纵向空间（照片墙第一行、英雄卡三元组
      各被往下推约 68dp / 42dp）。`PhotosScreen` 标题换成 `Spacer(8.dp)`，
      `HomeScreen` 标题块整删（Column 自带 14dp 顶部内边距，英雄卡不贴边）。
      `photos_title` string 资源保留（en/zh 对称，桌面端还用得上）。
      ⚠️ **这是对设计稿 layout-v1 的有意偏离**（照片页「标题单独站着」、
      设置页 T-083 目标 1「仅『设置』28px serif」两条都被推翻）——设计稿要跟着
      改，否则下次 UI 走查会把这里判成「未实现」。已 grep 确认没有测试钉这两个
      标题的样式。挂账：真机确认两页顶部无大字、不贴状态栏（用户）。
- [x] MOB-32 校准把正在跑的备份会话清空，186 张照片被静默丢弃 — **2026-08-21（真机验收 owed，L0）**:
      清场前 `du -sh` 抓到的：`.ppf/staging` 547M / 186 个已校验文件
      （`.upload` = 0，全过了 BLAKE3），其中只有 1 个进了索引，**185 个纯孤儿**；
      `originals` 只有 3.4M。审计对应段 `11:22:05 backup.finished ingested=0
      duplicates=0`。根因：`backup.begin` 无条件 `insert(peer, Session::default())`，
      而**漂移校准也走这条路**（`existCheck` = begin + manifest(items 空)），
      会话又按设备 NodeId 索引——校准和备份同一把钥匙。用户备份途中打开 App →
      会话被顶掉 → commit 循环零次报 0 张**却返回 ok** → 手机把整批标记「已备份」。
      三处修：①`begin` 改成 `entry().or_default().touch()`，会话生命周期归
      `commit` 与新的 janitor `sweep_sessions(1h)`；②新增独立于 session 的
      `delivered` 台账（上传平面校验通过即记），commit 在「交付 N 张、入库 0 张」
      时返回 `NothingIngested` 而非成功，水位也不推；③`inbox::sweep_orphans`
      按「裸文件 ∧ 不在活会话保护集 ∧ 落地超宽限期」回收 staging 孤儿（启动
      + 每小时各一次）。
      ⚠️ 审出来的回归也一并修了：`begin` 不再清空会话后，上一轮声明过、手机上
      已删掉的「幽灵 item」会让 commit 走 `fetch_from` 而手机从不 serve blobs
      → 报错时 `sessions.remove` 走不到、重试又把会话 touch 活 → janitor 也收
      不走 → 备份一直红。修法是拉取回退加 `provider.is_some()` 门。
      ⚠️ 这也是一次**有记录的裁决反转**：BLOB-01 当时定「staging 裸文件一律
      保留」，理由是「下一轮手机会重新 offer，省一次上传」——本卡的事故打掉了
      这个前提（假 ok 让手机再也不 offer）。现在正确性优先于带宽。
      反证 9/9 全红，`just ci` 全绿，Rust 313/313，Android 253/253。
      挂账：真机跑一次完整备份、**中途打开 App**，照片必须全部到位且 staging
      收尾为 0 字节（用户）。
- [x] MOB-31 界面从历史终态里随机挑一条 — **2026-08-21（真机验收 owed）**:
      用户真机：选了只有 12 张的相册，同步完成后界面显示「186 张」。根因在
      `uiStateOf` 的 `infos.lastOrNull { it.state.isFinished }`：取的是**列表
      最后一个元素**，而备份有五条通道（auto/catchup/process-catchup/manual/
      media-watch）各自独立 unique name、终态记录同时躺着最多五条、共用同一
      个 tag，且 `getWorkInfosByTagFlow` **不保证按时间排序**（Room 顺序，
      实际按 UUID）。于是「拿最后一个」= 随机挑一条历史记录，186 是 8/20
      那次全量运行留下的旧终态。改法：worker 每个终态都盖 `KEY_FINISHED_AT`
      （`successStamped()` 统一出口 + 失败分支单独盖），`uiStateOf` 按戳挑
      最大值；没戳的算最旧，一条戳都没有才退回列表顺序（升级首帧不空白）。
      守卫断言正文里不许再出现裸 `Result.success(`——真正的风险是以后加新
      终态返回点忘了盖戳。反证 4/4 全红，android 单测 252/252。
      ⚠️ 反证抓到我自己两个恒真式：①盖戳断言原本对整个文件 contains，而失败
      分支里有同一串；②「全无戳退回列表顺序」原本只放一条记录。都已修。
      ⚠️ 另记：第一次跑 gradlew 我 grep `^e:|error:`，而 gradle 报的是
      `Unable to locate a Java Runtime`——根本没跑起来我却报告"编译过了"。
      **grep 没匹配到 ≠ 成功。** `justfile` 的 `android-test` 带 JAVA_HOME。
      ⚠️ **更正（同日）**：本卡当时的结论里有一句「不是在跑全量」，那句是错的。
      我据以判断的事实都真（`WorkProgress` 零行、审计零 ingest、库里行数不变、
      `ppass-auto-backup` 排队未跑），但那些只证明**我检查那一刻没有 work 在跑**，
      我把它外推成了「那次全量没发生过」。真相见 MOB-32：11:18–11:22 确实上传了
      186 张（547MB 进 staging），commit 报 `ingested=0` 却返回成功把它扔了，
      所以入库审计里当然一条都没有。本卡只解释**数字为什么是 186**。
      挂账：真机选一个 12 张的相册，进度条与三元组分母都必须是 12（用户）。
- [x] MOB-30 入库跟着上传走，不再攒到 commit — **2026-08-21（真机验收 owed）**:
      用户裁决「上传是主动的，我觉得入库也应该是主动的，而不是说批量」。
      在此之前上传逐张校验落 staging，但 `place()` + 插索引行全在
      `backup.commit`，即所有文件传完之后。后果①传 500 张时照片墙 8 分钟毫无
      动静最后一秒全冒出来；②`manifest` 算 `missing` 只查索引不看 staging，
      传到第 400 张断掉时那 400 个文件安然在 staging 而索引一条都没有 →
      下一轮手机全部重新上传（BLOB-01 记的「断了整个重传」是单文件级别，
      commit 的批量性把它放大成整批级别）。改法：抽出
      `BackupEngine::ingest_one` 作为单条入库的**唯一**实现（上传路径与
      commit 路径共用——各写一遍必然漂移，MOB-19 那两条管线就是这么烂的），
      新增 `ingest_staged(peer, hash)` 供上传平面校验通过后立刻调。Session
      加 `ingested`/`duplicates`/`settled` 三项记账：前两项让 commit 的数字把
      上传阶段入库的算进去（否则 commit 只看到「已在索引里」报成 duplicates，
      界面说「新增 0 张」），`settled` 让 commit 跳过且**不计数**已办的（否则
      数第二遍）。即时入库失败不让上传流失败（文件已校验落盘，commit 兜底；
      把 ACK 变错误只会让手机重传这张），但留 warn 不静默吞。**后果②顺带解掉**。
      反证 4/4 全红，Rust 307/307，BLOB-01 两条性质与
      `interrupted_commit_rerun_converges` 都仍绿。
      挂账：真机传一批照片，照片墙必须逐张浮现而不是最后一跳（用户）。
- [x] MOB-28 区分「重启」与「被清」，被清了只提示不恢复 — **2026-08-20（真机端到端验过）**:
      取代 backlog 里的 MOB-18。用户要的语义一直是"检测到 → 提示 → 用户点了
      才恢复"，MOB-18 做不到是因为监听是 WorkManager 的 work，`ForceStopRunnable`
      跑在 `androidx.startup` 的 ContentProvider 里、比 `Application.onCreate`
      还早就自愈了。**MOB-27 把这个前提推翻**——监听现在是我们自己注册的
      JobScheduler job，WorkManager 不知道它存在，碰不到它。
      判据换成**开机时刻**（`currentTimeMillis - elapsedRealtime`，同一次开机内
      稳定、重启后变，零权限）：重启 → 自动恢复；同一次开机内监听凭空消失
      （force-stop / OEM 清理）→ 只记录 + 设置页琥珀提示卡，点「恢复备份」才重挂。
      三处闸门（Application 对账 / MainActivity 的 LaunchedEffect / 开机 receiver）
      缺一处等于没有——用户实测栽过两次的正是第二条。
      顺带把 MOB-27 §五那个待定项做了：加开机 receiver。此前判断"性价比不明"
      **是错的**——`RECEIVE_BOOT_COMPLETED` 本来就在合并 manifest 里（WorkManager
      带进来的，不增加用户可见权限），且 manifest receiver 不常驻。重启后监听
      立刻回来，不再等 5h 周期任务。
      234/234 + 18 条反证全红（MOB-27 的 9 条一起复跑）。真机端到端：force-stop
      → 打开 App → 看门 job **没有**被自动装回去、提示卡真的出现 → 点「恢复备份」
      → job 回来 + 标志清除 + 立刻补跑。
      已知边界：force-stop **再重启**再打开会被判成重启（那段时间我们一行代码
      都跑不了，没人记下"被清过"），卡里如实记了。
- [x] MOB-27 监听与干活分家（content trigger → JobScheduler 看门 job） — **2026-08-19（代码完成，真机验收 owed）**:
      监听 work 与干活 work 是同一个，**备份跑多久监听就断多久**——用户实测
      "前面的出去了，后面的就没有同步"。上一轮的治标（重挂延迟 + 按批次大小
      补捞）被用户当场否掉："你强行用时间来做判断的话，是不太合适的。"
      根治方案由用户提出（"参照 JS 的 event loop：事件来了，执行完之后再释放"），
      核对 AOSP 文档后确认**这就是官方模式**——`JobInfo.Builder#addTriggerContentUri`
      的 javadoc 明写：用 `schedule(同一个 job ID)` 代替 `jobFinished()`，
      "while your job is running, the system will continue monitoring for content
      changes, and propagate any changes it sees over to the next job you schedule"。
      **系统就是那个事件队列**，我们吃不到只因中间隔着 WorkManager（REPLACE 换
      WorkSpec → 换 job ID → 转交认不上人）。新增 `MediaWatchJob`（毫秒级：
      先派活、后重挂），备份走 `APPEND_OR_REPLACE` 排队；删掉整套 rearm 机关，
      **一个时间常数都没剩下**。顺手堵掉更严重的第二个洞：旧监听带着
      `UNMETERED` 约束 = **不连 Wi-Fi 时压根收不到通知**，出门拍一天照全靠 5h
      兜底；现在监听裸挂永远在线，约束挂在派出去的备份 work 上。
      代价：trigger URI 与 `setPersisted` 互斥，**看门 job 每次重启必死**，
      靠周期任务拉起进程时重挂（数据不丢，亏时延）。装机时真机 dumpsys 又发现
      升级路径 bug（旧 unique work 随 `install -r` 存活 → 新旧监听并行），已加
      一次性清理。真机实测**监听空窗 32 毫秒**（旧实现 = 整个备份时长），看门
      job `batteryNotLow=false` 且无 Network type 行。218/218 + 10 条反证全红。
- [x] MOB-11 同步节奏改为「尽快送达」 — **2026-08-18（用户定稿，待验收）**:
      `CONTENT_UPDATE_DELAY_MS` 2min→1s、`CONTENT_MAX_DELAY_MS` 15min→30s；
      真机实测端到端 **1.6 秒**（改前 2 分 03 秒）。`setTriggerContentUpdateDelay`
      是尾沿防抖，1s 能聚合任意长度连拍——防的是事件爆炸不是推迟触发；
      max delay 收到 30s 防的是截图/IM 收图这类**持续 churn** 把备份饿死
      （不是防连拍，初版记错、2026-08-19 已更正）。同批：删「仅充电」后果
      解释文案、把「自动备份」总开关放回设置页（桌面端有停止入口手机端没有）、
      修 main 上被增量构建掩盖已久的 `DiagTextTest` i18n 漂移红。
      ⚠️ 观察项：1s 节奏下任何 App 写 MediaStore 都会触发一次 run，而
      `setForeground` 在 scan 之前，空扫描也会闪 FGS——待实测噪音量后再定。
- [x] MOB-08 后台自动同步不生效 三根因 — **2026-08-18（用户真机验收通过）**:
      三根因，前两个是自家代码 bug 与三星无关（"怀疑 One UI OEM 限制"被证据
      否掉）。**A** `addContentUriTrigger(it, false)`——MediaProvider 通知的是
      带行 id 的 item URI，精确匹配收不到，content trigger 从未触发。
      **B** content trigger 是 OneTimeWork，跑完进终态监听即消失，`doWork()`
      里没有重新 enqueue——后台自动同步只在开过 App 之后的第一张照片有效；
      用独立 name 的中转 `ContentTriggerRearmWorker` 修（不能在 doWork 里
      REPLACE 同名 unique work，那会取消正在跑的自己）。**C** 现象 2 的
      `JobCancellationException` 是排查前提错了——插着 USB 但 `status:4
      NOT_CHARGING`，JobScheduler 放行、WorkManager 的 BatteryChargingTracker
      叫停；顺带修掉 `setForeground()` 在 try 之外、cancellation 被当业务失败
      吞掉、`client.close()` 在取消路径跑不到三个真缺陷，并加 stopReason 仪器化。
      真机验收：真实拍照两张端到端均 2 分 03 秒（当时还是 2min 节奏），第二张
      全程未开 App 也送达。

- [x] MOB-06 查看页右上角「分享」 — **2026-08-12（用户询问「分享 vs 用其他
      应用打开是不是一回事」，待推 main）**: 不是一回事——分享=`ACTION_SEND`
      （文件作为内容/附件发给目标 app，分享面板：微信/邮件/云盘）；
      打开=`ACTION_VIEW`（目标 app 以打开模式处理文件，打开方式选择器）。
      底层共用 FileProvider + FLAG_GRANT_READ_URI_PERMISSION + 临时文件即用
      即清。实现：`AssetActions.shareIntent` + 分享图标（原自绘 ic_share.xml，
      **ICON-02 已换成 `Icons.Filled.Share`**）+ 照片/视频
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

- [x] **SYNC-06 订阅生命周期上提到 App 前台级别 — merged 2026-08-13（本 commit）**:
      用户 review 指出 SYNC-04 的订阅绑在 PhotosScreen 组合可见性上——切设置
      tab 订阅就断、切回重建有空窗还丢信号。订阅状态与驱动循环抽到
      `TimelineSubscriptionHolder`（MainActivity 跟 ForegroundHeartbeat 并列
      持有，复用同一条 LifecycleEventObserver）：ON_RESUME 起 / ON_STOP 停
      （PRES-01 后台零网络红线同款判断），前台期间不管哪个 tab 订阅保持、
      信号照收照刷；回前台重建订阅 + 整页刷新补齐。协议层（SYNC-03/04）一字
      未动，nextSubscribeRetry 原样，60s 兜底轮询保持 REV-01#2「仅追加」语义；
      配对监视（前台 2s 轮询 pairing.json）处理重配对/断开/换 token；翻页也
      收进 holder（appendNextPage）。PhotosScreen 只渲染。测试：纯函数状态机
      7 项（tab 0→1→0 零转换 = 订阅发起次数 0 变化，旧接线对照每次切回 +1）
      + holder 协程级 5 项（计数 fake 通道，tab 切换不重连/start 幂等/
      ON_STOP 关 ON_RESUME 重建/耗尽后手动重试/未配对空闲+配对落盘自动起订）
      ——android 178/178 绿 + assembleDebug 绿。**真机验收挂用户**（两条，见
      NEXT；未经确认不得宣称「已对齐前台」）。
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
- [x] **WATCH-04 宽容入库：originals/ 是用户的目录 — merged 2026-08-21（真机验收 owed）**:
      用户裁决「人工往底层目录移动这种超高权限的操作，我们要像 OS 一样兼容」。
      规则：`originals/` 底下任何位置的媒体文件照原样入索引，`mv` 到 canonical
      日期布局只对「我们自己从手机收到的文件」执行（那些还在 staging，本来就
      得找个家）。三条支撑：①实测 macOS 分不清「拖进来」和「拖出去」（两者都
      只有一条 `Modify(Name)`），我们本来就必须 stat 每个路径，宽容不多花一
      分钱；②`rebuild.rs`（ADR-006）本来就是宽容的，严格入库 + 宽容重建 =
      重建一次库的语义就变；③备份工具最不该干的是把用户文件从他放的位置挪走。
      归属：不在 `<64hex>/` 下的文件归**本机**（用户提案，比我原先说的「留空」
      好）——这条规则目录树自己就能重现，**ADR-006 铁律不用破**；我上一轮判定
      「这是解不了的架构张力」是错的。`rebuild()` 签名加 `local_node_id`。
      前置条件（不做就是引 bug）：**一个路径只能被一条索引行占用**。`hash` 是
      主键而 `rel_path` 没有唯一约束，用户编辑一张已入库照片 → hash 变 → 插新
      行，老行还指着同一路径（文件存在，对账不清它）→ 同一文件两条行 → 照片墙
      出现两次且其中一张 thumb 取不出来。旧的严格布局歪打正着躲过了这个坑
      （文件被搬走 + `-1` 后缀，老路径空了）。
      展示不受影响（核过）：时间线只看 `taken_at`，`AssetMeta` 连路径字段都没有。
      实测成本给 WATCH-05 定了优先级：stat 4.6 µs/张 vs hash 2.8 ms/张 =
      **620 倍**，但百张量级完全无感，几千张才有意义 → backlog。
      被否掉：`originals` 改名（破坏所有存量库，收益零）、软链物化文件视图
      （软链是第二个路径，刚立的路径唯一性当场破产；Windows 要管理员权限）。
      Rust **305/305** + `just ci` 绿，反证 5/5 全红。
      挂账：真机在 Finder 里建目录/挪照片/编辑照片三个动作的观感确认（用户）。
- [x] **WATCH-02 手动删 originals 的照片索引无反应 — merged 2026-08-20（真机验收 owed）**:
      用户 Finder 删光 185 张，索引 186 条一条没减。根因**不是**卡面三条假设
      里的任何一条（FSEvents 句柄失效 / 瞬态 remove 过滤 / 环境问题），而是
      **SQL 前缀多了一个斜杠**：整棵子树被删时 `affected_dirs` 收敛到
      `originals` 本身 → `rel` 空串 → `prefix = "originals/"` →
      `list_asset_paths_under` 再补 `/%` → `LIKE 'originals//%'` → **命中 0 行**
      → 什么也不删、不发事件。删单文件时 `rel` 非空所以一直是绿的——
      **测试形状和用户操作形状不一样**。`list_asset_paths_under` 此前零测试覆盖。
      顺带修掉第二个缺陷：`walk_media` 对已消失目录返回 `Err(ENOENT)` →
      `process` 早退 → 删除方向的对账被一起跳过（整树删除时 ENOENT 是必然结果，
      不是错误）。性能口径：存在性检查整批下放 `spawn_blocking`（候选集在变化
      目录是 `originals` 时就是全库，每行一次 stat，5 万行百毫秒级；逐行同步
      stat 会钉住 async 工作线程）。三种删除形状（单文件 / rm -rf 整棵 / Finder
      改名进废纸篓）全覆盖 + 事件断言。Rust 301/301，反证 8/8 全红。
      挂账：真机 Finder 删几张 → 照片墙 5 秒内消失（用户）。
- [x] **WATCH-03 Finder 挪动照片导致索引删行、照片凭空消失 — merged 2026-08-20（真机验收 owed）**:
      修 WATCH-02 时挖出来的，比它更严重：WATCH-02 是「删了但没消失」，这条是
      **「没删但消失了」**。用户把照片拖进自建目录 `originals/我的婚礼/`（就是
      给照片分类这个最自然的动作）→ `ingest_new` 见 hash 已存在返回 `Duplicate`
      **不更新 rel_path** → `reconcile_under` 见旧路径不存在 → 删行 + 删缩略图。
      两步各自都"对"，合起来是数据不可见，而且**再也回不来**（没有新事件了）。
      根本问题是身份口径：内容寻址系统里 hash 才是身份，`rel_path` 只是当前住址，
      搬家不该销户。改法：hash 命中时**先看记录的文件还在不在**——还在 =
      `Duplicate`（原样）；不在了 + 来源已在 `originals/` 树内 = `Moved`
      **就地采纳用户摆的位置**；不在了 + 来源在库外（手机重传）= `Moved` 按
      canonical 布局落位。新增 `IngestOutcome::Moved` + `update_asset_rel_path`
      + 审计 `asset.relocated`。顺带补掉既有的洞：手机重传一张曾被外部删掉的
      照片，旧代码返回 `Duplicate` → staged 被删、索引行指向不存在的文件 →
      下轮对账把行也删掉，照片永远补不回来。
      ⚠️ `rel_inside_originals` 两侧都必须 canonicalize（macOS `/var` →
      `/private/var`，watcher 监听根做过而 library_root 没做，不规范化则
      strip_prefix 永远失败 → 库内移动被误判成库外 → **文件被搬回日期目录，
      用户的分类被抹掉**）。反证含这一条。
      遗留（未做，等拍板）：①识别移动靠重算 hash，拖 5000 张 = 重读 5000 个
      文件，省掉需要 `(dev,inode,size,mtime)` 身份缓存（schema 变更，另立卡）；
      ②**用户新拖进来的照片（索引里还没有的）要不要被搬到日期目录** —— 现在
      会搬，这是产品决定不是 bug，没动。
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
- [x] blob-store GC (originals currently duplicated in the blob store)
      — **2026-08-20 由 `BLOB-01` 解决，实测占盘 2.05x → 1.00x**：根因不是
      "忘了清"，是主路径绕了一圈根本不该绕（上传平面已自己流式校验，却还要
      往 blob store 拷一份、commit 再拷回来）。改成校验通过原地改名坐实、
      commit 直接吃 staging；blob store 降级为只服务回退路径，启动时清空。
      不走 iroh 的 GC（单 blob delete 是 pub(crate)，gc_run_once 在私有模块，
      GcConfig 默认关且只能定时轮询）。真实 daemon 端到端
      `pushed=12 ingested=12; rerun pushed=0 dup=12`，占盘 1.00x。
- [ ] background thumbnail batch generation after ingest
- [ ] Windows smoke (T-040 will carry it)

## 链 2 取回/哨兵批次（2026-08-12 实施；语义基准 docs/product/2026-08-11-chain2-decisions.md ①③④⑤⑥）

- [x] RET-01 单张照片取回=使用动作 — **merged 2026-08-12 (4a92aae)**: 查看页「保存到相册」（MediaStore 29+ RELATIVE_PATH/26-28 DATA+扫描广播）+「用其他应用打开」（FileProvider+ACTION_VIEW）；原图按需下载 cacheDir/share 即用即清（MOB-04 红线）；文件头魔数嗅探真实 MIME（纯函数 JVM 可测）；防循环钉子显式断言（存回→再备份→ingested=0 duplicates=12）。android 140/140。挂账（真机）：家人照片保存到相册可见+时间元数据、打开面板+临时目录零残留、断网人话错误。
- [x] SENT-01 手机盯电脑哨兵 — **merged 2026-08-12 (29af0ff)**: 搭后台任务便车（非心跳）记 daemon 可达性；判定纯函数四条件（确认可达过/距今>72h/期间有失败尝试/去重窗口 72h）；「3 天没连上电脑了——照片没丢」走 UX-02 通道 id 2028。android 150/150。挂账（真机）：mock 全失败跨阈值→通知一次不重复、恢复可达清零。
- [x] DOG-02b 契机式白名单提醒 — **merged 2026-08-12 (a0792fe)**: 独立 store + 纯函数五条件（未加白/有失败/≤2天/失败后无成功/去重 72h）；成功一轮清零；通知进 App 见 DOG-02 Home 引导条。android 161/161。挂账（真机）：mock 条件满足→通知+点开引导、加白后不再通知。
- [x] DESK-04 桌面向导低成本对齐 — **merged 2026-08-12 (9072735)**: 文案按产品语言过一遍（去「常驻服务/访达」等词）；step3 接 T4 新配对流（daemon-event 事件驱动 + 3s 轮询兜底，pending 出现即时切确认列表）；全 token 化。vite build 绿。挂账（真机）：三步截图对照、走完向导→扫码→确认列表即时出现。
- [x] CI-04 release 等最慢的平台 — **merged 2026-08-26 (24f7ea3 + 1ee4a45 + 81ff6a2)**: ① windows vcpkg 缓存（`C:/vcpkg/installed`，不设 restore-keys、不跳过 install——缓存只负责让它快不负责让它可以不跑）；② **发布上传全拆**——原本一个 release job `needs` 三平台，Android 的 APK 5 分钟就在 artifact 里却要陪 win 等到最后（vcpkg 首次从源码编 libheif 10-20 分钟）。拆成 `create-draft`（秒级，消掉三条 lane 抢 create 的 TOCTOU）+ 三条独立 upload lane + `finalize-notes` 收口；manifest 签名 + test 自动发布跟着 android lane（`make-update-manifest.mjs` 结构上只吃 APK）→ 手机端约 6 分钟拿到包、自动更新立刻可验。**构建 job 的 `contents: read` 一字未动**——上传下沉到只做 download+upload 的独立 job，T-071b 红线保住，此前「等用户放宽权限」是我自造的障碍；③ 删掉 `environment: release-signing`——它从未配 reviewer、**从未拦过任何东西**，却被当成「发布前人工审批」向验收人描述了两轮。actionlint 通过、YAML 解析出 8 个 job。⚠️ **管线行为一次都没在 CI 上跑过**（`gh` 未登录+私有仓库，Actions 结果 agent 看不见）——判据待一次 dispatch 或下个 tag：(a) win 还在跑时 Android 资产是否已可下载 (b) notes 是否补齐签名状态+sha256 (c) `macOS=` 是否 `yes`。
- [x] CI-01 流水线分块重构 — **merged 2026-08-12 (5b8cb88)**: pr.yml 拆三域 workflow（ci-rust/ci-android/ci-desktop，paths 门控+concurrency 取消，纯 docs 零 CI）；release.yml platforms dispatch 输入（tag 恒全量）；T-070 scenarios 并轨 e2e nightly+tag；CF 联动门控（R2 镜像 ppf-dl/dl.p-pass.hawkeye-xb.com + ci-workers 自动部署，CLOUDFLARE_API_TOKEN 未就位跳过）；CLAUDE.md 底线①口径更新。actionlint 8 workflow 零告警。**2026-08-25 核实：`CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` 已在 Repository secrets（2 weeks ago），门控条件早已满足——此处「等用户」已作废，勿再照搬。**
- [x] DESK-05 桌面走查反馈三项 — **merged 2026-08-12**: ①向导第一步默认填充路径（`configuredLibraryDir || defaultDir`）+ 路径 ≠ 默认时旁挂「↺ 回到默认」；②活动记录改真表格（设备/事件/时间三列，ingest.* 逐文件行过滤，auditLine 拆 auditWho/auditText）；③照片墙 staleness 修复（activity.appended/device.changed 事件重置 photos 强制重拉——备份落地后照片库立刻出新照片）。vite build 绿。挂账（真机）：向导第一步默认填充观感、活动表格布局、备份后照片墙自动刷新。
- [x] DESK-07 桌面壳 Tailwind + shadcn-svelte 迁移（**第一轮：地基 + 家人与设备页**）— **merged 2026-08-14 (5507cf9)**（用户拍板拆多轮）：tailwindcss@4 + @tailwindcss/vite + shadcn-svelte 1.5（Vega preset）；`src/app.css` 用 `@theme inline` 把 Tailwind 工具类全部桥接到 tokens.css 的 `var(--pp-*)`（零平行调色板）；「家人与设备」页换 Button/Card + 工具类，19 项像素基准 DOM 实测迁移前后全等 + 反证有效 + 其余四页像素级 identical（preflight 两个副作用已在 base 层还原）。**其余页面（总览/照片/活动记录/设置）未迁，排后续卡**。挂账（真机）：Tauri 实际窗口观感。
- [ ] NAME-01 设备改名（L0 排队尾，可砍）
- [ ] 恢复向导（换机整库恢复）— 后置

## SITE 站点线（2026-08-11 启动；架构档案 docs/product/2026-08-11-site-architecture.md）

> Landing + blog 对外阵地，与 app 主线并行。内容 zh 先行，en 随开源节奏补。

- [x] SITE-01 站点脚手架（landing v1 + blog 骨架 + RSS + GH Pages 部署）— **code landed 2026-08-11**: Astro 5 纯静态，tokens.css 构建期从 tokens.json 生成（脚本断言一致），图标从 docs/design/2026-08-11-icon-v1/ 同步，零 tracker（CI 断言）。site.yml paths 过滤 `site/**` 与主 CI 隔离。挂账：Pages 部署三路由 200 + Lighthouse ≥90 + DNS CNAME 改指 hawkeye-xb.github.io（当前指向旧 p-pass-landing.pages.dev 占位）。
- [ ] SITE-02 首批三篇博文（定位故事 / 图标九轮 / IPC-02 重构）— 草稿完成。**优先级 L3（2026-08-25 用户降级：「优先级没这么高，回头统一审稿」）**——不再列为上线阻塞，不主动催审；用户择期统一审完再去 draft 发布
- [ ] DNS: p-pass.hawkeye-xb.com CNAME → hawkeye-xb.github.io（CF zone 65dec62bc61b00e5d22fedc40b774bdc）
- [ ] T-073 one-page site + README polish（M4 原条目，站点线落地后待并轨）

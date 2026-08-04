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
      landed 2026-08-03 (PR #26)**; **H-10c human-facing release assets
      in progress (PR #27)**: P-Pass-macos-arm64.dmg
      (.app + self-contained daemon sidecar + lib/) via
      tools/bundle-desktop-macos.sh + app-release-unsigned.apk
      (assembleRelease; signed version T-071 follow-up), both added to
      Release draft assets; H-10b naive-user test pending tag-build
      acceptance
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
      equal rejected, 0.1.0 downgrade rejected, "1.2" rejected
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
- [ ] **Gate: 5–10 household private beta, 2 weeks**

## M4 — Launch / 发布 ⬜

- [ ] T-073 one-page site + README polish
- [ ] r/selfhosted post, open-source announcement
- [ ] **Kill line: no exponential signal in 3 months → stop** (pre-agreed)

## UX micro-cards（NEXT.md 第四节尽量项；产品输入 docs/product/2026-08-04-experience-gaps.md）

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
- [ ] UX-04 「已直连」徽章降级（未开工）
- [ ] UX-05 folder.set 诚实化（未开工）
- [ ] UX-06 移动端「暂停自动备份」+「断开连接」（未开工）
- [ ] UX-07 daemon ephemeral 模式（未开工）
- [ ] UX-03 后台规则一行+极简设置 — **code landed 2026-08-05 (PR #37)**:
      backup page gets one rule line ("插电+WiFi 时自动备份，无需打开
      App") + two switches (仅充电 / 仅 WiFi). BackupSettings persists
      to filesDir JSON (tmp+rename, corrupt→defaults, JVM-tested);
      WorkManager constraints are built from the settings; flipping a
      switch saves + rescheduleAutoBackup (REPLACE — KEEP never updates
      existing constraints). android 52/52. Device acceptance (dumpsys
      jobscheduler constraints follow the switches) pending real phone.

## Standing debts / 挂账

- [ ] PPF_ADVERTISE_ADDR (QR carries LAN IP at boot on cloud boxes)
- [ ] blob-store GC (originals currently duplicated in the blob store)
- [ ] background thumbnail batch generation after ingest
- [ ] Windows smoke (T-040 will carry it)

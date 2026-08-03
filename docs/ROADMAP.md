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
      pending **T-070b** (disk-full never proves ENOSPC fired,
      crash-recovery races a sleep, TTL guard asserts a local copy of
      itself)
- [~] T-060..T-064 cloud workers + self-host compose + relay scripts —
      workers landed (rendezvous pending **T-060b**: alarm starvation,
      duplicate-POST overwrite, overstated security claim); selfhost/
      relay templates pending **T-063b**: reproduced doc-path failures,
      must close the loop on a real VPS
- [ ] H-07 self-hosted relay A/B (**priority raised** — unshipped relay
      domains proven harmful in dogfood smoke); merge T-063b into this
- [~] T-071 release workflow + attestation — pipeline runs end-to-end
      (draft v0.2.0-test.1), acceptance pending **T-071b** supply-chain
      hardening (job-level signing secrets + unpinned actions); no
      user-facing release before T-071b
- [~] T-072 i18n completeness + AV-block guide — landed; small fixes
      in **T-072b** (doc drift, zh-only docs); desktop badge
      regressions split to **T-042b**
- [x] T-061b telemetry fixes — **DONE 2026-08-03** (doubles fixed
      per-event columns so double2 has stable meaning; only POST /ingest
      accepts batches; 14/14 vitest) — **T-061b-fix** closes the
      deployment gap: compiled-in default telemetry URL now carries
      `/ingest` (asserted in config tests), toDataPoint switch is
      exhaustiveness-guarded with assertNever (negative-tested), stale
      header comment fixed
- [ ] T-062b update artifact verification + pinned pubkey (blocks any
      runtime update wiring)
- [ ] H-09 Windows smoke — kit landed, assertions soft (**H-09b**),
      real-box re-run pending
- [ ] H-10 naive-user onboarding line (quickstart docs → cold-start
      walkthrough → human-grade release assets)
- [ ] **Gate: 5–10 household private beta, 2 weeks**

## M4 — Launch / 发布 ⬜

- [ ] T-073 one-page site + README polish
- [ ] r/selfhosted post, open-source announcement
- [ ] **Kill line: no exponential signal in 3 months → stop** (pre-agreed)

## Standing debts / 挂账

- [ ] PPF_ADVERTISE_ADDR (QR carries LAN IP at boot on cloud boxes)
- [ ] blob-store GC (originals currently duplicated in the blob store)
- [ ] background thumbnail batch generation after ingest
- [ ] Windows smoke (T-040 will carry it)

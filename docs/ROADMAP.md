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
- [ ] T-052 pairing by camera scan
- [ ] T-053 MediaStore enumeration + generation watermark
- [ ] T-054 upload executor (WorkManager + FGS segmented migration)
- [ ] T-055 backup status page + timeline browsing
- [ ] T-056 video playback DataSource
- [ ] **Gate: one week of real family dogfood, 100 % backup completion**

## M3 — Hardening / 硬化 ⬜

- [ ] T-070 failure scenarios automated (disk-full, 4 GB file, clock
      jump, crash recovery, revoke mid-transfer)
- [ ] T-060..T-064 cloud workers + self-host compose + relay scripts
- [ ] H-07 self-hosted relay A/B (**priority raised** — unshipped relay
      domains proven harmful in dogfood smoke)
- [ ] T-071 release workflow + attestation
- [ ] T-072 i18n completeness + AV-block guide
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

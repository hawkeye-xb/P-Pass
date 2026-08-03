# M3 review fix cards / M3 评审修复卡

> Source: full four-track code review of the 2026-08-01~02 batch
> (fefa8ce..1d792f9, 21 commits), 2026-08-03. Every finding below was
> verified against code or reproduced; nothing here is speculation.
> 来源：对周末批次的四路代码评审（2026-08-03），每条发现都经代码核实
> 或实测复现，无猜测项。
>
> Rule: a `b` card blocks the acceptance of its parent card. The parent
> stays "code landed, acceptance pending" in ROADMAP until the `b` card
> is green. / 规则：`b` 卡阻塞父卡验收；父卡在 ROADMAP 标
> "代码已落地、验收待 b 卡"直至 b 卡全绿。

## Batch verdict / 批次总评

185/185 Rust tests green locally; rendezvous 7/7 + telemetry 12/12
vitest green; discipline items clean (personal git identity only, no
mainland endpoints, no hardcoded secrets). Systemic weakness: quality
drops sharply outside the author's verification radius (VPS deploys,
Windows real machines, supply-chain hardening) while PROGRESS.md still
says DONE; several test/smoke assertions are tautological or soft-fail.
本地全量测试绿、纪律项干净；系统性短板 = 验证半径之外自信不打折 +
断言松弛（恒真判据/soft-fail 稀释绿灯含金量）。

---

## Cloud-executable (pure code, CI-verifiable) / 云端可修（纯代码，CI 可验证）

### T-071b — release pipeline supply-chain hardening / 发布流水线供应链加固

Blocks: T-071 acceptance; no user-facing release before this is green.

- [ ] Move all Apple signing secrets from job-level `env` down to the
      two steps that need them (codesign / notarize). Job-level env
      exposes the signing key to every third-party action's process
      environment. (`release.yml:37-47`)
- [ ] Pin every third-party action to a commit SHA (`dtolnay/rust-
      toolchain@stable`, `actions/attest-build-provenance@v1`, cache,
      checkout, …). A SLSA-attestation pipeline with floating tags is
      self-contradictory.
- [ ] Fix VirusTotal step: writes `>> ../NOTES.md` from workspace root
      (lands outside the workspace); hoist `VT_API_KEY` gate to job env
      (`release.yml:246-255`).
- [ ] Per-job minimal `permissions:` (release job doesn't need
      id-token/attestations; build jobs don't need contents:write).
- [ ] `find | xargs -0 gh release create` → `gh release create` then
      `gh release upload` (xargs split = second create fails); ship
      SHA256SUMS as an asset, not notes-only.
- [ ] Signing notes: "signed=yes" must also reflect notarization state
      (unnotarized still hits Gatekeeper); fix double-Z timestamp
      (`release.yml:223`).
- [ ] `artifacts.yml` / `pr.yml`: add explicit `permissions:` blocks
      (default token is going read-only), add `concurrency` group to
      artifacts pushes, remove the `|| true` swallowing win-smoke.ps1
      copy failures (`artifacts.yml:139`), timeout on android job.
- [ ] Add actionlint (or equivalent) to pr.yml so workflow bugs stop
      needing a CI round-trip to surface.

Acceptance: re-run tag build end-to-end green; grep proves no secret at
job scope; every `uses:` is SHA-pinned.

### T-062b — update artifact verification + pinned pubkey / 更新工件校验与公钥落地

Blocks: any runtime wiring of update checks (T-071 follow-up).

- [ ] `verify_artifact(bytes, artifact)`: BLAKE3/SHA-256 hash check +
      per-artifact signature check — the download half of the story is
      currently absent (`update.rs:29-33` fields are carried, never
      enforced).
- [ ] Validate `sha256` is 64-hex at parse time; drop
      `#[serde(default)]` on `signature` (empty sig must be a loud
      error, not a skippable field).
- [ ] Land the official pinned public key constant (or a documented
      placeholder + test that it exists before runtime wiring).
- [ ] Freshness: document + test a minimal anti-rollback rule
      (`is_newer` vs current version already exists; add manifest
      `pub_date` staleness note or monotonic counter — decision
      recorded, implementation may stay M4).
- [ ] Fix the comment/assertion mismatch in
      `tampered_manifest_fails_verification` (comment says "must fail",
      asserts `is_ok` on the untampered path).
- [ ] `manifest.example.json` lists 3 platforms, README lists 5 — make
      them agree.

Acceptance: negative tests for wrong hash / wrong artifact sig / empty
sig all red-path tested; `cargo nextest` green.

### T-060b — rendezvous correctness + honest security claims / 会合服务修复与诚实的安全声明

Blocks: T-060 acceptance; must land before any real deployment.

- [ ] Alarm starvation: every POST unconditionally `setAlarm(now+601s)`,
      pushing the sweep forever under steady traffic → consumed
      envelopes linger. Check `getAlarm()` first; only set if none or
      later (`code-store.ts:105`).
- [ ] Duplicate `code_hash` POST silently overwrites an unconsumed
      envelope → cross-family envelope swap is decryptable (key derives
      from the short code alone). Return 409 for live unconsumed hashes
      (`code-store.ts:102-103`).
- [ ] Fix the security narrative: SHA-256 of a 10^6 short-code space is
      dictionary-reversible by the server operator in milliseconds, so
      "server cannot read NodeId" is false. Either (a) rewrite
      README/comments to the honest claim (protects against outsiders,
      not the operator), or (b) raise code entropy / adopt PAKE —
      decision goes to H-07 review. Read-once ≠ unlinkability; delete
      that sentence.
- [ ] Add missing tests: alarm sweep, GET rate limit, wrong-window
      rollover recovery, duplicate POST.

Acceptance: vitest green including the four new tests; README claims
match what the code enforces.

### T-070b — failure-scenario assertion hardening / 故障剧本判据加固

Blocks: T-070 acceptance ("五剧本 CI 绿" only counts with hard evidence).

- [ ] `disk_full.sh` never proves the disk actually filled: assert
      testclient exit != 0 AND grep daemon.err for ENOSPC ("No space
      left"); size the payload so it cannot fit (500×~2KB ≈ 3MB fits in
      the 6MB tmpfs today → scenario can pass without the fault ever
      firing) (`disk_full.sh:70-76`).
- [ ] `crash_recovery.sh`: replace `sleep 2` gamble with polling for
      "blob landed but not committed" before SIGKILL; add cleanup
      `trap` (only script of the three without one); `退出码 $?` after
      `|| true` is always 0 — report the real code.
- [ ] `clock_jump.rs`: assert against the production constant
      `daemon::pairing::TOKEN_TTL_MS`, not a local copy asserted equal
      to itself (`clock_jump.rs:15,147`); annotate the "expired token
      revives after clock restore" assertion as a known, deliberate
      trade-off (NTP rollback revives expired QR) — or change
      `pairing.rs:140` to consume on expiry (product decision, record
      it either way); `rsplit("&t=")` breaks silently if QR gains an
      `&a=` param — parse properly.
- [ ] `revoke_mid_transfer.rs`: rename or extend — no bytes are in
      flight today (manifest→commit with zero blobs, revoke via direct
      db call). Either drive a real mid-upload revoke through IPC or
      rename to `revoke_before_commit` so the card claim stays honest.
- [ ] `testclient/main.rs:311`: `prev = std::fs::read(&path)` runs in
      the `--file-size` branch too → reads a 2-4GB sparse file into
      memory, contradicting the streaming-hash design; keep `prev`
      updates in the small-file branch only; don't swallow errors with
      `unwrap_or_default`.
- [ ] Extract the 4 copy-pasted python `ipc()` heredocs (3 scenario
      scripts + dogfood-smoke) into one sourceable helper.

Acceptance: scenario scripts fail loudly when the fault does NOT fire
(prove by temporarily inverting); `just scenarios` green locally +
disk_full green in CI.

### T-042b — desktop wizard/badge regressions / 桌面向导与徽章回归

Blocks: next desktop release; user-visible regressions.

- [ ] Badge renders raw placeholders: `t(STATE_KEYS[...])` passes no
      vars → INDEXING/STORAGE_OFFLINE show literal `{progress}` /
      `{last_seen}` (`App.svelte:178`). Pass vars from status or add
      placeholder-free desktop variants.
- [ ] Dictionary keys are phone-perspective ("存储电脑离线了", "等待存
      储电脑上确认…") — wrong on the storage computer itself. Add
      desktop-perspective keys (msg_key sharing stays; the dictionary
      gains per-surface variants).
- [ ] Oneshot-degraded users (autostart registration failed — the
      "wizard never dead-ends" path, `lib.rs:126-134`) bounce back to
      wizard step 1 whenever the daemon is down, and re-picking a
      folder re-points the config (orphaned-library risk). Route:
      wizard must prefill existing config / running-state check must
      not rely on `autostart_installed()` alone (`App.svelte:194`).
- [ ] token discovery fix is macOS-only: `ipc.rs:28` hardcodes
      `~/Library/Application Support/P-Pass/config.toml` and `HOME`;
      reuse `platform::adapter().data_dir()` (already a dependency) so
      Windows gets the same fix.
- [ ] The config-parsing "test" rewrites the developer's REAL
      `config.toml` and a panic skips the restore (`ipc.rs:126-144`) —
      rewrite against a temp dir; and wire `apps/desktop/src-tauri`
      tests into pr.yml (they currently never run in CI).
- [ ] Same-screen mixed language: badge is locale-aware but "后台服务
      未运行" and the else-branch stay hardcoded zh (`App.svelte:177`)
      — half-migrated is worse than not migrated; finish the screen.
- [ ] StringsSymmetryTest parses XML with a regex that silently skips
      attributed/multiline entries — switch to a real XML parser
      (silent pass = no protection).

Acceptance: desktop `vite build` + walkthrough of the three states
(indexing / offline / pairing) shows no raw placeholders, no mixed
language, correct perspective; src-tauri tests green in CI.

### H-09b — win-smoke assertion fixes / Windows 冒烟判据修复

Code fixes cloud-executable; re-verification needs a real Windows box.

- [ ] Idempotency check is a tautology: `-match "缺 0|0 个"` matches
      "清单 50 个文件" (`win-smoke.ps1:117`) → tighten to `缺 0 个`.
- [ ] Revoke is a security semantic: hard-fail when post-revoke backup
      is not rejected (today prints "需人工核对" and still says ALL
      GREEN, `:135`); stop discarding IPC Resp for pairing.confirm /
      device.revoke / logs.export.
- [ ] try/finally (or trap) so failed runs stop the daemon instead of
      leaking it against the named pipe.
- [ ] ExitCode quirk: cache `$proc.Handle` after `Start-Process
      -PassThru` (standard fix) instead of matching localized log text;
      correct the runbook attribution (bare pipe name is the .NET
      NamedPipeClientStream contract, not a "PS 5.1 environment bug").
- [ ] `$tokenLines[1]` on a single-line file indexes the 2nd char —
      wrap `@(Get-Content ...)`.

Acceptance: script red when idempotency/revoke actually fail (prove by
inversion locally); then one full re-run on the real Windows box.

### T-061b / T-072b — small fixes / 小修（低优先）

- [ ] telemetry: fixed per-event-type column mapping for AE `doubles`
      (Object.entries order = client field order → `double2` has no
      stable meaning); accept POST only on one path.
- [ ] Doc drift: `infra/relay/README.md:26-28` claims relay domains are
      "compiled into daemon defaults" — stale since `relay_urls = []`;
      `blocked-by-av.md` references a `P-Pass-Setup-x64.exe` that no
      pipeline produces; add the one actually-executable verification
      step (`gh attestation verify <file> -R hawkeye-xb/P-Pass`);
      windows-smoke.md / blocked-by-av.md are zh-only — bilingual rule
      says en primary + zh sibling.

---

## Real-environment required (implementation agent / human) / 需真实环境（实施 agent/人工）

### T-063b — selfhost/relay templates: close the loop on a real VPS / 自建模板真机闭环

Blocks: T-063/T-064 acceptance. The templates demonstrably never ran:

- [ ] `docker compose config` fails outright when `.env` is absent
      (`${RENDEZVOUS_DOMAIN:?}` interpolates file-wide) — reproduced
      locally. Provide a working `.env` bootstrap (or per-service
      defaults) so `up -d relay` alone works.
- [ ] relay LetsEncrypt cannot issue: HTTPS moved to 8443 but ACME
      HTTP-01/TLS-ALPN-01 need 80/443, both owned by caddy which only
      proxies the rendezvous domain → route relay's ACME through caddy
      or use DNS-01.
- [ ] healthcheck exec-array treats `">"`/`"/dev/null"` as wget URLs —
      always fails; use CMD-SHELL (and confirm wget exists in the
      image).
- [ ] cloud-init: never creates `.env`, `sed -i … > /dev/null` edits
      the .example file with a useless redirect; ufw profiles written
      but never `ufw allow`/`ufw enable` — the "SSH + relay ports only"
      comment is currently fiction.
- [ ] `node:22-alpine` + `wrangler dev` as a production runtime is
      suspect (workerd/glibc on musl) — verify on the VPS or switch
      base image / runtime.
- [ ] Then: walk SELFHOST.md top-to-bottom on a fresh VPS, fix every
      stumble, record the run. Merge naturally with **H-07** (Vultr SG
      relay pilot).

Acceptance: a fresh VPS goes from DNS to green Kuma probes using only
the docs; `PPF_RELAY_URLS=<self-hosted>` dogfood-smoke green.

### H-10 — naive-user onboarding line / 「无脑用户」快速上手线

Goal: a non-technical user goes from *nothing* to *phone backing up*
in ≤15 minutes using only what the repo/release hands them. Today that
path does not exist (README is developer-only; releases are unsigned
drafts; no quickstart).

- [ ] **H-10a Quickstart docs** (cloud-executable): README gains a
      "Get started in 10 minutes" section (en + zh): download → open
      P-Pass.app → wizard → scan QR on the phone → first backup; with
      the AV/Gatekeeper caveats linked, screenshots placeholders for
      the human pass. Android install path documented (APK sideload
      until a store exists).
- [ ] **H-10b Cold-start walkthrough** (real devices): a clean Mac +
      one phone, executed literally from the docs by someone who did
      NOT build the product (or an agent role-playing one: no repo
      knowledge allowed, only the README). Log every stumble as a card.
      This is the M2 family-dogfood on-ramp: wife's Mac gets the
      updated bundle, HarmonyOS phone re-pairs once (daemon identity
      changed for the last time), user + family phones get the release
      APK.
- [ ] **H-10c Release artifact for humans**: the draft release ships
      bare binaries; family dogfood needs P-Pass.app (+dmg) and an APK
      as release assets — wire `bundle-macos.sh` + `assembleRelease`
      into release.yml (depends on T-071b).

Acceptance: one real person (not the builder) completes setup from docs
alone; every friction point captured as a card.

---

## Sequencing / 顺序建议

1. **T-071b + T-060b + T-070b + T-042b** — parallel, cloud (independent
   files, no conflicts).
2. **T-062b + H-09b(code) + T-061b/T-072b** — second cloud wave.
3. **H-10a** docs anytime; **H-10c** after T-071b.
4. **T-063b(+H-07)** on the VPS; **H-09b re-run** on the Windows box;
   **H-10b** with real devices — these gate M3, not each other.
5. Main line unchanged: **T-056 video playback on-device check +
   `just verify-m2`** closes M2, then the family dogfood week (M2 gate)
   runs concurrently with the M3 fix waves.

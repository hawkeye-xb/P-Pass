# P-Pass

[中文版 / Chinese version](README.zh.md)

Peer-to-peer photo backup for families: phones back up automatically to
a computer in your own home; everyone in the family browses across
devices. No cloud storage, no accounts, no subscription — original
files are the source of truth and the index can be rebuilt from them at
any time.

**Roadmap & status: [docs/ROADMAP.md](docs/ROADMAP.md)**

## Monorepo layout (every client lives in this one repo)

```
crates/       Rust core (Cargo workspace, 9 crates)
  proto/          Wire format: message types + JSON codec + golden snapshots
  transport/      Transport trait + iroh impl (the ONLY crate importing iroh)
  storage/        SQLite index + migrations + repositories
  core-index/     Ingest / dedup / timeline / rebuild (pure domain logic)
  core-media/     EXIF metadata (pure parsing)
  media-codec/    HEIC/JPEG decode, thumbnails, ffmpeg frame extraction
  platform/       Platform adapter trait (the ONLY crate with platform #[cfg])
  daemon/         Assembly: authz router, pairing, backup intake, queries,
                  local IPC, telemetry
  diag/           Diagnostic state machine + msg_key dictionary + i18n
apps/         Per-platform applications (thin skins; logic lives in crates)
  desktop/        Tauri tray shell (talks to the daemon over local IPC only)
  android/        Android app (iroh-ffi + generated proto types)
infra/        Cloud & self-hosting (everything self-hostable)
  workers/        rendezvous / telemetry / update (Cloudflare Workers)
  relay/          Official relay deployment templates (placeholders only)
  selfhost/       One-command compose for self-hosters
  website/        One-page site
tools/        testclient (agent-drivable scenario CLI), arch-check,
              gen-kotlin, dogfood-smoke.sh
tests/        Cross-module failure scenarios
docs/         Engineering docs: ROADMAP, PROGRESS (log & decisions),
              network matrix, runbooks
```

## Build & caching (native incremental per toolchain, no extra framework)

- **Rust**: Cargo workspace gives incremental builds + a shared `target/`
  cache; CI caches the registry and build artifacts keyed on `Cargo.lock`.
- **Binary distribution**: every push to main builds Linux binaries and
  force-pushes them to the `bin-linux-x64` orphan branch — deploy boxes
  run `git clone -b bin-linux-x64` instead of compiling.
- **Android** (future): Gradle incremental + build cache.
- **Frontend/Workers** (future): pnpm workspace; turborepo only if the JS
  task graph ever warrants it — not introduced today.
- Single task entry point: `just` (`just ci` = fmt + clippy + tests +
  architecture checks).

## Development

```bash
just ci                    # all gates (must be green before committing)
cargo nextest run          # full test suite
tools/dogfood-smoke.sh     # production-shape end-to-end smoke, agent-runnable
```

## Contribution rules

- **Bilingual docs**: user- and contributor-facing documents ship in
  English with a Chinese sibling (`*.zh.md`), or as clearly-sectioned
  bilingual files for short READMEs. Internal engineering logs may be
  Chinese-first; commit messages are English.
- **Agent-first interfaces**: every feature must be drivable and
  verifiable through the testclient CLI / daemon IPC without a human —
  GUIs are skins over those interfaces.
- **Architecture gates**: `iroh` imports only in `transport`; platform
  `#[cfg]` only in `platform`; enforced by `tools/arch-check.sh` in CI.

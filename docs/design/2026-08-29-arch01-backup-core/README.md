# ARCH-01 Backup Core Design Archive

> English companion · archived 2026-08-29 · per-item loop model 2026-09-23  
> Canonical task card: [`ARCH-01`](../../../cards/done/ARCH-01-backup-core-flow-queue-design.md) · Product design: [#413](https://github.com/hawkeye-xb/P-Pass/issues/413) · Chinese primary archive: [`README.zh-CN.md`](README.zh-CN.md)

This directory archives the ARCH-01 product semantics, boundaries, and editable SVG diagrams. It describes logical facts and does **not** choose a table schema, file format, Iroh FFI, or UI layout; the only storage prerequisite is a ledger that supports per-row, transactional writes (see “Logical ledger”). Implementation cards must not redefine these business rules.

## Diagram index

> **Diagrams pending update:** all three diagrams still show a paged pending list, a discovery watermark, an UploadCursor head, and a cancellation round, which do not match the per-item loop model below. The text is authoritative; do not implement from the diagrams until they are redrawn.

| Diagram | Purpose | Preview | Editable source |
|---|---|---|---|
| [01 Architecture and responsibilities](01-architecture.png) | Single pipeline, logical ledger, phone/Desktop boundary (pending update) | PNG | [SVG](01-architecture.svg) |
| [02 Runtime flow](02-runtime-flow.png) | Discovery, per-item loop, Pause, constraints, cancellation (pending update) | PNG | [SVG](02-runtime-flow.svg) |
| [03 States and important transitions](03-state-transitions.png) | Per-item outcomes, user control, scope change, re-pairing (pending update) | PNG | [SVG](03-state-transitions.svg) |

The SVG files are the source assets. They can be edited in a browser, Figma, Illustrator, Inkscape, or a text editor.

## Test contract

- [Failure Case Matrix — Chinese](04-case-matrix.zh-CN.md)
- [Failure Case Matrix — English](04-case-matrix.md)

The matrix maps each product rule to an automated contract test, negative proof, and reviewer-operated device acceptance. Review the matrix before writing production code.

## Agreed product rules

```text
One core pipeline
+ one durable logical ledger on the phone
= UI, background wakes, triggers, and transport obey the same facts.
```

- **The pending list is not materialized.** MediaStore itself is the source of truth for “which photos remain”; the phone keeps no cache of it. After each photo the loop asks MediaStore for the next one. There is no paging window, no discovery watermark, and no pending snapshot.
- **Every decision about a photo must be evidenced by that photo’s own order.** Each photo’s outcome lives on its order: `CONFIRMED` / `FAILED` / `SKIPPED_BY_USER` / `SKIPPED_SOURCE_MISSING` / `CANCELLED_BY_SCOPE`. Range records or cursor positions never stand in for per-photo evidence.
- **A photo’s identity is its content hash (BLAKE3).** `(_id, version)` is only an index for fast filtering; if `_id` changes but the hash does not, it is the same photo and is not re-sent.
- `Pause` is a durable user command. App death, reboot, a network change, or a background wake cannot clear it; only `Continue` can. Every trigger checks Pause first.
- Missing Wi-Fi, low battery, an exhausted daily quota, or an unreachable Desktop means waiting for constraints: release the FGS, register the matching wake-up, resume automatically when the constraint recovers, and consume no failure budget.
- Triggers only mean “new media may exist”; triggers arriving while the loop runs are coalesced. Photos are handled strictly one at a time in ascending generation order; new photos never jump the line.
- A photo becomes `CONFIRMED` only after Desktop has **completely received, verified, durably saved, and explicitly acknowledged** it.
- Once `CONFIRMED`, a later scope change, cancellation, or phone restart cannot revoke that completed fact.
- P-Pass is one-way backup and never deletes the phone original. When reconciliation finds a confirmed photo missing on Desktop, it is **re-sent automatically**; only orders that carry an explicit user decision (`SKIPPED_BY_USER`) are not re-sent.

## Logical ledger

These are logical facts, not a table schema. The one storage prerequisite: orders must be writable per row and per transaction (SQLite). A store that rewrites a whole snapshot on every update gets slower as it grows and forces a paging window; with per-row transactional writes, writing 5000 orders is a single transaction and no window is needed.

| Class | Durable fact | Lifecycle |
|---|---|---|
| User configuration and scope | enabled state, Wi-Fi/battery constraints, selected albums | retained after Desktop change |
| User control | `PAUSED_BY_USER` | only Continue changes it |
| Order table | one row per photo: `(_id, version) → BLAKE3 content hash` plus state; the state is unfinished (resumable) or one of the five outcomes | backup history of the current pairing (see “Change Desktop”) |
| Fast-path hint G | the last `GENERATION_MODIFIED` handled; only an acceleration hint, losing or skewing it loses no photo | discardable at any time; the next slow path covers it |
| MediaStore version | `MediaStore.getVersion()` at the last reconciliation; any change triggers a full reconciliation | phone-local |
| FGS-blocked fact | the FGS was denied or timed out; `startForegroundService` is not called again until the app comes to the foreground (#414) | cleared when the app comes to the foreground |
| Pairing and transfer ownership | current Desktop, valid transfer ownership, and partial ownership | cleared on Desktop change |

The five order outcomes:

| Outcome | Meaning | Does slow reconciliation re-send it automatically? |
|---|---|---|
| `CONFIRMED` | Desktop fully received, verified, durably saved, and acknowledged it | yes, when it is missing on Desktop |
| `FAILED` | a per-photo failure that still failed after one immediate retry | retried once per slow path |
| `SKIPPED_BY_USER` | written per photo by “Cancel remaining N” | no |
| `SKIPPED_SOURCE_MISSING` | the phone original no longer exists | no (nothing to send) |
| `CANCELLED_BY_SCOPE` | found out of scope on resume | open: whether it is re-admitted when its album returns to scope |

### Invariants

```text
Any decision about a photo
= that photo has its own row in the order table, recording the outcome.

Confirmation and bookkeeping
= when a Desktop completion receipt is handled, setting the order to CONFIRMED,
  the (_id, version) → hash mapping, and advancing G happen in one write;
  a half-written ledger is never observable.
  If a crash lands after Desktop confirms but before that write, the photo is sent
  once more after restart; Desktop deduplicates by content, so the result is idempotent.

Desktop completion evidence
= completed fact; later control actions cannot overwrite it.

Same BLAKE3 hash
= same photo; an _id or version change only updates the mapping, never re-sends.

Bulk outcome (Cancel remaining N)
= N rows in one transaction; all take effect or none do.
```

## Discovery

### Fast path

- Query `GENERATION_MODIFIED > G`, ascending by generation. G is only an acceleration hint: a photo the fast path misses is not lost; the next slow path picks it up.
- Content triggers carry the changed URIs in batches; after each photo the loop also uses the fast path to fetch the next one. Photos taken while the loop runs are therefore picked up naturally, and triggers arriving meanwhile are coalesced into the running loop.
- **Open:** `GENERATION_MODIFIED` exists only on API 30+, while the app’s minSdk is 26. The fast-path key on API 26–29, and whether photos can be missed there (and fully covered by the slow path), is undecided.

### Slow path

Triggers: a 5-hour safety net, app open, and a `MediaStore.getVersion()` change (which triggers a full reconciliation).

1. **Merge diff:** sort both MediaStore and the order table by `_id` and merge row by row, reading only `_id`, modification time, and size.
2. **Hash mapping:** compute BLAKE3 for photos that are new or whose version changed.
   - Hash already known: MediaStore was rebuilt or the file moved; only update the `(_id, version) → hash` mapping, do not re-send.
   - New hash: send it (an edited photo is a new version and is sent as such).
3. **Missing source:** orders present in the table but absent from MediaStore become `SKIPPED_SOURCE_MISSING`. **Open:** whether this step applies to `CONFIRMED` orders — if it does, deleting a backed-up original would overwrite a completed fact, contradicting “CONFIRMED cannot be revoked.”
4. **Desktop presence:** ask Desktop, page by page, whether every confirmed photo still exists. Missing ones are **re-sent automatically**; orders carrying an explicit user decision such as `SKIPPED_BY_USER` are not. **Open:** what a photo becomes, and how it is shown, when it is missing on Desktop and the phone original is also gone.
5. **Failure retry:** retry each `FAILED` photo once.

Estimate (not yet measured): a routine pass over 100 000 photos takes seconds; after a MediaStore rebuild, recomputing every hash takes minutes.

## Loop

```text
Trigger (new photo / app to foreground / process start / network-change callback
         / 3 probes 10 minutes apart after unreachability / constraint job / 5h safety net / manual)
→ check inside the worker, without holding an FGS: Pause, background switch (except manual),
  Wi-Fi only, battery, daily quota, Desktop reachable, FGS-blocked fact
  any check fails → register the matching wake-up and stop
→ acquire FGS + PARTIAL_WAKE_LOCK (with a timeout, renewed as progress advances)
→ pick order: ① unfinished orders → ② items the slow path marked for re-send or retry
              → ③ the fast path’s next photo
  before each photo, re-check the conditions above and confirm the FGS is still valid
  hash → create order → transfer
  success → CONFIRMED (in the same write as the bookkeeping)
  per-photo failure → retry once immediately; still failing → FAILED, continue with the next
  path failure → order stays resumable, exit the loop
→ nothing left or a condition fails → release FGS + wakelock
```

- **FGS lifetime = loop lifetime.** It is not started and stopped per photo, and not switched with app foreground/background state (foreground time does not count toward the FGS quota, #411).
- **Transfer verdicts (#410):** no incoming connection for 15 seconds → ask Desktop for status and keep waiting if it answers active; connection alive but no new file bytes for 3 minutes (iroh-blobs `Progress.end_offset` does not advance) → disconnect and classify as a path failure.
- **Partially transferred data:** iroh-blobs verifies chunk by chunk with bao as it receives, and resume fetches only the missing parts. If Desktop garbage-collects a partial, the fetch restarts from zero and is still correct; GC affects cost, never correctness.

### Three failure classes

| Class | Examples | Handling |
|---|---|---|
| Path failure | Desktop unreachable, handshake failure, no new bytes for 3 minutes | order stays resumable; exit the loop, release the FGS, register a wake-up; not counted as a per-photo failure |
| Per-photo failure | this photo cannot be read, hashing fails | retry once immediately; still failing → `FAILED`, loop continues with the next photo; the slow path retries once more |
| Peer failure | Desktop explicitly reports it cannot receive or save | **Open:** #413 does not define the handling (count as per-photo or not, exit the loop or not, which wake-up to register) |

## Control semantics

| State/action | Meaning | Who may resume it |
|---|---|---|
| `PAUSED_BY_USER` | Exit the loop and release the FGS with no keep-alive; the process may be killed. Every trigger checks it first; nothing is sent while paused | Only user Continue |
| `WAITING_FOR_CONSTRAINTS` | Wi-Fi, battery, daily quota, or Desktop is temporarily unavailable: release the FGS and register a wake-up (network-change callback / 3 probes 10 minutes apart after unreachability / constraint job / on quota exhaustion, wait for the app to come to the foreground) | Resumes automatically once the wake-up arrives and the constraint recovers |
| FGS denied or timed out | Record the FGS-blocked fact and exit the loop; do not call `startForegroundService` again until the app comes to the foreground (#414) | App comes to the foreground |
| `DISABLED` | Background switch is off: automatic triggers no longer start the loop; manual triggers are unaffected | User enables it |
| Cancel remaining N | Write each of the N photos that have no outcome yet as `SKIPPED_BY_USER` (one transaction); the photo in flight is cancelled too and Desktop is told to drop its partial data | Open: see “Cancellation” |

## Scope, cancellation, and pairing

### Scope

A scope change does nothing on the spot; the next query simply uses the new scope. The current photo (in flight, or partially sent when paused) is re-checked before every resume:

```text
album still in scope and original present → resume
album removed from scope                  → CANCELLED_BY_SCOPE; tell Desktop to drop the partial
original deleted                          → SKIPPED_SOURCE_MISSING
```

- `CONFIRMED` photos are unaffected by scope changes.
- **Open:** whether the photo in flight at the moment of a scope change is interrupted on the spot or allowed to finish; the pre-resume check only covers resuming after a pause or interruption.
- **Open:** historical photos in a newly added album have generations older than G, so the fast path cannot see them; they wait for the next slow path (app open / 5h safety net). Whether a scope change should trigger a slow path immediately is undecided.

### Cancellation

The UI reads “Cancel remaining N”. N is the number of in-scope photos without an outcome at the moment of confirmation.

```text
User confirms “Cancel remaining N”
→ in one transaction, write each of the N photos as SKIPPED_BY_USER
→ cancel the photo in flight too; tell Desktop to drop its partial data
→ exit the loop, release the FGS
→ photos taken afterwards are backed up as usual
```

- The slow path neither re-sends nor retries `SKIPPED_BY_USER`; it is an explicit user decision.
- **Open:** the way out of `SKIPPED_BY_USER` — whether the settings entry “Skipped photos” keeps a restore action, and whether restoring moves those orders into the re-send list.
- **Open:** whether writing N `SKIPPED_BY_USER` orders requires computing each photo’s hash on the spot (orders use the hash as identity; for a large N that is expensive).
- **Open:** whether cancellation requires a prior Pause.

### Change Desktop

```text
Keep: user configuration and album choices
Clear: partials, running transfer state, and old Desktop ownership
Result: the new Desktop starts a new backup history
```

**Open:** how order history is separated by pairing (`pairingEpoch`), and whether orders from the old pairing are kept.

### Migration

There are no production users yet, so the old ledger is cleared outright. The first full slow reconciliation rebuilds the order table; Desktop deduplicates by content, so nothing is transferred twice.

## Implementation gate

The next phase does not revisit product semantics. It translates them into failure tests and local atomic-commit boundaries, in this order:

```text
Order table (SQLite) with confirmation and bookkeeping in one write
→ fast-path / slow-path discovery and hash mapping
→ per-item loop, FGS + wakelock lifetime, three failure classes
→ Pause / Continue / Cancel remaining N / scope change
→ native transport, partial lifecycle, and restart recovery
→ scheduler and UI
```

# ARCH-01 Backup Core Design Archive

> English companion · 2026-08-29  
> Canonical task card: [`ARCH-01`](../../../cards/ARCH-01-backup-core-flow-queue-design.md) · Chinese primary archive: [`README.zh-CN.md`](README.zh-CN.md)

This directory archives the agreed ARCH-01 product semantics, boundaries, and editable SVG diagrams. It intentionally does **not** choose a database, file format, Iroh FFI, or UI layout. Implementation cards must not redefine these business rules.

## Diagram index

| Diagram | Purpose | Preview | Editable source |
|---|---|---|---|
| [01 Architecture and responsibilities](01-architecture.png) | Single pipeline, logical ledger, phone/Desktop boundary | PNG | [SVG](01-architecture.svg) |
| [02 Runtime flow and cancel-current-round](02-runtime-flow.png) | Discovery, strict delivery, Pause, constraints, cancellation | PNG | [SVG](02-runtime-flow.svg) |
| [03 States and important transitions](03-state-transitions.png) | Item state, user control, scope change, re-pairing | PNG | [SVG](03-state-transitions.svg) |

The SVG files are the source assets. They can be edited in a browser, Figma, Illustrator, Inkscape, or a text editor.

## Agreed product rules

```text
One core pipeline
+ one durable logical ledger on the phone
= UI, background wakes, triggers, and transport obey the same facts.
```

- `Pause` is a durable user command. App death, reboot, a network change, or a background wake cannot clear it; only `Continue` can.
- Missing Wi-Fi, insufficient battery, or an unreachable Desktop means waiting for constraints. It may resume automatically when constraints recover and does not consume an item failure budget.
- Triggers only mean “new media may exist.” Equivalent triggers are coalesced. Discovery advances by a durable watermark; delivery consumes exactly one item at a time.
- An item becomes `CONFIRMED` only after Desktop has completely received, verified, durably saved, and explicitly acknowledged it.
- Once `CONFIRMED`, a later scope change, cancellation, or phone restart cannot revoke that completed fact.
- P-Pass is one-way backup. An externally missing Desktop copy becomes a user-decision fact; it never auto-reuploads or deletes the phone original.

## Logical ledger

These are logical facts, not a storage-technology decision. Small user preferences, the queue ledger, and transport partials may use different implementations as long as the invariants hold.

| Class | Durable fact | Lifecycle |
|---|---|---|
| User configuration and scope | enabled state, Wi-Fi/battery constraints, selected albums | retained after Desktop change |
| User control | `PAUSED_BY_USER` | only Continue changes it |
| Discovery progress | safely handled media position and backfill requests | phone backup history |
| Per-item queue and completion evidence | order, current item, outcome, errors, Desktop completion evidence | current Desktop transfer history |
| Cancellation round | active cancellation, cancellation scan progress, cancelled items | restorable or discardable |
| Pairing and transfer ownership | current Desktop and valid partial ownership | cleared on Desktop change |

### Invariants

```text
Advance discovery progress
= the page is durably queued or durably cancelled.

Desktop completion evidence
= completed fact; later control actions cannot overwrite it.

Active cancellation round
= every item admitted to the pending list is cancelled, never delivered.

Change Desktop
= keep user configuration; clear old queue, progress, cancellation round,
  partials, running transfers, and old Desktop ownership.
```

## Control semantics

| State/action | Meaning | Who may resume it |
|---|---|---|
| `PAUSED_BY_USER` | Explicit stop of queue consumption | Only user Continue |
| `WAITING_FOR_CONSTRAINTS` | Wi-Fi, battery, or Desktop is temporarily unavailable | Constraints recover |
| `RETRYING` | One item has a retryable error | Retry policy |
| `DISABLED` | Automatic backup accepts no automatic work | User enables it |
| `Cancel Current Round` | After Pause, cancel every unfinished pending item in this round | Explicit Restore re-admits |

## Scope, cancellation, and pairing

### Scope

- **Add albums:** preserve the current head/window; record a historical backfill for the new albums and append results later.
- **Remove albums:** old items without Desktop completion evidence are cancelled. Items with durable Desktop completion evidence remain `CONFIRMED`, even if the acknowledgement arrives later.

### Cancel Current Round

```text
Pause
→ Cancel Current Round
→ cancel existing unfinished pending items
→ discover remaining candidates in 500-item pages and cancel them directly
→ cancel any item admitted while the cancellation round remains active
→ atomically close when the round has no pending item left
→ items admitted after close belong to the next round
```

`Restore Cancelled Round` re-admits that round’s cancelled items. `Discard Cancelled Round` removes the quick restore entry without affecting later new media.

### Change Desktop

```text
Keep: user configuration and album choices
Clear: old queue, discovery progress, cancellation round, partials,
       running transfer state, and old Desktop ownership
Result: the new Desktop starts a new transfer history
```

## Implementation gate

The next phase does not revisit product semantics. It translates them into failure tests and local atomic-commit boundaries, in this order:

```text
Phone logical ledger and atomic discovery
→ strict consumer and completion evidence
→ Pause / Continue / Cancel Current Round
→ native transport, partial lifecycle, and restart recovery
→ scheduler and UI
```

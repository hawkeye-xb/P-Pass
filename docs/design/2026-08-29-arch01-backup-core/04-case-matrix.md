# ARCH-01 Failure Case and Acceptance Matrix

> English companion · 2026-08-29  
> Product-rule source: [`ARCH-01`](../../../cards/ARCH-01-backup-core-flow-queue-design.md) · Chinese primary matrix: [`04-case-matrix.zh-CN.md`](04-case-matrix.zh-CN.md)

This is the pre-production test contract. Every case is first written as a failing behavioral test; minimal implementation is written only after the failure has been observed for the expected reason. The matrix introduces no new product semantics and does not choose a database, file format, or UI.

## Three evidence layers

| Layer | Purpose | Executor |
|---|---|---|
| Contract tests | Lock product rules through public commands and ledger projections | Automated development tests |
| Fault / negative tests | Simulate crashes, late receipts, and races; removal of a protection must fail | Automated development tests |
| Device acceptance | Verify UI, OS wakes, real connectivity, and visible user result | Reviewer |

Device acceptance uses a dedicated disposable test album only. It must not write, delete, or otherwise damage a real photo library.

## Delivery order

```text
D discovery atomicity
→ C consumer control
→ E completion receipt and scope
→ X cancel current round
→ P change Desktop
→ R restore/discard and remote reconciliation
→ native transport adapter, scheduling, UI
```

## P0: Discovery watermark and local admission

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| D-01 | 500 candidates after watermark W | Commit one discovery page | all 500 enter pending list; watermark moves to page end | writing watermark without queue must fail | no manual timing required |
| D-02 | Same as D-01 | crash before local commit | neither queue nor watermark changes; restart finds all 500 | moving watermark first must fail | kill app during discovery; pending items must not disappear |
| D-03 | D-01 committed then immediate crash | discover again after restart | no duplicate item for the same media version | removing stable-id dedupe must fail | repeated foreground/background changes do not inflate pending count |
| D-04 | cancellation round active, candidates after watermark | discover a page | candidates become `CANCELLED_BY_USER_ROUND`; watermark still advances | admitting them as `QUEUED` must fail | covered by X-02 |

## P0: Consumer control and strict head

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| C-01 | #18 native transfer active, #19 behind it | user pauses | #18 stops; partial remains; cursor stays #18; #19 never starts | allowing #19 to start must fail | pause in-flight transfer; no later item begins |
| C-02 | user pause is durable | reboot, background wake, network restoration, repeated triggers | remains paused; no transfer | any wake clearing pause must fail | pause, kill/reopen app, foreground/background, restore network: still paused |
| C-03 | paused with unfinished #18 | user continues | resumes #18 only; no Manual/full-scan second pipeline | Continue creating a new pipeline must fail | Continue resumes original pending item |
| C-04 | #18 active | Wi-Fi/battery/Desktop constraint fails | stops with partial; failure budget unchanged; recovery auto-resumes #18 | counting wait as failure or requiring Continue must fail | turn off Wi-Fi or Desktop; restore and verify auto-resume |
| C-05 | #18 has a real permanent error | retry budget exhausted | #18=`FAILED_NEEDS_USER`; strict head may then advance | infinite retry or unrecorded skip must fail | primarily automated; review error and available recovery action |

## P0: Completion evidence and scope race

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| E-01 | Desktop fully received, verified, durably saved, and issued receipt | phone handles receipt | #18=`CONFIRMED`; cursor advances | confirming merely at transfer start must fail | completed test photo displays as backed up |
| E-02 | #18 already has completion evidence | scope is reduced and receipt arrives late | #18 remains `CONFIRMED` | letting scope overwrite completed fact must fail | complete a test photo, then remove its album; confirmation remains |
| E-03 | #18 has no completion evidence / only partial | scope is reduced | #18=`CANCELLED_BY_SCOPE`; partial cannot finally confirm | allowing old partial to confirm must fail | remove an in-flight test photo's album; it must not finish |
| E-04 | #18 confirmed | Cancel Current Round | #18 stays `CONFIRMED` | turning completed item into cancellation must fail | completed photo is unaffected by cancellation |

## P0: Cancel Current Round

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| X-01 | paused; 500 discovered and 400 still to discover | cancel current round | cancel first 500, discover/cancel next 400, deliver none | cancelling only visible 500 must fail | small album variant; 900 items stay automated |
| X-02 | cancellation round active | new item enters pending list | new item becomes `CANCELLED_BY_USER_ROUND` | turning it `QUEUED` must fail | add/trigger a test photo during cancellation; it must not transfer |
| X-03 | cancellation sweep partly complete | app restarts | resume saved cancellation progress; no missed cancellation or delivery | reset/omission after restart must fail | automated |
| X-04 | round has no pending item | atomically close then admit new item | new item belongs to next round and may queue | cancelling post-close item must fail | after cancellation closes, capture a test photo; it is eligible later |
| X-05 | one cancelled round exists | user Restore / Discard | Restore re-admits only its unfinished items; Discard removes shortcut only | ordinary trigger reviving cancellation must fail | validate Restore/Discard affordances and outcomes |

## P0: Change Desktop and isolate old results

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| P-01 | Wi-Fi/battery/album settings plus queue, watermark, cancellation round, partial | pair a new Desktop | settings stay; old queue, watermark, round, partial, and runtime ownership clear | clearing settings or retaining old runtime data must fail | switch Desktop; settings remain and old pending work does not follow |
| P-02 | paired to new Desktop | late old-Desktop receipt arrives | old receipt cannot mutate new transfer history | old receipt confirming new history must fail | automated |

## P1: Remote reconciliation

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| R-01 | confirmed item missing externally on Desktop; phone source remains | low-frequency reconciliation | `remotePresence=MISSING` + `NEEDS_DECISION`; no auto-upload | auto-uploading on missing evidence must fail | test on disposable copy only; review the prompt |
| R-02 | both Desktop and phone source missing | low-frequency reconciliation | `UNRECOVERABLE` and explicit message | claiming recovery is possible must fail | automated |

## Required observable evidence

Tests and device diagnostics record state facts only, never photo names, paths, or content:

```text
Discovery page: size, watermark before/after, queued count, cancelled count
Control: persisted Pause/Continue; waiting and recovery reason
Item: sequence, state change, failure reason, completion receipt received
Cancellation round: start, per-page progress, completion, total cancelled
Pairing: old runtime data cleared; user settings retained
```

## Reviewer checklist

Before an implementation card starts:

- [ ] The card cites concrete IDs from this matrix and does not alter product semantics.
- [ ] Every automated case has Given / When / Then and a reproducible command.
- [ ] Each P0 risk has negative proof: removing its protection makes the test red.
- [ ] Device steps use only a test album and state the visible expected result.
- [ ] Diagnostic evidence contains no photo path, name, or content.

After an implementation card completes, review red→green output, negative-proof output, and the relevant device checklist. The reviewer never needs to manually manufacture crashes, 900-item pagination, or races.

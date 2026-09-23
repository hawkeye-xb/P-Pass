# ARCH-01 Failure Case and Acceptance Matrix

> English companion · archived 2026-08-29 · per-item loop model 2026-09-23  
> Product-rule source: [`ARCH-01`](../../../cards/done/ARCH-01-backup-core-flow-queue-design.md) · [#413](https://github.com/hawkeye-xb/P-Pass/issues/413) · Chinese primary matrix: [`04-case-matrix.zh-CN.md`](04-case-matrix.zh-CN.md)

This is the pre-production test contract. Every case is first written as a failing behavioral test; minimal implementation is written only after the failure has been observed for the expected reason. The matrix introduces no new product semantics and does not choose a table schema or UI.

How to read a row: **Given + When = trigger**; **Then = expectation**; **Negative proof = which protection, once removed, must turn the test red**; **Device acceptance = the reviewer’s steps and visible result**. The decisions behind each row are the two ruling comments on #413 (leftovers of #415 / #416).

## Three evidence layers

| Layer | Purpose | Executor |
|---|---|---|
| Contract tests | Lock product rules through public commands and ledger projections | Automated development tests |
| Fault / negative tests | Simulate crashes, late receipts, and races; removal of a protection must fail | Automated development tests |
| Device acceptance | Verify UI, OS wakes, real connectivity, and visible user result | Reviewer |

Device acceptance uses a dedicated disposable test album only. It must not write, delete, or otherwise damage a real photo library.

## Delivery order

```text
O orders and set difference
→ D discovery
→ C per-item loop and consumer control
→ E completion receipt
→ X cancellation and scope change
→ P change Desktop
→ native transport adapter, scheduling, UI
```

## P0: Orders and set difference

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| O-01 | a new in-scope photo #N with generation greater than G; #N has no order | content trigger starts the loop | the fast path `GENERATION_MODIFIED > G` finds #N; BLAKE3 → create order → transfer → `CONFIRMED` | removing the fast-path query (relying on the slow path only) leaves #N unsent in this loop, which must fail | take a photo in the test album with the app in the foreground; it becomes backed up without opening settings or waiting 5h |
| O-02 | #M is in scope with no order, but its generation is not greater than G (G ran ahead or the hint was lost, so the fast path missed it) | slow path runs (app open / 5h safety net) | the `_id` merge diff finds #M has no order; after hashing it is sent and ends `CONFIRMED` | letting the slow path handle only rows `> G` means #M is never sent, which must fail | primarily automated (a fast-path miss is hard to produce by hand) |
| O-03 | #K is `CONFIRMED` with hash H; after a MediaStore rebuild #K has a new `_id`, same content | slow path (full reconciliation triggered by a `getVersion` change) | the new `_id` hashes to H and hits the existing order: only the `(_id, version) → H` mapping is updated, no new transfer, transfer count 0 | removing “known hash → update mapping only” causes a re-send, which must fail | primarily automated; on device only check the home-screen backed-up count does not drop after a large media-library change |
| O-04 | #K is `CONFIRMED` with hash H1 | the user edits and saves #K; content becomes H2 | sent as a new version: a new order for H2 is created and transferred to `CONFIRMED`; the H1 order stays `CONFIRMED` | deduplicating by `_id` only (ignoring version / hash) leaves H2 unsent, which must fail | edit a backed-up test photo (e.g. rotate or crop); it is sent to Desktop again |
| O-05 | #S has an unfinished or `FAILED` order; the original was deleted from the phone | slow-path merge diff | #S becomes `SKIPPED_SOURCE_MISSING`; no further transfer or retry. A `CONFIRMED` order is not rewritten, only flagged `source_missing`; when the original reappears, `SKIPPED_SOURCE_MISSING` becomes transferable again and the flag clears | keeping a source-missing order retryable makes every slow path retry and fail, which must fail | delete a pending test photo in the system gallery, then open the app; it no longer appears in pending progress |
| O-06 | N in-scope photos have no outcome | user confirms “Cancel remaining N”, then the slow path runs | one transaction writes N `SKIPPED_BY_USER` orders; the slow path neither re-sends nor retries these N | cancellation that only exits the loop without writing orders lets the next slow path re-send all N, which must fail; letting the slow path put `SKIPPED_BY_USER` into the re-send list must also fail | put 5 new photos in the test album; after the first is sent tap “Cancel remaining 4”, kill and reopen the app and wait for a background wake: those 4 are never sent |
| O-07 | the last chunk of #R has arrived and Desktop issues a completion receipt | the phone handles the receipt; fault injection: crash during the write | order=`CONFIRMED`, the hash mapping, and advancing G take effect in one write; after the crash either all three exist or none do (then the photo is re-sent after restart and Desktop deduplicates by content) | splitting `CONFIRMED` and the mapping into two writes makes “`CONFIRMED` without mapping” or “mapping without confirmation” observable, which must fail | primarily automated |
| O-08 | #K is `CONFIRMED`; its Desktop copy was deleted externally; the phone original remains | slow path asks Desktop for presence page by page | #K is marked for re-send and the next loop re-sends it automatically (pick order ②) to `CONFIRMED` | removing the Desktop presence check, or only recording the miss without re-sending, must fail | on a disposable test copy, delete a backed-up photo on Desktop and open the app; it is sent back automatically |
| O-09 | #F is `FAILED` | the slow path runs twice and every retry of #F fails | each slow path retries once; still failing stays `FAILED`, never looping within one slow path | removing the once-per-slow-path limit yields infinite retries, which must fail; removing the slow-path retry means #F is never tried again, which must also fail | primarily automated |
| O-10 | a slow path has finished | query the state of every in-scope `_id` | each photo has an outcome order, an unfinished order waiting to send, or is a new photo found in this pass; no photo is ambiguous between “skipped” and “missed” | replacing per-photo orders with range records leaves photos whose generation changed after editing without an answerable state, which must fail | primarily automated |
| O-11 | #K is `CONFIRMED`, missing on Desktop, and the phone original is also deleted | slow path | #K stays `CONFIRMED` (with the `source_missing` flag); only an `unrecoverable` audit event is recorded; no re-send, no UI | treating it as re-sendable (inserting a pending row) tries to send an original that no longer exists, which must fail | primarily automated |

## P0: Discovery

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| D-01 | g=10 and g=11 are pending; a new photo g=20 is taken | the loop picks the next photo | order is 10 → 11 → 20; new photos never jump the line | putting URIs from a new trigger at the front makes 20 go first, which must fail | primarily automated |
| D-02 | the loop is sending #1 | 3 content triggers arrive in a row | only one loop runs; their URIs are coalesced, no second loop starts, no repeated FGS request | starting a loop per trigger causes concurrent transfers or multiple FGS requests, which must fail | take 3 test photos quickly during a transfer; only one FGS notification is shown |
| D-03 | the loop is sending #1; a new photo #N is taken meanwhile | #1 completes and the loop picks the next photo | the fast path finds #N and sends it within the same loop, with no extra trigger | a loop that consumes only its start-time snapshot (a materialized queue) leaves #N for the next trigger, which must fail | take a new photo while a large file is transferring; it is sent within the same notification progress |
| D-04 | G is lost or reset; most photos are `CONFIRMED` | fast-path query | photos with outcome orders are filtered by their orders and not re-sent; no photo is lost | skipping the order filter in the fast path re-sends confirmed photos, which must fail | primarily automated |
| D-05 | the last reconciliation recorded `getVersion` V1 | the MediaStore version becomes V2 and any trigger arrives | a full reconciliation runs (all 5 slow-path steps) and V2 is recorded | ignoring the `getVersion` change leaves `_id` changes after a MediaStore rebuild unhandled, which must fail | primarily automated |
| D-06 | among 10 000 photos only 3 are new or changed | slow-path merge diff | only `_id`, modification time, and size are read; BLAKE3 is computed only for those 3 | hashing unchanged photos makes the hash call count exceed 3, which must fail | primarily automated; timing measurement is listed under “to be measured” in #413 |
| D-07 | device on API 26–29 (no `GENERATION_MODIFIED`), or more than one external volume | fast path | API 26–29 uses `DATE_MODIFIED > G` as a speed-up hint and the slow path covers misses; G is stored and queried per volume | a fast path that queries only one volume never sends photos on other volumes, which must fail | on a device with an SD card, take a photo in an SD-card test album; it is backed up |

## P0: Per-item loop and consumer control

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| C-01 | #18 is transferring, more photos follow | user pauses | exit the loop; release FGS and wakelock; #18’s order stays resumable and its partial is kept; the next photo does not start; no keep-alive | still holding the FGS after pause, or starting the next photo, must fail | pause during a transfer: the FGS notification disappears and no next photo starts |
| C-02 | paused | app restart, background wake, network restoration, repeated triggers, manual trigger | still paused; the worker sees Pause and stops without requesting an FGS or transferring | any trigger skipping the Pause check, or able to clear Pause, must fail | after pausing, kill/reopen the app, switch foreground/background, toggle Wi-Fi: still paused, no FGS notification |
| C-03 | paused; #18’s order is unfinished; there are also slow-path re-send items and fast-path new photos | user continues | pick order: ① resume #18 → ② re-send or retry items → ③ the fast path’s next photo | shuffling the pick order (e.g. fast-path new photos first) makes #18 not the first, which must fail | pause a half-sent photo, then Continue: progress resumes on that photo |
| C-04 | not paused; Wi-Fi only is on but the network is mobile (or battery low, daily quota exhausted, Desktop unreachable) | any trigger | the in-worker check fails: no FGS request; the matching wake-up is registered (network-change callback / 3 probes 10 minutes apart after unreachability / constraint job / on quota exhaustion, wait for app foreground) | requesting an FGS while a condition fails, or not registering a wake-up so recovery never resumes, must fail | enable “Wi-Fi only” and switch to mobile data: no FGS notification; switch back to Wi-Fi and transfer starts automatically |
| C-05 | #18 is transferring | Wi-Fi, battery, or Desktop condition is lost | exit the loop, release the FGS, register a wake-up; #18 stays resumable and is not counted as a failure; after the wake-up it resumes automatically | counting the wait as a failure, or requiring user Continue, must fail | turn Desktop off during a transfer and back on: it resumes automatically with no error or Continue button |
| C-06 | 3 photos pending, all conditions met | one trigger | the whole loop requests FGS + PARTIAL_WAKE_LOCK once; both are released after the 3 photos when nothing is left | starting/stopping the FGS per photo gives 3 requests, or holding it after the loop ends, must fail | send 3 photos in a row: the FGS notification does not flicker and disappears when done |
| C-07 | inside the loop, #18 has completed | before #19 a condition changed (e.g. Pause just set, or the FGS is no longer valid) | conditions and FGS validity are re-checked before each photo; if not met, #19 does not start and the loop exits | checking only once at loop start lets #19 start with a failed condition, which must fail | primarily automated |
| C-08 | a background trigger’s FGS request is denied by the system, or the FGS times out | another background trigger in the same process or after restart | record the FGS-blocked fact and exit; do not call `startForegroundService` until the app comes to the foreground; on foreground, clear the fact and continue | repeatedly requesting in the background after denial (#414) must fail | primarily automated; on device only check it resumes automatically after returning to the foreground |
| C-09 | #18 cannot be read (per-photo failure) | transfer #18 | retry once immediately; still failing → `FAILED`; the loop continues with #19 | no retry, infinite retry, or a failure that blocks later photos must fail | primarily automated |
| C-10 | #18’s connection is alive but no new file bytes for 3 minutes (`Progress.end_offset` does not advance) | transfer verdict | disconnect and classify as a path failure: #18 stays resumable, exit the loop, release the FGS, not counted as a per-photo failure | waiting forever, or recording the path failure as `FAILED`, must fail | primarily automated |
| C-11 | no Desktop connection for 15 seconds | transfer verdict | ask Desktop for status; keep waiting if it answers active, no failure verdict | failing directly at 15 seconds must fail | primarily automated |
| C-12 | Desktop explicitly reports it cannot store the photo (`storage_failed`, peer failure) | transfer #18 | exit the loop and release FGS; #18 stays resumable and no per-photo attempt is counted; wait for the next wake-up. `fetch_failed` is a path failure; unknown codes are per-photo failures | counting a peer failure as a per-photo attempt (`FAILED`) must fail; ignoring the code and treating everything as per-photo must fail | fill the Desktop disk, send a photo: no failure count appears; after freeing space the next wake-up finishes it |

## P0: Completion receipt

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| E-01 | Desktop fully received, verified, durably saved, and issued a receipt for #18 | phone handles the receipt | #18=`CONFIRMED` (in the same write as the bookkeeping, see O-07); the loop picks the next photo | confirming merely at transfer start or when the last chunk is sent must fail | a completed test photo displays as backed up |
| E-02 | #18 already has completion evidence | scope is reduced and the receipt arrives late | #18 remains `CONFIRMED` | letting scope overwrite the completed fact must fail | complete a test photo, then remove its album; confirmation remains |
| E-03 | #18 is `CONFIRMED` | user “Cancel remaining N” | #18 is not counted in N and stays `CONFIRMED` | rewriting a completed item as `SKIPPED_BY_USER` must fail | backed-up photos are unaffected by cancellation; the home-screen backed-up count does not drop |

## P0: Cancellation and scope change

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| X-01 | N in-scope photos have no outcome; #18 among them is in flight | the UI shows “Cancel remaining N” and the user confirms | one transaction writes N `SKIPPED_BY_USER` orders; #18’s transfer is cancelled and Desktop is told to drop its partial; the loop exits and releases the FGS; zero photos continue | ending the loop without writing orders lets the next trigger re-send the same photos, which must fail | 5 new photos in the test album; cancel while the 2nd is half sent: the button shows the remaining count, nothing continues after confirming, the FGS notification disappears |
| X-02 | same as X-01 | fault injection: crash in the middle of the transaction writing N rows | after restart either all N exist or none; the N shown in the UI equals the number written | committing rows independently leaves only part of the `SKIPPED_BY_USER` rows after restart, which must fail | primarily automated |
| X-03 | “Cancel remaining N” done | a new photo #P is taken and a trigger arrives | #P gets an order and is sent normally; the N photos stay unsent | implementing cancellation as “pause” or “disable auto backup” leaves #P unsent, which must fail | take a test photo after cancelling; it is backed up normally while the cancelled photos stay put |
| X-04 | #18 is transferring | user changes the album scope | no order written and no scan on the spot; the next fast / slow path query uses the new scope. #18 in flight is allowed to finish, and the next photo is checked against the new scope before it starts; adding an album triggers a slow path immediately | synchronously scanning and bulk-rewriting orders on scope change must fail | primarily automated |
| X-05 | #18 half sent then paused; its album is still in scope and the original exists | user continues | #18 resumes, fetching only the missing parts | discarding the partial and restarting on resume transfers more bytes than remain, which must fail | pause a large file and Continue: progress resumes from where it stopped |
| X-06 | #18 half sent then paused; the user removes #18’s album from scope | user continues | #18=`CANCELLED_BY_SCOPE`; Desktop is told to drop the partial; the loop picks the next photo; the partial can never finally confirm | not re-checking scope before resume lets #18 finish, which must fail | after pausing, remove the album and Continue: that photo is not sent |
| X-07 | #18 half sent then paused; the original is deleted in the system gallery | user continues | #18=`SKIPPED_SOURCE_MISSING`; the loop picks the next photo | reporting the deleted file as a per-photo failure and retrying must fail | after pausing, delete the test photo in the system gallery and Continue: it no longer appears in progress |

## P0: Change Desktop and isolate old results

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| P-01 | Wi-Fi/battery/album settings plus unfinished orders and partials | pair a new Desktop | settings stay; partials and runtime ownership clear; the new Desktop starts a new backup history: switching Desktop clears the order table (the `pairing_epoch` column stays as a guard) and new order ids start above a timestamp | clearing settings or carrying old partials to the new Desktop must fail | switch Desktop; settings remain and old transfer progress does not follow |
| P-02 | paired to new Desktop | late old-Desktop receipt arrives | old receipt cannot mutate the new backup history | old receipt confirming new history must fail | automated |

## Required observable evidence

Tests and device diagnostics record state facts only, never photo names, paths, or content:

```text
Discovery: fast / slow path, G before/after, merge-diff row count, hash computations, hash hits, getVersion before/after
Orders: state changes, outcome, bulk write count (Cancel remaining N), re-send and retry counts
Loop: FGS and wakelock acquire/release, FGS-blocked fact, pre-photo condition check result
Control: persisted Pause/Continue; waiting reason, registered wake-up, and recovery reason
Failures: path / per-photo / peer class, per-photo retry count
Pairing: old runtime data cleared; user settings retained
```

## Reviewer checklist

Before an implementation card starts:

- [ ] The card cites concrete IDs from this matrix and does not alter product semantics.
- [ ] Every automated case has Given / When / Then and a reproducible command.
- [ ] Each P0 risk has negative proof: removing its protection makes the test red.
- [ ] Device steps use only a test album and state the visible expected result.
- [ ] Diagnostic evidence contains no photo path, name, or content.

After an implementation card completes, review red→green output, negative-proof output, and the relevant device checklist. The reviewer never needs to manually manufacture crashes, a MediaStore rebuild, bulk order writes, or races.

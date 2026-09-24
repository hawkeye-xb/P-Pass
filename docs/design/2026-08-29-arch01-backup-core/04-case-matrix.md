# ARCH-01 Failure Case and Acceptance Matrix

> English companion · archived 2026-08-29 · aligned with the #413 final design 2026-09-24  
> Product-rule source: [`ARCH-01`](../../../cards/done/ARCH-01-backup-core-flow-queue-design.md) · [#413](https://github.com/hawkeye-xb/P-Pass/issues/413) · [Final design summary](final-design-413.md) · Chinese primary matrix: [`04-case-matrix.zh-CN.md`](04-case-matrix.zh-CN.md)

This is the pre-production test contract. Every case is first written as a failing behavioral test; minimal implementation is written only after the failure has been observed for the expected reason. The matrix introduces no new product semantics and does not choose a table schema or UI.

How to read a row: **Given + When = trigger**; **Then = expectation**; **Negative proof = which protection, once removed, must turn the test red**; **Device acceptance = the reviewer’s steps and visible result**. Each row is grounded in [`final-design-413.md`](final-design-413.md). IDs are stable: rows whose meaning survives keep their ID, retired rows are marked “Retired” with a one-line reason, and new rules get new IDs.

## Three evidence layers

| Layer | Purpose | Executor |
|---|---|---|
| Contract tests | Lock product rules through public commands and ledger projections | Automated development tests |
| Fault / negative tests | Simulate crashes, late receipts, and races; removal of a protection must fail | Automated development tests |
| Device acceptance | Verify UI, OS wakes, real connectivity, and visible user result | Reviewer |

Device acceptance uses a dedicated disposable test album only. It must not write, delete, or otherwise damage a real photo library.

## Delivery order

```text
O orders and the three-layer model
→ D discovery and counting
→ R file reads
→ C transfer loop, interruptions, and failures
→ H Desktop health and partials
→ E completion receipt
→ X pause, cancellation, restore, and scope change
→ P change Desktop
→ scheduling, UI
```

## P0: Orders and the three-layer model

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| O-01 | A new in-scope photo #N with generation greater than G; #N has no order | trigger, loop starts | `GENERATION_MODIFIED > G LIMIT 1` returns #N; Prepare computes the hash by reference import and creates the order → offer → fetch → confirmed; the state and the advance of G happen in one write | Without picking new photos by G, #N is not sent in this loop; must fail | Take a photo in the test album with the app in the foreground; it becomes backed up without opening settings or waiting for the backstop |
| O-02 | Retired: the slow path covering photos the fast path missed | — | There is no slow path any more; which pick source admits unsent photos with generation ≤ G is to be confirmed | — | — |
| O-03 | #K is confirmed with hash H; after a MediaStore rebuild #K has a new `_id`, same content | the new `_id` enters the pending set and is picked | Prepare computes H by reference import (1 read); on offer Desktop answers “already have” by hash → the new row is confirmed; 0 bytes transferred | Without Desktop dedup (always fetching), bytes transferred > 0; must fail | Mostly automated; on device, only check that the backed-up count does not drop after a large media-library change |
| O-04 | #K is confirmed with hash H1 | the user edits and saves #K; content becomes H2 | Sent as a new version: a new row, transferred to confirmed; the H1 row stays confirmed | Deduplicating by `_id` only (ignoring version / hash) leaves H2 unsent; must fail. Rewriting the H1 row’s state after the edit must also fail | Edit a backed-up test photo (rotate or crop); it is sent to Desktop again |
| O-05 | #S is pending; its original has been deleted from the phone | picked, then Prepare | Prepare finds the original gone and records “source deleted” on the spot; no further transfer and no retry | If a source-deleted order stays retryable, every backstop retries and fails; must fail | Delete a pending test photo in the system gallery, then open the app; it no longer appears in pending progress |
| O-06 | Paused, N photos pending | the user confirms “Cancel remaining N”, then the backstop reconciliation runs | One transaction: N photos go onto the skip list and in-flight orders become skipped by user; reconciliation neither re-sends nor retries these N | If cancellation only exits the loop without writing the skip list, the next trigger re-sends all N; must fail. Letting reconciliation re-send skip-listed photos must also fail | Put 5 new photos in the test album; after the first is sent, pause and tap “Cancel remaining 4”; kill and reopen the app and wait for background wakes; those 4 are never sent |
| O-07 | The last chunk of new photo #R arrived and Desktop issued a completion receipt | the phone commits; fault injection: crash during the write | Confirmed and the advance of G take effect in one write; after a crash either both exist or neither does (then it is sent once more after restart and Desktop answers “already have” by hash) | Splitting state and G into two writes makes “confirmed but G not advanced” or “G advanced but not confirmed” observable; must fail | Mostly automated |
| O-08 | #K is confirmed; its Desktop file was deleted externally; the phone original still exists | the backstop reconciliation asks Desktop page by page | A new order row (id differs from the original row) is picked at level ④ and transferred to confirmed; the original row is unchanged | Recording the gap without re-sending, or reusing the original order id (Desktop answers “done” for an id it completed, so nothing is re-sent), must fail | On a dedicated test copy, delete one backed-up photo from Desktop and open the app; it is sent back automatically |
| O-09 | #F is failed | the backstop reconciliation runs twice and the retry fails each time | Each reconciliation retries once (a new row); no retry loop within one run; the total number of attempts is bounded | Removing the once-per-run limit causes endless retries; must fail. Removing reconciliation retry leaves #F never tried again; must also fail | Mostly automated |
| O-10 | Any moment | query the state of every in-scope photo | Each is confirmed, on the skip list, or pending; pending count = in scope − skip list − confirmed, exactly | Materializing the pending set as a list that goes stale makes the count wrong after a scope change or restore; must fail | Mostly automated |
| O-11 | #K is confirmed, missing on Desktop, and its phone original is gone | backstop reconciliation | The original row stays confirmed; there is nothing to re-send, and the re-send row records “source deleted” at Prepare, with no retry | Changing the original row to failed or any other state breaks “confirmed cannot be revoked”; must fail | Mostly automated |
| O-12 | A leftover in-flight order #L; G = 100; #L’s generation is 50 | #L finishes and commits | State only; G does not advance and stays 100 | If committing an existing order also advances G, G is overwritten; must fail | Mostly automated |
| O-13 | #E was interrupted in flight; the user edited #E during the interruption | Continue resumes #E | The import hash does not match the order’s hash → this row becomes “source deleted” and `cancel_tuple` is sent; the new version is sent separately as a new photo; any confirmed row of an older version is kept | Resuming with the old hash to completion leaves the old version on Desktop; must fail | Pause a large photo mid-transfer, edit it, then continue: Desktop receives the edited version |
| O-14 | The pending set includes photos of album A | the user removes album A from scope | No order state is written; the pending count immediately excludes A’s photos | Bulk-rewriting order states on a scope change must fail | Untick a test album; the home screen pending count drops immediately |

## P0: Discovery and counting

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| D-01 | At once: a leftover in-flight #L, a just-restored #U, a new photo #N, a reconciliation re-send #B | the loop picks one by one | Order is #L → #U → #N → #B | Breaking the priority (e.g. new photos before leftover resume) must fail | Pause a half-sent photo, take another, continue: the half-sent one resumes first |
| D-02 | The loop is sending #1 | 3 triggers arrive in a row | Only one loop runs; triggers coalesce; no second loop and no repeated FGS acquisition | One loop per trigger causes concurrent transfers or repeated FGS requests; must fail | Take 3 test photos during a transfer; only one FGS notification appears |
| D-03 | The loop is sending #1; #N is taken meanwhile | #1 finishes, the loop picks the next photo | #N is picked by G and sent in the same loop with no extra trigger | If the loop consumes only a startup snapshot, #N waits for another trigger; must fail | Take a photo while a large file is sending; it is sent within the same progress notification run |
| D-04 | G is lost or reset; most photos are confirmed | pick new photos | No photo is lost; confirmed photos transfer no bytes again (Desktop answers “already have” by hash) | Without Desktop dedup, confirmed photos are re-sent; must fail | Mostly automated |
| D-05 | Retired: a `getVersion` change triggering a full reconciliation | — | There is no local full reconciliation any more | — | — |
| D-06 | Retired: the slow path hashing only changed photos | — | There is no local reconciliation; file reads are covered by group R | — | — |
| D-07 | Several external volumes exist | pick new photos | G is stored and queried per volume; the pick source on API 26–29 (no `GENERATION_MODIFIED`) is to be confirmed | Querying only one volume leaves photos on other volumes unsent; must fail | On a device with an SD card, take a photo in an SD-card test album; it is backed up normally |
| D-08 | 10 photos in scope, 3 confirmed and 2 on the skip list; 5 more outside scope | entry count | Count = 5, exactly; metadata only, no file reads, no FGS | Counting without the scope condition gives 10; must fail. Reading files or acquiring the FGS while counting must also fail | The home screen pending count matches the number of unsent photos in the test album |

## P0: File reads

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| R-01 | New photo #N; Desktop does not have this content | Prepare + Transfer | The original is read 2 times in total: reference import (hash + outboard) once, serving once; no copy is written; Kotlin no longer hashes separately | Keeping the separate Kotlin hash reads 3 times; must fail | Mostly automated (count file opens) |
| R-02 | New photo #N; Desktop already has this content | Prepare + Transfer | The original is read once (reference import); Desktop’s “already have” completes it | Serving anyway reads twice; must fail | Mostly automated |
| R-03 | An existing order (leftover resume / user restore / reconciliation re-send); Desktop already has it | Prepare + Transfer | The original is read 0 times; the hash comes from the order | Re-importing an existing order to hash it reads once; must fail | Mostly automated |
| R-04 | Reference-import conditions do not hold: API 29 (`dataPath` is null), path and fd disagree, file ≤ 16 KiB, or `has()` is true | import | Fall back to copying with a 1 MiB read buffer; the resulting hash equals reference import’s; hashing and serving both stream with constant memory | Using reference import anyway reads wrong bytes; must fail | On device, verify the reference-import path is readable and bytes match |
| R-05 | The original is modified, truncated, or deleted while being served | serving | Serving aborts and reports through the existing status; incomplete content is never confirmed | Continuing to serve the changed bytes makes Desktop verification fail or confirm wrong content; must fail | Mostly automated |

## P0: Transfer loop, interruptions, and failures

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| C-01 | Running, #18 in flight | the user pauses | Write the pause flag → `flow.suspend` (synchronous, not cancellable, returns within about 3 seconds) → exit the loop → release FGS and wakelock; #18 stays in flight and the Desktop partial is kept; global = paused | Still holding the FGS, starting the next photo, or sending `flow.cancel` to drop the partial must fail | Pause during a transfer: the FGS notification disappears within 3 seconds and no next photo starts |
| C-02 | Paused | app restart, background wake, network recovery, repeated triggers | Still paused; the entry’s first check stops everything: no counting, no FGS, no transfer | Any trigger that skips the pause check or can clear pause must fail | After pausing, kill and reopen the app, switch foreground/background, toggle Wi-Fi: still paused, no FGS notification |
| C-03 | Paused; #18 in flight and unfinished; new photos and reconciliation re-sends also exist | the user continues | Clear the pause flag → back to the entry; pick order #18 → new photos → reconciliation re-sends | Picking new photos first after Continue means #18 is not first; must fail | Pause a half-sent photo, then continue; progress resumes from that photo |
| C-04 | Not paused; Wi-Fi only is on but the phone is on cellular (or battery low, quota exhausted, not paired) | any trigger | The entry constraint check fails: no FGS; global = waiting (matching reason), reason persisted; the matching wake-up is registered | Acquiring the FGS anyway, or not registering the wake-up so nothing resumes when the constraint recovers, must fail | Turn on Wi-Fi only and switch to cellular: no FGS notification; switch back to Wi-Fi and transfer starts automatically |
| C-05 | #18 in flight | Wi-Fi or battery constraint lost, or the FGS reclaimed by the system, or network lost | `flow.suspend`, exit the loop, release the FGS; #18 stays in flight and is not counted as a failure; global = waiting; resumes #18 automatically on wake | Counting the wait as a failure, or requiring user Continue, must fail | Stop Desktop during a transfer and start it again: the transfer resumes automatically, with no error and no Continue button |
| C-06 | 3 photos pending, all constraints met | one trigger | The whole loop acquires the FGS + wakelock + one push subscription once; all three are released after the 3 photos and nothing left to pick | Starting and stopping the FGS per photo, or opening one subscription per photo, must fail | Send 3 photos in a row; the FGS notification does not flicker and disappears afterwards |
| C-07 | In the loop, #18 finished | before picking #19 a condition changed (e.g. pause just set, or the FGS no longer valid) | Pause / constraints / FGS / pairing are re-checked before every photo; if any fails, #19 does not start and the loop exits | Checking only once at loop start lets #19 start under failed conditions; must fail | Mostly automated |
| C-08 | A background trigger; the system refuses the FGS | later background triggers | Global = waiting (`FGS_BLOCKED`); the next trigger retries as usual, with no sticky block until foreground | Recording a durable block and retrying only after the app returns to the foreground must fail | Mostly automated; starting a dataSync FGS in the background after boot on Android 15 is a separate device experiment |
| C-09 | #18 cannot be read (per-photo failure) | transferring #18 | Retry once on the spot; still failing → failed, the loop continues with #19 | No retry, endless retry, or a failure that blocks later photos must fail | Mostly automated |
| C-10 | #18’s connection is alive but no new file bytes arrive for 3 consecutive minutes (`Progress.end_offset` does not advance) | transfer verdict | Disconnect and classify as a path failure: #18 stays in flight, exit the loop, release the FGS, not a per-photo failure | Waiting forever, or recording the path failure as failed, must fail | Mostly automated |
| C-11 | No Desktop connection for 15 seconds | transfer verdict | Ask Desktop for status first; keep waiting if it answers active, without a failure | Failing directly at 15 seconds must fail | Mostly automated |
| C-12 | Desktop reports `storage_full` / `library_unavailable` / `storage_failed` (peer failure) | transferring #18 | Mapped to the matching peer-failure reason and shown on the phone; exit the loop, release the FGS; #18 is not counted as a per-photo failure; global = waiting (`DESKTOP_STORAGE_FULL` / `DESKTOP_LIBRARY_UNAVAILABLE` / `DESKTOP_STORAGE_ERROR`). `fetch_failed` is a path failure; unknown codes are per-photo failures | Counting a peer failure as a per-photo attempt, or treating every code as per-photo without reading it, must fail | Fill the Desktop disk, then send a photo: the phone shows Desktop storage full with no failure count; after freeing space the next wake finishes it automatically |
| C-13 | #18 in flight | network callback `onLost` | Path failure immediately, without waiting for the 3-minute timeout | Relying only on the 3-minute no-bytes rule leaves the loop idling after `onLost`; must fail | Turn off phone Wi-Fi during a transfer: the FGS notification disappears immediately |
| C-14 | Path failure, Desktop unreachable | no network change in the next 30 minutes | A network-change callback + 3 probes 10 minutes apart are registered, each probe being a trigger; not counted | Registering no probes, or counting the path failure as per-photo, must fail | Mostly automated |
| C-15 | Global is idle or waiting | the user taps pause | No effect: pause is available only while running | Writing the pause flag while waiting must fail | Mostly automated |
| C-16 | Global is waiting (some reason) | the process is killed and restarted | The wait reason is still there and the UI shows the same reason | Keeping the wait reason only in memory loses it on restart; must fail | Turn on Wi-Fi only, switch to cellular, kill and reopen the app: it still shows waiting for Wi-Fi |

## P0: Desktop health and partials

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| H-01 | The probe reply’s `health` says the photo library is not writable (or the index store is broken, or space is exhausted) | entry probe | No FGS; global = waiting (specific reason); Desktop shows a system notification | Acquiring the FGS and transferring regardless of health must fail | Make the Desktop photo library folder read-only: the phone shows the matching reason with no FGS notification, and Desktop shows a system notification |
| H-02 | An older Desktop whose probe reply has no `health` field | entry probe | Treated as healthy; proceed as usual | Treating the missing field as unhealthy must fail | Mostly automated |
| H-03 | Desktop free space is smaller than the photo | offer (with `size_bytes`) | Desktop pre-checks against the photo size and rejects on the spot with code `storage_full`; the phone handles it as C-12 | Skipping the pre-check and filling the disk mid-fetch must fail | Fill the Desktop test volume to a few MB free and send a large photo: storage full is shown immediately |
| H-04 | The Desktop photo library volume has < 5 GiB free | probe or offer | Desktop shows a low-space warning; the phone reads low space from `health` | A non-fixed threshold or no warning must fail | Mostly automated |
| H-05 | Desktop has an active grant with no resume for more than 3 days | Desktop cleanup | Marked cancelled and its partial reclaimed; no orphan order remains on the phone | Keeping the partial forever must fail | Mostly automated |

## P0: Completion receipt

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| E-01 | Desktop fully received, verified, durably saved #18 and issued a completion receipt | the phone commits | #18 = confirmed (written together with G for a new photo, see O-07); the loop picks the next photo | Confirming on “transfer started” or “last chunk sent” must fail | A photo shows as backed up after completion |
| E-02 | #18 has a completion receipt | the user narrows scope and the receipt arrives late | #18 stays confirmed | A scope change overwriting the completed fact must fail | Complete a test photo, then remove its album; the completion remains |
| E-03 | #18 is confirmed | the user runs “Cancel remaining N” | #18 is not pending, not counted in N, and stays confirmed | Rewriting a confirmed row as skipped by user must fail | Backed-up photos are unaffected and the backed-up count does not drop |

## P0: Pause, cancellation, restore, and scope change

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| X-01 | Paused, N pending, #18 in flight | the UI shows “Cancel remaining N” and the user confirms | One transaction: N photos go onto the skip list, #18 and pending-transfer orders become skipped by user → `cancel_tuple` drops the Desktop partial → clear the pause flag → idle; zero photos continue | Only ending the loop without writing the skip list lets the next trigger send the same photos again; must fail | 5 new test photos; pause while the 2nd is half-sent and cancel: the button shows the remaining count, nothing continues after confirming, and the UI returns to idle |
| X-02 | As X-01 | fault injection: crash mid-transaction | After restart either all of it applies or none of it does; the N shown equals the number written to the skip list | Committing entries independently leaves a partial set after restart; must fail | Mostly automated |
| X-03 | “Cancel remaining N” has run | a new photo #P is taken and a trigger arrives | #P gets an order and is sent normally; the N photos stay unsent | Implementing cancellation as pause or as disabling auto-backup leaves #P unsent; must fail | Take a test photo after cancelling; it is backed up and the cancelled photos are untouched |
| X-04 | #18 in flight | the user changes album scope | No order write and no scan on the spot; the next query and count use the new scope | Scanning synchronously and bulk-rewriting orders on a scope change must fail | Mostly automated |
| X-05 | #18 was half-sent, then paused; its album is still in scope and the original exists | the user continues | #18 resumes and fetches only the missing parts | Dropping the partial and restarting sends more bytes than remain; must fail | Pause a large file and continue; progress resumes from where it was |
| X-06 | Retired: removing the album while paused → cancelled by scope | — | The “cancelled by scope” state no longer exists; whether an in-flight order whose album leaves the scope is still finished is to be confirmed | — | — |
| X-07 | #18 was half-sent, then paused; the original was deleted in the system gallery | the user continues | #18 = source deleted; the loop picks the next photo | Reporting a per-photo failure and retrying the deleted file must fail | Pause, delete the test photo in the system gallery, continue: it no longer appears in progress |
| X-08 | Paused, 5 pending; after the “Cancel remaining 5” dialog appears and before confirmation, a new photo #Q is taken | the user confirms | The skip list holds only the 5 from the moment the dialog appeared; #Q is not skipped and is backed up afterwards | Recomputing the pending set at confirmation skips #Q too; must fail | Open the cancel dialog, take a photo, then confirm: the new photo is still backed up |
| X-09 | 4 photos on the skip list | the user runs “Restore skipped” | Removed from the skip list; the recomputed pending set includes them; sent at pick level ②. Restoring while paused only changes intent; they are sent after Continue | Needing some full scan before they reappear as pending must fail | Tap restore in settings: the home pending count rises by 4 immediately and they are sent |
| X-10 | Running or idle | “Cancel remaining” is invoked | No effect: it is available only while paused (whether also while waiting is to be confirmed) | Cancellation taking effect while running must fail | No “Cancel remaining” while running |

## P0: Change Desktop and isolate old results

| ID | Given | When | Then | Negative proof | Device acceptance |
|---|---|---|---|---|---|
| P-01 | Wi-Fi / battery / album settings exist, plus in-flight orders and Desktop partials | pair with a different Desktop | Settings are kept; partials and runtime ownership are cleared; changing Desktop clears the order table (the `pairing_epoch` column stays as a guard) and new order ids start above the timestamp. Whether the skip list is kept is to be confirmed | Clearing settings or carrying old partials to the new Desktop must fail | After changing Desktop, settings remain and old transfer progress is not carried over |
| P-02 | Already switched to a new Desktop | a receipt from the old Desktop arrives | The old receipt cannot change the new backup history | An old receipt confirming a new-history item must fail | Mostly automated |

## Required observable evidence

Tests and device diagnostics record state facts only, never photo names, paths, or content:

```text
Discovery: G before/after, pick source (leftover resume / user restore / new photo / reconciliation re-send), entry count
File reads: opens per photo, reference import or copy fallback
Orders: state changes, new rows (re-send / retry), failure count, number written to the skip list
Transfer: FGS, wakelock, and push subscription acquire/release; pre-photo re-check result; flow.suspend / cancel_tuple calls
State: global state changes; pause flag; wait reason (persisted) and recovery reason
Failures: interruption / path / per-photo / peer class, peer failure code, per-photo retry count
Desktop: health from the probe, offer pre-check result, partial reclamation
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

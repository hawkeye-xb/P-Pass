---
title: Why we rebuilt our photo backup core around a per-photo ledger
date: 2026-09-07
tags: [engineering, architecture, backup]
lang: en
draft: false
---

P-Pass has a simple job: you take a photo on your phone, and it makes its way back to the computer at home on its own.

"Automatic backup" hides a set of questions that need exact answers, though. If you hit pause halfway through a transfer, what state is that photo in? After the network drops, why should some transfers resume by themselves while others wait for the user to tap "Resume"? When you cancel the current round, are you canceling the few photos on screen, or the whole batch, including photos that haven't been scanned yet? And if someone later deletes a file from the computer in Finder, should the phone quietly upload it again?

Our old backup core couldn't answer these, and one more branch in its code wouldn't have changed that, so this time we replaced the core.

## The old system treated a batch as if it were the photos

The old pipeline looked roughly like this:

```text
scan the photo library
→ compute hashes
→ build a manifest
→ transfer
→ commit
→ advance the watermark
```

Its unit of work was one batch run. Each time the Worker woke up, it tried to get through as much of the batch as it could.

That made sense at first. There weren't many photos, and the only goal was to get new files across. The trouble is that real use doesn't run in a straight line. Along the way you get pauses, dropped connections, low battery, the computer going offline, changes to which albums are included, phone restarts, and files on the remote side being deleted by hand. Meanwhile, the state of each photo (discovered, pending, confirmed, failed, paused) was spread across the Worker, state files, and several scheduling channels.

So the system could usually say "this round is running" or "this round is done," but it couldn't answer the question users actually ask: **what is happening with this particular photo right now?**

Folding each photo's fate into a whole batch is like a shipping company that records "the truck left" but never records whether each package was signed for. When the truck breaks down on the road, nobody can reliably tell which packages already arrived, which should keep going, and which should stop.

## First, define what "backed up" means

The first thing we settled in the new design was the meaning of completion. Class names and the database came after it:

> A photo is `CONFIRMED` only after Desktop has fully received it, verified it, stored it durably, and explicitly returned a completion receipt.

"Started sending," "the computer saw the request," and "the hash is computed locally" all fall short of completion.

The rule sounds strict, but it settles a lot of edge cases on its own:

- Once a completion receipt is in hand, later changes to the album scope, a pause, or canceling the current round can't turn that photo back into "not done."
- An item that only has a partial transfer and no completion receipt can't quietly become complete after the scope changes.
- A file that goes missing on the Desktop side is a fact to record. It doesn't mean the user asked for an automatic re-upload.
- When the phone's records and Desktop's records disagree, both sides can compare the completion receipt for the same photo. If each side tries to guess whether a batch finished, there's nothing to reconcile.

As a result, "backed up" can be checked against the same completion receipt on both the phone and Desktop.

## The new core: one ledger, one queue

At the center of the new model is a logical ledger stored on the phone. For every photo it records identity, order, state, failures, the completion receipt, and which pairing and scope version the photo belongs to. It can't track "roughly how far this backup round got," and it no longer needs to.

The pipeline is split into four clearly separated roles:

```text
Trigger          = there might be new photos
Discoverer       = writes new photos into the ledger reliably
Strict consumer  = handles only the photo at the head of the queue
Desktop          = native fetch/resume, returns a completion receipt after storing
```

Triggers no longer start a backup round. A photo library change, opening the app, a periodic job, or a manual action all carry the same meaning: **there might be new photos, please check.** Multiple triggers get merged, so a new notification doesn't open another transfer pipeline competing with the ones already running.

The discoverer finds photos using MediaStore's incremental cursor, at most 500 items per page. Writing the candidates into the ledger and advancing the discovery cursor have to happen in the same local commit. If the app crashes before the commit, neither happens. If the commit succeeds, both take effect together.

Without that, you get the most dangerous failure: the cursor moves forward before the photos are queued. On the next launch the system thinks it has already scanned that range, and those photos are skipped for good.

The strict consumer starts working only once the ledger has pending items. It processes only the current head of the queue, pointed to by `UploadCursor`. Until that photo reaches a terminal state, nothing behind it is allowed to jump ahead. Transfers still go through iroh-blobs' native `fetch/resume`. Resuming an interrupted transfer is a capability of the underlying protocol, so the application layer no longer maintains its own offsets, chunk maps, or a separate "send it again" protocol.

With this split, the answer to "what happened to this photo," which used to be scattered across several channels, now sits in one place you can look up.

## Pause, waiting on conditions, and canceling the current round

With a per-photo ledger, several actions that used to blur together finally have plain meanings.

**Tapping "Pause"** is a standing command. The app being killed, the network coming back, or the OS waking a background task again can't lift the pause on the user's behalf. Only tapping "Resume" continues the transfer, starting from the same head of the queue.

**Waiting on conditions** works differently. When Wi-Fi, battery, or Desktop availability isn't met for the moment, the current transfer stops, but any valid partial data is kept. Once conditions recover, the transfer can resume automatically. It doesn't count against the failure budget, and the user doesn't have to tap Resume again.

**"Cancel current round"** doesn't delete files one by one. It only appears after a pause, and it means "don't transfer any photo in this round that isn't finished yet." It keeps paging through the round and marks candidates that haven't been discovered yet as canceled, so the whole round is canceled instead of only the first 500 photos on screen. Photos that already have a completion receipt are unaffected. Photos queued later belong to the next round. If the user changes their mind, the only way to bring back this round's canceled items is to tap "Retransfer" explicitly.

That looks like a lot of states, but each one maps to a different user intent, and they can't be collapsed into a single "stop." "I don't want to transfer right now" from the user and "conditions for transferring aren't met" from the system naturally have different recovery rules.

## Why we couldn't keep patching the old Worker

The basic unit of the old batch pipeline was the round, and its watermark and confirmation logic were designed around that round. Adding a few `if` statements doesn't change that. The basic unit of the new rules is a single photo: completion comes from Desktop's receipt, and pause, scope, cancellation, and pairing all have to remain explainable after a restart.

The two models are built around different centers. Pushing the new semantics back into the old path would only leave two competing sources of truth.

So the first step of the production switch was to draw a boundary; deleting old code came later. The old `BackupWorker`, Runner, confirmation queue, and retransfer queue were marked legacy, and the new core was only allowed to live in `backup/flow`. After that, we connected discovery requests, atomic ledger writes, the strict queue head, native transfer, and completion receipts into one production path. Finally, the old Worker was reduced to an adapter for system wake-ups. It no longer scans, hashes, builds manifests, or commits batches itself.

The line between the new and old systems is now a physical boundary in the code that we can check, and it doesn't depend on everyone remembering a convention.

## Write the failure cases first, then the new path

The easiest mistake when replacing a core is letting old tests force the new code back into the old shape.

This time we started by writing the product rules that still held into a failure case matrix. If the app crashes before a discovery page commits, the cursor and the queue must both stay unchanged. After a pause and a restart, the head of the queue still must not start on its own. A late completion receipt from Desktop must not be dropped just because the phone has already paused or canceled locally. And new photos that arrive after a canceled round ends must enter the next round normally.

Every test has to answer one question: if you remove the protection, does the system actually break? If it doesn't, the test isn't guarding a rule.

We handled two problems found during regression testing on real devices the same way. When the scope was expanded, new album photos that sat before the old cursor didn't make it into the new ledger. And in a race between pause and cancel, Desktop had already persisted the completion receipt while the phone could still be sitting in the pending state for a while. We didn't work around either one by clearing data or re-pairing. The first became new Flow semantics, and the second became a receipt reconciliation rule.

There will still be bugs after the core swap. The difference is that each new problem lands in the same ledger, where it can be traced and reproduced, and fixing it doesn't depend on guessing.

## What we actually replaced

The ability to transfer photos was there all along. What we replaced is the rule for when a backup counts as complete:

```text
Before: a round finishes running, so the backup is probably done
Now:    every photo has persistent state; it's done only when Desktop returns a completion receipt
```

The first approach works for a one-off script. A long-running backup product gets paused, interrupted, moved to a new computer, and exposed to whatever real users do, and it needs the second.

The new main path has already been switched over in production, and we're still tightening its edge cases through regression testing on real devices. It's far from finished. This post only records why we stopped patching the batch pipeline and pretending it could still answer every question.

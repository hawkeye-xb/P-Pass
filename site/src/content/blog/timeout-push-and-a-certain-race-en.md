---
title: RPC timeouts, 202-style polling, and a tokio broadcast race in phone-to-desktop backup
date: 2026-09-17
tags: [networking, engineering]
lang: en
draft: true
---

When P-Pass sends a photo from a phone to a desktop, one step in the middle is called `flow.fetch`. The phone tells the desktop "I have a photo for you," then blocks on that same network request until the desktop has pulled the whole photo, written it to disk, and confirmed it. Only then does the phone get a reply.

On a shared Wi-Fi network this design never showed a problem. LAN latency is measured in milliseconds, a photo transfers in a few seconds at most, and nobody notices the wait.

Across networks, going through a relay, it fails in a very specific way. The phone caps this wait at 15 seconds. The relay is the fallback that forwards traffic when hole punching between the two devices fails; we use iroh's public relays, run by number 0, which only forward encrypted data. Fifteen seconds is plenty for a screenshot of a few hundred KB. A 288MB video is a different story. In one test, with the phone on a cellular hotspot and the computer left on its original network, the phone hit the same error three times in a row:

```
DaemonUnreachableException: flow.fetch: no response from the computer within 15000ms
```

After that, the item was flagged as needing the user's attention. Any transfer that takes longer than 15 seconds is guaranteed to time out, however good the network is. Earlier, when `backup.begin` ran into the same 15-second limit, the symptom on a real device was a long pause after the photos finished hashing before the transfer started again.

The fix for the timeout was to separate "submit" from "wait for the result." That separation exposed a second problem: when content deduplication hit, each photo took an extra 30 seconds, because of a race that lost every single time.

## One timeout value doing two jobs

The phone's connection client has a single constant:

```kotlin
// DaemonClient.kt
private const val CONNECT_TIMEOUT_MS = 15_000L
```

It is used in two places: establishing the connection, and waiting for the response to a single RPC. The `flow.fetch` RPC only responds after the entire transfer is done, so waiting for the transfer got folded into the same 15 seconds.

That one value has to serve two opposite goals:

- If the desktop has actually died or dropped off, we want to find out **as soon as possible** so we can retry or tell the user.
- If the transfer is healthy and the file is simply large or the network path is long, we want to keep waiting and not declare it dead while it is making progress.

No single number satisfies both. Raise it, and a connection that is really gone takes longer to detect. Lower it, and large files are guaranteed to be killed. We had written down an interim plan with a timeout per call type: 60 seconds to connect, 15 seconds for control RPCs, a 30-minute safety limit for `flow.fetch`, and an explicit rule against deriving the timeout from file size. That plan still hasn't been implemented. It was only ever meant to stop the bleeding. The real fix was to stop making this number carry two meanings at once.

## Submitting and waiting for the result should be separate requests

Stepping back, the phone wants two independent things. One is to tell the desktop "I want to send this." The other is to find out whether the transfer has finished.

Those two things were welded into one RPC, so the minimum duration of that RPC was set by how long the transfer takes, a variable we have no control over. How long a transfer takes and whether a network request should time out are separate questions.

In HTTP, this shape corresponds to 202 Accepted: submit the job, get a handle, and later use the handle to check status. Checking status is fast no matter how long the job behind it runs. Our `timeline.subscribe` already worked this way: it pushes a `timeline.invalidated` event to speed things up and relies on periodic reconciliation as the fallback. This change brings the same pattern to the phone's photo transfer path.

## offer returns immediately, status checks the ledger

The new flow has three steps. The first step is no longer called fetch; it is called offer. It registers the intent and moves no bytes.

```
Phone:   flow.offer (register intent to transfer)  → desktop replies immediately, does not wait for the transfer
Desktop: spawns the transfer task in the background, writes the final state to the ledger
Phone:   calls flow.status periodically (reads the ledger) → active / completed / cancelled / failed / not_found
```

`flow.status` is a cheap query. It reads the database and an in-memory flag that says whether the task is still running, and it never touches the data-plane connection that actually moves bytes. So however long the transfer takes, a `status` request normally returns within the control timeout (still 15 seconds, but now it only covers this one small query). It can still time out when the network is flaky.

The implementation follows one rule: **the phone only believes what the ledger says**. A timed-out `status` query does not mean the transfer failed. It only means that one network round trip didn't succeed; what happened to the transfer is whatever the desktop's ledger says. The phone checks again on the next round, and if the ledger still says active, it keeps waiting. It never resends `offer` because of a single query timeout, which would collide with the transfer the desktop is already running.

```kotlin
// NativeFlowDeliveryPort.kt (illustrative)
// One failed status round-trip ≠ a failed transfer;
// only failed/cancelled written in the ledger is a final state.
fun flowStatusPollOutcome(reply: FlowStatusReply?, consecutiveTimeouts: Int): PollOutcome
```

This change also let us untangle pause and cancel. Previously, dropping the connection was a single action standing in for three questions: is the lease still held, is the task still running, does the user still want this. Now a change of intent is written straight to the ledger, and observing state means reading the ledger. Nothing has to guess from whether the call is still connected. Bytes left behind by a pause stay protected and the transfer resumes where it stopped; a cancel really gives up, and those bytes are garbage-collected afterward.

## Tests and real-device verification

On the daemon side we added a test that injects a delay into the data-plane fetch, far longer than the control timeout, and asserts that the phone reaches the confirmed state and gets a receipt by polling. This test failed before the change.

A stronger negative check: we temporarily deleted the line that records the current task so that suspend can find it and interrupt it, then reran the test. `suspend` became a no-op, the transfer quietly finished in the background, and the test's assertion that there must be an explicit interruption result failed. Restoring the line turned the test green again. That shows the test really exercises suspend's interruption path.

The real-device run was more direct. A Samsung phone, freshly paired, sending a 224MB video plus 23 photos: all 24 items were confirmed. In the ledger the video went from active to completed over 80-plus seconds, with no failures along the way. With the old code, `flow.fetch` for this video would have timed out at the 15-second mark.

## After the split, deduplicated photos got slower

With offer and status in place, we added another capability: checking for duplicates before transferring. If the desktop library already has a photo with the same content, there is no reason to pull the bytes again. The check lives in the `offer` handler, which queries the content store before deciding whether to spawn a transfer task:

- Hit: skip the data plane entirely, take the same completion path a real successful transfer takes, generate a receipt, write the ledger, and then emit a `flow.delivered` event to notify the phone.
- Miss: spawn the transfer task as before.

This path fired a lot during a real-device test after a dropped connection and reconnect. We restarted the backup and all 11 photos hit deduplication. By design they should have finished instantly. Instead each one waited the full 30 seconds, and the 11 photos took about 3 minutes.

The 30 seconds has a clear origin. To decide whether a transfer is done, the phone checks three signals in priority order: the `flow.delivered` push from the desktop, the state of the phone's local iroh-blobs sender, and, as a last resort, a `flow.status` query. That fallback originally fired when the local sender had been idle for more than 30 seconds. A deduplication hit means not a single byte crossed the data plane, so the local sender never produces any event, its idle duration stays null, and it never reaches the threshold. An earlier fix had added a way out for this case: if there has never been a local signal, use the wait loop's own wall clock, and query status once it reaches 30 seconds.

So 30 seconds per photo tells us one thing: across those 11 photos, the `flow.delivered` push never reached the phone even once. If it had arrived even once, that photo would have returned immediately through the push branch and never reached the fallback.

## Why the push never arrived

On the phone, the calls happen in this order, all inside the same coroutine block:

```kotlin
// NativeFlowDeliveryPort.kt (simplified)
val reply = desktop.offer(request)            // await offer first
val pushChannel = Channel<FlowPushOutcome>(...)
launch { client.subscribeTimeline(...) }      // subscribe only after offer returns, and via an async launch
```

The phone awaits `offer`, and only after it has the reply does it subscribe to the event stream. The subscription is also started with an async launch, so when that line finishes, the subscription connection hasn't been established yet.

On the daemon, a deduplication hit runs the whole path synchronously inside the `offer` handler: it finds the existing durable copy, writes the completion receipt, emits `flow.delivered` right away, and only then returns the `offer` reply to the phone.

The event bus is a tokio `broadcast::Sender`. The module header comment says it plainly: with no subscribers, send just drops the message. `emit` does `let _ = bus.send(...)` and never surfaces the error. To be precise here: the desktop shell itself keeps a standing subscription on the same bus, so at the moment of send there is usually a receiver. The event was lost because this phone's subscription didn't exist yet, and broadcast only delivers to receivers that exist at the moment of sending. A receiver that subscribes later never sees earlier messages, and nothing is redelivered.

Lay out the timeline and the conclusion is certain. The daemon emits the event before it returns the offer reply. The phone receives the offer reply before it starts subscribing. The event is always emitted before the subscription exists, so this race loses every time.

Real transfers never exposed it because they have to connect and move bytes. That takes at least some time before the daemon emits `flow.delivered`, which gives the phone's subscription enough margin to get established first. Deduplication cut that delay to zero, and a window that was almost never hit became one that was hit every time.

Deduplication has a cost of its own. It trades "retransmit zero bytes" for "wait one fallback window per item." For a 224MB video that is still a very good trade. For a photo of a few hundred KB, the old behavior wasted a few bytes but confirmed promptly; the new behavior saved the bytes but stalled each photo for 30 seconds, which is most likely a net loss.

## Why we didn't just reorder the subscription

The most direct fix is to reverse the order: subscribe first, wait for confirmation that the subscription is established, then send offer. That would win the race.

We didn't take that route, because winning a race by arranging timing is the wrong kind of fix. After reordering, correctness still depends on the subscription existing before completion. We would need to add a confirmation that the subscription is up, handle the window where the subscription dies and is rebuilt during a reconnect, and every extra async step is one more place to lose. Also, in this design the push has always been an accelerator, with polling and local signals as the safety net. Adding timing guarantees to keep the accelerator from dropping messages would be heading in the wrong direction.

Our timeline sync had already been down this road. One of the rules we settled on then was "subscribing returns the current state": as soon as a subscription connection is established, the daemon pushes the current state once, so the client doesn't need two separate actions (fetch everything, then subscribe) and there is no gap where getting the order wrong loses events. The other rule was that events are allowed to be dropped, and the client falls back to periodically refetching the whole page. This time the gap sat between `flow.offer` and the phone's subscription, and the fix follows the same idea.

## Have the offer reply carry the current state

The change we settled on: the `flow.offer` reply now returns a `FlowStatusReply`. In other words, whatever you would get by calling `flow.status` right after offer, the daemon hands you directly in the offer reply.

In the standard use of the 202 pattern, 200/201 versus 202 is decided per request, not fixed per endpoint. If the work was done on the spot, return the result; return 202 with a job handle only when the work really is async. The old code had the answer in hand on the daemon and still insisted on replying "accepted, go wait."

The closest precedent is cross-repository blob mount in Docker Registry v2. It is also addressed by content digest, and it also has a dedup short-circuit:

```
POST /v2/<name>/blobs/uploads/?mount=<digest>&from=<repo>
  content already present → 201 Created, zero bytes transferred, final state is in this response
  not present             → 202 Accepted + upload location, normal upload follows
```

The 201 and the 202 are themselves the discriminator. HTTP conditional requests with 304 Not Modified, the Git protocol negotiation where the client first announces `have <sha>`, and rsync exchanging checksums first all do the same thing: they answer "I already have it" in the very response the caller is waiting for, instead of pushing that fact out to an out-of-band notification or to polling.

In code, the existing `FlowStatusReply` shape in the repo fit well: `state`, a `receipt` that is only set when completed, and `task_running`. The three possible outcomes of offer map to three replies:

- Dedup hit: `state: "completed"` plus the receipt already in hand, so the phone waits zero time.
- Transfer started: `state: "active"`, `task_running: true`, and the phone enters the existing wait loop.
- Lost to a concurrent cancel or pause: reply with the actual current state from the ledger, and never fabricate a receipt.

On the daemon, the logic that maps state to a reply was pulled into a shared private function that both `status()` and `offer()` call, so the two paths don't each grow their own version and drift apart later. The phone didn't even need new parsing: after offer returns, the reply goes straight through `flowStatusPollOutcome`, which the polling path already used. Completed means record the receipt on the spot, with no subscription and no wait loop; cancelled means give up this round; only active goes through the original flow.

We checked two concerns in advance. First, the receipt might arrive twice: once in the reply, and again from the push if the push makes it in time. Receipt handling was already designed to be idempotent, so receiving it again after the item is confirmed doesn't record an extra audit fact. Second, a new phone talking to an old daemon gets a null offer reply. In that case the phone must fail with an explicit error. It is not allowed to silently fall back to the old path of waiting for a push and then a timeout, because that hidden stall is exactly what this change set out to remove.

Daemon unit tests cover the first two outcomes. As a negative check, we reverted the terminal-state branch to its old shape (reply without the final state); the two relevant tests turned red immediately, and the "transfer started" test stayed green. The concurrent-cancel branch has no direct test, because the test harness has no injection point that can slip a cancel precisely between the two steps. That branch delegates to the mapping `status()` already covers.

## Results: 3.30 seconds, and whether the push works at all

Real-device acceptance used the same phone and the same 11 photos. After reinstalling the app on the phone and re-pairing, the library already held all 11, and after rediscovery every one of them hit deduplication:

| Scenario | Photos | Total time | Max per photo |
|---|---|---|---|
| Before | 11 | about 3 minutes | 30 seconds |
| After | 11 | 3.30 seconds | 0.396 seconds |

There is direct evidence that the new reply path is actually running: the hard failure we added on the phone for a null reply never appears anywhere in the logs. If the desktop were still running the old daemon, it would have fired.

One question remained. The dedup case was fixed, but the subscription order hadn't changed, and the acceptance run couldn't tell us whether the push had ever arrived on the real transfer path. The real transfers were fast too, but the local iroh sender's completion event can also let the phone get an answer from status within a second. Both paths produce the same timing, so the timing alone can't tell which one settled the item.

So we added one log line at each of the phone's three settlement points, recording what settled the item: `offer_reply`, `push`, or `status`. No behavior change, only observability. Then we picked an album that had never been backed up:

| Round | Items | Settled by |
|---|---|---|
| Real transfer | 12 | 6 items `by=push`, 6 items `by=status` |
| Same batch resent after re-pairing (dedup hit) | 25 | all 25 `by=offer_reply` |

The 6 `by=push` lines are positive evidence that the push does get delivered on the real path, so it needs no fix. The other 6 `by=status` items don't mean the push was lost either: in those 6 log lines the local state was already Completed, and the wait loop was only on its first iteration, 1 millisecond in. The phone's own sender signal arrived before the push, so under the "local liveness check first" rule it went straight to status, and the push never got its turn. Nothing hit the 30-second fallback.

The second round doubled as a negative check. If the logs looked the same in both scenarios, this classification would be meaningless. In practice, real transfers show only `push` and `status`, and dedup shows only `offer_reply`. The three paths separate cleanly.

## FAQ

### Why do tokio broadcast messages get dropped?

tokio's `broadcast` only delivers a message to receivers that exist at the moment it is sent. A receiver created by a later `subscribe()` call only gets messages sent after it subscribed. When there are no receivers at all, `send` returns an error and the message is dropped. It is designed for live broadcast; if you need replay, you have to build that layer yourself. In our case there were other subscribers on the bus, but the phone's subscription didn't exist yet, which has the same effect.

### When should I use the 202 Accepted pattern (submit, then poll for status)?

When the time a request takes depends on variables you don't control (file size, network path, queue length), the caller shouldn't block on that single request. Accept the job, return a handle, and check status later, so that whether a network request times out depends only on the network. The other half matters just as much: when you can return the result on the spot, return it. A server that already knows the answer shouldn't reply 202.

### Doesn't subscribing before submitting avoid the race?

For a single call, yes, but only if the subscription is fully established, which usually takes a confirmation round trip. During a reconnect the subscription dies and is rebuilt, and that window needs separate handling. If the final state is produced synchronously while the submission is being handled, the most reliable approach is to return it in the submission's response and keep the push as an accelerator.

### Should connection timeouts and RPC timeouts be configured separately?

They answer different questions. A connection timeout answers "is the peer there, and can we reach it?" It is affected by hole punching and relays, so it is naturally slower than an RPC. An RPC timeout answers "did this round trip get a reply?" Put both in one constant and changing either one affects the other. More important still, don't let an RPC's wait time include the time the actual work takes; leave that to a status query.

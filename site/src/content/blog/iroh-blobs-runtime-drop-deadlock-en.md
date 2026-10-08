---
title: "Why a failed iroh-blobs FsStore::load hangs instead of returning an error: a tokio runtime self-deadlock"
description: "A failed iroh-blobs FsStore::load hangs instead of returning an error. We traced an intermittent CI timeout to a tokio runtime dropped on the error path."
date: 2026-08-12
tags: [rust, engineering, debugging]
lang: en
draft: false
---

P-Pass uses iroh-blobs in its transport layer to store and fetch file contents. Its fs store sits on top of a redb database file called `blobs.db`. One of our integration tests exists to check resumable transfers: the receiver is killed halfway through, restarts, picks up where it left off, and at the end we compare the file bit for bit.

This test kept timing out on CI now and then. It would run the full 300 seconds and get killed. That happened 3 times, and every rerun passed. Run in isolation, the same test takes 6.4 seconds. Running the full suite in parallel on a local machine, it takes 12.75 seconds.

A test that takes 6 to 13 seconds does not stretch past 300 seconds because a CI machine is a bit slower. The gap is an order of magnitude, which looks a lot more like something waiting for an event that will never happen. The cause turned out to be in iroh-blobs: when opening a store fails, a drop on the error path makes the thread running it wait for itself to exit.

## It should have returned DatabaseAlreadyOpen, but the process hung

The first step was to add timestamped phase logging to the test. Bind, transfer progress, kill, restart, re-fetch, and verify each write one line to stderr. The next time CI timed out, the last line would tell us where it got stuck.

It happened again soon. That commit only touched the Android app, the desktop app, and our Cloudflare Worker scripts; the Rust transport layer was untouched, so this was a purely intermittent reproduction. The test was killed after 322 seconds. The last log line was `restart: rebinding receiver endpoint`, and nothing came after it. Transfer progress before the kill grew normally, MB by MB, so the transfer itself was fine. The problem came after the restart.

Our first reading was that redialing after the restart had gotten stuck.

Before changing anything, we ruled out a few shortcuts as fixes: raising the timeout, shrinking the test data, adding retries, and marking the test flaky. All of those would only hide the symptom. Running serially with `--test-threads 1` falls in the same bucket. It can show that the problem depends on concurrency, but it can't be the fix, because the background service in production is concurrent too. Serializing the test would just hide a real race.

Finding the cause meant reproducing it locally first. Running the test in isolation had never reproduced it, so this time we added pressure: all 22 tests in the transport suite in parallel, plus a 50% CPU load on a 4-core machine. It hit on the first round. The restart phase hung for 115 seconds before nextest's slow-timeout (120 seconds) terminated it.

Once we split the restart phase into finer log points, the picture changed. The endpoint rebound almost immediately. What hung was the call right after it, `Blobs::open`, which is `FsStore::load`. Opening the local database was the step that never returned.

We did have a candidate for that step: the store from before the restart might not have released redb's file lock yet. But we had ruled that out ourselves earlier. Our reasoning was that redb takes the lock with a non-blocking try_lock, so if the lock is held it returns `DatabaseAlreadyOpen`, the `unwrap` in the test panics, and the process fails instead of hanging.

That reasoning was only half right. Reading the vendored redb 4.1.0 source confirms that it returns an error when the lock is held and does not block. The problem is that the error never reached the `unwrap`. The process didn't panic, and it didn't log anything either.

## Capturing stacks with sample

With no logs, reading output gets you nowhere. You have to look at where the threads are parked right now. macOS ships `/usr/bin/sample`, which samples the call stacks of every thread in a running process at a fixed interval.

We sampled the test process about 20 seconds into the hang. The result was clean: 1032 samples, and all 1032 landed on the same call chain.

```
Actor::new (fs.rs:678)                       ← runs on the store's own runtime
  → drop_glue(RtWrapper)
    → RtWrapper::drop
      → block_in_place(|| drop(rt))
        → Runtime::drop
          → BlockingPool::shutdown
            → Receiver::wait
              → park
```

The stack never changed during the sampling window. The thread sat in `park`, waiting for a signal. If the program were only slow, the samples would be spread across many functions doing real work. When every sample piles up on the same wait point, you can be fairly sure it's a deadlock.

## Root cause: dropping a runtime on one of its own threads

Reading this stack against the vendored source (iroh-blobs 0.103.0, tokio 1.53.1), the sequence breaks down into four steps.

1. `FsStore::load_with_opts` creates a separate multi-threaded tokio runtime for each store, then runs `handle.spawn(Actor::new(...)).await`. The spawned future captures an `RtWrapper`, and that `RtWrapper` owns this same runtime.
2. `Actor::new` returns a `Result`. When opening redb hits `DatabaseAlreadyOpen`, `?` propagates the error, the future completes with an error, and the `RtWrapper` it captured gets dropped. The future runs on one of this runtime's own worker threads, so the drop happens on that thread too.
3. `RtWrapper::drop` is implemented as `block_in_place(|| drop(rt))`. `block_in_place` turns the current worker thread into a blocking thread and runs `Runtime::drop` on it. `Runtime::drop` shuts down the blocking pool and waits for every thread in the pool to exit. The current thread is registered in that pool at this point, so it starts waiting for itself to exit.
4. The deadlock happens inside the future, so the future never completes, and the caller of `load` never gets that `Err`.

From the outside, an open failure that should have returned right away turns into a permanent hang with no output at all. That is why the error never reached the `unwrap`.

## Why the lock was still held

The trigger was in our own test.

"Killing the receiver" in the test is an in-process abort, which is very different from the OS killing a process in real use. The abort only drops the `FsStore` handle, which amounts to closing the channel to the store actor. The thing holding the redb `Database` (and with it the flock on `blobs.db`) is the actor running on the store's separate runtime. The actor has to finish the batch it is working on and then get scheduled before it exits and releases the lock.

The old code slept a fixed 100 milliseconds after the abort and then reopened the store in the same directory. Most of the time 100 milliseconds was enough. With 22 tests in parallel and extra CPU load, it wasn't. The reopen ran into the lock that hadn't been released yet, redb returned `DatabaseAlreadyOpen`, and execution went down the deadlock path above.

So there are two layers here. A timing race in our test made the reopen hit the lock, and iroh-blobs deadlocked itself while handling that error, which turned an ordinary open failure into a permanent hang. With only the first layer, the test would have failed right away with a clear `DatabaseAlreadyOpen`.

## Minimal reproduction

Given this mechanism, reproducing it takes two steps: open a store, drop the handle, then immediately open the same directory again.

```rust
use iroh_blobs::store::fs::FsStore;
use tempfile::tempdir;

#[tokio::main]
async fn main() {
    let dir = tempdir().unwrap();
    let path = dir.path();

    // Store A: open, then drop the handle while the actor is still alive
    // (the actor holds redb's Database + flock until it drains its queue).
    let a = FsStore::load(path).await.unwrap();
    drop(a);

    // Reopen the same path immediately, racing the actor's lock release.
    // If this wins the race, load() hits DatabaseAlreadyOpen and,
    // instead of returning Err, the process hangs.
    let b = FsStore::load(path).await;
    println!("second load: {b:?}");
}
```

We wrote this program from the mechanism and attached it to the upstream issue as the shape of the reproduction. Whether the second `load` hits the lock depends on timing. On an idle machine the actor usually releases the lock in time and the program prints a normal result. You are more likely to hit it by running many copies in parallel with the CPU saturated, over and over. The stacks we actually captured came from the loaded test setup described earlier, where we reproduced the hang 2 times, plus 1 more run that hung for over 50 seconds.

To check whether you are hitting the same problem, look for this segment in the stack during the hang: `RtWrapper::drop → block_in_place → Runtime::drop → BlockingPool::shutdown`.

## How we fixed it on our side

The test-side fix is narrow. We removed the fixed 100 millisecond sleep and replaced it with polling the file lock on `blobs.db`, reopening only once the lock is actually released.

```rust
let db_path = receiver_store.join("blobs.db");
let lock_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
loop {
    let free = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&db_path)
        .map(|f| f.try_lock().is_ok())
        .unwrap_or(true); // file doesn't exist yet (first round) -> no lock to wait for
    if free {
        break;
    }
    assert!(
        std::time::Instant::now() < lock_deadline,
        "old store did not release the blobs.db lock within 30s; actor exit is stuck"
    );
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
}
```

It polls every 10 milliseconds with a 30 second cap. Past the cap, the test fails with an explicit message instead of hanging silently until it gets killed.

After the fix, we ran 40 rounds in a loop under the same stress conditions that had reproduced the hang. All 40 passed with no timeouts, and all 149 tests in the full local suite passed. For comparison, before the fix the same conditions had reproduced the hang 2 times, and that is where we captured the deadlock stack.

In the product code, the background service opens the store once per process and never reopens it within the process, so it can't reach this race. In real use, when the app is killed the process exits, and the lock is released along with it.

That said, based on our reading of the source, anything that sends `FsStore::load` down its error path, such as a full disk or a corrupted database file, goes through the same drop logic. The result is a hang, and the caller never receives the error. For a background service that opens its store at startup, that means it could silently hang on startup with nothing in the logs. Our own test works around it, but the problem in iroh-blobs itself remains, so we reported it upstream.

## Upstream status

On 2026-08-12 we filed the mechanism, the stack, and the reproduction in the iroh repository (n0-computer/iroh#4468). It was later transferred to the iroh-blobs repository and now lives at [n0-computer/iroh-blobs#252](https://github.com/n0-computer/iroh-blobs/issues/252). The issue title is "iroh-blobs: a failed `FsStore::load` hangs the process forever (deadlock inside `RtWrapper::drop` on the store's own runtime) — the error never surfaces". (Update, 2026-09-29: the issue is still open and has no comments yet.)

In the issue we included a few possible fix directions for the maintainers to weigh:

- On the error path in `Actor::new`, avoid dropping `RtWrapper` on a thread of the current runtime. Hand it to another thread instead, or simply `mem::forget` it (there is one runtime per store, and usually only a few stores per process).
- Have `RtWrapper::drop` spawn a separate thread to run `Runtime::drop`, so the runtime's own threads can exit normally.
- Don't let the spawned future hold an owned `Runtime`. Keep it in the store struct and give the future only a handle.

How to fix it is up to upstream. Until there is a resolution, if you use the fs store in iroh-blobs 0.103 and close and reopen the same directory within one process, you can check that the old store has released the lock on `blobs.db` before reopening.

## FAQ

### Why does dropping a tokio Runtime inside an async context hang?

`Runtime::drop` shuts down the runtime and waits for every thread in its blocking pool to exit. If you run that drop with `block_in_place` on one of the runtime's own worker threads, the current thread is already registered as a blocking thread in the pool, so the set of threads it is waiting on includes itself. tokio has a panic check for dropping a Runtime directly in an async context. `block_in_place` lets this drop get past that check, but the thread still ends up waiting on itself. The safe approach is to hand the `Runtime` to a thread that doesn't belong to it and drop it there.

### How do I tell whether a process is deadlocked or just slow?

Start with the magnitude. When a test that takes around ten seconds in isolation turns into several minutes under load, or gets killed by a timeout, slowness is hard to square with a gap that large. Then capture stacks. On macOS, use `sample <pid>`. If nearly all samples sit on the same `park` or `wait` and the stack doesn't change for the whole sampling window, the process is almost certainly waiting for a signal that won't come. In our case, all 1032 samples landed on the same chain.

### Where do I start when a Rust process hangs with no logs?

First use timestamped phase logging to narrow the problem down to one specific step. In this case, that logging is what moved our diagnosis from "redialing" to "opening the store." Then capture thread stacks while the process is hung. The lack of logs is a clue in itself: if a call that should return `Err` neither reports an error nor panics, consider whether the error is being swallowed inside a future that can never complete.

### Can redb's DatabaseAlreadyOpen cause a process to hang?

redb on its own doesn't. It checks the file lock with a non-blocking try_lock and returns `DatabaseAlreadyOpen` immediately when the lock is held. We confirmed this by reading the vendored redb 4.1.0 source. The hang here happened on the drop path in iroh-blobs while it was handling that error. Based on our reading of the source, if `FsStore::load` fails for some other reason, it goes down the same path.

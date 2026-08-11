# iroh-blobs 0.103: `FsStore::load` failure deadlocks the process — draft issue

> ⚠️ DRAFT — not posted anywhere. Owner (xixi) reviews before we file it
> against n0-computer/iroh. Evidence from P-Pass FIX-SC2 (2026-08-11):
> reproduced locally 2× under load + captured a full thread stack via
> `sample`; root cause confirmed by reading vendored sources.

---

## Title (suggested)

**iroh-blobs: a failed `FsStore::load` hangs the process forever (deadlock
inside `RtWrapper::drop` on the store's own runtime) — the error never
surfaces**

## Summary

When `FsStore::load` (or `load_with_opts`) fails on its *error path* — e.g.
redb's `DatabaseAlreadyOpen` because a previous store's actor still holds
the `flock` on `blobs.db` — the spawned `Actor::new` future is dropped
mid-error, which drops the captured `RtWrapper` **on the store's own
runtime thread**. `RtWrapper::drop` then calls
`block_in_place(|| drop(rt))`, and `Runtime::drop` waits for the
`BlockingPool` to shut down — including the very thread executing the
drop. Classic self-deadlock: the future never completes, the error never
reaches the caller, and the process appears to hang (no panic, no
timeout, no log line).

**Impact**: any `FsStore::load` failure (disk full, corrupt database, or
a lock race when a previous store is still draining) hangs the whole
process instead of returning an error. For a daemon that opens the store
at startup this means a silent startup hang.

## Environment

- `iroh-blobs` `0.103.0` (crates.io), feature `fs-store`
- Reproduction host: macOS 14 (arm64), tokio multi-thread runtime
- Triggered under parallel test-suite load + CPU contention, but the
  mechanism is a plain error-path drop, not a load issue

## Stack trace (captured with `/usr/bin/sample`, 1032/1032 samples on one chain)

```
Actor::new (fs.rs:678)                       ← runs on the store's own runtime
  → drop_glue(RtWrapper)                     ← future errored, captured Runtime dropped
    → RtWrapper::drop
      → block_in_place(|| drop(rt))           ← blocking on the runtime's own thread
        → Runtime::drop
          → BlockingPool::shutdown
            → Receiver::wait
              → park                          ← waits forever for a thread that
                                                can never exit (it's this one)
```

The caller that awaited the `load` future never gets a result — the
`DatabaseAlreadyOpen` error from redb is swallowed by the deadlock.

## Root cause (from reading the vendored source)

1. `FsStore::load_with_opts` creates a **fresh multi-thread runtime per
   store** and does `handle.spawn(Actor::new(...)).await` (fs.rs ~line
   678 region).
2. `Actor::new` returns `Result`; on the error path the `?` propagates
   and the spawned future **completes with an error**, dropping the
   captured `RtWrapper` — which holds the `Runtime` that is *currently
   executing this future*.
3. `RtWrapper::drop` is implemented with
   `block_in_place(|| drop(self.rt))`. `Runtime::drop` shuts down the
   blocking pool and waits for all blocking threads to exit. The thread
   that is executing the drop is itself registered in that pool — it
   waits for itself to exit. Deadlock.
4. Because the deadlock happens inside the future, the error never
   propagates to the `load` caller. The bug is masked: callers see a
   hang where they expected an `Err`.

## Minimal reproduction

A standalone program (no test harness, no kill) that deterministically
creates the lock race, then `FsStore::load` a second time while the first
store's actor still holds the redb database:

```rust
use iroh_blobs::store::fs::FsStore;
use tempfile::tempdir;

#[tokio::main]
async fn main() {
    let dir = tempdir().unwrap();
    let path = dir.path();

    // Store A: open, then *drop the handle but keep the actor alive*
    // (the actor holds redb's Database + flock until it drains its queue).
    let a = FsStore::load(path).await.unwrap();
    drop(a);

    // Immediately reopen the same path — races the actor's lock release.
    // Under load this wins the race and load() hits DatabaseAlreadyOpen.
    // Result: instead of Err, the process hangs forever.
    let b = FsStore::load(path).await;
    println!("second load: {b:?}"); // never printed — deadlock
}
```

Deterministic-ish reproduction under stress (what we used):

```bash
# Run N copies in parallel while saturating CPU; one of them will hit
# the race and hang instead of erroring.
for i in $(seq 1 20); do ./repro & done
yes > /dev/null & yes > /dev/null &
wait
```

Observed behavior in our test suite (22 tests in parallel + ~50% CPU
load): the process hangs ~115 s until the test runner kills it. Same
binary run in isolation always succeeds in 6–12 s.

## Expected behavior

A failed `FsStore::load` returns `Err(...)` promptly. The error path
must not drop the runtime from inside itself.

## Suggested fix (for the maintainers to decide)

In `RtWrapper::drop` (or the `Actor::new` error path), do **not** drop
the `Runtime` from a thread that belongs to that runtime. Options:

1. In `Actor::new`'s error path, hand the `RtWrapper` (and thus the
   `Runtime`) to a *different* runtime to drop — e.g. detach it into a
   `spawn_blocking` on an outer runtime, or simply `mem::forget` it (a
   per-store runtime is only dropped once per store, at most a few per
   process lifetime).
2. Make `RtWrapper::drop` spawn a detached thread to perform the drop
   (the runtime's own threads can then shut down normally).
3. Alternatively, avoid holding the runtime inside the spawned future at
   all — construct the `Actor` on a non-owned handle and keep the owned
   `Runtime` in the store struct instead of the future.

## Workaround we shipped (harness side, for reference)

In our test harness we stopped betting on timing: instead of a fixed
100 ms sleep before reopening, we poll the file lock (`File::try_lock` on
`blobs.db`, 10 ms interval, 30 s cap) and only reopen once the previous
store has actually released it. Production code opens the store once per
process and never reopens, so it does not hit this path — but any
`FsStore::load` failure in production would still hang the process, which
is why we think this deserves an upstream fix.

## Related

- redb's `try_lock` returns `DatabaseAlreadyOpen` as an *error* (not a
  hang) — confirmed from vendored `redb-4.1.0` sources. The hang is
  entirely in the iroh-blobs drop path, not in redb.

---

*Draft by Salamira (agent) for xixi's review — not filed.*

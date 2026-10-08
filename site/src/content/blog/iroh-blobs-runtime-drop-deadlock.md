---
title: 一个本该报错的 Rust 程序为什么直接卡死：iroh-blobs FsStore::load 的自死锁
description: "iroh-blobs 的 FsStore::load 打开失败时不报错而是卡死：从 CI 偶发超时一路查到错误路径上的 tokio runtime 自死锁。"
date: 2026-08-12
tags: [Rust, 工程, 调试]
lang: zh
draft: false
---

P-Pass 的传输层用 iroh-blobs 存取文件内容，它的 fs store 底下是一个 redb 数据库文件 `blobs.db`。我们有一条集成测试专门验证断点续传：接收端传到一半被杀掉，重启后接着传，最后逐位核对文件。

这条测试在 CI 上时不时超时。300 秒打满被杀，前后撞了 3 次，每次重跑就过。同一条测试隔离跑 6.4 秒，本机全量并行跑 12.75 秒。

一个 6 到 13 秒的测试，不会因为 CI 机器慢一点就拖到 300 秒以上。差了一个数量级，更像是有什么东西在等一件永远不会发生的事。最后查下来，是 iroh-blobs 打开 store 失败时，错误路径上的一次 drop，让执行它的线程开始等自己退出。

## 本该报 DatabaseAlreadyOpen，进程却挂住了

第一步是给测试加带时间戳的阶段打点：绑定、传输进度、kill、重启、重新拉取、校验，每个阶段都往 stderr 打一行。下次 CI 再超时，最后一条打点就能说明卡在哪。

很快又撞了一次。那次提交只改了 Android、桌面端和 worker，Rust 传输层一行没动，属于纯粹的偶发复现。测试在 322 秒后被杀，最后一条打点是 `restart: rebinding receiver endpoint`，之后什么都没有。kill 之前的传输进度逐 MB 正常增长，所以传输过程本身没问题，问题在重启之后。

我们一开始把它读成"重启后重新拨号卡住了"。

动手之前，我们先把几种省事的做法排除在修复之外：放宽超时、缩小测试数据量、加重试、把测试标成 flaky，这些都只会让症状消失。`--test-threads 1` 串行跑也一样，它可以用来证明问题跟并发有关，但不能当修法，因为生产环境里的后台服务同样是并发的，把测试串行化等于把一个真实的竞态藏起来。

要找到原因，只能先在本地复现。之前隔离跑从来没复现过，这次加了压力：transport 全量套件 22 个测试并行，再给 4 核机器压上 50% 的 CPU 负载。第一轮就撞上了，restart 阶段卡了 115 秒，被 nextest 的 slow-timeout（120 秒）终止。

把 restart 阶段再拆细打点以后，结论变了。打点显示 endpoint 很快就重新绑定完成，卡住的是紧接着的 `Blobs::open`，也就是 `FsStore::load`。问题出在打开本地数据库这一步，它一直没有返回。

打开本地数据库这一步，我们手上其实有一个候选：重启前的那个 store 可能还没放掉 redb 的文件锁。但这个候选早先被我们自己排除过，理由是 redb 拿锁用的是非阻塞的 try_lock，锁被占就返回 `DatabaseAlreadyOpen`，测试里的 `unwrap` 会直接 panic，不会挂着不动。

这个推理只对了一半。读 vendored 的 redb 4.1.0 源码可以确认，锁被占时它确实返回错误，不会阻塞。问题在于这个错误根本没有走到 `unwrap`。进程既没有 panic，也没留下任何日志。

## 用 sample 抓栈

没有日志的挂起，靠读输出查不下去，只能直接看线程此刻停在哪。macOS 自带 `/usr/bin/sample`，可以对一个正在运行的进程按固定间隔采样所有线程的调用栈。

我们在挂起约 20 秒时对测试进程采样。结果很干净：1032 个样本，1032 个都落在同一条调用链上。

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

整个采样期间这条栈没有变过，线程停在 `park` 上等一个信号。程序只是慢的话，样本会分散在很多正在干活的函数里；样本全部压在同一个等待点上，基本可以认定是死锁。

## 根因：在 runtime 自己的线程上 drop 这个 runtime

对照 vendored 源码（iroh-blobs 0.103.0，tokio 1.53.1）读这条栈，过程可以拆成四步。

1. `FsStore::load_with_opts` 为每个 store 新建一个独立的多线程 tokio runtime，然后执行 `handle.spawn(Actor::new(...)).await`。被 spawn 的 future 捕获了一个 `RtWrapper`，而 `RtWrapper` 持有的正是这个 runtime 本身。
2. `Actor::new` 返回 `Result`。打开 redb 遇到 `DatabaseAlreadyOpen` 时，`?` 把错误往上抛，future 以错误结束，它捕获的 `RtWrapper` 随之被 drop。执行这个 future 的是这个 runtime 自己的工作线程，所以 drop 也发生在这个线程上。
3. `RtWrapper::drop` 的实现是 `block_in_place(|| drop(rt))`。`block_in_place` 把当前工作线程转成阻塞线程，再在上面执行 `Runtime::drop`。`Runtime::drop` 要关闭 blocking pool，并等 pool 里的所有线程退出。当前线程此时就登记在这个 pool 里，于是它开始等自己退出。
4. 死锁发生在 future 内部，future 永远结束不了，`load` 的调用方也就永远拿不到那个 `Err`。

从外面看，一次本该立刻返回的打开失败，变成了一个没有任何输出的永久挂起。前面说的"错误没有走到 `unwrap`"，原因就在这里。

## 锁为什么还没放

触发条件出在我们自己的测试里。

测试里的"杀掉接收端"是进程内的 abort，跟真实场景里进程被系统杀掉差别很大。abort 只 drop 了 `FsStore` 句柄，相当于关掉通往 store actor 的 channel。持有 redb `Database`（也就是持有 `blobs.db` 上 flock）的是那个跑在 store 独立 runtime 上的 actor。actor 要先写完手头的 batch，再等到被调度，才会退出并释放锁。

旧代码在 abort 之后固定睡 100 毫秒，然后在同一个目录重开 store。平时 100 毫秒够用，22 个测试并行加 CPU 负载时就不够了。重开撞上还没释放的锁，redb 返回 `DatabaseAlreadyOpen`，接着进入上面那条死锁路径。

所以这件事有两层：测试里的时序竞态让重开撞上了锁，而 iroh-blobs 处理这个错误时把自己锁死，一次普通的打开失败就成了永久挂起。如果只有前一层，测试会直接以一条清楚的 `DatabaseAlreadyOpen` 失败。

## 最小复现

按这个机制，复现只要两步：开一个 store，丢掉句柄，然后立刻在同一个目录再开一次。

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

这段程序是我们按机制整理出来、附在上游 issue 里的复现形态。第二次 `load` 能不能撞上锁取决于时序：机器空闲时 actor 通常来得及放锁，程序会正常打印结果；要在多个副本并行、CPU 吃满的情况下反复跑才容易命中。我们实际抓到栈的场景是前面那套测试加压环境，共复现 2 次卡死，另有 1 次挂起超过 50 秒。

判断自己遇到的是不是同一个问题，看挂起时的栈里有没有 `RtWrapper::drop → block_in_place → Runtime::drop → BlockingPool::shutdown` 这一段。

## 我们这边的修法

测试侧的修法很窄：去掉固定的 100 毫秒睡眠，改成轮询 `blobs.db` 的文件锁，锁真正释放了才重开。

```rust
let db_path = receiver_store.join("blobs.db");
let lock_deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
loop {
    let free = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&db_path)
        .map(|f| f.try_lock().is_ok())
        .unwrap_or(true); // 文件还不存在（首轮）→ 无锁可等
    if free {
        break;
    }
    assert!(
        std::time::Instant::now() < lock_deadline,
        "旧 store 30s 内未释放 blobs.db 锁——actor 退出被卡死"
    );
    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
}
```

间隔 10 毫秒，上限 30 秒。超过上限就带着明确的信息失败，不会再无声地挂到被杀。

修完以后，在能复现的同一套压力条件下循环跑了 40 轮，40 轮全绿，没有一次超时；本地全量 149 个测试全部通过。作为对照，修复前在同样的条件下复现过 2 次，并抓到了死锁栈。

产品代码这边，后台服务每个进程只打开一次 store，从不在进程内重开，走不到这条竞态。真实使用中 App 被杀就是进程退出，锁随进程一起释放。

不过按我们读源码的理解，任何让 `FsStore::load` 走到错误路径的情况，比如磁盘满、数据库文件损坏，都会进入同一段 drop 逻辑，结果是挂起，调用方收不到错误。对一个启动时打开 store 的后台服务来说，这意味着启动时可能静默卡住，日志里什么也看不到。我们自己的测试绕过去了，这个影响面还在，所以我们把它报给了上游。

## 上游进展

我们在 2026-08-12 把机制、栈和复现提交到了 iroh 仓库（n0-computer/iroh#4468）。之后它被转到了 iroh-blobs 仓库，现在的地址是 [n0-computer/iroh-blobs#252](https://github.com/n0-computer/iroh-blobs/issues/252)。issue 标题是 "iroh-blobs: a failed `FsStore::load` hangs the process forever (deadlock inside `RtWrapper::drop` on the store's own runtime) — the error never surfaces"。（2026-09-29 补记：这个 issue 仍是 open 状态，还没有评论。）

issue 里我们附了几个修复方向，供维护者判断：

- 在 `Actor::new` 的错误路径上，不在当前 runtime 的线程里 drop `RtWrapper`，改为交给别的线程处理，或者直接 `mem::forget`（每个 store 只有一个 runtime，一个进程里通常也就几个）；
- 让 `RtWrapper::drop` 起一个独立线程去执行 `Runtime::drop`，runtime 自己的线程就能正常退出；
- 不让 spawn 出去的 future 持有 owned `Runtime`，把它放在 store 结构体里，future 只拿 handle。

具体怎么改由上游决定。在有结论之前，如果你也在用 iroh-blobs 0.103 的 fs store，并且会在同一个进程里关掉再重开同一个目录，可以在重开前先确认旧 store 已经释放了 `blobs.db` 的锁。

## 常见问题

### 为什么在 tokio 异步上下文里 drop Runtime 会卡住？

`Runtime::drop` 会关闭 runtime，并等待它的 blocking pool 里所有线程退出。如果在这个 runtime 自己的工作线程上用 `block_in_place` 执行这个 drop，当前线程已经被登记为 pool 里的阻塞线程，它等待的对象里就包括它自己。tokio 对"在异步上下文里直接 drop Runtime"有 panic 检查，`block_in_place` 让这次 drop 绕过了这项检查，但自我等待依然存在。稳妥的做法是把 `Runtime` 交给一个不属于它的线程去 drop。

### 怎么判断进程是死锁而不是慢？

先看量级。隔离跑十秒上下的测试，在负载下变成几分钟甚至被超时杀掉，慢很难解释这么大的差距。再抓栈：macOS 上用 `sample <pid>`，如果几乎所有样本都停在同一个 `park` 或 `wait` 上，而且整个采样期间栈都不变，基本就是在等一个不会来的信号。我们这次是 1032 个样本全部落在同一条链上。

### Rust 进程 hang 住又没有任何日志，该从哪里查？

先用带时间戳的阶段打点把范围缩到一个具体步骤，这次就是靠打点把问题从"重新拨号"改判到"打开 store"。然后在挂起现场直接抓线程栈。没有日志本身也是线索：如果一个本该返回 `Err` 的调用既不报错也不 panic，要考虑错误是不是在一个永远结束不了的 future 里被吞掉了。

### redb 的 DatabaseAlreadyOpen 会导致进程挂起吗？

redb 自己不会。它用非阻塞的 try_lock 检查文件锁，锁被占时立刻返回 `DatabaseAlreadyOpen`，我们读 vendored 的 redb 4.1.0 源码确认过这一点。这次的挂起发生在 iroh-blobs 处理这个错误时的 drop 路径上。按我们读源码的理解，换成别的原因让 `FsStore::load` 失败，也会走进同一段路径。

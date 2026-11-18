# NET-29 用虚拟时钟验证「一次 serve 只等一个 deadline」

- 状态：已采纳（产品负责人 2026-11-18，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1758)）
- 日期：2026-11-18
- 关联：#1758、#570（QA-20）、#1730、#1827（作废的独占线程方案）
- 代码基线：`ba348944`

## 背景

手机 provider 的 endpoint 在 serve 前要等它上线，最多等一个 `online_timeout`（400ms）。NET-29 要求验证两件事：**一次 serve 只等一个 deadline 就放弃**，以及**每次失败都换一个新的 endpoint**。

原判据把「只等一个 deadline」压在真实时钟上：断言错误里的 `waited_ms`（`std::time::Instant` 实测值）落在 `[400, 800)`。这条断言在 Windows 全量并发时偶发为红——实测 `waited 1582ms`（#1730），而同样的分支单跑、以及受控实验里 `wait_online` 内部一直只等 400–444ms。

原因不是产品超了预算，而是判据本身用错了钟：**定时器只保证「不早于 deadline 唤醒」，从不保证「不晚太多」**。CPU 被抢占时回调迟到多久都合法，因此墙钟上界量到的是 runner 有多忙，不是产品等了几次。它既证明不了语义，又会在最不该红的时候红。

## 决定

1. NET-29 的等待改用 **tokio 虚拟时钟**验证：测试自建一个 `start_paused` 的 `current_thread` runtime，在该 runtime 上 await 等待所在的 `BlobsProvider::online_endpoint`，断言**虚拟时间正好前进一个 deadline**（`assert_eq!(waited, NET29_ONLINE_TIMEOUT)`）。删掉基于 `waited_ms` 的墙钟上界。
2. 「每次失败都换新 endpoint」仍按原样逐次验证：`endpoint_generation() == attempt`，且每次拿到的 NodeId 都没出现过。
3. 该用例放进 `crates/transport/src/provider.rs` 的 `#[cfg(test)]` 模块，不再放在 `tests/media_import.rs`：`time::pause()` 只对 `current_thread` runtime 生效，而 provider 自己的 runtime 是 `multi_thread`；但 `wait_online` 的 `timeout` 认的是**任务所在**的 runtime，所以只有同 crate、能拿到 `online_endpoint` 的测试模块才能把定时器放到虚拟时钟上。
4. 产品代码不改：等待逻辑、deadline、错误文案、endpoint 换代行为一律保持原样；`Cargo.toml` 只为 dev-dependency 补 tokio 的 `test-util`。
5. 上一版「让该用例独占整个线程池」的方案作废（PR #1827 已关闭）：它只是让迟到不容易发生，没有消除对真实时钟的依赖。

## 理由

- **验证语义，而不是验证机器耗时。** 「只等一个 deadline」是一条关于**等了几次**的断言，与 CPU 忙不忙无关。虚拟时钟只在定时器到期、且没有可运行任务时前进，与调度延迟完全解耦，因此 `waited == 400ms` 在同一条执行路径上只有一种解释：等满一个 deadline 就放弃，没有等第二个。
- **反证仍然成立。** 把等待改成两个 deadline，虚拟时间前进 800ms，断言当场红；把 `replace_endpoint` 改成不换新 endpoint，generation 不涨，断言当场红。两条反证都不再依赖机器负载。
- **稳定性可复现地变好。** 原来的红是概率性的（要靠机器恰好很忙才撞到），现在是确定性的：要么语义正确，要么直接红。连续跑 20 次全绿不能证明「将来也不会因为调度迟到而红」——旧判据做不到这一点，新判据在原理上排除了这种可能。

## 后果

- 这条用例不再受 CPU 争用影响，全量并发下不会因为调度迟到误报；相应地，它也不再能发现「runner 上定时器迟到」这类环境问题——那不是它要保证的事，环境问题由受控实验与日志看。
- 用例从集成测试搬到 crate 内的 `#[cfg(test)]` 模块，覆盖的是 `serve` 里唯一碰时钟的一步（`online_endpoint`）；`serve` 的外层（查持有、装 handler）仍由 `tests/media_import.rs` 的其它用例覆盖。
- dev-dependency 多一个 `test-util` 特性，只影响测试构建，不进发布产物。
- 测试代码之外的调用方式不变：生产仍用 provider 自己的 `multi_thread` runtime 与真实时钟。

## 备选

- **独占线程（nextest `threads-required = "num-test-threads"`）**：已实现过并关闭（#1827）。它降低迟到概率，不改变「用真实时钟当判据」这个根因；runner 上仍可能被饿死到超预算，且让全量跑为一条用例串行化。**不采用。**
- **放大上界（如 3×deadline）**：同样治不了根因，只是把红线挪远，仍然是概率。**不采用。**
- **把 deadline 调大以降低相对误差**：牺牲真实行为的时间预算去迁就测试，方向相反。**不采用。**
- **给产品加时钟注入点、在测试里替换时钟**：需要改产品 API 与生产调用路径，为一个测试扩大公开面，且与第 4 条冲突。**不采用。**

## 验收

- 用例在虚拟时钟下稳定通过：连续跑 20 次全绿，与机器负载无关。
- 虚拟时间恰好前进一个 deadline（三次 attempt 均为 400ms）。
- 两条反证必须变红：等待两倍 deadline → `800ms ≠ 400ms`；不换 endpoint → generation `0 ≠ 1`。

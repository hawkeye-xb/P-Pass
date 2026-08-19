# E2E-02 DaemonHelloTest 断言一个 2026-08-08 就废弃的契约，e2e 门禁常红　级别 L1

**发现于**：用户打 `v0.3.3-test.7` 后 e2e 门禁红（2026-08-19）。

## 现象

`tools/android-hello.sh` 起一个临时 daemon → 抓配对码 → 跑
`DaemonHelloTest`，结果 `BUILD FAILED`。用户贴的 daemon 日志一切正常
（身份铸造、二维码、SYNC-01 对账都完成），迷惑性很强。

## 根因：测试停在旧契约上

`DaemonHelloTest.kt` 第一步就断言配对码必须带 `a=`：

```kotlin
val parsed = parsePairingQr(qr!!.trim())
assertNotNull("QR must carry an address (a=)", parsed.addr)
```

而 `crates/daemon/src/pairing.rs` 里写得很清楚，**H-10b 改造
（2026-08-08）已经把 `&a=` 从配对码里去掉了**：

```rust
/// H-10b rework (2026-08-08): the full PeerAddr QR (id + relay +
/// direct IPs, 100–180 chars base64) was too dense to scan. The QR
/// now carries only the relay URL as `&r=`; the Android side rebuilds
/// the address token from node + relay. Kept for reference only —
/// start() no longer appends `&a=`.
#[allow(dead_code)]
addr_provider: ...
```

daemon 现在**永远不会**产出 `a=`，这条断言必然失败。实测日志里的配对码
确实只有 `node` / `t` / `r` 三个参数。

**干扰项（都不是病因，别再往这两条上排查）**：
- `libc::sendmsg failed with Invalid argument (os error 22); halting
  segmentation offload` —— GitHub runner 上的常见噪音（关掉 UDP 分段卸载）。
- `network_path=Ip { remote: …, local: None }` —— 走 relay 路径时的正常表现。

## 为什么拖到现在才炸

跟同日发现的 `DiagTextTest` i18n 漂移是同一个模式：**这条测试平时根本
不跑**。它靠 `assumeTrue(PPF_DAEMON_QR 非空)` 自我跳过，日常
`testDebugUnitTest` 里恒为 skipped；只有 `tools/android-hello.sh` 会设
这个环境变量，而该脚本只在 `e2e.yml`（nightly + tag 门禁）里跑。所以
它从 2026-08-08 起就该红了，一直没人碰到。

## 修法：改测试，不要改 daemon

H-10b 是**有意的产品决策**（完整 PeerAddr 二维码密到扫不动），不许为了
让测试变绿而退回去加 `a=`。断言应该改成验证**新契约**：

- 配对码带 `node` + `r=`；
- Android 侧能从 node + relay 重建出可拨号地址（这条链路本身就是
  H-10b 的核心，值得被 e2e 守住）；
- hello 往返成功、`protoVer == 1`、capabilities 含 `thumbnail.v1`。

## 可执行验收

- `bash tools/android-hello.sh` 本地跑通（需要 `target/release/daemon`，
  先 `cargo build --release -p daemon`）→ 期望输出 `HELLO OK: …`。
- **反证**：把重建地址那一步改坏（例如丢掉 relay）→ 测试必须红，证明它
  真的在守 H-10b 的重建链路，而不是恒真式。

## 范围

只准动 `apps/android/app/src/test/java/com/hawkeyexb/ppass/transport/DaemonHelloTest.kt`，
必要时 `tools/android-hello.sh`。**不准动** `crates/daemon/src/pairing.rs`
的 QR 生成逻辑。

## 收尾

e2e 门禁绿 + PROGRESS.md 一行 + 本卡移入 `done/`。

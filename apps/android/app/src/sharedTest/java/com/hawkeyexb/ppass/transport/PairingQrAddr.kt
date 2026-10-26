// E2E-02: 从配对码重建可连接地址的**唯一一份**测试辅助。
// #420: 放在 src/sharedTest，JVM 单测与 androidTest 两个源集共用（之前只在 src/test，设备测试编不过）。
//
// H-10b（2026-08-08）把 `&a=`（完整 PeerAddr，100–180 字符 base64，太密扫
// 不动）从配对码里去掉了，新码只带 relay URL（`r=`），手机端从 node+relay
// 重建。生产代码在 `PairFlow.pairWithQr` 里做这件事。
//
// 而**四个 e2e 测试各自写了 `parsePairingQr(qr).addr!!`**，于是从那天起全部
// 恒挂（NPE / 断言失败），nightly 与每个 release tag 的 e2e 门禁一直是红的，
// 而 daemon 日志一切正常，迷惑性极强。2026-08-20 修 E2E-02 时我只改了
// DaemonHelloTest 一处，跑真实备份脚本才撞出另外三处——所以抽成一份，
// 下次协议再变只改这里。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.ffi.parsePairLink

/** 与 `PairFlow.pairWithQr` 同源：配对串交给 Rust 核心的唯一解析器（#1149），再从它给出的
 *  PeerAddr token 取可连接地址。畸形串直接抛出，不再有手写解析。 */
fun addrOf(qr: String): PeerAddrParts = parsePeerAddrToken(parsePairLink(qr.trim()).peerToken)

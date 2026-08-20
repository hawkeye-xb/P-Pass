// E2E-02: 从配对码重建可连接地址的**唯一一份**测试辅助。
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

/** 与 `PairFlow.pairWithQr` 同源的地址重建：新码走 node+relay，旧码的
 *  `a=` 仍兼容。两者都没有 = 配对码无法解析，明确失败而不是 NPE。 */
fun addrOf(qr: PairingQr): PeerAddrParts =
    qr.addr
        ?: qr.relayUrl?.let { PeerAddrParts(qr.nodeIdHex, it, emptyList()) }
        ?: error(
            "pairing code carries neither a= nor r= — " +
                "daemon and app versions disagree (see H-10b)"
        )

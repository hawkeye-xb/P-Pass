// #1122 / #1124：桌面在连接层发出的 QUIC 应用关闭码（跨端注册表，Rust 唯一定义在
// `crates/proto/src/close_codes.rs`；iOS 镜像 `PPassCore/Flow/DesktopCloseCodes.swift`）。
//
// 关闭帧在 TLS 握手之后发出，经桌面身份认证，与 `not_paired` 应答同样可信。手机只在「关闭方就是配对
// 记录里的那台电脑」且关闭码是下面两个之一时，把这次关闭归为明确的「未配对」，汇入与 `not_paired`
// 应答同一条「被拒即清理」路径；其它一律按「连不上」（超时、网络断、本地关闭、未知关闭码、关闭方
// 不是记录的那台电脑）。取值不在别处重复：契约测试读 `snapshots__close_codes_registry` 快照核对这里。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.flow.DesktopRejectedException
import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import com.hawkeyexb.ppass.ffi.PeerCloseListener
import java.io.IOException

object DesktopCloseCodes {
    /** 接受连接时因为「没有配对记录、也不在配对窗口内」被拒。 */
    const val NOT_PAIRED: Long = 401

    /** 已有连接因为这台设备的配对记录被删除而被关。 */
    const val UNPAIRED: Long = 410

    /** 注册表：(关闭码, 线上原因串)，顺序与快照一致。 */
    val registry: List<Pair<Long, String>> = listOf(NOT_PAIRED to "not_paired", UNPAIRED to "unpaired")

    /** 这个关闭码是不是「未配对」。 */
    fun meansNotPaired(code: Long): Boolean = code == NOT_PAIRED || code == UNPAIRED
}

/**
 * 连接被经认证的对端用应用关闭码关掉（FFI `FfiException.PeerClosed` 的 Kotlin 镜像）。本身按「连不上」
 * 处理（IOException）；只有经 [desktopRejectionForClose] 翻译过的才算「未配对」。
 */
class PeerClosedException(val nodeId: String, val code: Long) :
    IOException("connection closed by ${nodeId.take(8)}… with code $code")

/**
 * 关闭帧 → 「未配对」。只有关闭方 == 本地配对记录里的 daemonNodeId、且关闭码属于「未配对」才返回
 * [DesktopRejectedException]（`not_paired`，走与应答同一条被拒路径）；否则 null（按「连不上」处理）。
 */
internal fun desktopRejectionForClose(
    nodeId: String,
    code: Long,
    recordedDaemonNodeId: String?,
    method: String,
): DesktopRejectedException? {
    if (!DesktopCloseCodes.meansNotPaired(code)) return null
    val recorded = recordedDaemonNodeId?.takeIf { it.isNotBlank() } ?: return null
    if (!nodeId.equals(recorded, ignoreCase = true)) return null
    return DesktopRejectedException("not_paired", method)
}

/**
 * #1124：[DaemonClient.onPeerClosed] 的处理——任何一条连接（请求、探测、订阅流、取原图）被对端用应用
 * 关闭码关掉时调用。关闭方是 [pairing] 里记录的那台电脑、且码是「未配对」⇒ 记进 [loss]（随后由被拒即
 * 清理删配对、清缓存、停任务，#1119）并返回 true；其余（别的关闭方、别的码、没有配对）不动，按连不上处理。
 */
internal fun recordDesktopClose(
    nodeId: String,
    code: Long,
    pairing: Pairing?,
    loss: FlowDeliveryPairingLoss,
): Boolean {
    val p = pairing ?: return false
    val rejected = desktopRejectionForClose(nodeId, code, p.daemonNodeId, "connection") ?: return false
    loss.record(PairingId(p.pairingId), rejected)
    return true
}

/**
 * FFI 的 [PeerCloseListener] → Kotlin 回调。控制面（[DaemonClient]）与上传 provider（#1126）共用这一个：
 * 回调在 Rust 自己的线程上，抛出的异常不能穿回 Rust，所以统一 `runCatching`。
 */
internal fun peerCloseListener(handler: (nodeId: String, code: Long) -> Unit): PeerCloseListener =
    object : PeerCloseListener {
        override fun onPeerClosed(nodeId: String, code: ULong) {
            runCatching { handler(nodeId, code.toLong()) }
        }
    }

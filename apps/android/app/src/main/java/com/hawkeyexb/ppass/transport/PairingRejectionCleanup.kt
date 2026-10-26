// #1119：被拒即清理（被动断开）。
//
// 桌面不认这台手机（业务请求回 not_paired / pairing_mismatch，或 hello 成功却不带本机的 pairing id）时，
// 手机删掉自己这一侧的配对记录并清理——与用户手动断开同一份清单，只是**不发** device.unpair（对方已经不认我们）。
//
// 发现与清理分开：发现的地方（探测、投递、前台心跳）只在 [FlowDeliveryPairingLoss] 上记一笔（按配对 id），
// 清理由这里执行。不能在发现处同步清：探测跑在引擎这一轮的协程里，清单里的「停 Flow 运行时」会关掉正在跑这一轮的引擎。
//
// 幂等：判据永远是「本地当前保存的配对 id 就是被记为失效的那一条」。
// - 多个调用路径同时发现 → 进程内串行，第一个清掉，后面的看到没有配对，空操作；
// - 清完之后在途请求再收到拒绝 → 没有配对，空操作；
// - 迟到的旧拒绝（用户已经重新配对）→ 当前配对 id 不是被记的那条，不动新配对。
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.backup.flow.FlowDeliveryPairingLoss
import com.hawkeyexb.ppass.backup.flow.PairingId
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

internal class PairingRejectionCleanup(
    private val currentPairing: () -> Pairing?,
    private val loss: FlowDeliveryPairingLoss,
    /** 断开清单的执行体（生产：clearLocalPairingLogged）。清理失败只记日志，由它自己吞掉。 */
    private val clear: (Pairing) -> Unit,
) {
    private val lock = Any()
    private val _clearedPairingId = MutableStateFlow<String?>(null)

    /** 最近一次被「被拒即清理」清掉的配对 id；界面据此回欢迎页（StateFlow：界面晚接上也能看到）。 */
    val clearedPairingId: StateFlow<String?> get() = _clearedPairingId

    /** 有新的失效被记下时调用。返回是否真的清了。 */
    fun onLossRecorded(): Boolean = synchronized(lock) {
        val pairing = currentPairing() ?: return false
        if (!loss.isLost(PairingId(pairing.pairingId))) return false
        clear(pairing)
        // 配对记录没删掉（写盘失败）就不能让界面以为已经断开。
        if (currentPairing()?.pairingId == pairing.pairingId) return false
        _clearedPairingId.value = pairing.pairingId
        true
    }
}

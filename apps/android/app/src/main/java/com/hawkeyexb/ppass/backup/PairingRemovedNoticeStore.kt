// #1219 V4：被拒即清理（#1119）之后的一次性说明。
package com.hawkeyexb.ppass.backup

import java.io.File

/**
 * 电脑不再认这台手机、本地配对已被被拒即清理删掉——这件事要在**下一次打开 App 时说明一次**。
 *
 * 清理多半发生在后台（投递、探测、周期任务），当时没有界面；系统通知又依赖通知权限。所以把「有一条
 * 待说明的移除」落盘，界面在用户看到时弹一次，点「知道了」即清（一次性事件持久化后在前台确认，
 * 与系统的账号被移除提示同一做法）。
 *
 * - 放在 `filesDir` 顶层，断开清单里登记为 KEEP：它在清理**之后**写入，必须活过这次清理；
 * - 重新配对成功后就不再说明（界面只在没有配对时弹，有配对时顺手清掉）；
 * - 纯文件 IO，JVM 单测能真跑往返。
 */
class PairingRemovedNoticeStore(private val dir: File) {
    private val file = File(dir, FILE_NAME)

    /** 记下：配对 [pairingId] 已被被拒即清理删掉，待说明。 */
    fun record(pairingId: String) {
        dir.mkdirs()
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(pairingId)
        check(tmp.renameTo(file)) { "cannot persist $FILE_NAME" }
    }

    /** 有没有待说明的移除。 */
    fun pending(): Boolean = file.exists()

    /** 用户看过了（或已经重新配对），不再说明。 */
    fun clear() {
        file.delete()
    }

    companion object {
        const val FILE_NAME = "pairing_removed_notice"
    }
}

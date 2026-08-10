// MOB-02（2026-08-11 用户定稿）§五：失败重试计数——连续失败次数落盘。
// 成功或放弃本轮时 reset（下一个触发事件 ②③④ 天然就是新一轮重试）。
// tmp+rename 崩溃安全（WatermarkStore 同款），损坏读 0。
package com.hawkeyexb.ppass.backup

import java.io.File

class BackupAttemptStore(private val dir: File) {
    private val file = File(dir, "backup-attempt.txt")

    /** 当前连续失败次数（0 = 无失败；文件不存在/损坏都算 0）。 */
    fun current(): Int =
        if (file.isFile) file.readText().trim().toIntOrNull() ?: 0 else 0

    /** 记录一次失败，返回新的连续失败次数。 */
    fun recordFailure(): Int {
        dir.mkdirs()
        val next = current() + 1
        val tmp = File(dir, "backup-attempt.txt.tmp")
        tmp.writeText(next.toString())
        check(tmp.renameTo(file)) { "cannot persist backup attempt counter" }
        return next
    }

    /** 成功 / 放弃本轮后清零——下次触发从 0 开始。 */
    fun reset() {
        file.delete()
    }
}

// #548：App 写 logcat 的唯一出口。
//
// 本质：日志里的敏感值（对端 / 本机公网地址、自建 relay 域名、全长 hash / NodeId、原生层异常文本里
// 夹带的地址）不能指望每个调用点都记得删——调用点会一直增加，记性不会。标准做法是在日志的唯一
// 出口统一脱敏：电脑端 daemon 在日志写入器（`log_guard`）落盘前过 `redact()`（#544），这里是
// Android 端的同一个位置。
//
// - 只有本文件可以碰 `android.util.Log`；门禁测试 `LogExitGateTest` 扫 src/main 下所有 Kotlin
//   源码，绕过本出口直接写 logcat（含 printStackTrace / System.out）即红。
// - Throwable 不交给 `Log.w(tag, msg, t)`：那样系统会把异常 message 与整条 cause 链原样打出来，
//   打码管不到。这里先转成文本，与 msg 一起过 [Redact.redact] 再写。
// - 「源头只记事件和类别」仍是第一原则（如 CallTrace 只输出 lan / public、n0 / custom）；本出口是兜底。
package com.hawkeyexb.ppass.log

import android.util.Log

object PLog {

    /** 写出端：生产 = `android.util.Log.println`；JVM 单测里换成收集器（真 Log 在 JVM 上会抛）。 */
    fun interface Sink {
        fun write(priority: Int, tag: String, message: String)
    }

    private val logcat = Sink { priority, tag, message -> Log.println(priority, tag, message) }

    @Volatile
    internal var sink: Sink = logcat

    /** 测试结束时还原。 */
    internal fun resetSink() {
        sink = logcat
    }

    // android.util.Log 的级别常量值（文档化的稳定 ABI）。
    const val VERBOSE = 2
    const val DEBUG = 3
    const val INFO = 4
    const val WARN = 5
    const val ERROR = 6

    fun v(tag: String, msg: String, tr: Throwable? = null) = write(VERBOSE, tag, msg, tr)
    fun d(tag: String, msg: String, tr: Throwable? = null) = write(DEBUG, tag, msg, tr)
    fun i(tag: String, msg: String, tr: Throwable? = null) = write(INFO, tag, msg, tr)
    fun w(tag: String, msg: String, tr: Throwable? = null) = write(WARN, tag, msg, tr)
    fun e(tag: String, msg: String, tr: Throwable? = null) = write(ERROR, tag, msg, tr)

    /** 写出前的最终文本（与 `Log.w(tag, msg, t)` 同形：msg + 换行 + 栈），已脱敏。 */
    internal fun render(msg: String, tr: Throwable?): String {
        val raw = if (tr == null) msg else msg + "\n" + tr.stackTraceToString()
        return Redact.redact(raw)
    }

    private fun write(priority: Int, tag: String, msg: String, tr: Throwable?) {
        sink.write(priority, tag, render(msg, tr))
    }
}

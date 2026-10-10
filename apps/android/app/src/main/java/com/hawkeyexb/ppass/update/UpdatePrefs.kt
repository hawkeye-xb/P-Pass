// UPD-02: 自动检查节流 + 版本变更回执 + 待办更新的落盘。
//
// 三个事实，一份文件（与 DefinitiveNoticeStore 同款 tmp+rename 写法）：
//  1. lastCheckAt——ON_RESUME 触发自动检查的 6h 节流门。国产 ROM 上进程常驻
//     数天，冷启动检查可能一直不跑，ON_RESUME 是唯一能接到这类用户的口子；
//     但闸门必须立在「距上次满 6h」上，否则每次切回前台都打一次更新源。
//  2. lastSeenVersion——升级回执。PackageInstaller 的 SUCCESS 只告诉我们
//     「系统收了」，进程随即被替换；下次启动比对 BuildConfig 版本才发现
//     「真的换过来了」，据此清掉上个版本的下载产物与待办（#808 起不弹提示）。
//  3. pending——用户点了「下载安装」的那一次更新。WorkManager 进程死亡后
//     UI 靠它把「下载中 / 待安装」状态恢复出来，不靠内存。
package com.hawkeyexb.ppass.update

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 自动检查的最小间隔：6 小时。手动「检查更新」不受此门限制（用户的意思表示）。 */
internal const val AUTO_CHECK_INTERVAL_MS = 6L * 60 * 60 * 1000

/**
 * ON_RESUME 自动检查节流（纯函数，JVM 可测）：
 * 从没查过必查；距上次满 [AUTO_CHECK_INTERVAL_MS] 才查；时钟回拨（now < last）
 * 不查——差值为负，天然落在门槛内。
 */
fun shouldAutoCheck(lastCheckAt: Long, now: Long): Boolean =
    lastCheckAt <= 0L || now - lastCheckAt >= AUTO_CHECK_INTERVAL_MS

/** 用户已确认、正在（或等待）下载安装的那一个版本。 */
@Serializable
data class PendingUpdate(
    val version: String,
    val notes: String = "",
    val url: String,
    val sha256: String = "",
    val signature: String = "",
    /**
     * #719: 承载这条更新线的 WorkRequest id。界面只观察这一个 id——被顶替的旧请求
     * 发出的 CANCELLED 与这条线无关。#719 之前写下的待办没有它（null）：没有
     * 能驱动它的请求，按孤儿处理（UPD-21）。
     */
    val workId: String? = null,
)

/** 待办绑定的请求 id；缺失或读不出 = 没有能驱动这条线的请求。 */
internal fun PendingUpdate.workUuid(): java.util.UUID? =
    workId?.let { runCatching { java.util.UUID.fromString(it) }.getOrNull() }

@Serializable
private data class UpdatePrefsData(
    val lastCheckAt: Long = 0L,
    val lastSeenVersion: String? = null,
    val pending: PendingUpdate? = null,
)

class UpdatePrefs(private val dir: File) {
    private val file = File(dir, "update_prefs.json")
    private val json = Json { ignoreUnknownKeys = true }

    private fun load(): UpdatePrefsData =
        if (file.isFile) {
            runCatching { json.decodeFromString(UpdatePrefsData.serializer(), file.readText()) }
                .getOrDefault(UpdatePrefsData())
        } else {
            UpdatePrefsData()
        }

    private fun save(data: UpdatePrefsData) {
        dir.mkdirs()
        val tmp = File(dir, "update_prefs.json.tmp")
        tmp.writeText(json.encodeToString(UpdatePrefsData.serializer(), data))
        check(tmp.renameTo(file)) { "cannot persist update_prefs.json" }
    }

    fun lastCheckAt(): Long = load().lastCheckAt

    fun markChecked(now: Long) = save(load().copy(lastCheckAt = now))

    /** 上次启动看到的版本；null = 这版第一次跑（老用户升级上来也算——只记基线，不报"已更新"）。 */
    fun lastSeenVersion(): String? = load().lastSeenVersion

    fun markSeenVersion(version: String) = save(load().copy(lastSeenVersion = version))

    fun pendingUpdate(): PendingUpdate? = load().pending

    fun markPending(pending: PendingUpdate) = save(load().copy(pending = pending))

    fun clearPending() = save(load().copy(pending = null))
}

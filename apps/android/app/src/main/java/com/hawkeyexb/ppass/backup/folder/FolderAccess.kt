// #1762「素材文件夹」的 UI ↔ 引擎装配层：进程级单例 registry（引擎与设置页共用一份，互不覆盖写）、
// 二级页的读取与三项操作（添加 / 移除 / 重新授权）。全部在调用方的 IO 线程执行（UI 侧 withContext(IO)）。
// 变更后一律叫醒引擎（SCOPE_ADDED：人在场 + 对账），备份立刻跟上——不依赖下一次周期触发。
package com.hawkeyexb.ppass.backup.folder

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.hawkeyexb.ppass.backup.flow.SourceUnavailableException
import java.io.File

/** 二级页展示用的一条目录来源（[com.hawkeyexb.ppass.ui.FolderUi] 的装配侧形状）。 */
data class FolderEntry(val sourceId: String, val name: String, val needsPermission: Boolean)

object FolderAccess {

    @Volatile
    private var instance: FolderRegistry? = null

    /** 进程级单例：[AndroidFlowRuntime] 的引擎与设置页读写同一份（FolderRegistry 自带文件锁语义，但两个实例同时写互踩）。 */
    fun registry(context: Context): FolderRegistry =
        instance ?: synchronized(this) {
            instance ?: FolderRegistry(File(context.applicationContext.filesDir, "folder-registry.json"))
                .also { instance = it }
        }

    /** 二级页列表：名称 + 授权状态。状态按真实 SAF 可用性判（每个来源一层 query，不递归）。 */
    fun listEntries(context: Context): List<FolderEntry> {
        val app = context.applicationContext
        return registry(app).allRecords().map { record ->
            val tree = treeFor(app, record)
            val ok = try {
                tree.checkReadable()
                true
            } catch (_: SourceUnavailableException) {
                false
            } catch (_: Exception) {
                false
            }
            FolderEntry(record.id, record.displayName, needsPermission = !ok)
        }
    }

    /**
     * 添加：系统目录选择器返回的 URI → 取持久授权 → 登记。重复目录 / 登记失败不启用（不假装成功），
     * 释放刚取的授权并返回 null。成功后由调用方叫醒引擎（[changed]）。
     */
    fun addFolder(context: Context, uri: Uri): String? {
        val app = context.applicationContext
        val registry = registry(app)
        val treeUri = uri.toString()
        if (registry.hasTreeUri(treeUri)) return null
        takePersistable(app, uri)
        val displayName = try {
            SafFolderTree(app, uri).displayName()
        } catch (_: Exception) {
            null
        } ?: uri.lastPathSegment.orEmpty().ifEmpty { "folder" }
        return try {
            registry.addFolder(treeUri, displayName)
        } catch (failure: Exception) {
            releasePersistable(app, uri)
            null
        }
    }

    /** 移除：只停止后续备份，不删手机素材或桌面副本；持久授权一并释放（授权名额是稀缺系统资源）。
     * registry 落盘失败会抛（假移除会在重启后复活来源）：先撤销内存移除失败的可能，再放授权——
     * 顺序反过来（先放授权再登记失败）会把来源留在「已登记但失访」的卡死态。
     */
    fun removeFolder(context: Context, sourceId: String) {
        val app = context.applicationContext
        val record = registry(app).record(sourceId) ?: return
        try {
            registry(app).removeFolder(sourceId)
        } catch (failure: IllegalStateException) {
            com.hawkeyexb.ppass.log.PLog.w(TAG, "folder remove persist failed; source stays", failure)
            throw failure
        }
        releasePersistable(app, Uri.parse(record.treeUri))
    }

    private const val TAG = "PPassFolder"

    /**
     * 重新授权：新 URI 必须指向**同一个目录**（documentId 一致）——用户明确重选；选了别处不算重新授权。
     * 成功换上新 URI、恢复 registered；旧 URI 的授权释放。来源已移除返回 false。
     */
    fun reauthorize(context: Context, sourceId: String, newUri: Uri): Boolean {
        val app = context.applicationContext
        val registry = registry(app)
        val old = registry.record(sourceId) ?: return false
        val oldUri = Uri.parse(old.treeUri)
        // tree URI 只有 tree 段：用 getTreeDocumentId（getDocumentId 对它抛 IllegalArgumentException）。
        val sameDirectory = try {
            DocumentsContract.getTreeDocumentId(newUri) == DocumentsContract.getTreeDocumentId(oldUri)
        } catch (_: Exception) {
            false
        }
        if (!sameDirectory) return false
        takePersistable(app, newUri)
        if (!registry.reauthorize(sourceId, newUri.toString())) {
            // 失败回滚；同 URI 的重授权（newUri == 旧记录的 treeUri）不许释放——那正是旧授权本身。
            if (newUri.toString() != old.treeUri) releasePersistable(app, newUri)
            return false
        }
        // 用户重选同一目录时新 URI 就是旧 URI：release 会把刚 take 的授权放掉，重授权反而失访。
        if (newUri.toString() != old.treeUri) releasePersistable(app, oldUri)
        return true
    }

    /** 任一变更后调用：人在场 + 对账的触发，目录内容这轮就进待办（不依赖下一个周期）。 */
    fun changed(context: Context) {
        com.hawkeyexb.ppass.backup.flow.requestFlowScopeBackfillAndWake(context, constraintsSatisfied = true)
    }

    private fun treeFor(context: Context, record: FolderRecord): SafFolderTree =
        SafFolderTree(context, Uri.parse(record.treeUri))

    private fun takePersistable(context: Context, uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    private fun releasePersistable(context: Context, uri: Uri) {
        runCatching { context.contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
    }
}

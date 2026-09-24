// #413 §3：原图 → 手机侧 iroh store。引用优先，条件不满足回退复制；导入与供数分两步。
package com.hawkeyexb.ppass.backup.flow

import android.content.Context
import android.net.Uri
import java.io.FileNotFoundException

/**
 * [MediaImporter] 的实现。[open] 按 content URI 打开只读描述符（生产用 ContentResolver，见 [forContentResolver]），
 * 打不开 / 为 null 视为照片已不在 → [ImportResult.SourceMissing]。描述符只在导入这次调用里用：原生侧引用时
 * 按路径重开、复制时已读完，所以导入返回（或抛出）即关闭。
 *
 * `dataPath` 由调用方传入（MediaStore `_data`；API 29 或查不到时传 null，直接复制）。原生侧会校验它与描述符
 * 是同一个文件，不一致就复制——传错路径只会慢，不会传错数据。
 */
internal class AndroidMediaImporter(
    private val bridge: IrohBlobsProviderBridge,
    private val open: (String) -> AutoCloseable?,
    private val log: FlowLogger = FlowLogger {},
) : MediaImporter {

    override fun import(mediaId: Long, contentUri: String, dataPath: String?): ImportResult {
        val source = try {
            open(contentUri)
        } catch (_: FileNotFoundException) {
            null
        } catch (_: SourceMissingException) {
            null
        } ?: return ImportResult.SourceMissing
        val imported = source.use { bridge.importMedia(dataPath, it) }
        if (!imported.byReference) {
            // 回退是正确的，但多读写一遍整张图；原因要看得见（#413：引用不满足条件不许静默）。
            log.log("import media=$mediaId copied: fallback=${imported.fallback} ${imported.detail.orEmpty()}")
        }
        return ImportResult.Imported(imported.contentHash, imported.sizeBytes, imported.byReference)
    }

    /** 原图已删 / 已变 → [SourceMissingException]；这份内容没导入过或已 release → IllegalStateException。 */
    override fun serve(lease: ProviderLease): String = bridge.serve(lease)

    override fun release(contentHash: String) {
        try {
            bridge.release(contentHash)
        } catch (failure: Exception) {
            log.log("release $contentHash failed; ignoring: $failure")
        }
    }

    companion object {
        fun forContentResolver(context: Context, bridge: IrohBlobsProviderBridge, log: FlowLogger): AndroidMediaImporter {
            val resolver = context.applicationContext.contentResolver
            return AndroidMediaImporter(bridge, { uri -> resolver.openFileDescriptor(Uri.parse(uri), "r") }, log)
        }
    }
}

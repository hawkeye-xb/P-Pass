// #1762 [FolderTree] 的两个实现：生产走 SAF（DocumentsContract，零新依赖），JVM 单测走 java.io.File。
// 两者共用同一套类型口径（mimeByExtension / isMediaMime），测试与生产对「哪些文件算照片/视频」判等。
package com.hawkeyexb.ppass.backup.folder

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import com.hawkeyexb.ppass.backup.flow.SourceUnavailableException
import java.io.File
import java.io.InputStream

/** [FolderTree] 的 java.io.File 实现。JVM 单测与语义核对用；生产只走 [SafFolderTree]。 */
class FileFolderTree(private val root: File) : FolderTree {
    override fun enumerate(): List<FolderFile> {
        if (!root.isDirectory) throw SourceUnavailableException("folder root is not a directory: ${root.name}")
        val out = ArrayList<FolderFile>()
        walk(root, out)
        return out
    }

    override fun uriOf(relativePath: String): String? {
        requireRoot()
        return resolve(relativePath)?.takeIf { it.isFile }?.toURI()?.toString()
    }

    override fun stat(relativePath: String): FolderFile? {
        requireRoot()
        val file = resolve(relativePath)?.takeIf { it.isFile } ?: return null
        return FolderFile(
            relativePath = FolderPaths.normalize(relativePath) ?: return null,
            mimeType = mimeByExtension(file.name),
            sizeBytes = file.length(),
            modifiedAtMs = file.lastModified(),
        )
    }

    /** 相对路径 → 文件（导入用）。文件不在返回 null（源缺失）；根不可达抛 [SourceUnavailableException]。 */
    fun open(relativePath: String): File? {
        requireRoot()
        return resolve(relativePath)?.takeIf { it.isFile }
    }

    /** 根不可达 = 整个来源不可用（不许混成「单个文件没了」）。 */
    private fun requireRoot() {
        if (!root.isDirectory) throw SourceUnavailableException("folder root is not a directory: ${root.name}")
    }

    private fun resolve(relativePath: String): File? {
        val normalized = FolderPaths.normalize(relativePath) ?: return null
        var file = root
        for (part in normalized.split("/")) file = File(file, part)
        return file
    }

    private fun walk(dir: File, out: MutableList<FolderFile>) {
        val children = dir.listFiles() ?: throw SourceUnavailableException("cannot list directory: ${dir.name}")
        // 目录内按名字排（枚举顺序稳定，只影响日志与分配次序，不影响判等——判等按 mediaId）。
        for (child in children.sortedBy { it.name }) {
            // ADR §3：首版跳过 symlink，不解析、不跟随（目录同理）。
            // 注意：不能用 canonicalPath != absolutePath——路径**前缀**里有 symlink（macOS /var → /private/var、
            // 某些模拟器路径）时恒为真，会把整棵树误跳成空；只看最后一段本身是不是 symlink。
            if (runCatching { java.nio.file.Files.isSymbolicLink(child.toPath()) }.getOrDefault(false)) continue
            if (child.isDirectory) {
                walk(child, out)
            } else if (child.isFile) {
                out += FolderFile(
                    relativePath = child.toRelativeString(root).replace(File.separatorChar, '/'),
                    mimeType = mimeByExtension(child.name),
                    sizeBytes = child.length(),
                    modifiedAtMs = child.lastModified(),
                )
            }
        }
    }
}

/**
 * [FolderTree] 的 SAF 生产实现：树 URI → DocumentsContract 递归枚举。授权被撤销 / 根不可达时
 * ContentResolver 抛 [SecurityException]（或对坏树 URI 抛 IllegalArgumentException）——这里一律转成
 * [SourceUnavailableException]，不返回部分列表或空列表冒充「没有文件」。单个文件不在（文档 ID 查无）
 * 返回 null：那是源缺失，不是授权失效。
 */
class SafFolderTree(context: Context, private val treeUri: Uri) : FolderTree {
    private val resolver: ContentResolver = context.contentResolver

    override fun enumerate(): List<FolderFile> = try {
        val rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
        val rootTree = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDoc)
        val out = ArrayList<FolderFile>()
        walk(rootTree, "", out)
        out
    } catch (failure: SourceUnavailableException) {
        throw failure
    } catch (failure: Exception) {
        // SecurityException（授权被撤销）与其他读失败同样按「来源不可用」：枚举失败不是「没有文件」。
        throw SourceUnavailableException("enumerate failed: ${failure.javaClass.simpleName}", failure)
    }

    override fun uriOf(relativePath: String): String? = try {
        find(relativePath)?.toString()
    } catch (failure: SourceUnavailableException) {
        throw failure
    } catch (failure: Exception) {
        throw SourceUnavailableException("resolve failed: ${failure.javaClass.simpleName}", failure)
    }

    /** 单文档 query（O(路径深度)），不枚举整棵树。 */
    override fun stat(relativePath: String): FolderFile? = try {
        val doc = find(relativePath) ?: return null
        resolver.query(
            doc,
            arrayOf(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            ),
            null,
            null,
            null,
        )?.use { rows ->
            if (!rows.moveToFirst()) null else FolderFile(
                relativePath = FolderPaths.normalize(relativePath) ?: return@use null,
                mimeType = rows.getString(1) ?: MIME_UNKNOWN,
                sizeBytes = rows.getLong(2),
                modifiedAtMs = rows.getLong(3),
            )
        }
    } catch (failure: SourceUnavailableException) {
        throw failure
    } catch (failure: Exception) {
        throw SourceUnavailableException("stat failed: ${failure.javaClass.simpleName}", failure)
    }

    /** 相对路径 → SAF 文档 URI（导入时打开）。文件不在返回 null；授权失效抛 [SourceUnavailableException]。 */
    fun open(relativePath: String): Uri? = try {
        find(relativePath)
    } catch (failure: SourceUnavailableException) {
        throw failure
    } catch (failure: Exception) {
        throw SourceUnavailableException("resolve failed: ${failure.javaClass.simpleName}", failure)
    }

    /** 轻量可用性检查：查根目录一层子项。给二级页显示状态用，不递归。 */
    fun checkReadable() {
        try {
            val rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, rootDoc)
            resolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)
                ?.use { it.moveToFirst() }
                ?: throw SourceUnavailableException("tree children query returned null")
        } catch (failure: SourceUnavailableException) {
            throw failure
        } catch (failure: Exception) {
            throw SourceUnavailableException("tree unreadable: ${failure.javaClass.simpleName}", failure)
        }
    }

    /** 树 URI 的人类可读名（目录显示名）。拿不到时回退到 URI 最后一段。 */
    fun displayName(): String = try {
        val rootDoc = DocumentsContract.getTreeDocumentId(treeUri)
        val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootDoc)
        resolver.query(
            docUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    } catch (_: Exception) {
        null
    } ?: treeUri.lastPathSegment.orEmpty().ifEmpty { "folder" }

    private fun find(relativePath: String): Uri? {
        val normalized = FolderPaths.normalize(relativePath) ?: return null
        var docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))
        for (part in normalized.split("/")) {
            val child = childByName(docUri, part) ?: return null
            docUri = child
        }
        return docUri
    }

    private fun childByName(parentDoc: Uri, name: String): Uri? {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parentDoc),
        )
        resolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { rows ->
            while (rows.moveToNext()) {
                if (rows.getString(1) == name) {
                    return DocumentsContract.buildDocumentUriUsingTree(treeUri, rows.getString(0))
                }
            }
        }
        return null
    }

    private fun walk(dirDoc: Uri, prefix: String, out: MutableList<FolderFile>) {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(dirDoc),
        )
        val cursor = resolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS,
            ),
            null,
            null,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME + " ASC",
        ) ?: throw SourceUnavailableException("children query returned null")
        cursor.use { rows ->
            while (rows.moveToNext()) {
                val id = rows.getString(0)
                val name = rows.getString(1) ?: continue
                val mime = rows.getString(2) ?: MIME_UNKNOWN
                val size = rows.getLong(3)
                val modified = rows.getLong(4)
                val flags = rows.getLong(5)
                val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                val virtual = flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT.toLong() != 0L
                when {
                    virtual -> Unit // 虚拟文档没有稳定字节，跳过
                    mime == MIME_DIR -> walk(childUri, "$prefix$name/", out)
                    else -> out += FolderFile(
                        relativePath = "$prefix$name",
                        mimeType = mime,
                        sizeBytes = size,
                        modifiedAtMs = modified,
                    )
                }
            }
        }
    }

    companion object {
        /** 打开相对路径文件的流（[FolderImporter] 用）。文件不在返回 null；授权失效抛 [SourceUnavailableException]。 */
        fun openStream(context: Context, treeUri: Uri, relativePath: String): InputStream? {
            val tree = SafFolderTree(context, treeUri)
            val doc = tree.open(relativePath) ?: return null
            return try {
                context.contentResolver.openInputStream(doc)
                    ?: throw SourceUnavailableException("openInputStream returned null")
            } catch (failure: SecurityException) {
                throw SourceUnavailableException("permission revoked: ${failure.javaClass.simpleName}", failure)
            } catch (failure: java.io.IOException) {
                throw SourceUnavailableException("open failed: ${failure.javaClass.simpleName}", failure)
            }
        }
    }
}

/** DocumentsContract 的目录 MIME 常量（DocumentsContract.Document.MIME_TYPE_DIR）。 */
private const val MIME_DIR = DocumentsContract.Document.MIME_TYPE_DIR
private const val MIME_UNKNOWN = "application/octet-stream"

/** 已知的照片 / 视频扩展名 → MIME（[FileFolderTree] 用；JVM 没有 probeContentType 的稳定保证）。 */
private val EXT_MIME = mapOf(
    "jpg" to "image/jpeg", "jpeg" to "image/jpeg", "png" to "image/png", "gif" to "image/gif",
    "webp" to "image/webp", "bmp" to "image/bmp", "heic" to "image/heic", "heif" to "image/heif",
    "avif" to "image/avif", "dng" to "image/x-adobe-dng", "tiff" to "image/tiff", "tif" to "image/tiff",
    "mp4" to "video/mp4", "mov" to "video/quicktime", "m4v" to "video/x-m4v", "webm" to "video/webm",
    "mkv" to "video/x-matroska", "3gp" to "video/3gpp", "3gpp" to "video/3gpp", "avi" to "video/x-msvideo",
    "mts" to "video/mp2t", "m2ts" to "video/mp2t",
)

internal fun mimeByExtension(name: String): String =
    EXT_MIME[name.substringAfterLast('.', "").lowercase()] ?: MIME_UNKNOWN

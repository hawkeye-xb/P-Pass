package com.hawkeyexb.ppass.ui

import android.content.Intent
import android.net.Uri

/** 单次备份的系统文件选择：只返回用户本次选中的 URI，不授予目录或自动备份范围。 */
object SingleTransferFilePicker {
    fun intent(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }

    /**
     * SAF 的多选结果装在 clipData 里（每项一个 URI），单选落在 data；
     * 取消或空结果返回空表，上层据此不登记任何任务。
     */
    fun urisFromResult(intent: Intent?): List<Uri> {
        if (intent == null) return emptyList()
        val clip = intent.clipData ?: return listOfNotNull(intent.data)
        return buildList {
            for (index in 0 until clip.itemCount) clip.getItemAt(index)?.uri?.let(::add)
        }.ifEmpty { listOfNotNull(intent.data) }
    }
}

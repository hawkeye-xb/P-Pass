package com.hawkeyexb.ppass.ui

import android.content.Intent

/** 单次备份的系统文件选择：只返回用户本次选中的 URI，不授予目录或自动备份范围。 */
object SingleTransferFilePicker {
    fun intent(): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }
}

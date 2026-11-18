package com.hawkeyexb.ppass.ui

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.log.PLog
import com.hawkeyexb.ppass.backup.flow.TriggerReason
import com.hawkeyexb.ppass.backup.flow.requestFlowWake
import com.hawkeyexb.ppass.backup.picked.PickedUploads
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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

/**
 * #1798 单次备份的文件选择入口。Material 3 Button（触控区、涟漪、role=Button 由组件给出），
 * 点击唤起 [SingleTransferFilePicker.intent] 的系统文件选择；结果原样进既有 Picked 队列
 * （[PickedUploads.enqueue]，登记与去重沿用现有链路），再以 PICKED_ADDED 唤醒传输循环。
 * 取消（resultCode 不是 RESULT_OK 或 data 为空）不建任务。
 */
@Composable
fun SingleTransferPickEntry(
    label: String = stringResource(R.string.pick_files_label),
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    onPicked: (count: Int) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result: ActivityResult ->
        // 取消不建任务：非 RESULT_OK（取消/返回）一律按空处理。
        val picked = if (result.resultCode == Activity.RESULT_OK) SingleTransferFilePicker.urisFromResult(result.data) else emptyList()
        if (picked.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            val count = withContext(Dispatchers.IO) {
                runCatching { PickedUploads.enqueue(context, picked) }
                    .onFailure { PLog.w("PPassFlow", "picked enqueue failed", it) }
                    .getOrDefault(0)
            }
            if (count > 0) {
                requestFlowWake(context, TriggerReason.PICKED_ADDED)
                onPicked(count)
            }
        }
    }
    Button(
        onClick = { launcher.launch(SingleTransferFilePicker.intent()) },
        enabled = enabled,
        modifier = modifier.fillMaxWidth(),
        colors = ButtonDefaults.buttonColors(containerColor = PPColor.Ink, contentColor = PPColor.Paper),
    ) {
        Text(label)
    }
}

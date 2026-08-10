// REL-02: 更新通道（stable 默认 / test）——显式切换，默认永远 stable。
// stable = GitHub latest（只认已发布的正式 release，人工 publish 即发布
// 动作）；test = 最新 prerelease（CI 出 test tag 全绿后自动 publish）。
package com.hawkeyexb.ppass.update

import android.content.Context

/** 更新通道。stable 默认；切换必须显式（设置页），绝不自动回退。 */
enum class UpdateChannel(val id: String) {
    Stable("stable"),
    Test("test"),
    ;

    companion object {
        fun fromId(id: String?): UpdateChannel =
            entries.firstOrNull { it.id == id } ?: Stable
    }
}

class UpdateChannelStore(context: Context) {
    private val prefs =
        context.getSharedPreferences("update_channel", Context.MODE_PRIVATE)

    fun load(): UpdateChannel = UpdateChannel.fromId(prefs.getString("channel", null))

    fun save(channel: UpdateChannel) {
        prefs.edit().putString("channel", channel.id).apply()
    }
}

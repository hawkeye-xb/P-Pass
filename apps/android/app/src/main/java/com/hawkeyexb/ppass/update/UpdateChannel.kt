// REL-02: 更新通道（stable / test）。
// DESK-02①: 通道不再由用户切换——构建期 PPF_BUILD_VERSION 注入版本串，
// channelFromVersion() 推导（含 `-test.` → test，否则 stable）。零 UI、
// 零持久化；UpdateChannelStore 已随设置页通道行一并删除。
package com.hawkeyexb.ppass.update

/** 更新通道。正式构建永远 stable（家人设备不被 test 构建波及）。 */
enum class UpdateChannel(val id: String) {
    Stable("stable"),
    Test("test"),
    ;

    companion object {
        fun fromId(id: String?): UpdateChannel =
            entries.firstOrNull { it.id == id } ?: Stable
    }
}

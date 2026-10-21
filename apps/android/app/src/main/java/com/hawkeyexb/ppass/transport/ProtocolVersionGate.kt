// #1072: the latest version verdict from the desktop, process-wide. DaemonClient feeds it every reply
// (so pairing, the backup probe, the foreground heartbeat and any other call all count); the home
// screen shows a full-screen "update" prompt while it is set. In memory only: after a restart the
// first reply (the heartbeat's hello) sets it again.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.proto.Resp
import com.hawkeyexb.ppass.proto.outdatedSide
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object ProtocolVersionGate {
    private val _outdated = MutableStateFlow<OutdatedSide?>(null)

    /** null = the last reply was from a compatible desktop (or nothing has been heard yet). */
    val outdated: StateFlow<OutdatedSide?> get() = _outdated

    /** Any reply decides it: a compatible one clears the prompt, an incompatible one sets it. */
    fun observe(reply: Resp) {
        _outdated.value = reply.outdatedSide()
    }
}

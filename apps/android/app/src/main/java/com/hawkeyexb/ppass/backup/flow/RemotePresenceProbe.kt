// ARCH-08: validate one bounded, read-only Desktop presence page.
package com.hawkeyexb.ppass.backup.flow

import com.hawkeyexb.ppass.proto.BackupPresenceQuery
import com.hawkeyexb.ppass.proto.BackupMissing
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.ProtoJson
import com.hawkeyexb.ppass.transport.DaemonClient
import com.hawkeyexb.ppass.transport.PeerAddrParts
import kotlinx.serialization.json.encodeToJsonElement

const val REMOTE_PRESENCE_PAGE_SIZE = 500

internal fun presenceQueryFor(hashes: List<String>): BackupPresenceQuery {
    require(hashes.isNotEmpty()) { "presence page must not be empty" }
    require(hashes.size <= REMOTE_PRESENCE_PAGE_SIZE) { "presence page exceeds $REMOTE_PRESENCE_PAGE_SIZE hashes" }
    require(hashes.all(::isBlake3Hex)) { "presence page contains an invalid hash" }
    return BackupPresenceQuery(hashes)
}

class RemotePresenceProbe(private val client: DaemonClient) {
    suspend fun missing(peer: PeerAddrParts, hashes: List<String>): Set<String> {
        val query = presenceQueryFor(hashes)
        val response = client.call(
            peer,
            Methods.BACKUP_PRESENCE,
            ProtoJson.encodeToJsonElement(BackupPresenceQuery.serializer(), query),
        )
        check(response.ok) { "backup.presence rejected: ${response.error?.msgKey}" }
        return ProtoJson.decodeFromJsonElement(BackupMissing.serializer(), response.result!!).hashes.toSet()
    }
}

private fun isBlake3Hex(hash: String): Boolean =
    hash.length == 64 && hash.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }

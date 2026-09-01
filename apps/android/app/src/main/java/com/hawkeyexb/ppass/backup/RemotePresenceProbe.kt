// ARCH-08: validate one bounded, read-only Desktop presence page.
package com.hawkeyexb.ppass.backup

import com.hawkeyexb.ppass.proto.BackupPresenceQuery

const val REMOTE_PRESENCE_PAGE_SIZE = 500

internal fun presenceQueryFor(hashes: List<String>): BackupPresenceQuery {
    require(hashes.isNotEmpty()) { "presence page must not be empty" }
    require(hashes.size <= REMOTE_PRESENCE_PAGE_SIZE) { "presence page exceeds $REMOTE_PRESENCE_PAGE_SIZE hashes" }
    require(hashes.all(::isBlake3Hex)) { "presence page contains an invalid hash" }
    return BackupPresenceQuery(hashes)
}

private fun isBlake3Hex(hash: String): Boolean =
    hash.length == 64 && hash.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }

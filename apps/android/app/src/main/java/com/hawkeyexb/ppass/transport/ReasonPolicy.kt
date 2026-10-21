// #1072: what the phone does about each desktop `reason` — the one table every channel reads.
// Decided on the reason alone, never on text. Exhaustive over [Reason] with no `else`: a reason added
// to the registry (and mirrored in Proto.kt) does not compile until it is placed here.
// iOS mirrors this table (#1073); ReasonPolicyTest pins it row by row.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Reason

enum class ReasonClass {
    /** The desktop no longer accepts this pairing: red card + notice, wait for the user to re-pair. */
    PAIRING_LOST,
    /** The two versions cannot talk: stop, count nothing, keep the pairing, say which side to update. */
    OUTDATED,
    /** Desktop-side storage problems: stop the loop, count nothing, show the cause. */
    STORAGE_FULL,
    LIBRARY_UNAVAILABLE,
    STORAGE_FAILED,
    /** The path did not carry the item: stays resumable, counts nothing. */
    PATH,
    /** Anything else (incl. a reason this build does not know): one item failed on a delivery
     *  channel (counted, bounded), unreachable on a `hello`. */
    OTHER,
}

fun reasonClassOf(reason: Reason): ReasonClass = when (reason) {
    // epoch_mismatch / role_forbidden: the desktop's `err.not_authorized` before v2 — kept (#1072 sign-off).
    Reason.NOT_PAIRED, Reason.REVOKED, Reason.EPOCH_MISMATCH, Reason.ROLE_FORBIDDEN -> ReasonClass.PAIRING_LOST
    Reason.PHONE_OUTDATED, Reason.DESKTOP_OUTDATED -> ReasonClass.OUTDATED
    Reason.STORAGE_FULL -> ReasonClass.STORAGE_FULL
    Reason.LIBRARY_UNAVAILABLE -> ReasonClass.LIBRARY_UNAVAILABLE
    Reason.STORAGE_FAILED -> ReasonClass.STORAGE_FAILED
    Reason.FETCH_FAILED -> ReasonClass.PATH
    // grant_not_found / grant_conflict: one photo's grant is out of step, the pairing is fine (#1072 sign-off).
    Reason.GRANT_NOT_FOUND, Reason.GRANT_CONFLICT, Reason.CANCELLED,
    Reason.PAIR_TOKEN_INVALID, Reason.UNSUPPORTED_METHOD, Reason.BAD_REQUEST, Reason.NOT_FOUND,
    Reason.INTERNAL, Reason.BACKUP_FAILED, Reason.UNKNOWN,
    -> ReasonClass.OTHER
}

fun isPairingLost(reason: Reason): Boolean = reasonClassOf(reason) == ReasonClass.PAIRING_LOST

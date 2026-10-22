// #1072: what the phone does about each desktop `reason` — the one table every delivery channel reads
// (offer / status rejections and `flow.failed` pushes alike). Decided on the reason alone, never on
// text. Exhaustive over [Reason] with no `else`: a reason added to the registry (and mirrored in
// Proto.kt) does not compile until it is placed here.
// Principle (#1069 sign-off): classify by where the problem is and who can fix it. Everything that
// should not happen (a phone bug, records out of step, a reason this build does not know) takes the
// ordinary one-item-failed path: skip this photo, carry on with the round, count it (bounded), let
// reconciliation retry (#1072 final). iOS mirrors this table (#1073); ReasonPolicyTest pins it.
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Reason

enum class ReasonClass {
    /** The desktop no longer accepts this pairing: red card + notice, wait for the user to re-pair. */
    PAIRING_LOST,
    /** P-Pass on one side is too old for the other: stop, count nothing, keep the pairing, say which. */
    OUTDATED,
    /** Desktop-side problems: stop the round, count nothing, show the cause, retry later. */
    STORAGE_FULL,
    LIBRARY_UNAVAILABLE,
    STORAGE_FAILED,
    DESKTOP_INTERNAL,
    /** The path did not carry the item: stays resumable, counts nothing. */
    PATH,
    /** Should not happen — a request the desktop could not use, the two sides' records of this one
     *  item out of step, or a reason this build does not know: one item failed. Skip it, carry on
     *  with the round, count an attempt (MAX_FAILURES), reconciliation retries it; logged with its
     *  reason and queue sequence. */
    ITEM_FAILED,
}

fun reasonClassOf(reason: Reason): ReasonClass = when (reason) {
    Reason.NOT_PAIRED, Reason.PAIRING_MISMATCH, Reason.ROLE_FORBIDDEN -> ReasonClass.PAIRING_LOST
    // unsupported_method: the desktop does not know a method this phone relies on — it is too old.
    Reason.PHONE_OUTDATED, Reason.DESKTOP_OUTDATED, Reason.UNSUPPORTED_METHOD -> ReasonClass.OUTDATED
    Reason.STORAGE_FULL -> ReasonClass.STORAGE_FULL
    Reason.LIBRARY_UNAVAILABLE -> ReasonClass.LIBRARY_UNAVAILABLE
    Reason.STORAGE_FAILED -> ReasonClass.STORAGE_FAILED
    Reason.INTERNAL -> ReasonClass.DESKTOP_INTERNAL
    Reason.FETCH_FAILED -> ReasonClass.PATH
    Reason.BAD_REQUEST, Reason.NOT_FOUND, Reason.BACKUP_FAILED, Reason.CANCELLED,
    Reason.PAIR_TOKEN_INVALID, Reason.GRANT_NOT_FOUND, Reason.GRANT_CONFLICT, Reason.UNKNOWN,
    -> ReasonClass.ITEM_FAILED
}

fun isPairingLost(reason: Reason): Boolean = reasonClassOf(reason) == ReasonClass.PAIRING_LOST

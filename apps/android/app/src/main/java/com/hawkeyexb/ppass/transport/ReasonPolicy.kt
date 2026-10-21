// #1072: what the phone does about each desktop `reason` — the one table every delivery channel reads
// (offer / status rejections and `flow.failed` pushes alike). Decided on the reason alone, never on
// text. Exhaustive over [Reason] with no `else`: a reason added to the registry (and mirrored in
// Proto.kt) does not compile until it is placed here.
// Principle (#1069 sign-off): classify by where the problem is and who can fix it. Only a problem
// with the photo itself counts against the photo. iOS mirrors this table (#1073); ReasonPolicyTest
// pins it row by row.
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
    /** The two sides' records of this one item disagree. Handling pending sign-off (#1072); until
     *  then it keeps the pre-v2 behaviour: a rejection was `err.not_authorized` (pairing lost), a
     *  push was `guard_mismatch` (one item failed). The only class that still depends on the channel. */
    GRANT_OUT_OF_STEP,
    /** The phone sent something the desktop could not use (a phone bug), or a reason this build does
     *  not know: not the photo's fault — stop the round, back off, count nothing, log it. */
    PHONE_ERROR,
}

fun reasonClassOf(reason: Reason): ReasonClass = when (reason) {
    Reason.NOT_PAIRED, Reason.REVOKED, Reason.EPOCH_MISMATCH, Reason.ROLE_FORBIDDEN -> ReasonClass.PAIRING_LOST
    // unsupported_method: the desktop does not know a method this phone relies on — it is too old.
    Reason.PHONE_OUTDATED, Reason.DESKTOP_OUTDATED, Reason.UNSUPPORTED_METHOD -> ReasonClass.OUTDATED
    Reason.STORAGE_FULL -> ReasonClass.STORAGE_FULL
    Reason.LIBRARY_UNAVAILABLE -> ReasonClass.LIBRARY_UNAVAILABLE
    Reason.STORAGE_FAILED -> ReasonClass.STORAGE_FAILED
    Reason.INTERNAL -> ReasonClass.DESKTOP_INTERNAL
    Reason.FETCH_FAILED -> ReasonClass.PATH
    Reason.GRANT_NOT_FOUND, Reason.GRANT_CONFLICT -> ReasonClass.GRANT_OUT_OF_STEP
    // bad_request: the wire cannot yet tell "ticket names different content" (the photo's problem)
    // from "malformed request" (a phone bug) — both are bad_request today. Reported on #1072.
    Reason.BAD_REQUEST, Reason.NOT_FOUND, Reason.BACKUP_FAILED, Reason.CANCELLED,
    Reason.PAIR_TOKEN_INVALID, Reason.UNKNOWN,
    -> ReasonClass.PHONE_ERROR
}

fun isPairingLost(reason: Reason): Boolean = reasonClassOf(reason) == ReasonClass.PAIRING_LOST

// #1072: phone-side wording for the protocol outcomes — the desktop sends a reason, the phone picks
// the words. Pure mappings so the choice is testable without Compose.
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.transport.PairRefusal

/**
 * The title of a pairing that ended without joining (10-29 copy B6 / C10): only the owner's "decline"
 * is "the computer declined"; an expired QR code says so in the title; everything else "couldn't join".
 */
internal fun pairRefusalTitleRes(cause: PairRefusal): Int = when (cause) {
    PairRefusal.DENIED -> R.string.pair_refused_title
    PairRefusal.QR_EXPIRED -> R.string.pair_qr_expired_title
    else -> R.string.pair_lapsed_title
}

/**
 * The body of a pairing that ended without joining: the reason line, which carries its own way out
 * (10-29 copy B5). Null when the owner declined on the computer: the title says it all (B5), and an
 * empty line would still take up a row.
 */
internal fun pairRefusalDetailRes(cause: PairRefusal): Int? = when (cause) {
    PairRefusal.TOKEN_INVALID -> R.string.pair_refused_detail_token_invalid
    PairRefusal.DENIED -> null
    PairRefusal.EXPIRED -> R.string.pair_refused_detail_expired
    PairRefusal.DESKTOP_RESTARTED -> R.string.pair_refused_detail_restarted
    PairRefusal.CODE_WRONG -> R.string.pair_refused_detail_code_wrong
    PairRefusal.PROOF_FAILED -> R.string.pair_desktop_proof_failed
    PairRefusal.QR_EXPIRED -> R.string.pair_qr_expired_body
    PairRefusal.OTHER -> R.string.error_generic
}

/**
 * 10-29 copy B13: the small "error code" line under a pairing refusal. Only the generic body gets one;
 * the code is the body's key without its prefix (same rule as the desktop's `ui.err_code`).
 */
internal fun pairRefusalErrorCode(cause: PairRefusal): String? =
    if (cause == PairRefusal.OTHER) "generic" else null

/**
 * #1069 sign-off: it is the P-Pass app that is out of date, not the device. One sentence per side,
 * used on the home status card and as the pairing result's body.
 */
internal fun outdatedTextRes(side: OutdatedSide): Int = when (side) {
    OutdatedSide.PHONE -> R.string.state_waiting_phone_outdated
    OutdatedSide.DESKTOP -> R.string.state_waiting_desktop_outdated
}

/** Only an outdated phone app can be fixed from here: offer the in-app update check. */
internal fun offersAppUpdate(side: OutdatedSide): Boolean = side == OutdatedSide.PHONE

/**
 * The home status card's version line: shown whenever the last reply said the versions are
 * incompatible (any channel, see ProtocolVersionGate), in place of the waiting/idle line — no dialog,
 * no full-screen block. Same gates as the waiting line: hidden behind the media-access card and
 * when the pairing is lost (the red card is the way out then).
 */
internal fun visibleOutdatedSide(outdated: OutdatedSide?, mediaAccess: MediaAccess, pairingLost: Boolean): OutdatedSide? =
    outdated?.takeIf { mediaAccess == MediaAccess.FULL && !pairingLost }

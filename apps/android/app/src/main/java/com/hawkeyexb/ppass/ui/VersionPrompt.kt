// #1072: phone-side wording for the protocol outcomes — the desktop sends a reason, the phone picks
// the words. Pure mappings so the choice is testable without Compose.
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.transport.PairRefusal

/** The detail line under a pairing that ended without joining. */
internal fun pairRefusalDetailRes(cause: PairRefusal): Int = when (cause) {
    PairRefusal.TOKEN_INVALID -> R.string.pair_refused_detail_token_invalid
    PairRefusal.DENIED -> R.string.pair_refused_detail_denied
    PairRefusal.EXPIRED -> R.string.pair_refused_detail_expired
    PairRefusal.DESKTOP_RESTARTED -> R.string.pair_refused_detail_restarted
    PairRefusal.CODE_WRONG -> R.string.pair_refused_detail_code_wrong
    PairRefusal.PROOF_FAILED -> R.string.pair_desktop_proof_failed
    PairRefusal.OTHER -> R.string.error_generic
}

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

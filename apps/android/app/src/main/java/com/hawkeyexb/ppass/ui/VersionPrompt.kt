// #1072: phone-side wording for the protocol outcomes — the desktop sends a reason, the phone picks
// the words. Pure resource mappings so the choice is testable without Compose.
package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.transport.PairRefusal

/** The detail line under a pairing that ended without joining. */
internal fun pairRefusalDetailRes(cause: PairRefusal): Int = when (cause) {
    PairRefusal.TOKEN_INVALID -> R.string.pair_refused_detail_token_invalid
    PairRefusal.DENIED -> R.string.pair_refused_detail_denied
    PairRefusal.EXPIRED -> R.string.pair_refused_detail_expired
    PairRefusal.DESKTOP_RESTARTED -> R.string.pair_refused_detail_restarted
    PairRefusal.OTHER -> R.string.error_generic
}

internal fun updateNeededTitleRes(side: OutdatedSide): Int = when (side) {
    OutdatedSide.PHONE -> R.string.update_needed_phone_title
    OutdatedSide.DESKTOP -> R.string.update_needed_desktop_title
}

/** Full-screen prompt on the home screen (already paired: pairing and photos are kept). */
internal fun updateNeededBodyRes(side: OutdatedSide): Int = when (side) {
    OutdatedSide.PHONE -> R.string.update_needed_phone_body
    OutdatedSide.DESKTOP -> R.string.update_needed_desktop_body
}

/** The pairing screen's version of the prompt (nothing paired yet). */
internal fun pairNeedsUpdateBodyRes(side: OutdatedSide): Int = when (side) {
    OutdatedSide.PHONE -> R.string.pair_needs_update_phone_body
    OutdatedSide.DESKTOP -> R.string.pair_needs_update_desktop_body
}

/** Only an outdated phone can be fixed from here: offer the in-app update check. */
internal fun offersAppUpdate(side: OutdatedSide): Boolean = side == OutdatedSide.PHONE

package com.hawkeyexb.ppass.ui

import com.hawkeyexb.ppass.R
import com.hawkeyexb.ppass.backup.MediaAccess
import com.hawkeyexb.ppass.proto.OutdatedSide
import com.hawkeyexb.ppass.transport.PairRefusal

internal fun pairRefusalTitleRes(cause: PairRefusal): Int = when (cause) {
    PairRefusal.DENIED -> R.string.pair_refused_title
    PairRefusal.QR_EXPIRED -> R.string.pair_qr_expired_title
    else -> R.string.pair_lapsed_title
}

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

internal fun pairRefusalErrorCode(cause: PairRefusal): String? =
    if (cause == PairRefusal.OTHER) "generic" else null

internal fun outdatedTextRes(side: OutdatedSide): Int = when (side) {
    OutdatedSide.PHONE -> R.string.state_waiting_phone_outdated
    OutdatedSide.DESKTOP -> R.string.state_waiting_desktop_outdated
}

internal fun offersAppUpdate(side: OutdatedSide): Boolean = side == OutdatedSide.PHONE

internal fun visibleOutdatedSide(outdated: OutdatedSide?, mediaAccess: MediaAccess, pairingLost: Boolean): OutdatedSide? =
    outdated?.takeIf { mediaAccess == MediaAccess.FULL && !pairingLost }

// #1072: the phone's half of protocol v2 version negotiation (crates/proto version.rs `compatibility`,
// Role::Phone). The desktop already refuses an outdated phone; this covers the other direction — a
// pre-v2 desktop answers without `ver`, so only the phone can tell.
package com.hawkeyexb.ppass.proto

/** Which device has to be updated before the two can talk again. */
enum class OutdatedSide { PHONE, DESKTOP }

/** Mirror of `proto::compatibility(LOCAL, peer, Role::Phone)`: null = compatible. */
fun outdatedSideOf(peerVer: Int, peerMinVer: Int): OutdatedSide? = when {
    peerVer < MIN_SUPPORTED_VER -> OutdatedSide.DESKTOP
    PROTO_VER < peerMinVer -> OutdatedSide.PHONE
    else -> null
}

/** Thrown where a caller needs to unwind on an incompatible reply (it is never a lost pairing). */
class ProtocolOutdatedException(val side: OutdatedSide) : IllegalStateException("protocol version mismatch: $side outdated")

/**
 * `phone_outdated` / `desktop_outdated` → the side; `unsupported_method` (the desktop does not know a
 * method this phone relies on) → the desktop (#1069 sign-off); any other reason → null.
 */
fun outdatedSideOf(reason: Reason): OutdatedSide? = when (reason) {
    Reason.PHONE_OUTDATED -> OutdatedSide.PHONE
    Reason.DESKTOP_OUTDATED, Reason.UNSUPPORTED_METHOD -> OutdatedSide.DESKTOP
    else -> null
}

/** The side this reply says is outdated: the desktop's own verdict first, then the phone's check. */
fun Resp.outdatedSide(): OutdatedSide? =
    error?.let { outdatedSideOf(it.reasonKind) } ?: outdatedSideOf(ver, minVer)

/**
 * Every reply from the desktop passes through here (DaemonClient), so an incompatible desktop
 * looks the same to every caller whether it said so itself or is too old to know: a rejection
 * with `VERSION_MISMATCH` + the side's reason. A compatible reply is returned unchanged.
 */
fun Resp.versionChecked(): Resp {
    val side = outdatedSide() ?: return this
    if (!ok && error != null && outdatedSideOf(error.reasonKind) != null) return this
    val reason = if (side == OutdatedSide.PHONE) Reason.PHONE_OUTDATED else Reason.DESKTOP_OUTDATED
    return copy(ok = false, result = null, error = RespError(code = Codes.VERSION_MISMATCH, reason = reason.wire))
}

// The daemon's PeerAddr token — the `a=` parameter of a pairing QR and
// the `provider` field of a backup manifest: base64url (no padding) over
// JSON {"id": <64-hex>, "addrs": [{"Relay": url} | {"Ip": "host:port"}]}.
// Mirror of transport::PeerAddr's Display/FromStr (iroh_impl.rs).
package com.hawkeyexb.ppass.transport

import android.util.Base64 as AndroidBase64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

data class PeerAddrParts(
    /** EndpointId as 64 hex chars. */
    val idHex: String,
    /** First relay URL, if any (iroh-ffi EndpointAddr takes one). */
    val relayUrl: String?,
    /** Direct socket addresses, "host:port" strings. */
    val directAddresses: List<String>,
)

/** JVM-friendly base64url decode (java.util.Base64 exists on Android 26+). */
private fun b64UrlDecode(s: String): ByteArray =
    try {
        java.util.Base64.getUrlDecoder().decode(s.trimEnd('='))
    } catch (_: Throwable) {
        AndroidBase64.decode(s, AndroidBase64.URL_SAFE or AndroidBase64.NO_PADDING)
    }

fun parsePeerAddrToken(token: String): PeerAddrParts {
    val json = Json.parseToJsonElement(String(b64UrlDecode(token.trim()), Charsets.UTF_8))
    val obj = json.jsonObject
    val id = obj["id"]!!.jsonPrimitive.content
    require(id.length == 64) { "PeerAddr id must be 64 hex chars, got ${id.length}" }

    var relay: String? = null
    val direct = mutableListOf<String>()
    for (addr in obj["addrs"]?.jsonArray ?: emptyList()) {
        val entry = addr.jsonObject
        entry["Relay"]?.let { if (relay == null) relay = it.jsonPrimitive.content }
        entry["Ip"]?.let { direct.add(it.jsonPrimitive.content) }
    }
    return PeerAddrParts(id, relay, direct)
}

/** Extract node id and address token from a `ppf://pair?...` QR string. */
data class PairingQr(val nodeIdHex: String, val token: String, val addr: PeerAddrParts?)

fun parsePairingQr(qr: String): PairingQr {
    require(qr.startsWith("ppf://pair?")) { "not a P-Pass pairing code" }
    val params = qr.substringAfter('?').split('&').associate {
        val (k, v) = it.split('=', limit = 2)
        k to v
    }
    val node = params["node"] ?: error("pairing code missing node id")
    val token = params["t"] ?: error("pairing code missing token")
    val addr = params["a"]?.let { parsePeerAddrToken(it) }
    return PairingQr(node, token, addr)
}

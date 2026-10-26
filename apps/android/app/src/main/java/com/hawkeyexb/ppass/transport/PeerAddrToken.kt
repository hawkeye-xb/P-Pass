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
    /** First relay URL, if any. */
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

private fun b64UrlEncode(bytes: ByteArray): String =
    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

/**
 * #1124: the inverse of [parsePeerAddrToken] — the PeerAddr token the shared Rust core
 * (`CtrlClient`) dials. Same JSON shape as transport::PeerAddr's Display.
 */
fun PeerAddrParts.toToken(): String {
    val json = kotlinx.serialization.json.buildJsonObject {
        put("id", kotlinx.serialization.json.JsonPrimitive(idHex))
        put(
            "addrs",
            kotlinx.serialization.json.buildJsonArray {
                relayUrl?.let { add(kotlinx.serialization.json.buildJsonObject { put("Relay", kotlinx.serialization.json.JsonPrimitive(it)) }) }
                for (a in directAddresses) add(kotlinx.serialization.json.buildJsonObject { put("Ip", kotlinx.serialization.json.JsonPrimitive(a)) })
            },
        )
    }
    return b64UrlEncode(json.toString().toByteArray(Charsets.UTF_8))
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

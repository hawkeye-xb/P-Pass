// Device identity + pairing state, persisted in the app's sandboxed
// files dir. The 32-byte secret IS the device: pairing authorization
// binds to the NodeId derived from it. Android-Keystore encryption of
// the key file is a hardening card (M3) — the app sandbox guards it
// for the MVP, same trust level as the daemon's ipc.token.
package com.hawkeyexb.ppass.transport

import java.io.File
import java.security.SecureRandom
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

class IdentityStore(private val dir: File) {
    private val keyFile = File(dir, "identity.key")

    /** Load the persistent secret, minting one on first run. */
    fun secretKey(): ByteArray {
        if (keyFile.isFile) {
            val k = keyFile.readBytes()
            require(k.size == 32) { "corrupt identity.key (${k.size} bytes)" }
            return k
        }
        val k = ByteArray(32).also { SecureRandom().nextBytes(it) }
        dir.mkdirs()
        // Write-then-rename so a crash never leaves a half-written key.
        val tmp = File(dir, "identity.key.tmp")
        tmp.writeBytes(k)
        check(tmp.renameTo(keyFile)) { "cannot persist identity.key" }
        return k
    }
}

@Serializable
data class Pairing(
    /** Storage daemon's NodeId (64 hex). */
    val daemonNodeId: String,
    /** Its last known PeerAddr token (redialable without discovery). */
    val daemonAddrToken: String,
    /** Human name shown in the UI („P-Pass 存储端“…). */
    val storageDeviceName: String,
    /** M11（全页面状态稿）"配对日期"用——本地时间戳，配对成功时打上；
     *  0 = 未知（老版本升级上来的存量 pairing，字段不存在，`ignoreUnknownKeys`
     *  兜底出默认值，不倒推瞎编一个日期）。 */
    val pairedAt: Long = 0L,
    /** Owner-approved pairing generation for Flow delivery. Empty means this
     * legacy pairing must be renewed before it can authorize a Flow item. */
    val pairingEpoch: String = "",
)

class PairingStore(private val dir: File) {
    private val file = File(dir, "pairing.json")
    private val json = Json { ignoreUnknownKeys = true }

    fun load(): Pairing? =
        if (file.isFile) runCatching {
            json.decodeFromString(Pairing.serializer(), file.readText())
        }.getOrNull() else null

    fun save(p: Pairing) {
        dir.mkdirs()
        val tmp = File(dir, "pairing.json.tmp")
        tmp.writeText(json.encodeToString(Pairing.serializer(), p))
        check(tmp.renameTo(file)) { "cannot persist pairing.json" }
    }

    fun clear() {
        file.delete()
    }
}

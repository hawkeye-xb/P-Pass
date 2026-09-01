// T-052: the pairing conversation, camera-free — the scanner hands us a
// QR string; this turns it into a saved Pairing or a human-readable
// failure. The pair.request response blocks until the owner clicks
// Allow on the computer (or the daemon times the request out).
package com.hawkeyexb.ppass.transport

import com.hawkeyexb.ppass.proto.Hello
import com.hawkeyexb.ppass.proto.Methods
import com.hawkeyexb.ppass.proto.PairAccepted
import com.hawkeyexb.ppass.proto.PairRequest
import com.hawkeyexb.ppass.proto.ProtoJson
import kotlinx.serialization.json.buildJsonObject
import kotlinx.coroutines.withTimeout

sealed class PairOutcome {
    data class Joined(val pairing: Pairing) : PairOutcome()
    data class Refused(val msgKey: String) : PairOutcome()
    data class Failed(val reason: String) : PairOutcome()
}

/**
 * DEV-01 重装指纹：SHA-256(Build.MODEL + ANDROID_ID) 前 8 字节 hex。
 * - 免权限：Build.MODEL / ANDROID_ID 都无需运行时权限；
 * - ANDROID_ID 自 API 26 按「签名+用户+设备」隔离——同签名重装不变、
 *   仅恢复出厂重置才变——正是「识别重装」需要的性质；
 * - 只作提示不作凭据：daemon 的鉴权不读它。
 */
fun reinstallHint(): String {
    val model = android.os.Build.MODEL
    val androidId = android.provider.Settings.Secure.ANDROID_ID
    val digest = java.security.MessageDigest.getInstance("SHA-256")
        .digest((model + androidId).toByteArray(Charsets.UTF_8))
    return digest.take(8).joinToString("") { "%02x".format(it) }
}

/**
 * Scan result → pair.request → wait for the owner's Allow.
 * [waitMs] must exceed a human's reaction time generously; the QR
 * token itself lives 10 minutes.
 */
suspend fun pairWithQr(
    client: DaemonClient,
    qr: String,
    deviceName: String,
    waitMs: Long = 120_000,
    // DEV-01: 重装识别开关——关掉时不发指纹，行为回到 DEV-01 前
    // （重装后出新设备行）。默认开。
    reinstallHintEnabled: Boolean = true,
): PairOutcome {
    val parsed = try {
        parsePairingQr(qr)
    } catch (e: Exception) {
        return PairOutcome.Failed("这不是 P-Pass 配对码")
    }
    // H-10b: 新 QR 只有 r=（relay URL）——从 node+relay 重建可连接地址；
    // 旧 QR 的 a= 完整解析仍兼容。
    val addr: PeerAddrParts = parsed.addr ?: parsed.relayUrl?.let {
        PeerAddrParts(parsed.nodeIdHex, it, emptyList())
    } ?: return PairOutcome.Failed(
        // FIX-T3: 升级顺序地雷——旧 APK（≤0.3.0-test.2）只认 a=，新码
        // 只带 r=；a=/r= 都缺 = 配对码无法解析。明确引导升级而非静默失败。
        "配对码无法解析，请把电脑端和手机 App 都升级到最新版"
    )
    // 存储 token：旧码存原 a= 串；新码从 node+relay 重建（backup 的
    // parsePeerAddrToken 兼容）。
    val addrToken: String = parsed.addr?.let { qr.substringAfter("&a=", "") }
        ?: parsed.relayUrl?.let { buildAddrToken(parsed.nodeIdHex, it) }
        ?: ""

    // Already a member on this storage (same phone, the computer's
    // identity/address changed)? Then no pair.request is needed — and
    // it would be REFUSED (members can't re-apply). backup.begin is
    // member-gated: an ok means we're recognised; just re-save.
    try {
        val probe = withTimeout(20_000) {
            client.call(addr, Methods.BACKUP_BEGIN, buildJsonObject {})
        }
        if (probe.ok) {
            val hello = withTimeout(20_000) {
                client.call(addr, Methods.HELLO, buildJsonObject {})
            }
            val name = if (hello.ok) {
                ProtoJson.decodeFromJsonElement(Hello.serializer(), hello.result!!).deviceName
            } else "P-Pass 存储端"
            return PairOutcome.Joined(
                Pairing(
                    daemonNodeId = parsed.nodeIdHex,
                    daemonAddrToken = addrToken,
                    storageDeviceName = name,
                    pairedAt = System.currentTimeMillis(),
                )
            )
        }
    } catch (_: Exception) {
        // Not reachable or not recognised — fall through to pairing.
    }

    return try {
        val resp = withTimeout(waitMs) {
            client.call(
                addr,
                Methods.PAIR_REQUEST,
                ProtoJson.encodeToJsonElement(
                    PairRequest.serializer(),
                    PairRequest(
                        token = parsed.token,
                        deviceName = deviceName,
                        deviceHint = if (reinstallHintEnabled) reinstallHint() else null,
                    ),
                ),
            )
        }
        if (resp.ok) {
            val accepted = ProtoJson.decodeFromJsonElement(
                PairAccepted.serializer(), resp.result!!
            )
            PairOutcome.Joined(
                Pairing(
                    daemonNodeId = parsed.nodeIdHex,
                    daemonAddrToken = addrToken,
                    storageDeviceName = accepted.storageDeviceName,
                    pairedAt = System.currentTimeMillis(),
                    pairingEpoch = accepted.pairingEpoch,
                )
            )
        } else {
            PairOutcome.Refused(resp.error?.msgKey ?: "err.unknown")
        }
    } catch (e: Exception) {
        PairOutcome.Failed(e.toString())
    }
}

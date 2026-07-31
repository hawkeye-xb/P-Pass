// Length-prefixed JSON framing — Kotlin mirror of crates/proto codec.rs.
// Wire format: u32 little-endian byte count, then UTF-8 JSON payload.
// Drift-checked against the *_hex insta snapshots in FrameDriftTest.
package com.hawkeyexb.ppass.proto

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.serialization.KSerializer

/** 16 MiB, same cap as the Rust side (thumbs ride JSON; originals go blobs). */
const val MAX_PAYLOAD: Int = 16 * 1024 * 1024

class CodecException(message: String) : Exception(message)

fun <T> encodeFrame(serializer: KSerializer<T>, value: T): ByteArray {
    val payload = ProtoJson.encodeToString(serializer, value).toByteArray(Charsets.UTF_8)
    if (payload.size > MAX_PAYLOAD) {
        throw CodecException("payload too large: ${payload.size} bytes (max $MAX_PAYLOAD)")
    }
    return ByteBuffer.allocate(4 + payload.size)
        .order(ByteOrder.LITTLE_ENDIAN)
        .putInt(payload.size)
        .put(payload)
        .array()
}

fun frameLen(header: ByteArray): Int {
    require(header.size >= 4) { "frame header needs 4 bytes, got ${header.size}" }
    val len = ByteBuffer.wrap(header, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
    if (len < 0 || len > MAX_PAYLOAD) {
        throw CodecException("payload too large: $len bytes (max $MAX_PAYLOAD)")
    }
    return len
}

fun <T> decodePayload(serializer: KSerializer<T>, payload: ByteArray): T =
    ProtoJson.decodeFromString(serializer, payload.toString(Charsets.UTF_8))

/** Decode a complete frame (header + payload), mirroring codec::decode. */
fun <T> decodeFrame(serializer: KSerializer<T>, frame: ByteArray): T {
    val len = frameLen(frame)
    if (frame.size < 4 + len) {
        throw CodecException("incomplete frame: expected ${4 + len} bytes, got ${frame.size}")
    }
    return decodePayload(serializer, frame.copyOfRange(4, 4 + len))
}

// T-053: BLAKE3 content hashing. The hex digest IS the cross-device
// identity of a photo — dedup, storage paths and blob transfer all key
// on it, so Kotlin and Rust MUST agree bit-for-bit. Blake3VectorTest
// pins this against Rust-generated vectors.
package com.hawkeyexb.ppass.backup

import io.github.rctcwyvrn.blake3.Blake3
import java.io.InputStream

private const val CHUNK = 256 * 1024

/** Streaming BLAKE3 of an InputStream, hex-encoded (64 chars). */
fun blake3Hex(input: InputStream): String {
    val hasher = Blake3.newInstance()
    val buf = ByteArray(CHUNK)
    while (true) {
        val n = input.read(buf)
        if (n < 0) break
        if (n == buf.size) hasher.update(buf) else hasher.update(buf.copyOf(n))
    }
    return hasher.hexdigest()
}

fun blake3Hex(bytes: ByteArray): String =
    Blake3.newInstance().let { it.update(bytes); it.hexdigest() }

// UPD-02: RFC 7693 BLAKE2b——minisign「ED」签名的预哈希算法（验签链路的第一段）。
//
// 为什么手写：Android 没有内置 BLAKE2b；为这一个哈希引 BouncyCastle（数 MB）
// 在「照片备份 App 体积敏感」的仓库纪律下不成立（material-icons-extended 都
// 因体积被拒）。BLAKE2b 本体是公开的固定常数 + 压缩函数，实现面小，且正确性
// 由 Blake2bTest 用 hashlib 权威向量（含跨块长输入、分片喂入等价）锁死——
// 与 T-053 的 blake3「纯 Java 实现 + Rust 向量对拍」同一条纪律。
package com.hawkeyexb.ppass.update

/**
 * BLAKE2b（默认 64 字节摘要——minisign 预哈希固定用 512 位）。
 * 流式：多次 [update] 后 [digest]；[digest] 之后实例不可再用。
 */
class Blake2b(private val digestSize: Int = 64) {
    init {
        require(digestSize in 1..64) { "BLAKE2b digest size must be in 1..64" }
    }

    private val h = LongArray(8)
    private val buf = ByteArray(BLOCK_BYTES)
    private var bufLen = 0
    private var t0 = 0L // 已压缩字节计数（低 64 位）
    private var t1 = 0L // 高 64 位
    private var done = false

    init {
        IV.copyInto(h)
        // 参数块：digest_length | fanout=1<<16 | depth=1<<24（序列哈希，无盐无个性化）
        h[0] = h[0] xor (0x01010000L or digestSize.toLong())
    }

    fun update(data: ByteArray, offset: Int = 0, length: Int = data.size) {
        check(!done) { "Blake2b already finalized" }
        var off = offset
        var len = length
        while (len > 0) {
            if (bufLen == BLOCK_BYTES) {
                // 缓冲满：这不是最后一块（后面还有字节），按非终块压缩
                addCounter(BLOCK_BYTES)
                compress(buf, last = false)
                bufLen = 0
            }
            val take = minOf(BLOCK_BYTES - bufLen, len)
            System.arraycopy(data, off, buf, bufLen, take)
            bufLen += take
            off += take
            len -= take
        }
    }

    fun digest(): ByteArray {
        check(!done) { "Blake2b already finalized" }
        done = true
        addCounter(bufLen)
        buf.fill(0, bufLen, BLOCK_BYTES) // 最后一块零填充
        compress(buf, last = true)
        val out = ByteArray(digestSize)
        for (i in 0 until digestSize) {
            out[i] = (h[i / 8] ushr (8 * (i % 8))).toByte()
        }
        return out
    }

    private fun addCounter(n: Int) {
        val prev = t0
        t0 += n.toLong()
        if (java.lang.Long.compareUnsigned(t0, prev) < 0) t1 += 1L // 无符号回绕即向高位进位
    }

    private fun compress(block: ByteArray, last: Boolean) {
        val m = LongArray(16)
        for (i in 0..15) {
            var w = 0L
            for (j in 0..7) w = w or ((block[i * 8 + j].toLong() and 0xFF) shl (8 * j))
            m[i] = w
        }
        val v = LongArray(16)
        for (i in 0..7) v[i] = h[i]
        for (i in 0..7) v[i + 8] = IV[i]
        v[12] = v[12] xor t0
        v[13] = v[13] xor t1
        if (last) v[14] = v[14].inv()
        for (round in 0..11) {
            val s = SIGMA[round]
            g(v, 0, 4, 8, 12, m[s[0]], m[s[1]])
            g(v, 1, 5, 9, 13, m[s[2]], m[s[3]])
            g(v, 2, 6, 10, 14, m[s[4]], m[s[5]])
            g(v, 3, 7, 11, 15, m[s[6]], m[s[7]])
            g(v, 0, 5, 10, 15, m[s[8]], m[s[9]])
            g(v, 1, 6, 11, 12, m[s[10]], m[s[11]])
            g(v, 2, 7, 8, 13, m[s[12]], m[s[13]])
            g(v, 3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for (i in 0..7) h[i] = h[i] xor v[i] xor v[i + 8]
    }

    private fun g(v: LongArray, a: Int, b: Int, c: Int, d: Int, x: Long, y: Long) {
        v[a] = v[a] + v[b] + x
        v[d] = java.lang.Long.rotateRight(v[d] xor v[a], 32)
        v[c] = v[c] + v[d]
        v[b] = java.lang.Long.rotateRight(v[b] xor v[c], 24)
        v[a] = v[a] + v[b] + y
        v[d] = java.lang.Long.rotateRight(v[d] xor v[a], 16)
        v[c] = v[c] + v[d]
        v[b] = java.lang.Long.rotateRight(v[b] xor v[c], 63)
    }

    companion object {
        private const val BLOCK_BYTES = 128

        // 超 Long.MAX_VALUE 的字面量走 ULong 再转回（位型不变）。
        private val IV = longArrayOf(
            0x6a09e667f3bcc908L, 0xbb67ae8584caa73buL.toLong(),
            0x3c6ef372fe94f82bL, 0xa54ff53a5f1d36f1uL.toLong(),
            0x510e527fade682d1L, 0x9b05688c2b3e6c1fuL.toLong(),
            0x1f83d9abfb41bd6bL, 0x5be0cd19137e2179L,
        )

        private val SIGMA = arrayOf(
            intArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
            intArrayOf(14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3),
            intArrayOf(11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4),
            intArrayOf(7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8),
            intArrayOf(9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13),
            intArrayOf(2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9),
            intArrayOf(12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11),
            intArrayOf(13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10),
            intArrayOf(6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5),
            intArrayOf(10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0),
            intArrayOf(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
            intArrayOf(14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3),
        )
    }
}

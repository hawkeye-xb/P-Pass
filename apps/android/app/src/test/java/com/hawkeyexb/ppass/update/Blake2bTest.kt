// UPD-02: 手写 RFC 7693 BLAKE2b 的正确性锁——minisign「ED」验签链路的
// 第一段。向量全部来自 JDK/Python hashlib（权威实现），含：
//  - RFC 7693 经典向量（空串 / "abc" / fox）；
//  - 跨块长输入（128B 整数倍、129B 越界、1000B 多块）；
//  - 分片喂入与整喂等价（流式 API 的正确性）；
//  - digestSize 参数（32 字节摘要）。
// 反证：改动压缩函数 / IV / SIGMA / 计数器的任何一处，必有向量红。
package com.hawkeyexb.ppass.update

import org.junit.Assert.assertEquals
import org.junit.Test

class Blake2bTest {

    private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

    private fun hashOf(data: ByteArray, digestSize: Int = 64): String =
        Blake2b(digestSize).apply { update(data) }.digest().hex()

    @Test
    fun rfc7693ClassicVectors() {
        assertEquals(
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419" +
                "d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
            hashOf(ByteArray(0)),
        )
        assertEquals(
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2" +
                "d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
            hashOf("abc".toByteArray()),
        )
        assertEquals(
            "a8add4bdddfd93e4877d2746e62817b116364a1fa7bc148d95090bc7333b36" +
                "73f82401cf7aa2e4cb1ecd90296e3f14cb5413f8ed77be73045b13914cdcd6a918",
            hashOf("The quick brown fox jumps over the lazy dog".toByteArray()),
        )
    }

    @Test
    fun blockBoundaryInputs() {
        // 恰好一个整块（128B）：最后一块按「终块」压缩，与 129B（终块只剩 1B）
        // 走两条代码路径，都要对。
        assertEquals(
            "f5011c14425def0732ae5ad325ea7ceb558b908e390cb8157d15c365226d4e" +
                "076789bd1e9534353bfc852bb90c0c1c85755a7cc43f9fafecd8fabade9bcc8d77",
            hashOf(ByteArray(128) { 'A'.code.toByte() }),
        )
        assertEquals(
            "3dc8c5e69fe2ad0d8ea8bc16732f00cd7c1ce619783cb91a2f684ccf2e1e95" +
                "a4aba27640e9f6339df2b1d572c4fb3900deae6330b94e900a934e131b9ca5d136",
            hashOf(ByteArray(129) { 'A'.code.toByte() }),
        )
        assertEquals(
            "ffc91d5b8c0451522646f640b093e6d0ba10cad123c5d1cf39a1b43fce76d5" +
                "1ebbe529f908571e141118adad4554769f0f3b8323174c07f94e7d333e28d334df",
            hashOf(ByteArray(1000) { 'A'.code.toByte() }),
        )
    }

    @Test
    fun chunkedFeedingEqualsSingleFeed() {
        val data = ByteArray(1000) { (it * 7 % 251).toByte() }
        val whole = hashOf(data)
        for (chunk in listOf(1, 7, 63, 127, 128, 129, 384)) {
            val h = Blake2b()
            var off = 0
            while (off < data.size) {
                val n = minOf(chunk, data.size - off)
                h.update(data, off, n)
                off += n
            }
            assertEquals("chunk=$chunk", whole, h.digest().hex())
        }
    }

    @Test
    fun digestSizeParameter() {
        assertEquals(
            "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319",
            hashOf("abc".toByteArray(), digestSize = 32),
        )
    }
}

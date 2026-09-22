package com.hawkeyexb.ppass.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * IDX-03：查看器头部的尺寸位。
 *
 * 线上这个字段是 `u32`（`crates/proto/src/msgs.rs`），daemon 侧
 * `a.width.unwrap_or(0)` 已经把「库里是 NULL」压成了 `0` 才发出来——
 * 也就是说手机这边**收到的就是 0**，不是缺字段。所以「未知」在这一层
 * 唯一诚实的判据只能是 `<= 0`：没有任何一张照片是 0 像素宽的。
 *
 * 为什么不显示「尺寸未知」四个字：头部只有这一个信息位，视频本来就常常
 * 没有尺寸，那不是异常态，空着比写字干净（卡面判断 ③）。
 */
class PhotosScreenDimensionsTest {
    @Test
    fun known_dimensions_render_as_width_by_height() {
        assertEquals("1080×2340", dimensionsText(1080, 2340))
    }

    @Test
    fun unknown_dimensions_render_nothing_at_all() {
        // daemon 对 NULL 行发的就是这个：0×0 —— IDX-03 的原始症状。
        assertNull("0×0 是假数据，一个字都不许渲染", dimensionsText(0, 0))
        // 半缺也是缺：拿一个真数字配一个 0 拼出来的串同样是假的。
        assertNull("只有宽是假的也不许渲染", dimensionsText(0, 2340))
        assertNull("只有高是假的也不许渲染", dimensionsText(1080, 0))
        // 负数不该出现（u32 过来的），但真出现了也不许当真数据画出去。
        assertNull(dimensionsText(-1, -1))
    }
}

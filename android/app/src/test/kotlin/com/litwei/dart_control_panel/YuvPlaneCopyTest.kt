package com.litwei.dart_control_panel

import org.junit.Assert.assertArrayEquals
import org.junit.Test
import java.nio.ByteBuffer

class YuvPlaneCopyTest {
    @Test fun cropAndInterleaveWithPaddingAndBufferOffset() {
        val data = byteArrayOf(99, 99, 1, 9, 2, 9, 3, 9, 4, 9, 5, 9, 6, 9, 7, 9, 8, 9, 9, 9)
        val buffer = ByteBuffer.wrap(data).apply { position(2) }
        val out = ByteArray(8)
        YuvPlaneCopy.copy(buffer, 6, 2, 1, 0, 2, 2, out, 1, 2, 4)
        assertArrayEquals(byteArrayOf(0, 2, 0, 3, 0, 5, 0, 6), out)
    }
    @Test(expected = IllegalArgumentException::class)
    fun rejectsTruncatedPlane() {
        YuvPlaneCopy.copy(ByteBuffer.wrap(byteArrayOf(1)), 2, 1, 0, 0, 2, 2, ByteArray(4), 0, 1, 2)
    }
}

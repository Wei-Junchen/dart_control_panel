package com.litwei.dart_control_panel

import java.nio.ByteBuffer

/** Copy a cropped plane with independent decoder row/pixel strides. */
internal object YuvPlaneCopy {
    fun copy(source: ByteBuffer, rowStride: Int, pixelStride: Int,
             startX: Int, startY: Int, width: Int, height: Int,
             output: ByteArray, destination: Int, pixelStep: Int, rowStep: Int) {
        require(rowStride > 0 && pixelStride > 0 && startX >= 0 && startY >= 0 && width > 0 && height > 0)
        val buffer = source.duplicate(); val base = buffer.position()
        for (y in 0 until height) for (x in 0 until width) {
            val pos = base.toLong() + (startY + y).toLong() * rowStride + (startX + x).toLong() * pixelStride
            val target = destination.toLong() + y.toLong() * rowStep + x.toLong() * pixelStep
            require(pos >= 0 && pos < buffer.limit() && target >= 0 && target < output.size) { "解码器输出平面尺寸无效" }
            output[target.toInt()] = buffer.get(pos.toInt())
        }
    }
}

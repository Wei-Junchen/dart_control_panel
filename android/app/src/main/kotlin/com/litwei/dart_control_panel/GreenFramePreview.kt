package com.litwei.dart_control_panel

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream
import kotlin.math.max

/** Preview only; the detector continues to operate on the full-size NV21 frame. */
internal object GreenFramePreview {
    private fun png(pixels: IntArray, width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888)
        return try {
            val output = ByteArrayOutputStream()
            check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "无法生成预览图" }
            output.toByteArray()
        } finally { bitmap.recycle() }
    }
    fun build(native: NativeGreenDetector, handle: Long, frame: ByteArray, width: Int, height: Int, detection: LongArray, number: Int): Map<String, Any> {
        val step = max(1, max((width + 639) / 640, (height + 359) / 360))
        val pw = (width + step - 1) / step; val ph = (height + step - 1) / step
        val mask = native.mask(handle, frame, width, height, step)
        val rgb = IntArray(pw * ph); val yImage = IntArray(pw * ph); val maskImage = IntArray(pw * ph)
        fun clamp(v: Int) = v.coerceIn(0, 255)
        for (py in 0 until ph) for (px in 0 until pw) {
            val x = px * step; val y = py * step; val index = py * pw + px
            val luma = frame[y * width + x].toInt() and 255
            val uv = width * height + (y / 2) * width + (x and -2)
            val v = (frame[uv].toInt() and 255) - 128
            val u = (frame[uv + 1].toInt() and 255) - 128
            val c = max(0, luma - 16)
            val r = clamp((298*c + 409*v + 128) shr 8)
            val g = clamp((298*c - 100*u - 208*v + 128) shr 8)
            val b = clamp((298*c + 516*u + 128) shr 8)
            rgb[index] = (0xff000000.toInt() or (r shl 16) or (g shl 8) or b)
            yImage[index] = (0xff000000.toInt() or (luma shl 16) or (luma shl 8) or luma)
            val bit = mask[index].toInt() and 255
            maskImage[index] = (0xff000000.toInt() or (bit shl 16) or (bit shl 8) or bit)
        }
        return mapOf("frame" to number, "width" to width, "height" to height,
            "found" to (detection[0] != 0L), "rect" to detection.slice(3..6),
            "pixels" to detection[7], "rgb" to png(rgb, pw, ph),
            "y" to png(yImage, pw, ph), "mask" to png(maskImage, pw, ph))
    }
}

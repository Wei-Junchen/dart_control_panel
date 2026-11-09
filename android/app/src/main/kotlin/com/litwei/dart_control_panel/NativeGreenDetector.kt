package com.litwei.dart_control_panel

internal class NativeGreenDetector {
    companion object { init { System.loadLibrary("dart_green_detector") } }
    external fun create(values: IntArray, mode: String, lumaInts: IntArray, lumaFloats: DoubleArray, common: IntArray): Long
    external fun detect(handle: Long, nv21: ByteArray, width: Int, height: Int): LongArray
    external fun mask(handle: Long, nv21: ByteArray, width: Int, height: Int, step: Int): ByteArray
    external fun destroy(handle: Long)
}

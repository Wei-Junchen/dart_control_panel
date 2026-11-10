package com.litwei.dart_control_panel

import java.io.ByteArrayOutputStream
import java.io.InputStream

/** Bounded streaming reader. Neither the whole movie nor a GOP is kept in memory. */
internal class AnnexBReader(input: InputStream) : AutoCloseable {
    private val input = input.buffered(65536)
    private var started = false
    private var ended = false
    fun next(): ByteArray? {
        if (ended) return null
        var zeros = 0
        if (!started) {
            var searched = 0
            while (true) {
                val b = input.read()
                require(b >= 0) { "缺少 H.264 Annex-B 起始码" }
                require(++searched <= 1048576) { "H.264 起始码过远" }
                if (b == 1 && zeros >= 2) break
                require(b == 0) { "不是 Annex-B H.264 文件" }
                zeros++
            }
            started = true
            zeros = 0
        }
        val out = ByteArrayOutputStream(65536)
        while (true) {
            val b = input.read()
            if (b < 0) {
                ended = true
                return out.toByteArray().takeIf { it.isNotEmpty() }
            }
            if (b == 1 && zeros >= 2) {
                require(out.size() > 0) { "空 H.264 NAL" }
                return out.toByteArray()
            }
            if (b == 0) zeros++ else {
                repeat(zeros) { out.write(0) }
                zeros = 0
                out.write(b)
            }
            require(out.size().toLong() + zeros <= 16 * 1024 * 1024) { "H.264 NAL 超过16MB" }
        }
    }
    override fun close() = input.close()
}

internal class H264Bits(nal: ByteArray) {
    private val rbsp: ByteArray
    private var position = 0
    init {
        val out = ByteArrayOutputStream()
        var zeros = 0
        for (i in 1 until nal.size) {
            val b = nal[i].toInt() and 255
            if (zeros >= 2 && b == 3) { zeros = 0; continue }
            out.write(b)
            zeros = if (b == 0) zeros + 1 else 0
        }
        rbsp = out.toByteArray()
    }
    fun bits(count: Int): Int {
        require(count in 0..30 && position.toLong() + count <= rbsp.size.toLong() * 8) { "H.264 头部截断" }
        var v = 0
        repeat(count) {
            v = (v shl 1) or ((rbsp[position / 8].toInt() ushr (7 - position % 8)) and 1)
            position++
        }
        return v
    }
    fun ue(): Int {
        var count = 0
        while (bits(1) == 0) { count++; require(count < 30) { "无效 Exp-Golomb" } }
        return (1 shl count) - 1 + bits(count)
    }
    fun se(): Int { val n = ue(); return if (n % 2 == 0) -(n / 2) else (n + 1) / 2 }
}

internal fun h264Dimensions(sps: ByteArray): Pair<Int, Int> {
    val b = H264Bits(sps)
    val profile = b.bits(8)
    b.bits(8); b.bits(8); b.ue()
    var chroma = 1
    var separate = 0
    if (profile in setOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)) {
        chroma = b.ue(); require(chroma in 0..3) { "无效色度格式" }
        if (chroma == 3) separate = b.bits(1)
        b.ue(); b.ue(); b.bits(1)
        if (b.bits(1) != 0) repeat(if (chroma == 3) 12 else 8) { index ->
            if (b.bits(1) != 0) {
                var last = 8; var next = 8
                repeat(if (index < 6) 16 else 64) {
                    if (next != 0) next = (last + b.se() + 256) and 255
                    if (next != 0) last = next
                }
            }
        }
    }
    b.ue()
    when (b.ue()) {
        0 -> b.ue()
        1 -> { b.bits(1); b.se(); b.se(); val n = b.ue(); require(n <= 255); repeat(n) { b.se() } }
        2 -> Unit
        else -> error("无效 POC 类型")
    }
    b.ue(); b.bits(1)
    val widthMbs = b.ue() + 1; val heightMbs = b.ue() + 1
    require(widthMbs in 1..512 && heightMbs in 1..512) { "图像尺寸过大" }
    require(b.bits(1) == 1) { "暂不支持隔行 H.264，请使用桌面版封装" }
    b.bits(1)
    var left = 0; var right = 0; var top = 0; var bottom = 0
    if (b.bits(1) != 0) { left = b.ue(); right = b.ue(); top = b.ue(); bottom = b.ue() }
    val array = if (separate == 1) 0 else chroma
    val cropX = if (array == 1 || array == 2) 2 else 1
    val cropY = if (array == 1) 2 else 1
    val width = widthMbs.toLong() * 16 - (left.toLong() + right) * cropX
    val height = heightMbs.toLong() * 16 - (top.toLong() + bottom) * cropY
    require(width in 1..8192 && height in 1..8192) { "无效裁剪尺寸" }
    return Pair(width.toInt(), height.toInt())
}

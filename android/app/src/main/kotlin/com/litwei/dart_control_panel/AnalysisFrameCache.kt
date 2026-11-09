package com.litwei.dart_control_panel

import java.io.File
import java.io.RandomAccessFile

/** Full-resolution decoded NV21, independent of the detector parameters. */
internal class AnalysisFrameCache(private val file: File, private val limit: Long = 1024L * 1024 * 1024) {
    data class Frame(val number: Int, val width: Int, val height: Int, val nv21: ByteArray)
    private val offsets = ArrayList<Long>()
    private val io = RandomAccessFile(file, "rw")
    private var closed = false

    @Synchronized fun add(number: Int, width: Int, height: Int, nv21: ByteArray) {
        check(!closed)
        require(number == offsets.size + 1) { "缓存帧编号不连续" }
        require(width in 2..4096 && height in 2..4096 && width % 2 == 0 && height % 2 == 0 && nv21.size.toLong() == width.toLong() * height * 3 / 2) { "NV21 帧尺寸无效" }
        val size = 16L + nv21.size
        require(io.length() + size <= limit && file.parentFile!!.usableSpace > size + 64L * 1024 * 1024) {
            "原始帧缓存空间不足（上限 1 GiB），请缩短录像或释放存储空间"
        }
        io.seek(io.length())
        val offset = io.filePointer
        io.writeInt(number); io.writeInt(width); io.writeInt(height); io.writeInt(nv21.size)
        io.write(nv21)
        offsets.add(offset)
    }

    @Synchronized fun read(number: Int): Frame {
        check(!closed) { "帧缓存已关闭" }
        require(number in 1..offsets.size) { "帧编号超出范围" }
        io.seek(offsets[number - 1])
        val index = io.readInt(); val width = io.readInt(); val height = io.readInt(); val size = io.readInt()
        require(index == number && width in 2..4096 && height in 2..4096 && width % 2 == 0 && height % 2 == 0 && size.toLong() == width.toLong() * height * 3 / 2) { "帧缓存损坏" }
        return Frame(index, width, height, ByteArray(size).also { io.readFully(it) })
    }

    @Synchronized fun close() {
        if (!closed) { closed = true; io.close(); file.delete() }
    }
}

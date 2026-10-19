package com.litwei.dart_control_panel

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.roundToLong

/** File-only, progressive I/P Annex-B from the board. No decoding/re-encoding. */
internal object H264Remuxer {
    fun convert(raw: File, fps: Double): Map<String, Any> {
        require(fps.isFinite() && fps in 1.0..1000.0) { "帧率应在1..1000之间" }
        require(raw.isFile && raw.extension.lowercase() == "h264") { "没有 H.264 原文件" }
        val output = File(raw.parentFile, raw.nameWithoutExtension + ".mp4")
        require(!output.exists()) { "MP4 已存在，不覆盖" }
        val temporary = File(output.path + ".part")
        require(temporary.createNewFile()) { "存在未完成的 MP4 .part 文件，请先检查" }
        var muxer: MediaMuxer? = null
        var started = false
        var published = false
        var count = 0L
        var width = 0; var height = 0
        var sps: ByteArray? = null; var pps: ByteArray? = null
        var track = -1
        val frame = ByteArrayOutputStream()
        var hasSlice = false; var key = false
        fun append(nal: ByteArray) {
            require(frame.size().toLong() + nal.size + 4 <= 16 * 1024 * 1024) { "H.264 帧超过16MB" }
            frame.write(byteArrayOf(0, 0, 0, 1)); frame.write(nal)
        }
        fun flush() {
            if (!hasSlice) return
            require(count != 0L || key) { "录像必须从 IDR 关键帧开始" }
            val data = frame.toByteArray()
            val info = MediaCodec.BufferInfo()
            info.set(0, data.size, (count * 1000000.0 / fps).roundToLong(),
                if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            muxer!!.writeSampleData(track, ByteBuffer.wrap(data), info)
            count++; frame.reset(); hasSlice = false; key = false
        }
        try {
            AnnexBReader(raw.inputStream()).use { reader ->
                while (true) {
                    check(!Thread.currentThread().isInterrupted) { "封装已取消" }
                    val nal = reader.next() ?: break
                    require((nal[0].toInt() and 128) == 0) { "无效 H.264 NAL 头" }
                    when (val type = nal[0].toInt() and 31) {
                        7, 8 -> {
                            flush()
                            val previous = if (type == 7) sps else pps
                            require(previous == null || previous.contentEquals(nal)) { "录像中途编码参数改变，请使用桌面版封装" }
                            if (type == 7) sps = nal else pps = nal
                        }
                        1, 5 -> {
                            val bits = H264Bits(nal)
                            val firstMb = bits.ue(); val sliceType = bits.ue()
                            require(sliceType in 0..9 && sliceType % 5 in setOf(0, 2)) {
                                "暂支持板端 I/P 帧；B/SP/SI 帧请使用桌面版封装"
                            }
                            if (firstMb == 0) flush()
                            else require(hasSlice) { "缺少首个 slice" }
                            if (!started) {
                                val config = sps ?: error("缺少 SPS")
                                val picture = pps ?: error("缺少 PPS")
                                val dimensions = h264Dimensions(config)
                                width = dimensions.first; height = dimensions.second
                                val format = MediaFormat.createVideoFormat("video/avc", width, height)
                                format.setByteBuffer("csd-0", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1) + config))
                                format.setByteBuffer("csd-1", ByteBuffer.wrap(byteArrayOf(0, 0, 0, 1) + picture))
                                format.setInteger(MediaFormat.KEY_FRAME_RATE, fps.roundToLong().toInt())
                                muxer = MediaMuxer(temporary.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                                track = muxer!!.addTrack(format); muxer!!.start(); started = true
                            }
                            append(nal)
                            hasSlice = true; key = key || type == 5
                        }
                        6 -> { flush(); append(nal) }
                        9, 10, 11 -> flush()
                        12 -> Unit // filler
                        else -> error("不支持 H.264 NAL 类型 $type")
                    }
                }
            }
            flush()
            require(count > 0) { "没有可播放的 H.264 帧" }
            val end = MediaCodec.BufferInfo()
            end.set(0, 0, (count * 1000000.0 / fps).roundToLong(), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            muxer!!.writeSampleData(track, ByteBuffer.allocate(0), end)
            muxer!!.stop(); started = false
            muxer!!.release(); muxer = null
            check(!output.exists() && temporary.renameTo(output)) { "不能发布 MP4，未覆盖已有文件" }
            published = true
            return mapOf("path" to output.path, "frames" to count, "fps" to fps,
                "width" to width, "height" to height, "bytes" to output.length())
        } finally {
            if (started) try { muxer?.stop() } catch (_: Exception) { }
            try { muxer?.release() } finally { if (!published) temporary.delete() }
        }
    }
}

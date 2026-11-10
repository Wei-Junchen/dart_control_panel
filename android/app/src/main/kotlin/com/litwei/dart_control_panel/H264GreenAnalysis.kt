package com.litwei.dart_control_panel

import android.graphics.ImageFormat
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil

/** Offline decoding and analysis. Input is never modified. */
internal object H264GreenAnalysis {
    private fun checkCancelled(cancelled: AtomicBoolean) {
        check(!cancelled.get() && !Thread.currentThread().isInterrupted) { "分析已取消" }
    }

    /** Copy flexible YUV_420_888 planes respecting crop, rowStride and pixelStride. */
    internal fun toNv21(image: Image): ByteArray {
        require(image.format == ImageFormat.YUV_420_888 && image.planes.size == 3) { "解码器未提供 YUV_420_888 图像" }
        val crop = image.cropRect
        val w = crop.width(); val h = crop.height()
        require(w in 2..4096 && h in 2..4096 && w % 2 == 0 && h % 2 == 0 && crop.left % 2 == 0 && crop.top % 2 == 0) { "不支持非偶数的解码尺寸或裁剪" }
        val out = ByteArray(w * h * 3 / 2)
        val planes = image.planes
        fun copyPlane(index: Int, startX: Int, startY: Int, width: Int, height: Int, destination: Int, pixelStep: Int, rowStep: Int) {
            val plane = planes[index]
            YuvPlaneCopy.copy(plane.buffer, plane.rowStride, plane.pixelStride,
                startX, startY, width, height, out, destination, pixelStep, rowStep)
        }
        copyPlane(0, crop.left, crop.top, w, h, 0, 1, w)
        copyPlane(2, crop.left / 2, crop.top / 2, w / 2, h / 2, w * h, 2, w)
        copyPlane(1, crop.left / 2, crop.top / 2, w / 2, h / 2, w * h + 1, 2, w)
        return out
    }

    fun analyze(raw: File, cacheDir: File, values: IntArray, mode: String, lumaInts: IntArray, lumaFloats: DoubleArray, common: IntArray, cancelled: AtomicBoolean,
                preview: ((NativeGreenDetector, Long, ByteArray, Int, Int, LongArray, Int) -> Unit)? = null,
                pacePreview: Boolean = false, targetFrame: Int? = null,
                cacheFrame: ((ByteArray, Int, Int, Int) -> Unit)? = null): Map<String, Any> {
        require(targetFrame == null || targetFrame in 1..100000) { "目标帧超出范围" }
        require(raw.isFile && raw.extension.lowercase() == "h264") { "请选择本地 H.264 录像" }
        checkCancelled(cancelled)
        require(raw.length() <= cacheDir.usableSpace - 16L * 1024 * 1024) {
            "缓存空间不足，分析需要临时封装录像"
        }
        // The board's raw Annex-B has no container index; reuse the existing
        // validated I/P remuxer into a private temporary MP4, never beside raw.
        val native = NativeGreenDetector()
        val tmp = File.createTempFile("green-analysis-", ".mp4", cacheDir)
        check(tmp.delete()) { "无法准备临时文件" }
        var codec: MediaCodec? = null
        val extractor = MediaExtractor()
        var detector = 0L
        try {
            H264Remuxer.convert(raw, 80.0, tmp) { cancelled.get() }
            checkCancelled(cancelled)
            extractor.setDataSource(tmp.path)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true
            } ?: error("没有视频轨道")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: error("视频格式未知")
            require(mime == "video/avc") { "仅支持 H.264" }
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            codec = MediaCodec.createDecoderByType(mime)
            codec.configure(format, null, null, 0)
            codec.start()
            if (cacheFrame == null) {
                detector = native.create(values, mode, lumaInts, lumaFloats, common)
                check(detector != 0L) { "无法创建检测器" }
            }
            val info = MediaCodec.BufferInfo()
            val elapsed = ArrayList<Long>()
            var frames = 0; var found = 0; var lost = 0; var lostRun = 0; var longestLost = 0
            var previousFound = false; var inputEos = false; var outputEos = false
            var width = 0; var height = 0
            var idle = 0
            var nextPreviewAt = 0L
            var lastFrame: ByteArray? = null
            var lastDetection: LongArray? = null
            while (!outputEos) {
                checkCancelled(cancelled)
                var progress = false
                if (!inputEos) {
                    val index = codec.dequeueInputBuffer(10000)
                    if (index >= 0) {
                        val input = codec.getInputBuffer(index) ?: error("无法读取解码输入缓冲区")
                        input.clear()
                        val count = extractor.readSampleData(input, 0)
                        if (count < 0) {
                            codec.queueInputBuffer(index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputEos = true
                        } else {
                            codec.queueInputBuffer(index, 0, count, extractor.sampleTime.coerceAtLeast(0), 0)
                            extractor.advance()
                        }
                        progress = true
                    }
                }
                val out = codec.dequeueOutputBuffer(info, 10000)
                if (out >= 0) {
                    try {
                        if (info.size > 0) {
                            val image = codec.getOutputImage(out) ?: error("设备解码器不提供可读取 YUV 帧")
                            try {
                                val w = image.cropRect.width(); val h = image.cropRect.height()
                                if (frames != 0) require(width == w && height == h) { "视频中途分辨率变化" }
                                width = w; height = h
                                val nv21 = toNv21(image)
                                frames++
                                require(frames <= 100000) { "录像超过 100000 帧，请缩短后重试" }
                                if (cacheFrame != null) {
                                    cacheFrame(nv21, w, h, frames)
                                } else {
                                    val start = System.nanoTime()
                                    val detection = native.detect(detector, nv21, w, h)
                                    elapsed.add((System.nanoTime() - start) / 1000)
                                    val hit = detection[0] != 0L
                                    if (hit) { found++; lostRun = 0 } else {
                                        if (previousFound) lost++
                                        lostRun++; longestLost = maxOf(longestLost, lostRun)
                                    }
                                    previousFound = hit
                                    if (preview != null) { lastFrame = nv21; lastDetection = detection }
                                    if (preview != null && targetFrame == null && System.nanoTime() >= nextPreviewAt) {
                                        preview(native, detector, nv21, w, h, detection, frames)
                                        nextPreviewAt = System.nanoTime() + 180_000_000L
                                    }
                                    if (pacePreview && targetFrame == null) {
                                        repeat(4) { checkCancelled(cancelled); Thread.sleep(25) }
                                    }
                                }
                            } finally { image.close() }
                        }
                        outputEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0 || (targetFrame != null && frames >= targetFrame)
                    } finally { codec.releaseOutputBuffer(out, false) }
                    progress = true
                } else if (out == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) progress = true
                idle = if (progress) 0 else idle + 1
                check(idle < 1000) { "解码器长时间无响应" }
            }
            require(frames > 0) { "没有可分析的画面" }
            require(targetFrame == null || frames == targetFrame) { "目标帧超过录像总帧数" }
            if (cacheFrame != null) return mapOf("video" to mapOf("path" to raw.path, "width" to width, "height" to height, "frames" to frames), "runs" to emptyList<Any>(), "raw_cache" to true)
            elapsed.sort()
            fun percentile(f: Double): Double {
                val p = (elapsed.size - 1) * f
                val low = p.toInt(); val high = ceil(p).toInt()
                return (elapsed[low] + (elapsed[high] - elapsed[low]) * (p - low)) / 1000.0
            }
            val summary = mapOf("frames" to frames, "found" to found, "found_rate" to found.toDouble() / frames,
                "lost" to lost, "longest_lost" to longestLost, "mean_ms" to elapsed.average() / 1000.0,
                "p50_ms" to percentile(.5), "p90_ms" to percentile(.9), "p99_ms" to percentile(.99), "max_ms" to elapsed.last() / 1000.0)
            val result = mutableMapOf<String, Any>("video" to mapOf("path" to raw.path, "width" to width, "height" to height, "frames" to frames), "partial" to (targetFrame != null),
                "runs" to listOf(mapOf("settings" to mapOf("mode" to mode, "green_thresholds" to values.toList(), "luma_parameters" to (lumaInts.toList() + lumaFloats.toList())), "summary" to summary)))
            // Return the last preview with the result, so a very short file or
            // a busy UI still finishes on its actual final frame.
            if (preview != null && lastFrame != null && lastDetection != null) {
                checkCancelled(cancelled)
                result["last_preview"] = GreenFramePreview.build(native, detector, lastFrame, width, height, lastDetection, frames)
            }
            return result
        } finally {
            if (detector != 0L) native.destroy(detector)
            try { codec?.stop() } catch (_: Exception) { }
            try { codec?.release() } finally { extractor.release(); tmp.delete(); File(tmp.path + ".part").delete() }
        }
    }
}

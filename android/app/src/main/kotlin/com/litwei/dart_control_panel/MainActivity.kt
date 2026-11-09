package com.litwei.dart_control_panel

import android.content.Intent
import android.content.ClipData
import androidx.core.content.FileProvider
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private lateinit var connectivity: ConnectivityManager
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var boundWifi: Network? = null
    private var preferWifi = false
    private val videoJobs = Executors.newSingleThreadExecutor()
    private val converting = AtomicBoolean(false)
    private val analysisJobs = Executors.newSingleThreadExecutor()
    private val analyzing = AtomicBoolean(false)
    private val frameCaches = ConcurrentHashMap<String, AnalysisFrameCache>()
    private val cancelAnalysis = AtomicBoolean(false)
    private val shareJobs = Executors.newSingleThreadExecutor()
    private val sharing = AtomicBoolean(false)

    // Reapply after dialogs, keyboard or returning from another activity.
    private fun hideSystemBars() {
        window.decorView.post {
            WindowInsetsControllerCompat(window, window.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
        }
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars()
    }

    private fun bindWifi(): Boolean {
        preferWifi = true
        val wifi = connectivity.allNetworks.firstOrNull {
            val caps = connectivity.getNetworkCapabilities(it)
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        } ?: return false
        val bound = connectivity.bindProcessToNetwork(wifi)
        if (bound) boundWifi = wifi
        return bound
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        connectivity = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        // A board AP has no Internet: do not let cellular become this app's route.
        callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (preferWifi && connectivity.bindProcessToNetwork(network)) boundWifi = network
            }
            override fun onLost(network: Network) {
                if (boundWifi == network) { connectivity.bindProcessToNetwork(null); boundWifi = null }
            }
        }
        connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(), callback!!)
        // Remove abandoned temporary caches from a previous process. Never scan user files.
        cacheDir.listFiles()?.filter { it.name.startsWith("analysis-frames-") && it.name.endsWith(".cache") }
            ?.forEach { it.delete() }
        val analysisFrames = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.litwei.dart_control_panel/analysis_frames")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.litwei.dart_control_panel/platform").setMethodCallHandler { call, result ->
            when (call.method) {
                "paths" -> result.success(mapOf("config" to filesDir.absolutePath,
                    "data" to (getExternalFilesDir(null) ?: filesDir).absolutePath))
                "bindWifi" -> result.success(bindWifi())
                "useSystemNetwork" -> {
                    preferWifi = false
                    val cleared = connectivity.bindProcessToNetwork(null)
                    boundWifi = null
                    result.success(cleared)
                }
                "wifiIpv4" -> result.success(connectivity.allNetworks.filter {
                    val caps = connectivity.getNetworkCapabilities(it)
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                        !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                }.flatMap { network ->
                    connectivity.getLinkProperties(network)?.linkAddresses.orEmpty()
                        .mapNotNull { if (it.address is Inet4Address) it.address.hostAddress else null }
                }.distinct())
                "shareLogZip" -> {
                    val path = call.argument<String>("path")
                    if (path == null) result.error("ARGUMENT", "请选择一条日志", null)
                    else if (!sharing.compareAndSet(false, true)) result.error("BUSY", "正在打包日志", null)
                    else shareJobs.execute {
                        try {
                            val source = File(path).canonicalFile
                            val roots = listOfNotNull(filesDir, getExternalFilesDir(null))
                            require(roots.any { source.path.startsWith(it.canonicalPath + File.separator) }) {
                                "仅允许分享应用内的单次日志目录"
                            }
                            require(source.isDirectory && (File(source, "metadata.json").isFile || File(source, "flight.json").isFile)) {
                                "请选择包含元信息的单次日志目录"
                            }
                            val cache = File(cacheDir, "log_shares")
                            // Keep recent exports: a receiving app may open its URI later.
                            cache.listFiles()?.filter { it.isFile && System.currentTimeMillis() - it.lastModified() > 7L * 24 * 60 * 60 * 1000 }
                                ?.forEach { it.delete() }
                            val zip = LogZip.create(source, cache)
                            runOnUiThread {
                                try {
                                    check(!isFinishing && !isDestroyed) { "页面已关闭" }
                                    val uri = FileProvider.getUriForFile(this, "$packageName.logshare", zip)
                                    val send = Intent(Intent.ACTION_SEND).apply {
                                        type = "application/zip"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        clipData = ClipData.newRawUri(zip.name, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    startActivity(Intent.createChooser(send, "分享单次日志压缩包"))
                                    result.success(mapOf("name" to zip.name, "bytes" to zip.length()))
                                } catch (e: Exception) {
                                    result.error("SHARE", e.message ?: "无法打开分享面板", null)
                                } finally { sharing.set(false) }
                            }
                        } catch (e: Exception) {
                            sharing.set(false)
                            runOnUiThread { result.error("ZIP", e.message ?: "日志打包失败", null) }
                        }
                    }
                }
                "cancelH264Analysis" -> {
                    cancelAnalysis.set(true)
                    result.success(null)
                }
                "readAnalysisFrame" -> {
                    val id = call.argument<String>("analysis_id")
                    val frame = call.argument<Int>("frame")
                    val values = call.argument<List<Number>>("thresholds")
                    val mode = call.argument<String>("mode") ?: "nv21_green"
                    val lumaInts = call.argument<List<Number>>("luma_ints")
                    val lumaFloats = call.argument<List<Number>>("luma_floats")
                    val common = call.argument<List<Number>>("detector_common")
                    if (id == null || frame == null || values?.size != 5 || lumaInts?.size != 2 || lumaFloats?.size != 4 || common?.size != 9 || mode !in listOf("nv21_green", "luma_ellipse")) {
                        result.error("ARGUMENT", "缺少缓存帧或检测器参数", null)
                    } else analysisJobs.execute {
                        try {
                            val cached = frameCaches[id] ?: error("帧缓存已失效，请重新准备视频")
                            val rawFrame = cached.read(frame)
                            val native = NativeGreenDetector()
                            val handle = native.create(values.map { it.toInt() }.toIntArray(), mode,
                                lumaInts.map { it.toInt() }.toIntArray(), lumaFloats.map { it.toDouble() }.toDoubleArray(),
                                common.map { it.toInt() }.toIntArray())
                            check(handle != 0L) { "无法创建检测器" }
                            val data = try {
                                val detection = native.detect(handle, rawFrame.nv21, rawFrame.width, rawFrame.height)
                                GreenFramePreview.build(native, handle, rawFrame.nv21, rawFrame.width, rawFrame.height, detection, frame)
                            } finally { native.destroy(handle) }
                            runOnUiThread { result.success(data) }
                        } catch (e: Exception) { runOnUiThread { result.error("CACHE", e.message, null) } }
                    }
                }
                "releaseAnalysisCache" -> {
                    val id = call.argument<String>("analysis_id")
                    if (id != null) analysisJobs.execute { frameCaches.remove(id)?.close() }
                    result.success(null)
                }
                "analyzeH264" -> {
                    val path = call.argument<String>("path")
                    val values = call.argument<List<Number>>("thresholds")
                    val mode = call.argument<String>("mode") ?: "nv21_green"
                    val lumaInts = call.argument<List<Number>>("luma_ints") ?: listOf(80, 9)
                    val lumaFloats = call.argument<List<Number>>("luma_floats") ?: listOf(2.0, 0.9, 0.25, 1.5)
                    val common = call.argument<List<Number>>("detector_common") ?: listOf(20, 1, 1, 1, 1, 0, 0, 0, 0)
                    val targetFrame = call.argument<Int>("target_frame")
                    val analysisId = call.argument<String>("analysis_id")
                    val cacheAll = call.argument<Boolean>("cache_all") == true && targetFrame == null && analysisId != null
                    val preview = call.argument<Boolean>("preview") == true && analysisId != null
                    val pacePreview = call.argument<Boolean>("pace_preview") == true && preview
                    if (path == null || values == null || values.size != 5 || mode !in listOf("nv21_green", "luma_ellipse") || lumaInts.size != 2 || lumaFloats.size != 4 || common.size != 9) {
                        result.error("ARGUMENT", "需要 H.264 路径和五个阈值", null)
                    } else if (!analyzing.compareAndSet(false, true)) {
                        result.error("BUSY", "已有录像正在分析", null)
                    } else {
                        cancelAnalysis.set(false)
                        analysisJobs.execute {
                            var frameCache: AnalysisFrameCache? = null
                            try {
                                val raw = File(path).canonicalFile
                                val roots = listOfNotNull(filesDir, getExternalFilesDir(null))
                                require(roots.any { raw.path.startsWith(it.canonicalPath + File.separator) }) {
                                    "仅允许分析应用日志目录内的文件"
                                }
                                val previewQueued = AtomicBoolean(false)
                                val onFrame: ((NativeGreenDetector, Long, ByteArray, Int, Int, LongArray, Int) -> Unit)? = if (!preview) null else { native, handle, frame, width, height, detection, number ->
                                    if (previewQueued.compareAndSet(false, true)) {
                                        try {
                                            val snapshot = GreenFramePreview.build(native, handle, frame, width, height, detection, number) + ("analysis_id" to analysisId!!)
                                            runOnUiThread {
                                                try { analysisFrames.invokeMethod("frame", snapshot) }
                                                finally { previewQueued.set(false) }
                                            }
                                        } catch (e: Throwable) {
                                            previewQueued.set(false)
                                            throw e
                                        }
                                    }
                                }
                                if (cacheAll) frameCache = AnalysisFrameCache(File.createTempFile("analysis-frames-", ".cache", cacheDir))
                                var nextProgressAt = 0L
                                val cacheFrame: ((ByteArray, Int, Int, Int) -> Unit)? =
                                    if (!cacheAll) null else { frame, width, height, number ->
                                        frameCache!!.add(number, width, height, frame)
                                        if (System.nanoTime() >= nextProgressAt) {
                                            nextProgressAt = System.nanoTime() + 250_000_000L
                                            runOnUiThread { analysisFrames.invokeMethod("progress", mapOf("analysis_id" to analysisId!!, "frame" to number)) }
                                        }
                                    }
                                val data = H264GreenAnalysis.analyze(raw, cacheDir,
                                    values.map { it.toInt() }.toIntArray(), mode, lumaInts.map { it.toInt() }.toIntArray(),
                                    lumaFloats.map { it.toDouble() }.toDoubleArray(), common.map { it.toInt() }.toIntArray(), cancelAnalysis,
                                    if (cacheAll) null else onFrame, if (cacheAll) false else pacePreview, targetFrame, cacheFrame)
                                check(!cancelAnalysis.get() && !isDestroyed) { "分析已取消" }
                                if (frameCache != null) {
                                    frameCaches.put(analysisId!!, frameCache)?.close()
                                    frameCache = null
                                }
                                runOnUiThread { result.success(data) }
                            } catch (e: Throwable) {
                                runOnUiThread { result.error("ANALYSIS", e.message ?: "录像分析失败", null) }
                            } finally { frameCache?.close(); analyzing.set(false) }
                        }
                    }
                }
                "remuxH264" -> {
                    val path = call.argument<String>("path")
                    val fps = call.argument<Number>("fps")?.toDouble()
                    if (path == null || fps == null) {
                        result.error("ARGUMENT", "需要 H.264 路径与帧率", null)
                    } else if (!converting.compareAndSet(false, true)) {
                        result.error("BUSY", "正在封装另一条录像", null)
                    } else videoJobs.execute {
                        try {
                            val raw = File(path).canonicalFile
                            val roots = listOfNotNull(filesDir, getExternalFilesDir(null))
                            require(roots.any { raw.path.startsWith(it.canonicalPath + File.separator) }) {
                                "仅允许处理应用日志目录内的文件"
                            }
                            val info = H264Remuxer.convert(raw, fps)
                            runOnUiThread { result.success(info) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("REMUX", e.message ?: "MP4 封装失败", null) }
                        } finally { converting.set(false) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onDestroy() {
        cancelAnalysis.set(true)
        analysisJobs.shutdownNow()
        frameCaches.values.forEach { it.close() }
        frameCaches.clear()
        shareJobs.shutdownNow()
        videoJobs.shutdownNow()
        callback?.let { connectivity.unregisterNetworkCallback(it) }
        if (boundWifi != null) connectivity.bindProcessToNetwork(null)
        super.onDestroy()
    }
}

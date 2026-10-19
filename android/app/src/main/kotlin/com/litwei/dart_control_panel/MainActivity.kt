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
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity() {
    private lateinit var connectivity: ConnectivityManager
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var boundWifi: Network? = null
    private var preferWifi = false
    private val videoJobs = Executors.newSingleThreadExecutor()
    private val converting = AtomicBoolean(false)
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
        shareJobs.shutdownNow()
        videoJobs.shutdownNow()
        callback?.let { connectivity.unregisterNetworkCallback(it) }
        if (boundWifi != null) connectivity.bindProcessToNetwork(null)
        super.onDestroy()
    }
}

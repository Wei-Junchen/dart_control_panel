package com.litwei.dart_control_panel

import java.io.File
import org.json.JSONObject
import kotlin.system.exitProcess

/** ADB-only test entry point; excluded from release, no exported Activity. */
object H264RemuxSmoke {
    @JvmStatic fun main(args: Array<String>) {
        try {
            require(args.size == 2) { "usage: INPUT.h264 FPS" }
            println(JSONObject(H264Remuxer.convert(File(args[0]), args[1].toDouble())).toString())
        } catch (e: Exception) {
            System.err.println(JSONObject(mapOf("error" to (e.message ?: e.toString()))).toString())
            exitProcess(1)
        }
    }
}

package com.hongda.starlink

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "hongda_starlink/android"
        private const val VPN_REQUEST_CODE = 8193
    }

    private var pendingVpnPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleMethodCall)
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDataDir" -> result.success(filesDir.absolutePath)
            "coreAvailable" -> result.success(HongdaCoreRuntime.available())
            "getCoreVersion" -> result.success(HongdaCoreRuntime.version(this))
            "prepareVpn" -> prepareVpn(result)
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> {
                startService(Intent(this, HongdaVpnService::class.java).apply {
                    action = HongdaVpnService.ACTION_STOP
                })
                result.success(null)
            }
            "getRuntimeStatus" -> result.success(HongdaVpnService.runtimeSnapshot())
            else -> result.notImplemented()
        }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingVpnPermission = result
        startActivityForResult(intent, VPN_REQUEST_CODE)
    }

    private fun startVpn(call: MethodCall, result: MethodChannel.Result) {
        val configPath = call.argument<String>("configPath").orEmpty()
        val nodeName = call.argument<String>("nodeName").orEmpty()
        if (!HongdaCoreRuntime.available()) {
            result.success(
                mapOf(
                    "ok" to false,
                    "code" to "core_missing",
                    "message" to "未找到 HongdaCore.aar；请先运行 tools/build-android-core.ps1。",
                ),
            )
            return
        }
        if (configPath.isBlank()) {
            result.success(mapOf("ok" to false, "code" to "config_missing", "message" to "Android 配置路径为空"))
            return
        }

        val intent = Intent(this, HongdaVpnService::class.java).apply {
            action = HongdaVpnService.ACTION_START
            putExtra(HongdaVpnService.EXTRA_CONFIG_PATH, configPath)
            putExtra(HongdaVpnService.EXTRA_NODE_NAME, nodeName)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)

        // Do not fake success: wait for the native core to report READY/error.
        Thread {
            val deadline = System.currentTimeMillis() + 12_000L
            var snapshot = HongdaVpnService.runtimeSnapshot()
            while (System.currentTimeMillis() < deadline) {
                snapshot = HongdaVpnService.runtimeSnapshot()
                if (snapshot["running"] == true || snapshot["lastError"] != null) break
                Thread.sleep(80)
            }
            val running = snapshot["running"] == true
            val error = snapshot["lastError"]?.toString()
            runOnUiThread {
                result.success(
                    mapOf(
                        "ok" to running,
                        "code" to if (running) "ready" else "core_start_failed",
                        "message" to if (running) "HongdaCore 已启动" else (error ?: "HongdaCore 启动超时"),
                        "coreVersion" to snapshot["coreVersion"],
                    ),
                )
            }
        }.start()
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return
        pendingVpnPermission?.success(resultCode == Activity.RESULT_OK)
        pendingVpnPermission = null
    }
}

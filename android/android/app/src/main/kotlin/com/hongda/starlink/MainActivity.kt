package com.hongda.starlink

import android.app.Activity
import android.content.Intent
import android.net.VpnService
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
            "coreAvailable" -> result.success(isLibboxAvailable())
            "prepareVpn" -> prepareVpn(result)
            "startVpn" -> startVpn(call, result)
            "stopVpn" -> {
                stopService(Intent(this, HongdaVpnService::class.java).apply {
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
        if (!isLibboxAvailable()) {
            result.success(
                mapOf(
                    "ok" to false,
                    "code" to "core_missing",
                    "message" to "Android libbox.aar 尚未打包；UI/订阅/节点功能可直接使用。"
                )
            )
            return
        }

        // The native service shell is ready, but the exact libbox API must match
        // the libbox.aar version you choose. Do not fake a successful connection.
        result.success(
            mapOf(
                "ok" to false,
                "code" to "libbox_bridge_pending",
                "message" to "已检测到 libbox.aar；请按所用 sing-box 版本接入 HongdaVpnService 后再启动 VPN。",
                "configPath" to configPath,
                "nodeName" to nodeName
            )
        )
    }

    private fun isLibboxAvailable(): Boolean {
        val candidates = arrayOf("libbox.Libbox", "io.nekohasekai.libbox.Libbox")
        return candidates.any { className ->
            try {
                Class.forName(className)
                true
            } catch (_: Throwable) {
                false
            }
        }
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return
        pendingVpnPermission?.success(resultCode == Activity.RESULT_OK)
        pendingVpnPermission = null
    }
}

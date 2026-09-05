package com.hongda.starlink

import android.content.Intent
import android.net.VpnService

/**
 * Native Android VPN service shell.
 *
 * The Windows project launches HongdaService.exe, which cannot run on Android.
 * Android must bind the sing-box mobile library (libbox.aar) to VpnService.
 * Runtime values are exposed to Flutter through MainActivity's MethodChannel.
 */
class HongdaVpnService : VpnService() {
    companion object {
        const val ACTION_STOP = "com.hongda.starlink.STOP_VPN"

        @Volatile private var running = false
        @Volatile private var uploadBytesPerSecond = 0.0
        @Volatile private var downloadBytesPerSecond = 0.0
        @Volatile private var activeConnections = 0

        fun runtimeSnapshot(): Map<String, Any> = mapOf(
            "running" to running,
            "uploadBytesPerSecond" to uploadBytesPerSecond,
            "downloadBytesPerSecond" to downloadBytesPerSecond,
            "activeConnections" to activeConnections
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopRuntime()
            stopSelf()
            return START_NOT_STICKY
        }
        // libbox integration intentionally lives here once libbox.aar is supplied.
        return START_NOT_STICKY
    }

    override fun onRevoke() {
        stopRuntime()
        stopSelf()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopRuntime()
        super.onDestroy()
    }

    private fun stopRuntime() {
        running = false
        uploadBytesPerSecond = 0.0
        downloadBytesPerSecond = 0.0
        activeConnections = 0
    }
}

package com.hongda.starlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import com.hongda.starlink.core.libbox.CommandServer
import com.hongda.starlink.core.libbox.CommandServerHandler
import com.hongda.starlink.core.libbox.ConnectionOwner
import com.hongda.starlink.core.libbox.InterfaceUpdateListener
import com.hongda.starlink.core.libbox.Libbox
import com.hongda.starlink.core.libbox.LocalDNSTransport
import com.hongda.starlink.core.libbox.NetworkInterfaceIterator
import com.hongda.starlink.core.libbox.Notification as CoreNotification
import com.hongda.starlink.core.libbox.OverrideOptions
import com.hongda.starlink.core.libbox.PlatformInterface
import com.hongda.starlink.core.libbox.StringIterator
import com.hongda.starlink.core.libbox.SystemProxyStatus
import com.hongda.starlink.core.libbox.TunOptions
import com.hongda.starlink.core.libbox.WIFIState
import com.hongda.starlink.core.libbox.NetworkInterface as CoreNetworkInterface
import java.io.File
import java.net.Inet6Address
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.security.KeyStore
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Android runtime equivalent of Windows HongdaService.exe.
 *
 * It owns VpnService/TUN and drives HongdaCore.aar (sing-box libbox) in-process.
 */
class HongdaVpnService : VpnService(), CommandServerHandler, PlatformInterface {
    companion object {
        const val ACTION_START = "com.hongda.starlink.START_VPN"
        const val ACTION_STOP = "com.hongda.starlink.STOP_VPN"
        const val EXTRA_CONFIG_PATH = "configPath"
        const val EXTRA_NODE_NAME = "nodeName"

        private const val TAG = "HongdaVpnService"
        private const val CHANNEL_ID = "hongda_vpn"
        private const val NOTIFICATION_ID = 164

        @Volatile private var running = false
        @Volatile private var starting = false
        @Volatile private var lastError: String? = null
        @Volatile private var coreVersion: String? = null
        @Volatile private var nodeName: String = ""

        fun runtimeSnapshot(): Map<String, Any?> = mapOf(
            "running" to running,
            "starting" to starting,
            "lastError" to lastError,
            "coreVersion" to coreVersion,
            "nodeName" to nodeName,
        )
    }

    private lateinit var worker: ExecutorService
    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var currentConfig: String? = null
    private var currentConfigPath: String? = null

    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private var defaultInterfaceListener: InterfaceUpdateListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onCreate() {
        super.onCreate()
        worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "HongdaCoreWorker").apply { isDaemon = true }
        }
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                worker.execute {
                    stopRuntime("用户断开")
                    stopSelf()
                }
                return START_NOT_STICKY
            }
            else -> {
                val configPath = intent?.getStringExtra(EXTRA_CONFIG_PATH).orEmpty()
                val requestedNode = intent?.getStringExtra(EXTRA_NODE_NAME).orEmpty()
                startForeground(NOTIFICATION_ID, buildNotification("正在连接${if (requestedNode.isBlank()) "" else " · $requestedNode"}"))
                if (configPath.isBlank()) {
                    lastError = "缺少 Android 运行配置路径"
                    starting = false
                    running = false
                    updateNotification("启动失败")
                    return START_NOT_STICKY
                }
                worker.execute { startRuntime(configPath, requestedNode) }
                return START_STICKY
            }
        }
    }

    private fun startRuntime(configPath: String, requestedNode: String) {
        starting = true
        running = false
        lastError = null
        nodeName = requestedNode
        try {
            HongdaCoreRuntime.ensureInitialized(this)
            coreVersion = Libbox.version()
            val config = File(configPath).readText()
            if (config.isBlank()) error("Android sing-box 配置为空")
            Libbox.checkConfig(config)

            closeCoreOnly()
            currentConfig = config
            currentConfigPath = configPath

            val server = CommandServer(this, this)
            commandServer = server
            server.start()
            server.startOrReloadService(config, OverrideOptions())

            running = true
            starting = false
            lastError = null
            updateNotification("已连接${if (requestedNode.isBlank()) "" else " · $requestedNode"}")
            Log.i(TAG, "HongdaCore READY ${coreVersion.orEmpty()}")
        } catch (t: Throwable) {
            Log.e(TAG, "startRuntime", t)
            lastError = t.message ?: t.javaClass.simpleName
            running = false
            starting = false
            closeCoreOnly()
            updateNotification("连接失败")
        }
    }

    private fun reloadRuntime() {
        val content = currentConfig ?: return
        try {
            commandServer?.startOrReloadService(content, OverrideOptions())
        } catch (t: Throwable) {
            lastError = t.message ?: t.javaClass.simpleName
            Log.e(TAG, "reloadRuntime", t)
        }
    }

    private fun stopRuntime(reason: String) {
        Log.i(TAG, "stopRuntime: $reason")
        running = false
        starting = false
        closeCoreOnly()
        currentConfig = null
        currentConfigPath = null
        nodeName = ""
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    private fun closeCoreOnly() {
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
        val server = commandServer
        commandServer = null
        if (server != null) {
            runCatching { server.closeService() }
                .onFailure { runCatching { server.setError("android: close service: ${it.message}") } }
            runCatching { server.close() }
        }
        unregisterDefaultNetworkMonitor()
    }

    override fun onRevoke() {
        worker.execute {
            lastError = "Android VPN 权限已被系统撤销"
            stopRuntime("权限撤销")
            stopSelf()
        }
        super.onRevoke()
    }

    override fun onDestroy() {
        stopRuntime("Service 销毁")
        if (::worker.isInitialized) worker.shutdownNow()
        super.onDestroy()
    }

    // ---- CommandServerHandler ----

    override fun serviceStop() {
        worker.execute { stopRuntime("Core 请求停止") }
    }

    override fun serviceReload() {
        worker.execute { reloadRuntime() }
    }

    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        available = false
        enabled = false
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) {
        // Android TUN does not need the Windows system-proxy switch.
    }

    override fun writeDebugMessage(message: String?) {
        if (!message.isNullOrBlank()) Log.d(TAG, message)
    }

    // ---- PlatformInterface ----

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) error("android: protect outbound socket failed")
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("鸿达星轨智连")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val route = inet4Address.next()
            builder.addAddress(route.address(), route.prefix())
        }
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val route = inet6Address.next()
            builder.addAddress(route.address(), route.prefix())
        }

        if (options.autoRoute) {
            val dns = runCatching { options.dnsServerAddress.value }.getOrNull().orEmpty()
            if (dns.isNotBlank()) builder.addDnsServer(dns)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val v4Routes = options.inet4RouteAddress
                while (v4Routes.hasNext()) builder.addRoute(IpPrefix(v4Routes.next().string()))
                val v6Routes = options.inet6RouteAddress
                while (v6Routes.hasNext()) builder.addRoute(IpPrefix(v6Routes.next().string()))

                val v4Excluded = options.inet4RouteExcludeAddress
                while (v4Excluded.hasNext()) builder.excludeRoute(IpPrefix(v4Excluded.next().string()))
                val v6Excluded = options.inet6RouteExcludeAddress
                while (v6Excluded.hasNext()) builder.excludeRoute(IpPrefix(v6Excluded.next().string()))
            } else {
                val v4Routes = options.inet4RouteRange
                while (v4Routes.hasNext()) {
                    val route = v4Routes.next()
                    builder.addRoute(route.address(), route.prefix())
                }
                val v6Routes = options.inet6RouteRange
                while (v6Routes.hasNext()) {
                    val route = v6Routes.next()
                    builder.addRoute(route.address(), route.prefix())
                }
            }

            val includePackages = options.includePackage
            while (includePackages.hasNext()) {
                try {
                    builder.addAllowedApplication(includePackages.next())
                } catch (e: NameNotFoundException) {
                    Log.w(TAG, "include package missing", e)
                }
            }
            val excludePackages = options.excludePackage
            while (excludePackages.hasNext()) {
                try {
                    builder.addDisallowedApplication(excludePackages.next())
                } catch (e: NameNotFoundException) {
                    Log.w(TAG, "exclude package missing", e)
                }
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer,
                    options.httpProxyServerPort,
                    options.httpProxyBypassDomain.toKotlinList(),
                ),
            )
        }

        tunDescriptor?.close()
        val pfd = builder.establish() ?: error("android: VpnService.Builder.establish failed")
        tunDescriptor = pfd
        return pfd.fd
    }

    override fun useProcFS(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String?,
        sourcePort: Int,
        destinationAddress: String?,
        destinationPort: Int,
    ): ConnectionOwner {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("android: connection owner unavailable below API 29")
        val source = InetSocketAddress(sourceAddress.orEmpty(), sourcePort)
        val destination = InetSocketAddress(destinationAddress.orEmpty(), destinationPort)
        val uid = connectivity.getConnectionOwnerUid(ipProtocol, source, destination)
        if (uid < 0) error("android: connection owner not found")
        val packages = packageManager.getPackagesForUid(uid)?.toList().orEmpty()
        return ConnectionOwner().apply {
            userId = uid
            userName = packages.firstOrNull().orEmpty()
            setAndroidPackageNames(HongdaStringIterator(packages.iterator()))
        }
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        defaultInterfaceListener = listener
        unregisterDefaultNetworkMonitor(clearListener = false)
        if (listener == null) return

        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = notifyDefaultInterface(network)
            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) = notifyDefaultInterface(network)
            override fun onLost(network: Network) {
                defaultInterfaceListener?.updateDefaultInterface("", -1, false, false)
            }
        }
        networkCallback = callback
        connectivity.registerNetworkCallback(request, callback)
        connectivity.allNetworks.firstOrNull { network ->
            connectivity.getNetworkCapabilities(network)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) == true
        }?.let(::notifyDefaultInterface)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        unregisterDefaultNetworkMonitor()
    }

    private fun unregisterDefaultNetworkMonitor(clearListener: Boolean = true) {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
        if (clearListener) defaultInterfaceListener = null
    }

    private fun notifyDefaultInterface(network: Network) {
        val listener = defaultInterfaceListener ?: return
        val link = connectivity.getLinkProperties(network) ?: return
        val name = link.interfaceName ?: return
        val javaInterface = runCatching { NetworkInterface.getByName(name) }.getOrNull() ?: return
        val capabilities = connectivity.getNetworkCapabilities(network)
        val expensive = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        listener.updateDefaultInterface(name, javaInterface.index, expensive, false)
    }

    override fun getInterfaces(): NetworkInterfaceIterator {
        val javaInterfaces = NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        val result = mutableListOf<CoreNetworkInterface>()
        for (network in connectivity.allNetworks) {
            val link = connectivity.getLinkProperties(network) ?: continue
            val capabilities = connectivity.getNetworkCapabilities(network) ?: continue
            val name = link.interfaceName ?: continue
            val javaInterface = javaInterfaces.firstOrNull { it.name == name } ?: continue
            val item = CoreNetworkInterface().apply {
                this.name = name
                index = javaInterface.index
                mtu = runCatching { javaInterface.mtu }.getOrDefault(1500)
                addresses = HongdaStringIterator(javaInterface.interfaceAddresses.map { it.toPrefix() }.iterator())
                dnsServer = HongdaStringIterator(link.dnsServers.mapNotNull { it.hostAddress }.iterator())
                type = when {
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
                var currentFlags = 0
                if (javaInterface.isUp) currentFlags = currentFlags or OsConstants.IFF_UP or OsConstants.IFF_RUNNING
                if (javaInterface.isLoopback) currentFlags = currentFlags or OsConstants.IFF_LOOPBACK
                if (javaInterface.isPointToPoint) currentFlags = currentFlags or OsConstants.IFF_POINTOPOINT
                if (javaInterface.supportsMulticast()) currentFlags = currentFlags or OsConstants.IFF_MULTICAST
                flags = currentFlags
                metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            }
            result.add(item)
        }
        return HongdaNetworkInterfaceIterator(result.iterator())
    }

    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() = Unit

    override fun readWIFIState(): WIFIState? = runCatching {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
        @Suppress("DEPRECATION") val info = wifi.connectionInfo ?: return@runCatching null
        var ssid = info.ssid.orEmpty()
        if (ssid == "<unknown ssid>") return@runCatching null
        if (ssid.startsWith('"') && ssid.endsWith('"') && ssid.length > 1) ssid = ssid.substring(1, ssid.length - 1)
        WIFIState(ssid, info.bssid.orEmpty())
    }.getOrNull()

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun systemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        runCatching {
            val keyStore = KeyStore.getInstance("AndroidCAStore")
            keyStore.load(null, null)
            val aliases = keyStore.aliases()
            while (aliases.hasMoreElements()) {
                val cert = keyStore.getCertificate(aliases.nextElement()) ?: continue
                val encoded = Base64.encodeToString(cert.encoded, Base64.NO_WRAP)
                certificates += "-----BEGIN CERTIFICATE-----\n$encoded\n-----END CERTIFICATE-----"
            }
        }.onFailure { Log.w(TAG, "read Android CA store", it) }
        return HongdaStringIterator(certificates.iterator())
    }

    override fun sendNotification(notification: CoreNotification?) {
        val body = notification?.body?.takeIf { it.isNotBlank() }
            ?: notification?.title?.takeIf { it.isNotBlank() }
            ?: return
        updateNotification(body)
    }

    // ---- Android notification ----

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "鸿达星轨智连 VPN", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("鸿达星轨智连")
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }

    private class HongdaStringIterator(private val iterator: Iterator<String>) : StringIterator {
        override fun len(): Int = 0
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): String = iterator.next()
    }

    private class HongdaNetworkInterfaceIterator(
        private val iterator: Iterator<CoreNetworkInterface>,
    ) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()
        override fun next(): CoreNetworkInterface = iterator.next()
    }

    private fun StringIterator.toKotlinList(): List<String> {
        val values = mutableListOf<String>()
        while (hasNext()) values += next()
        return values
    }

    private fun InterfaceAddress.toPrefix(): String = if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }
}

package com.hongda.starlink

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.DnsResolver
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.OsConstants
import android.util.Base64
import android.util.Log
import com.hongda.starlink.core.libbox.CommandServer
import com.hongda.starlink.core.libbox.CommandServerHandler
import com.hongda.starlink.core.libbox.ConnectionOwner
import com.hongda.starlink.core.libbox.ExchangeContext
import com.hongda.starlink.core.libbox.Func
import com.hongda.starlink.core.libbox.InterfaceUpdateListener
import com.hongda.starlink.core.libbox.Libbox
import com.hongda.starlink.core.libbox.LocalDNSTransport
import com.hongda.starlink.core.libbox.NetworkInterfaceIterator
import com.hongda.starlink.core.libbox.Notification as CoreNotification
import com.hongda.starlink.core.libbox.OverrideOptions
import com.hongda.starlink.core.libbox.PlatformInterface
import com.hongda.starlink.core.libbox.RoutePrefix
import com.hongda.starlink.core.libbox.StringIterator
import com.hongda.starlink.core.libbox.SystemProxyStatus
import com.hongda.starlink.core.libbox.TunOptions
import com.hongda.starlink.core.libbox.WIFIState
import com.hongda.starlink.core.libbox.NetworkInterface as CoreNetworkInterface
import java.io.File
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.net.UnknownHostException
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

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
        @Volatile private var tunEstablished = false
        @Volatile private var tunDns: String = ""
        @Volatile private var tunRouteV4Count = 0
        @Volatile private var tunRouteV6Count = 0
        @Volatile private var defaultInterfaceName: String = ""
        @Volatile private var physicalDnsServers: String = ""
        @Volatile private var physicalNetworkType: String = ""
        @Volatile private var lastDnsEvent: String = ""
        @Volatile private var lastDnsError: String? = null
        @Volatile private var dnsQueryCount: Long = 0
        @Volatile private var protectedSocketCount: Long = 0
        @Volatile private var vpnCaptureMode: String = "GLOBAL"
        @Volatile private var vpnAppliedRoutes: String = ""
        @Volatile private var coreRequestedRoutes: String = ""
        @Volatile private var coreRequestedIncludePackages: String = ""
        @Volatile private var coreRequestedExcludePackages: String = ""
        @Volatile private var lastNativeEvent: String = ""

        fun runtimeSnapshot(): Map<String, Any?> = mapOf(
            "running" to running,
            "starting" to starting,
            "lastError" to lastError,
            "coreVersion" to coreVersion,
            "nodeName" to nodeName,
            "tunEstablished" to tunEstablished,
            "tunDns" to tunDns,
            "tunRouteV4Count" to tunRouteV4Count,
            "tunRouteV6Count" to tunRouteV6Count,
            "defaultInterface" to defaultInterfaceName,
            "physicalDns" to physicalDnsServers,
            "physicalNetworkType" to physicalNetworkType,
            "lastDnsEvent" to lastDnsEvent,
            "lastDnsError" to lastDnsError,
            "dnsQueryCount" to dnsQueryCount,
            "protectedSocketCount" to protectedSocketCount,
            "vpnCaptureMode" to vpnCaptureMode,
            "vpnAppliedRoutes" to vpnAppliedRoutes,
            "coreRequestedRoutes" to coreRequestedRoutes,
            "coreRequestedIncludePackages" to coreRequestedIncludePackages,
            "coreRequestedExcludePackages" to coreRequestedExcludePackages,
            "lastNativeEvent" to lastNativeEvent,
        )
    }

    private lateinit var worker: ExecutorService
    private lateinit var dnsExecutor: ExecutorService
    private var commandServer: CommandServer? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private var currentConfig: String? = null
    private var currentConfigPath: String? = null

    private val connectivity by lazy {
        getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    }
    private var defaultInterfaceListener: InterfaceUpdateListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var underlyingNetwork: Network? = null

    override fun onCreate() {
        super.onCreate()
        worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "HongdaCoreWorker").apply { isDaemon = true }
        }
        dnsExecutor = Executors.newCachedThreadPool { runnable ->
            Thread(runnable, "HongdaDns").apply { isDaemon = true }
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
            captureUnderlyingNetwork()
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

            if (!tunEstablished) error("android: core started but TUN was not established")
            running = true
            starting = false
            lastError = null
            lastNativeEvent = "READY tun=$tunEstablished v4Routes=$tunRouteV4Count v6Routes=$tunRouteV6Count dns=$tunDns if=$defaultInterfaceName"
            updateNotification("已连接${if (requestedNode.isBlank()) "" else " · $requestedNode"}")
            Log.i(TAG, "HongdaCore READY ${coreVersion.orEmpty()} · $lastNativeEvent")
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
        tunEstablished = false
        tunDns = ""
        tunRouteV4Count = 0
        tunRouteV6Count = 0
        vpnAppliedRoutes = ""
        coreRequestedRoutes = ""
        coreRequestedIncludePackages = ""
        coreRequestedExcludePackages = ""
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
        if (::dnsExecutor.isInitialized) dnsExecutor.shutdownNow()
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
        protectedSocketCount++
        if (protectedSocketCount <= 3L) {
            Log.d(TAG, "protected outbound socket fd=$fd count=$protectedSocketCount")
        }
    }

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")

        val builder = Builder()
            .setSession("鸿达星轨智连")
            .setMtu(options.mtu)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        var hasInet4 = false
        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val route = inet4Address.next()
            builder.addAddress(route.address(), route.prefix())
            hasInet4 = true
        }
        var hasInet6 = false
        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val route = inet6Address.next()
            builder.addAddress(route.address(), route.prefix())
            hasInet6 = true
        }

        var v4RouteCount = 0
        var v6RouteCount = 0
        var dnsAddress = ""

        if (options.autoRoute) {
            dnsAddress = runCatching { options.dnsServerAddress.value }.getOrNull().orEmpty()
            if (dnsAddress.isNotBlank()) builder.addDnsServer(dnsAddress)

            // R8: this application currently exposes only a whole-device VPN mode.
            // Do not let libbox route-prefix/package overrides accidentally turn the
            // Android VpnService into a partial/per-app VPN. All eligible IPv4/IPv6
            // application traffic is captured here; direct/LAN/proxy decisions remain
            // sing-box route rules inside the TUN.
            val requestedV4 = mutableListOf<String>()
            val requestedV6 = mutableListOf<String>()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val coreV4 = options.inet4RouteAddress
                while (coreV4.hasNext()) {
                    val route = coreV4.next()
                    requestedV4 += "${route.address()}/${route.prefix()}"
                }
                val coreV6 = options.inet6RouteAddress
                while (coreV6.hasNext()) {
                    val route = coreV6.next()
                    requestedV6 += "${route.address()}/${route.prefix()}"
                }
                // Drain route excludes for diagnostics only. Whole-device capture must
                // not bypass arbitrary destinations at the VpnService layer.
                val excludedV4 = options.inet4RouteExcludeAddress
                while (excludedV4.hasNext()) {
                    val route = excludedV4.next()
                    requestedV4 += "!${route.address()}/${route.prefix()}"
                }
                val excludedV6 = options.inet6RouteExcludeAddress
                while (excludedV6.hasNext()) {
                    val route = excludedV6.next()
                    requestedV6 += "!${route.address()}/${route.prefix()}"
                }
            } else {
                val coreV4 = options.inet4RouteRange
                while (coreV4.hasNext()) {
                    val route = coreV4.next()
                    requestedV4 += "${route.address()}/${route.prefix()}"
                }
                val coreV6 = options.inet6RouteRange
                while (coreV6.hasNext()) {
                    val route = coreV6.next()
                    requestedV6 += "${route.address()}/${route.prefix()}"
                }
            }
            coreRequestedRoutes = (requestedV4 + requestedV6).joinToString(",")

            if (hasInet4) {
                builder.addRoute("0.0.0.0", 0)
                v4RouteCount = 1
            }
            if (hasInet6) {
                builder.addRoute("::", 0)
                v6RouteCount = 1
            }
            vpnAppliedRoutes = buildList {
                if (hasInet4) add("0.0.0.0/0")
                if (hasInet6) add("::/0")
            }.joinToString(",")

            // Drain package filters but deliberately do not apply them. Empty
            // Builder allow/disallow lists mean Android captures every application.
            val requestedInclude = mutableListOf<String>()
            val includePackages = options.includePackage
            while (includePackages.hasNext()) requestedInclude += includePackages.next()
            val requestedExclude = mutableListOf<String>()
            val excludePackages = options.excludePackage
            while (excludePackages.hasNext()) requestedExclude += excludePackages.next()
            coreRequestedIncludePackages = requestedInclude.joinToString(",")
            coreRequestedExcludePackages = requestedExclude.joinToString(",")
            vpnCaptureMode = "GLOBAL"

            Log.i(
                TAG,
                "VPN capture GLOBAL routes=$vpnAppliedRoutes coreRoutes=$coreRequestedRoutes " +
                    "ignoredInclude=$coreRequestedIncludePackages ignoredExclude=$coreRequestedExcludePackages",
            )
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
        tunEstablished = true
        tunDns = dnsAddress
        tunRouteV4Count = v4RouteCount
        tunRouteV6Count = v6RouteCount
        lastNativeEvent = "TUN established mtu=${options.mtu} v4Routes=$v4RouteCount v6Routes=$v6RouteCount dns=$dnsAddress capture=$vpnCaptureMode routes=$vpnAppliedRoutes"
        Log.i(TAG, lastNativeEvent)
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

        // Follow sing-box-for-android's default-network strategy instead of a
        // generic registerNetworkCallback listener. A generic listener can see
        // multiple physical networks and the last callback wins, which can make
        // DNS/outbound resolution use a non-default or stale network after the
        // VPN becomes active.
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (isUsablePhysicalNetwork(network)) {
                    underlyingNetwork = network
                    notifyDefaultInterface(network)
                }
            }

            override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                if (isUsablePhysicalNetwork(network)) {
                    underlyingNetwork = network
                    notifyDefaultInterface(network)
                }
            }

            override fun onLost(network: Network) {
                if (underlyingNetwork == network) {
                    underlyingNetwork = findUnderlyingNetwork()
                    underlyingNetwork?.let(::notifyDefaultInterface)
                        ?: defaultInterfaceListener?.updateDefaultInterface("", -1, false, false)
                }
            }
        }
        networkCallback = callback
        val handler = Handler(Looper.getMainLooper())
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
                    connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.P -> {
                    connectivity.requestNetwork(request, callback, handler)
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    connectivity.registerDefaultNetworkCallback(callback, handler)
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N -> {
                    connectivity.registerDefaultNetworkCallback(callback)
                }
                else -> {
                    connectivity.requestNetwork(request, callback)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "default network callback fallback", t)
            runCatching { connectivity.registerNetworkCallback(request, callback) }
                .onFailure { Log.e(TAG, "register physical network callback", it) }
        }

        captureUnderlyingNetwork()
        underlyingNetwork?.let(::notifyDefaultInterface)
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener?) {
        unregisterDefaultNetworkMonitor()
    }

    private fun unregisterDefaultNetworkMonitor(clearListener: Boolean = true) {
        networkCallback?.let { runCatching { connectivity.unregisterNetworkCallback(it) } }
        networkCallback = null
        if (clearListener) defaultInterfaceListener = null
    }

    private fun isUsablePhysicalNetwork(network: Network): Boolean {
        val caps = connectivity.getNetworkCapabilities(network) ?: return false
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) return false
        return true
    }

    private fun physicalNetworkScore(network: Network): Int {
        val caps = connectivity.getNetworkCapabilities(network) ?: return Int.MIN_VALUE
        if (!isUsablePhysicalNetwork(network)) return Int.MIN_VALUE
        var score = 0
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || connectivity.activeNetwork == network) score += 1000
        if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) score += 300
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) score += 90
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) score += 80
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) score += 70
        if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)) score += 10
        return score
    }

    private fun findUnderlyingNetwork(): Network? = connectivity.allNetworks
        .filter(::isUsablePhysicalNetwork)
        .maxByOrNull(::physicalNetworkScore)

    private fun captureUnderlyingNetwork() {
        val active = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) connectivity.activeNetwork else null
        underlyingNetwork = if (active != null && isUsablePhysicalNetwork(active)) {
            active
        } else {
            val existing = underlyingNetwork
            if (existing != null && isUsablePhysicalNetwork(existing)) existing else findUnderlyingNetwork()
        }
        underlyingNetwork?.let(::recordUnderlyingNetwork)
    }

    private fun requireUnderlyingNetwork(): Network {
        val current = underlyingNetwork
        if (current != null && isUsablePhysicalNetwork(current)) return current
        val replacement = findUnderlyingNetwork() ?: error("android: missing physical default network")
        underlyingNetwork = replacement
        recordUnderlyingNetwork(replacement)
        return replacement
    }

    private fun recordUnderlyingNetwork(network: Network) {
        val link = connectivity.getLinkProperties(network) ?: return
        val caps = connectivity.getNetworkCapabilities(network)
        defaultInterfaceName = link.interfaceName.orEmpty()
        physicalDnsServers = link.dnsServers.mapNotNull { it.hostAddress }.joinToString(",")
        physicalNetworkType = when {
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true -> "WIFI"
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "CELLULAR"
            caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "ETHERNET"
            else -> "OTHER"
        }
        // Explicitly tell Android which physical network backs this VPN. This
        // does not replace protect(fd), but avoids the platform treating the VPN
        // itself as the preferred transport for VPN-owned DNS/outbound work.
        runCatching { setUnderlyingNetworks(arrayOf(network)) }
            .onFailure { Log.d(TAG, "setUnderlyingNetworks: ${it.message}") }
    }

    private fun notifyDefaultInterface(network: Network) {
        val listener = defaultInterfaceListener ?: return
        val link = connectivity.getLinkProperties(network) ?: return
        val name = link.interfaceName ?: return
        val javaInterface = runCatching { NetworkInterface.getByName(name) }.getOrNull() ?: return
        val capabilities = connectivity.getNetworkCapabilities(network)
        val expensive = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false
        underlyingNetwork = network
        recordUnderlyingNetwork(network)
        lastNativeEvent = "physical interface=$name index=${javaInterface.index} type=$physicalNetworkType dns=$physicalDnsServers"
        Log.i(TAG, lastNativeEvent)
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

    override fun localDNSTransport(): LocalDNSTransport = HongdaLocalResolver()

    private inner class HongdaLocalResolver : LocalDNSTransport {
        override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

        override fun exchange(ctx: ExchangeContext, message: ByteArray) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("android: raw DNS requires API 29")
            val network = requireUnderlyingNetwork()
            dnsQueryCount++
            lastDnsError = null
            val signal = CancellationSignal()
            ctx.onCancel(object : Func {
                override fun invoke() { signal.cancel() }
            })
            val latch = CountDownLatch(1)
            var callbackError: Throwable? = null
            DnsResolver.getInstance().rawQuery(
                network,
                message,
                DnsResolver.FLAG_NO_RETRY,
                dnsExecutor,
                signal,
                object : DnsResolver.Callback<ByteArray> {
                    override fun onAnswer(answer: ByteArray, rcode: Int) {
                        if (rcode == 0) {
                            ctx.rawSuccess(answer)
                            lastDnsEvent = "raw DNS ok via $defaultInterfaceName bytes=${answer.size}"
                            lastDnsError = null
                        } else {
                            ctx.errorCode(rcode)
                            lastDnsError = "raw DNS rcode=$rcode via $defaultInterfaceName"
                        }
                        latch.countDown()
                    }

                    override fun onError(error: DnsResolver.DnsException) {
                        val cause = error.cause
                        if (cause is ErrnoException) ctx.errnoCode(cause.errno) else callbackError = error
                        lastDnsError = "raw DNS error via $defaultInterfaceName: ${error.message}"
                        latch.countDown()
                    }
                },
            )
            if (!latch.await(8, TimeUnit.SECONDS)) {
                signal.cancel()
                lastDnsError = "raw DNS timeout via $defaultInterfaceName"
                error("android: DNS raw query timeout")
            }
            callbackError?.let { throw it }
        }

        override fun lookup(ctx: ExchangeContext, networkType: String, domain: String) {
            val network = requireUnderlyingNetwork()
            dnsQueryCount++
            lastDnsError = null
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                try {
                    val answer = network.getAllByName(domain).mapNotNull { it.hostAddress }
                    ctx.success(answer.joinToString("\n"))
                    lastDnsEvent = "DNS ok $domain -> ${answer.take(2).joinToString(",")} via $defaultInterfaceName"
                } catch (_: UnknownHostException) {
                    ctx.errorCode(3) // NXDOMAIN
                    lastDnsError = "DNS NXDOMAIN $domain via $defaultInterfaceName"
                }
                return
            }

            val signal = CancellationSignal()
            ctx.onCancel(object : Func {
                override fun invoke() { signal.cancel() }
            })
            val latch = CountDownLatch(1)
            var callbackError: Throwable? = null
            val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
                override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                    if (rcode == 0) {
                        val addresses = answer.mapNotNull { it.hostAddress }
                        ctx.success(addresses.joinToString("\n"))
                        lastDnsEvent = "DNS ok $domain -> ${addresses.take(2).joinToString(",")} via $defaultInterfaceName"
                        lastDnsError = null
                    } else {
                        ctx.errorCode(rcode)
                        lastDnsError = "DNS rcode=$rcode $domain via $defaultInterfaceName"
                    }
                    latch.countDown()
                }

                override fun onError(error: DnsResolver.DnsException) {
                    val cause = error.cause
                    if (cause is ErrnoException) ctx.errnoCode(cause.errno) else callbackError = error
                    lastDnsError = "DNS error $domain via $defaultInterfaceName: ${error.message}"
                    latch.countDown()
                }
            }
            val type = when {
                networkType.endsWith("4") -> DnsResolver.TYPE_A
                networkType.endsWith("6") -> DnsResolver.TYPE_AAAA
                else -> null
            }
            if (type == null) {
                DnsResolver.getInstance().query(network, domain, DnsResolver.FLAG_NO_RETRY, dnsExecutor, signal, callback)
            } else {
                DnsResolver.getInstance().query(network, domain, type, DnsResolver.FLAG_NO_RETRY, dnsExecutor, signal, callback)
            }
            if (!latch.await(8, TimeUnit.SECONDS)) {
                signal.cancel()
                lastDnsError = "DNS timeout $domain via $defaultInterfaceName"
                error("android: DNS lookup timeout for $domain")
            }
            callbackError?.let { throw it }
        }
    }

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

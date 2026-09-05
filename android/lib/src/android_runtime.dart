import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'singbox_config_builder.dart';
import 'storage.dart';

enum AndroidConnectionStatus { stopped, preparing, running, stopping, error }

class AndroidPlatformBridge {
  static const MethodChannel _channel = MethodChannel(
    'hongda_starlink/android',
  );

  static Future<String?> getDataDirectory() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getDataDir');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> coreAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('coreAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> coreVersion() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('getCoreVersion');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> prepareVpn() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('prepareVpn') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<Map<String, dynamic>> startVpn({
    required String configPath,
    required String nodeName,
  }) async {
    if (!Platform.isAndroid) {
      return <String, dynamic>{'ok': false, 'message': '当前平台不是 Android'};
    }
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'startVpn',
        <String, dynamic>{'configPath': configPath, 'nodeName': nodeName},
      );
      return value ??
          <String, dynamic>{'ok': false, 'message': 'Android VPN Bridge 未返回结果'};
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'ok': false,
        'message': e.message ?? e.code,
        'code': e.code,
      };
    } catch (e) {
      return <String, dynamic>{'ok': false, 'message': e.toString()};
    }
  }

  static Future<void> stopVpn() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('stopVpn');
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> runtimeStatus() async {
    if (!Platform.isAndroid) return const <String, dynamic>{};
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'getRuntimeStatus',
      );
      return value ?? const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }
}

class AndroidRuntimeController extends ChangeNotifier {
  AndroidRuntimeController({required this.storage, required this.trafficStats});

  final AppStorage storage;
  final TrafficStats trafficStats;
  final Set<String> testingNodeIds = <String>{};
  final List<String> logs = <String>[];

  AndroidConnectionStatus status = AndroidConnectionStatus.stopped;
  DateTime? connectedAt;
  String? lastError;
  bool coreAvailable = false;
  String? coreVersion;
  double uploadBytesPerSecond = 0;
  double downloadBytesPerSecond = 0;
  int totalUploadBytes = 0;
  int totalDownloadBytes = 0;
  int activeConnections = 0;

  Timer? _statusTimer;
  Timer? _apiTimer;
  Timer? _persistTimer;
  Timer? _trafficReconnectTimer;
  WebSocket? _trafficSocket;
  DateTime? _lastTrafficSampleAt;
  int _metricsGeneration = 0;

  bool get isRunning => status == AndroidConnectionStatus.running;
  int get totalTrafficBytes => totalUploadBytes + totalDownloadBytes;
  int get lifetimeTrafficBytes => trafficStats.totalBytes;

  Future<void> initialize({required AppSettings settings}) async {
    coreAvailable = await AndroidPlatformBridge.coreAvailable();
    coreVersion = coreAvailable
        ? await AndroidPlatformBridge.coreVersion()
        : null;
    _appendLog(
      coreAvailable
          ? 'HongdaCore 已加载${coreVersion == null ? '' : ' · $coreVersion'}'
          : 'HongdaCore.aar 未打包；请先构建 Android Core',
    );
    if (coreAvailable) {
      final native = await AndroidPlatformBridge.runtimeStatus();
      if (native['running'] == true && native['tunEstablished'] == true) {
        final startedAt = int.tryParse(
          native['startedAtMillis']?.toString() ?? '',
        );
        status = AndroidConnectionStatus.running;
        connectedAt = startedAt != null && startedAt > 0
            ? DateTime.fromMillisecondsSinceEpoch(startedAt)
            : DateTime.now();
        coreVersion = native['coreVersion']?.toString() ?? coreVersion;
        _appendLog(
          '已恢复运行中的 HongdaVpnService${native['nodeName']?.toString().isNotEmpty == true ? ' · ${native['nodeName']}' : ''}',
        );
        _startRuntimePolling();
        _startMetrics(settings);
        _startTrafficPersistence();
      }
    }
    notifyListeners();
  }

  Future<void> start({
    required NodeProfile node,
    required AppSettings settings,
    required List<NodeProfile> nodes,
    required List<ProxyGroupProfile> groups,
    required List<RouteRuleProfile> rules,
  }) async {
    if (status == AndroidConnectionStatus.preparing || isRunning) return;
    lastError = null;
    status = AndroidConnectionStatus.preparing;
    notifyListeners();

    try {
      coreAvailable = await AndroidPlatformBridge.coreAvailable();
      if (!coreAvailable) {
        throw StateError(
          '未找到 HongdaCore.aar；请先运行 tools/build-android-core.ps1。',
        );
      }

      final prepared = await AndroidPlatformBridge.prepareVpn();
      if (!prepared) throw StateError('未获得 Android VPN 授权');

      final preferredMixedPort = settings.mixedPort;
      final preferredApiPort = settings.apiPort;
      settings.mixedPort = await _findAvailablePort(preferredMixedPort, fallback: 7890);
      settings.apiPort = await _findAvailablePort(
        preferredApiPort,
        fallback: 9090,
        reserved: <int>{settings.mixedPort},
      );
      if (preferredMixedPort != settings.mixedPort || preferredApiPort != settings.apiPort) {
        await storage.saveSettings(settings);
        _appendLog('端口自动避让：Mixed $preferredMixedPort -> ${settings.mixedPort}，API $preferredApiPort -> ${settings.apiPort}');
      }

      final config = SingBoxConfigBuilder(storage).build(
        selectedNode: node,
        nodes: nodes,
        groups: groups,
        rules: rules,
        settings: settings,
        androidMode: true,
      );
      final configFile = await storage.writeRuntimeConfig(config);
      final result = await AndroidPlatformBridge.startVpn(
        configPath: configFile.path,
        nodeName: node.name,
      );
      if (result['ok'] != true) {
        throw StateError(result['message']?.toString() ?? 'Android VPN 启动失败');
      }

      final nativeStatus = await AndroidPlatformBridge.runtimeStatus();
      if (nativeStatus['tunEstablished'] != true) {
        throw StateError('HongdaCore 已启动，但 Android TUN 未建立');
      }
      final v4Routes =
          int.tryParse(nativeStatus['tunRouteV4Count']?.toString() ?? '') ?? 0;
      final v6Routes =
          int.tryParse(nativeStatus['tunRouteV6Count']?.toString() ?? '') ?? 0;
      if (v4Routes == 0 && v6Routes == 0) {
        throw StateError('Android VPN 已建立，但没有下发任何 TUN 路由');
      }
      coreVersion =
          result['coreVersion']?.toString() ??
          await AndroidPlatformBridge.coreVersion();
      status = AndroidConnectionStatus.running;
      connectedAt = DateTime.now();
      totalUploadBytes = 0;
      totalDownloadBytes = 0;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      activeConnections = 0;
      _appendLog(
        '连接已建立：${node.name}${coreVersion == null ? '' : ' · Core $coreVersion'}',
      );
      _appendLog(
        'Android 兼容配置：Karing-style · stack=gvisor · MTU=4064 · TUN IPv4-only · sniff+DNS hijack',
      );
      _appendLog(
        'Android TUN：v4=${nativeStatus['tunRouteV4Count'] ?? 0} · v6=${nativeStatus['tunRouteV6Count'] ?? 0} · DNS=${nativeStatus['tunDns'] ?? '--'} · IF=${nativeStatus['defaultInterface'] ?? '--'}',
      );
      final coreRequestedRoutes =
          nativeStatus['coreRequestedRoutes']?.toString() ?? '';
      _appendLog(
        'VPN 接管：${nativeStatus['vpnCaptureMode'] ?? '--'} · Routes=${nativeStatus['vpnAppliedRoutes'] ?? '--'} · CoreRoutes=${coreRequestedRoutes.isNotEmpty ? coreRequestedRoutes : '--'}',
      );
      final includePackages =
          nativeStatus['coreRequestedIncludePackages']?.toString() ?? '';
      final excludePackages =
          nativeStatus['coreRequestedExcludePackages']?.toString() ?? '';
      if (includePackages.isNotEmpty || excludePackages.isNotEmpty) {
        _appendLog(
          'VPN 应用过滤：R9 已强制忽略 · include=$includePackages · exclude=$excludePackages',
        );
      }
      _startRuntimePolling();
      _startMetrics(settings);
      _startTrafficPersistence();
      unawaited(testNode(node, settings));
      unawaited(_runPostConnectDiagnostics(node, settings));
    } catch (e) {
      await AndroidPlatformBridge.stopVpn();
      status = AndroidConnectionStatus.error;
      lastError = _cleanError(e);
      _appendLog(lastError!, error: true);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (status == AndroidConnectionStatus.stopped ||
        status == AndroidConnectionStatus.stopping)
      return;
    status = AndroidConnectionStatus.stopping;
    notifyListeners();
    try {
      await AndroidPlatformBridge.stopVpn();
      await _persistTraffic();
    } finally {
      _stopRuntimePolling();
      _stopMetrics();
      _stopTrafficPersistence();
      status = AndroidConnectionStatus.stopped;
      connectedAt = null;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      activeConnections = 0;
      _appendLog('已断开连接');
      notifyListeners();
    }
  }

  Future<void> selectNodeRuntime(NodeProfile node, AppSettings settings) async {
    if (!isRunning) return;
    if (!node.enabled) throw StateError('目标节点已禁用');
    final tag = SingBoxConfigBuilder.nodeTag(node.id);
    final before = await _apiJson(settings, 'GET', '/proxies/proxy');
    final all =
        (before['all'] as List?)?.map((e) => e.toString()).toSet() ??
        <String>{};
    if (all.isNotEmpty && !all.contains(tag)) {
      throw StateError('当前运行配置未包含目标节点，需要重载 Core');
    }
    await _apiJson(
      settings,
      'PUT',
      '/proxies/proxy',
      body: <String, dynamic>{'name': tag},
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final after = await _apiJson(settings, 'GET', '/proxies/proxy');
    final active = after['now']?.toString() ?? '';
    if (active.isNotEmpty && active != tag) {
      throw StateError('Core 未切换到目标节点（当前：$active）');
    }
    _appendLog('运行时切换节点：${node.name} -> $tag');
  }

  Future<int?> testNode(NodeProfile node, AppSettings settings) async {
    if (testingNodeIds.contains(node.id)) return node.latencyMs;
    testingNodeIds.add(node.id);
    node.testError = null;
    notifyListeners();
    try {
      if (isRunning) {
        final tag = SingBoxConfigBuilder.nodeTag(node.id);
        final target = Uri.encodeQueryComponent(settings.urlTestUrl);
        final uri = Uri.parse(
          'http://127.0.0.1:${settings.apiPort}/proxies/${Uri.encodeComponent(tag)}/delay?timeout=7000&url=$target',
        );
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        try {
          final request = await client.getUrl(uri);
          if (settings.clashApiSecret.isNotEmpty) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer ${settings.clashApiSecret}',
            );
          }
          final response = await request.close().timeout(
            const Duration(seconds: 8),
          );
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode < 200 || response.statusCode >= 300) {
            throw HttpException(
              'Core URLTest ${response.statusCode}: $body',
              uri: uri,
            );
          }
          final decoded = jsonDecode(body);
          final delay = decoded is Map
              ? int.tryParse(decoded['delay']?.toString() ?? '')
              : null;
          if (delay == null || delay <= 0) {
            throw StateError('Core URLTest 未返回有效延迟');
          }
          node.latencyMs = delay;
          node.lastLatencyTest = DateTime.now();
          node.testError = null;
          return delay;
        } catch (e) {
          // Do not fall back to TCP and present a server-port handshake as proxy
          // latency. VLESS TCP reachability can succeed while Reality/TLS/auth or
          // the Android route is broken; Hysteria2 is UDP and TCP fallback is
          // meaningless.
          node.latencyMs = null;
          node.lastLatencyTest = DateTime.now();
          node.testError = 'Core URLTest 失败：${_cleanError(e)}';
          return null;
        } finally {
          client.close(force: true);
        }
      }

      node.latencyMs = null;
      node.lastLatencyTest = DateTime.now();
      final protocol = node.protocol.toLowerCase();
      if (protocol == 'hysteria2' ||
          protocol == 'hysteria' ||
          protocol == 'tuic') {
        node.testError =
            '${node.protocol} 使用 UDP；请连接后由 HongdaCore 执行真实 URLTest';
        return null;
      }

      // Disconnected preflight: only report reachability text, never store it as
      // proxy latency. This prevents "VLESS has delay but cannot proxy".
      try {
        final sw = Stopwatch()..start();
        final socket = await Socket.connect(
          node.server,
          node.port,
          timeout: const Duration(seconds: 4),
        );
        sw.stop();
        socket.destroy();
        final ms = mathMax1((sw.elapsedMicroseconds + 999) ~/ 1000);
        node.testError = '服务器 TCP 端口可达（$ms ms）；连接后才会显示真实代理延迟';
      } catch (e) {
        node.testError = '服务器端口不可达：${_cleanError(e)}';
      }
      return null;
    } finally {
      testingNodeIds.remove(node.id);
      notifyListeners();
    }
  }

  Future<void> _runPostConnectDiagnostics(
    NodeProfile node,
    AppSettings settings,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (!isRunning) return;

    try {
      final native = await AndroidPlatformBridge.runtimeStatus();
      _appendLog(
        '诊断物理网络：${native['physicalNetworkType'] ?? '--'} · IF=${native['defaultInterface'] ?? '--'} · DNS=${native['physicalDns'] ?? '--'}',
      );
      _appendLog(
        '诊断 VPN 接管：${native['vpnCaptureMode'] ?? '--'} · Routes=${native['vpnAppliedRoutes'] ?? '--'} · protect=${native['protectedSocketCount'] ?? 0}',
      );
    } catch (_) {}

    var coreOutboundOk = false;
    try {
      final tag = SingBoxConfigBuilder.nodeTag(node.id);
      final target = Uri.encodeQueryComponent(settings.urlTestUrl);
      final result = await _apiJson(
        settings,
        'GET',
        '/proxies/${Uri.encodeComponent(tag)}/delay?timeout=7000&url=$target',
      );
      final delay = int.tryParse(result['delay']?.toString() ?? '');
      if (delay == null || delay <= 0) throw StateError('未返回有效延迟');
      coreOutboundOk = true;
      _appendLog('诊断 Core 出口：正常 · ${delay}ms');
    } catch (e) {
      _appendLog('诊断 Core 出口：失败 · ${_cleanError(e)}', error: true);
    }

    var ipTunnelOk = false;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(Uri.parse('http://1.1.1.1/'));
        final response = await request.close().timeout(
          const Duration(seconds: 7),
        );
        await response.drain<void>();
        ipTunnelOk = true;
        _appendLog('诊断 TUN IP：正常 · HTTP ${response.statusCode}');
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      _appendLog('诊断 TUN IP：失败 · ${_cleanError(e)}', error: true);
    }

    var dnsOk = false;
    final probeHost = Uri.tryParse(settings.urlTestUrl)?.host.isNotEmpty == true
        ? Uri.parse(settings.urlTestUrl).host
        : 'www.gstatic.com';
    try {
      final answer = await InternetAddress.lookup(
        probeHost,
      ).timeout(const Duration(seconds: 6));
      dnsOk = answer.isNotEmpty;
      _appendLog(
        '诊断 TUN DNS：正常 · $probeHost -> ${answer.take(2).map((e) => e.address).join(', ')}',
      );
    } catch (e) {
      final native = await AndroidPlatformBridge.runtimeStatus();
      _appendLog(
        '诊断 TUN DNS：失败 · ${_cleanError(e)} · Native=${native['lastDnsError'] ?? native['lastDnsEvent'] ?? '--'}',
        error: true,
      );
    }

    var fullTunnelOk = false;
    try {
      final uri = Uri.tryParse(settings.urlTestUrl);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty)
        throw StateError('URLTest 地址无效');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      try {
        final request = await client.getUrl(uri);
        final response = await request.close().timeout(
          const Duration(seconds: 8),
        );
        await response.drain<void>();
        fullTunnelOk = response.statusCode >= 200 && response.statusCode < 500;
        _appendLog(
          '诊断完整代理：${fullTunnelOk ? '正常' : '异常'} · HTTP ${response.statusCode}',
        );
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      _appendLog('诊断完整代理：失败 · ${_cleanError(e)}', error: true);
    }

    if (coreOutboundOk && !ipTunnelOk) {
      _appendLog(
        '诊断结论：节点/Core 出口可用，但 Android 应用流量没有完成 TUN 转发；重点检查 VpnService 路由/设备兼容。',
        error: true,
      );
    } else if (coreOutboundOk && ipTunnelOk && !dnsOk) {
      _appendLog('诊断结论：IP 代理链路正常，DNS 链路异常。', error: true);
    } else if (!coreOutboundOk) {
      _appendLog(
        '诊断结论：Core 自身无法通过当前节点完成 URLTest，问题在节点握手、物理出口或节点配置。',
        error: true,
      );
    } else if (coreOutboundOk && ipTunnelOk && dnsOk && !fullTunnelOk) {
      _appendLog(
        '诊断结论：Core/IP/DNS 均正常，但域名 HTTP 仍失败；继续检查 MTU/TLS/规则命中。',
        error: true,
      );
    } else if (fullTunnelOk) {
      _appendLog(
        '诊断结论：鸿达进程内 TUN + DNS + 节点链路正常；R9 使用 Karing-style Android TUN 参数并强制 GLOBAL 全应用接管。',
      );
    }
    notifyListeners();
  }

  void _startRuntimePolling() {
    _stopRuntimePolling();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!isRunning) return;
      final value = await AndroidPlatformBridge.runtimeStatus();
      if (value.isEmpty) return;
      final nativeRunning = value['running'] == true;
      final nativeError = value['lastError']?.toString();
      if (!nativeRunning) {
        final failed = nativeError != null && nativeError.isNotEmpty;
        lastError = failed ? nativeError : null;
        status = failed
            ? AndroidConnectionStatus.error
            : AndroidConnectionStatus.stopped;
        connectedAt = null;
        _appendLog(
          failed ? nativeError : 'Android VPN Service 已停止',
          error: failed,
        );
        _stopRuntimePolling();
        _stopMetrics();
        _stopTrafficPersistence();
        notifyListeners();
      }
    });
  }

  void _stopRuntimePolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  void _startMetrics(AppSettings settings) {
    _stopMetrics();
    final generation = ++_metricsGeneration;
    unawaited(_connectTraffic(settings, generation));
    _apiTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollConnections(settings)),
    );
  }

  void _stopMetrics() {
    _metricsGeneration++;
    _apiTimer?.cancel();
    _apiTimer = null;
    _trafficReconnectTimer?.cancel();
    _trafficReconnectTimer = null;
    _trafficSocket?.close();
    _trafficSocket = null;
    _lastTrafficSampleAt = null;
  }

  void _scheduleTrafficReconnect(AppSettings settings, int generation) {
    if (!isRunning || generation != _metricsGeneration) return;
    _trafficReconnectTimer?.cancel();
    _trafficReconnectTimer = Timer(const Duration(seconds: 2), () {
      if (isRunning && generation == _metricsGeneration) {
        unawaited(_connectTraffic(settings, generation));
      }
    });
  }

  Future<void> _connectTraffic(AppSettings settings, int generation) async {
    if (!isRunning || generation != _metricsGeneration) return;
    try {
      final headers = <String, dynamic>{};
      if (settings.clashApiSecret.isNotEmpty) {
        headers[HttpHeaders.authorizationHeader] =
            'Bearer ${settings.clashApiSecret}';
      }
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${settings.apiPort}/traffic',
        headers: headers,
      );
      if (!isRunning || generation != _metricsGeneration) {
        await socket.close();
        return;
      }
      await _trafficSocket?.close();
      _trafficSocket = socket;
      _lastTrafficSampleAt = DateTime.now();
      socket.listen(
        (data) {
          try {
            final decoded = jsonDecode(data.toString());
            if (decoded is! Map) return;
            final now = DateTime.now();
            final previous = _lastTrafficSampleAt ?? now;
            final elapsed = (now.difference(previous).inMilliseconds / 1000.0)
                .clamp(.25, 3.0);
            _lastTrafficSampleAt = now;
            uploadBytesPerSecond = (decoded['up'] as num?)?.toDouble() ?? 0;
            downloadBytesPerSecond = (decoded['down'] as num?)?.toDouble() ?? 0;
            final up = (uploadBytesPerSecond * elapsed).round();
            final down = (downloadBytesPerSecond * elapsed).round();
            totalUploadBytes += up;
            totalDownloadBytes += down;
            if (up > 0 || down > 0)
              trafficStats.add(upload: up, download: down, at: now);
            notifyListeners();
          } catch (_) {}
        },
        onDone: () {
          if (identical(_trafficSocket, socket)) _trafficSocket = null;
          _scheduleTrafficReconnect(settings, generation);
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleTrafficReconnect(settings, generation);
    }
  }

  Future<void> _pollConnections(AppSettings settings) async {
    if (!isRunning) return;
    try {
      final json = await _apiJson(settings, 'GET', '/connections');
      if (json['connections'] is List) {
        activeConnections = (json['connections'] as List).length;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _apiJson(
    AppSettings settings,
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final uri = Uri.parse('http://127.0.0.1:${settings.apiPort}$path');
      late HttpClientRequest request;
      switch (method) {
        case 'PUT':
          request = await client.putUrl(uri);
          break;
        case 'POST':
          request = await client.postUrl(uri);
          break;
        case 'DELETE':
          request = await client.deleteUrl(uri);
          break;
        default:
          request = await client.getUrl(uri);
      }
      if (settings.clashApiSecret.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${settings.clashApiSecret}',
        );
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Clash API ${response.statusCode}: $text',
          uri: uri,
        );
      }
      if (text.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(text);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{'data': decoded};
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isPortAvailable(int port) async {
    if (port < 1 || port > 65535) return false;
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false);
      return true;
    } on SocketException {
      return false;
    } finally {
      await socket?.close();
    }
  }

  Future<int> _findAvailablePort(
    int preferred, {
    required int fallback,
    Set<int> reserved = const <int>{},
  }) async {
    final base = preferred >= 1024 && preferred <= 65535 ? preferred : fallback;
    for (var offset = 0; offset < 128; offset++) {
      final candidate = base + offset <= 65535 ? base + offset : 1024 + (base + offset - 65536);
      if (reserved.contains(candidate)) continue;
      if (await _isPortAvailable(candidate)) return candidate;
    }
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0, shared: false);
      if (reserved.contains(socket.port)) throw StateError('系统分配的本地端口发生冲突，请重试');
      return socket.port;
    } finally {
      await socket?.close();
    }
  }

  void _startTrafficPersistence() {
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_persistTraffic()),
    );
  }

  void _stopTrafficPersistence() {
    _persistTimer?.cancel();
    _persistTimer = null;
  }

  Future<void> _persistTraffic() async {
    try {
      await storage.saveTrafficStats(trafficStats);
    } catch (_) {}
  }

  void _appendLog(String message, {bool error = false}) {
    final now = DateTime.now();
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    logs.add('[$clock] ${error ? '[ERR] ' : ''}$message');
    if (logs.length > 1000) logs.removeRange(0, logs.length - 800);
  }

  String _cleanError(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _stopRuntimePolling();
    _stopMetrics();
    _stopTrafficPersistence();
    super.dispose();
  }
}

int mathMax1(int value) => value < 1 ? 1 : value;

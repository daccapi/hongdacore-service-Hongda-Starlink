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
  static const MethodChannel _channel = MethodChannel('hongda_starlink/android');

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
      return value ?? <String, dynamic>{'ok': false, 'message': 'Android VPN Bridge 未返回结果'};
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
      final value = await _channel.invokeMapMethod<String, dynamic>('getRuntimeStatus');
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
  WebSocket? _trafficSocket;
  DateTime? _lastTrafficSampleAt;
  AppSettings? _runtimeSettings;

  bool get isRunning => status == AndroidConnectionStatus.running;
  int get totalTrafficBytes => totalUploadBytes + totalDownloadBytes;
  int get lifetimeTrafficBytes => trafficStats.totalBytes;

  Future<void> initialize() async {
    coreAvailable = await AndroidPlatformBridge.coreAvailable();
    coreVersion = coreAvailable ? await AndroidPlatformBridge.coreVersion() : null;
    _appendLog(coreAvailable
        ? 'HongdaCore 已加载${coreVersion == null ? '' : ' · $coreVersion'}'
        : 'HongdaCore.aar 未打包；请先构建 Android Core');
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
        throw StateError('未找到 HongdaCore.aar；请先运行 tools/build-android-core.ps1。');
      }

      final prepared = await AndroidPlatformBridge.prepareVpn();
      if (!prepared) throw StateError('未获得 Android VPN 授权');

      final config = SingBoxConfigBuilder(storage).build(
        selectedNode: node,
        nodes: nodes,
        groups: groups,
        rules: rules,
        settings: settings,
      );
      final configFile = await storage.writeRuntimeConfig(config);
      final result = await AndroidPlatformBridge.startVpn(
        configPath: configFile.path,
        nodeName: node.name,
      );
      if (result['ok'] != true) {
        throw StateError(result['message']?.toString() ?? 'Android VPN 启动失败');
      }

      coreVersion = result['coreVersion']?.toString() ?? await AndroidPlatformBridge.coreVersion();
      status = AndroidConnectionStatus.running;
      connectedAt = DateTime.now();
      totalUploadBytes = 0;
      totalDownloadBytes = 0;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      activeConnections = 0;
      _runtimeSettings = settings;
      _appendLog('连接已建立：${node.name}${coreVersion == null ? '' : ' · Core $coreVersion'}');
      _startRuntimePolling();
      _startMetrics(settings);
      _startTrafficPersistence();
    } catch (e) {
      status = AndroidConnectionStatus.error;
      lastError = _cleanError(e);
      _appendLog(lastError!, error: true);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (status == AndroidConnectionStatus.stopped || status == AndroidConnectionStatus.stopping) return;
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
      _runtimeSettings = null;
      _appendLog('已断开连接');
      notifyListeners();
    }
  }

  Future<void> selectNodeRuntime(NodeProfile node, AppSettings settings) async {
    if (!isRunning) return;
    if (!node.enabled) throw StateError('目标节点已禁用');
    final tag = SingBoxConfigBuilder.nodeTag(node.id);
    final before = await _apiJson(settings, 'GET', '/proxies/proxy');
    final all = (before['all'] as List?)?.map((e) => e.toString()).toSet() ?? <String>{};
    if (all.isNotEmpty && !all.contains(tag)) {
      throw StateError('当前运行配置未包含目标节点，需要重载 Core');
    }
    await _apiJson(settings, 'PUT', '/proxies/proxy', body: <String, dynamic>{'name': tag});
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
        try {
          final tag = SingBoxConfigBuilder.nodeTag(node.id);
          final target = Uri.encodeQueryComponent(settings.urlTestUrl);
          final uri = Uri.parse(
            'http://127.0.0.1:${settings.apiPort}/proxies/${Uri.encodeComponent(tag)}/delay?timeout=5000&url=$target',
          );
          final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
          try {
            final request = await client.getUrl(uri);
            if (settings.clashApiSecret.isNotEmpty) {
              request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${settings.clashApiSecret}');
            }
            final response = await request.close().timeout(const Duration(seconds: 6));
            final body = await response.transform(utf8.decoder).join();
            final decoded = jsonDecode(body);
            if (decoded is Map) {
              final delay = int.tryParse(decoded['delay']?.toString() ?? '');
              if (delay != null && delay > 0) {
                node.latencyMs = delay;
                node.lastLatencyTest = DateTime.now();
                node.testError = null;
                return delay;
              }
            }
          } finally {
            client.close(force: true);
          }
        } catch (_) {
          // Fall through to TCP reachability. Never display a false 0 ms.
        }
      }

      final sw = Stopwatch()..start();
      final socket = await Socket.connect(node.server, node.port, timeout: const Duration(seconds: 4));
      sw.stop();
      socket.destroy();
      final ms = mathMax1((sw.elapsedMicroseconds + 999) ~/ 1000);
      node.latencyMs = ms;
      node.lastLatencyTest = DateTime.now();
      node.testError = isRunning ? null : 'TCP 可达延迟；连接后会使用真实 URLTest';
      return ms;
    } catch (e) {
      node.latencyMs = null;
      node.lastLatencyTest = DateTime.now();
      node.testError = _cleanError(e);
      return null;
    } finally {
      testingNodeIds.remove(node.id);
      notifyListeners();
    }
  }

  void _startRuntimePolling() {
    _stopRuntimePolling();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!isRunning) return;
      final value = await AndroidPlatformBridge.runtimeStatus();
      if (value.isEmpty) return;
      final nativeRunning = value['running'] == true;
      final nativeError = value['lastError']?.toString();
      if (!nativeRunning && nativeError != null && nativeError.isNotEmpty) {
        lastError = nativeError;
        status = AndroidConnectionStatus.error;
        _appendLog(nativeError, error: true);
        _stopMetrics();
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
    unawaited(_connectTraffic(settings));
    _apiTimer = Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_pollConnections(settings)));
  }

  void _stopMetrics() {
    _apiTimer?.cancel();
    _apiTimer = null;
    _trafficSocket?.close();
    _trafficSocket = null;
    _lastTrafficSampleAt = null;
  }

  Future<void> _connectTraffic(AppSettings settings) async {
    try {
      final headers = <String, dynamic>{};
      if (settings.clashApiSecret.isNotEmpty) {
        headers[HttpHeaders.authorizationHeader] = 'Bearer ${settings.clashApiSecret}';
      }
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${settings.apiPort}/traffic',
        headers: headers,
      );
      if (!isRunning) {
        await socket.close();
        return;
      }
      _trafficSocket = socket;
      _lastTrafficSampleAt = DateTime.now();
      socket.listen(
        (data) {
          try {
            final decoded = jsonDecode(data.toString());
            if (decoded is! Map) return;
            final now = DateTime.now();
            final previous = _lastTrafficSampleAt ?? now;
            final elapsed = (now.difference(previous).inMilliseconds / 1000.0).clamp(.25, 3.0);
            _lastTrafficSampleAt = now;
            uploadBytesPerSecond = (decoded['up'] as num?)?.toDouble() ?? 0;
            downloadBytesPerSecond = (decoded['down'] as num?)?.toDouble() ?? 0;
            final up = (uploadBytesPerSecond * elapsed).round();
            final down = (downloadBytesPerSecond * elapsed).round();
            totalUploadBytes += up;
            totalDownloadBytes += down;
            if (up > 0 || down > 0) trafficStats.add(upload: up, download: down, at: now);
            notifyListeners();
          } catch (_) {}
        },
        onDone: () {
          if (isRunning) {
            Future<void>.delayed(const Duration(seconds: 2), () => _connectTraffic(settings));
          }
        },
        onError: (_) {},
        cancelOnError: true,
      );
    } catch (_) {
      if (isRunning) {
        Future<void>.delayed(const Duration(seconds: 2), () => _connectTraffic(settings));
      }
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
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${settings.clashApiSecret}');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(const Duration(seconds: 6));
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Clash API ${response.statusCode}: $text', uri: uri);
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

  void _startTrafficPersistence() {
    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_persistTraffic()));
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
    final clock = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
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

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
      final value = await _channel.invokeMapMethod<String, dynamic>('startVpn', <String, dynamic>{
        'configPath': configPath,
        'nodeName': nodeName,
      });
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
  AndroidRuntimeController({
    required this.storage,
    required this.trafficStats,
  });

  final AppStorage storage;
  final TrafficStats trafficStats;
  final Set<String> testingNodeIds = <String>{};
  final List<String> logs = <String>[];

  AndroidConnectionStatus status = AndroidConnectionStatus.stopped;
  DateTime? connectedAt;
  String? lastError;
  bool coreAvailable = false;
  double uploadBytesPerSecond = 0;
  double downloadBytesPerSecond = 0;
  int totalUploadBytes = 0;
  int totalDownloadBytes = 0;
  int activeConnections = 0;
  Timer? _statusTimer;
  Timer? _persistTimer;
  DateTime? _lastSampleAt;

  bool get isRunning => status == AndroidConnectionStatus.running;
  int get totalTrafficBytes => totalUploadBytes + totalDownloadBytes;
  int get lifetimeTrafficBytes => trafficStats.totalBytes;

  Future<void> initialize() async {
    coreAvailable = await AndroidPlatformBridge.coreAvailable();
    _appendLog(coreAvailable
        ? 'Android libbox runtime detected'
        : 'Android libbox runtime not bundled; UI/data mode is available');
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
        throw StateError('Android 版尚未放入 libbox.aar 核心；当前可使用完整 UI、订阅、节点与配置功能。');
      }

      final prepared = await AndroidPlatformBridge.prepareVpn();
      if (!prepared) {
        throw StateError('未获得 Android VPN 授权');
      }

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

      status = AndroidConnectionStatus.running;
      connectedAt = DateTime.now();
      totalUploadBytes = 0;
      totalDownloadBytes = 0;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      _lastSampleAt = DateTime.now();
      _appendLog('连接已建立：${node.name}');
      _startRuntimePolling();
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
      _stopTrafficPersistence();
      status = AndroidConnectionStatus.stopped;
      connectedAt = null;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      activeConnections = 0;
      _lastSampleAt = null;
      _appendLog('已断开连接');
      notifyListeners();
    }
  }

  Future<int?> testNode(NodeProfile node, AppSettings settings) async {
    if (testingNodeIds.contains(node.id)) return node.latencyMs;
    testingNodeIds.add(node.id);
    node.testError = null;
    notifyListeners();
    try {
      // When the Android runtime is active, prefer Clash-compatible URLTest.
      if (isRunning) {
        try {
          final tag = SingBoxConfigBuilder.nodeTag(node.id);
          final target = Uri.encodeQueryComponent(settings.urlTestUrl);
          final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
          try {
            final uri = Uri.parse(
              'http://127.0.0.1:${settings.apiPort}/proxies/${Uri.encodeComponent(tag)}/delay?timeout=5000&url=$target',
            );
            final request = await client.getUrl(uri);
            if (settings.clashApiSecret.isNotEmpty) {
              request.headers.set('Authorization', 'Bearer ${settings.clashApiSecret}');
            }
            final response = await request.close().timeout(const Duration(seconds: 6));
            final body = await response.transform(utf8.decoder).join();
            final json = jsonDecode(body);
            if (json is Map) {
              final delay = int.tryParse(json['delay']?.toString() ?? '');
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
          // Fall through to reachability probe.
        }
      }

      final sw = Stopwatch()..start();
      final socket = await Socket.connect(
        node.server,
        node.port,
        timeout: const Duration(seconds: 4),
      );
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
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!isRunning) return;
      final value = await AndroidPlatformBridge.runtimeStatus();
      if (value.isEmpty) return;
      final now = DateTime.now();
      final previous = _lastSampleAt ?? now;
      final elapsed = (now.difference(previous).inMilliseconds / 1000).clamp(.25, 3.0);
      _lastSampleAt = now;

      uploadBytesPerSecond = (value['uploadBytesPerSecond'] as num?)?.toDouble() ?? uploadBytesPerSecond;
      downloadBytesPerSecond = (value['downloadBytesPerSecond'] as num?)?.toDouble() ?? downloadBytesPerSecond;
      activeConnections = int.tryParse(value['activeConnections']?.toString() ?? '') ?? activeConnections;

      final up = (uploadBytesPerSecond * elapsed).round();
      final down = (downloadBytesPerSecond * elapsed).round();
      if (up > 0 || down > 0) {
        totalUploadBytes += up;
        totalDownloadBytes += down;
        trafficStats.add(upload: up, download: down, at: now);
      }
      notifyListeners();
    });
  }

  void _stopRuntimePolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
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
    _stopTrafficPersistence();
    super.dispose();
  }
}

int mathMax1(int value) => value < 1 ? 1 : value;

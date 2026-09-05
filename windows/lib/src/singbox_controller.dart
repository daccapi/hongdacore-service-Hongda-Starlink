import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'clash_traffic_counter.dart';
import 'core_manager.dart';
import 'models.dart';
import 'singbox_config_builder.dart';
import 'storage.dart';
import 'windows_integration.dart';

enum CoreStatus { stopped, starting, running, stopping, error }

enum StartupStage {
  idle,
  locatingService,
  verifyingService,
  checkingPermissions,
  checkingPorts,
  buildingConfig,
  validatingConfig,
  launchingService,
  waitingCore,
  waitingApi,
  handshakingIpc,
  enablingProxy,
  connected,
  failed,
}

String startupStageLabel(StartupStage stage) {
  switch (stage) {
    case StartupStage.idle:
      return '准备就绪';
    case StartupStage.locatingService:
      return '检查服务组件';
    case StartupStage.verifyingService:
      return '验证 Service 版本';
    case StartupStage.checkingPermissions:
      return '检查系统权限';
    case StartupStage.checkingPorts:
      return '检查本地端口';
    case StartupStage.buildingConfig:
      return '生成运行配置';
    case StartupStage.validatingConfig:
      return '校验 sing-box 配置';
    case StartupStage.launchingService:
      return '启动 HongdaService';
    case StartupStage.waitingCore:
      return '等待核心进程';
    case StartupStage.waitingApi:
      return '等待 Clash API';
    case StartupStage.handshakingIpc:
      return '建立 Service IPC';
    case StartupStage.enablingProxy:
      return '应用系统代理';
    case StartupStage.connected:
      return '连接完成';
    case StartupStage.failed:
      return '启动失败';
  }
}

double startupStageProgress(StartupStage stage) {
  switch (stage) {
    case StartupStage.idle:
      return 0;
    case StartupStage.locatingService:
      return .06;
    case StartupStage.verifyingService:
      return .13;
    case StartupStage.checkingPermissions:
      return .20;
    case StartupStage.checkingPorts:
      return .28;
    case StartupStage.buildingConfig:
      return .38;
    case StartupStage.validatingConfig:
      return .52;
    case StartupStage.launchingService:
      return .64;
    case StartupStage.waitingCore:
      return .73;
    case StartupStage.waitingApi:
      return .83;
    case StartupStage.handshakingIpc:
      return .91;
    case StartupStage.enablingProxy:
      return .97;
    case StartupStage.connected:
      return 1;
    case StartupStage.failed:
      return 1;
  }
}

class ServiceStartException implements Exception {
  const ServiceStartException(this.phase, this.message, {this.detail = ''});
  final String phase;
  final String message;
  final String detail;

  @override
  String toString() =>
      detail.isEmpty ? '$phase：$message' : '$phase：$message · $detail';
}

class NeedsElevationException implements Exception {
  const NeedsElevationException();
  @override
  String toString() => 'TUN / Tailscale 系统接口需要管理员权限';
}

class SingBoxController extends ChangeNotifier {
  SingBoxController({
    required this.storage,
    required this.coreManager,
    required this.trafficStats,
  }) : configBuilder = SingBoxConfigBuilder(storage);

  final AppStorage storage;
  final CoreManager coreManager;
  final TrafficStats trafficStats;
  final SingBoxConfigBuilder configBuilder;

  CoreStatus status = CoreStatus.stopped;
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Timer? _apiTimer;
  Timer? _ipcTimer;
  Timer? _trafficPersistTimer;
  Timer? _trafficReconnectTimer;
  WebSocket? _trafficSocket;
  DateTime? _lastTrafficSampleAt;
  DateTime? _lastWebSocketTrafficAt;
  DateTime? _lastFallbackTrafficAt;
  DateTime? _lastConnectionSampleAt;
  DateTime? _lastConnectionTotalsAt;
  final ClashTrafficCounter _connectionCounter = ClashTrafficCounter();
  Map<String, int> _connectionUploadTotals = <String, int>{};
  Map<String, int> _connectionDownloadTotals = <String, int>{};
  bool _trafficFallbackLogged = false;
  int _metricsGeneration = 0;
  int _ipcSequence = 0;
  Completer<void>? _readyCompleter;
  final Map<String, Completer<Map<String, dynamic>>> _ipcPending =
      <String, Completer<Map<String, dynamic>>>{};
  final List<String> _stderrTail = <String>[];
  String _runtimeLogLevel = 'warn';

  final List<String> logs = <String>[];
  double uploadBytesPerSecond = 0;
  double downloadBytesPerSecond = 0;
  int totalUploadBytes = 0;
  int totalDownloadBytes = 0;
  int activeConnections = 0;
  bool? tunRoutingVerified;
  String tunRoutingDetail = 'TUN 未启用';
  String? activeNodeTag;
  DateTime? connectedAt;
  String? lastError;
  bool ipcConnected = false;
  Map<String, dynamic> serviceInfo = <String, dynamic>{};
  StartupStage startupStage = StartupStage.idle;
  String startupDetail = '等待连接';
  Map<String, dynamic>? lastServiceError;
  final Set<String> testingNodeIds = <String>{};

  bool get isRunning => status == CoreStatus.running;
  int get totalTrafficBytes => totalUploadBytes + totalDownloadBytes;
  int get lifetimeTrafficBytes => trafficStats.totalBytes;

  Future<void> start(
    NodeProfile selectedNode,
    AppSettings settings, {
    List<NodeProfile>? nodes,
    List<ProxyGroupProfile> groups = const <ProxyGroupProfile>[],
    List<RouteRuleProfile> rules = const <RouteRuleProfile>[],
  }) async {
    if (status == CoreStatus.starting ||
        status == CoreStatus.running ||
        status == CoreStatus.stopping) {
      return;
    }
    lastError = null;
    lastServiceError = null;
    activeNodeTag = null;
    tunRoutingVerified = settings.tunEnabled ? false : null;
    tunRoutingDetail = settings.tunEnabled ? '等待 HongdaTun 路由' : 'TUN 未启用';
    _stderrTail.clear();
    _runtimeLogLevel = settings.logLevel.trim().toLowerCase();
    status = CoreStatus.starting;
    _setStartup(StartupStage.locatingService, '正在定位 HongdaService.exe');

    try {
      if (!SingBoxConfigBuilder.supportsNode(selectedNode)) {
        throw ServiceStartException(
          '节点协议',
          'HongdaCore 1.10 暂不支持 ${selectedNode.protocol}',
          detail: '请选择 VLESS、Trojan、Hysteria2 或 TUIC 节点。',
        );
      }
      RouteRuleProfile? processRule;
      for (final rule in rules) {
        if (rule.enabled && rule.processNames.isNotEmpty) {
          processRule = rule;
          break;
        }
      }
      if (processRule != null) {
        throw ServiceStartException(
          '路由规则',
          'HongdaCore 1.10 暂不支持进程匹配',
          detail: '请编辑规则“${processRule.name}”并清空进程名。',
        );
      }
      final core = await coreManager.findCore();
      if (core == null) {
        throw const ServiceStartException(
          '服务组件',
          '未找到 HongdaService.exe',
          detail: '请确认 runtime\\service\\HongdaService.exe 已随程序发布。',
        );
      }
      final serviceFile = File(core);
      final serviceBytes = await serviceFile.length();
      if (serviceBytes < 8 * 1024 * 1024) {
        throw ServiceStartException(
          '服务组件',
          'HongdaService.exe 不完整',
          detail:
              '当前只有 ${(serviceBytes / 1024 / 1024).toStringAsFixed(1)} MB；自包含版本应包含内嵌 HongdaCore。',
        );
      }
      _appendLog(
        'Service: $core · ${(serviceBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );

      _setStartup(
        StartupStage.verifyingService,
        '验证 HongdaService、HongdaCore ${CoreManager.version} 与必要功能',
      );
      ProcessResult versionResult;
      ProcessResult featuresResult;
      try {
        versionResult = await Process.run(
          core,
          <String>['version'],
          workingDirectory: File(core).parent.path,
        ).timeout(const Duration(seconds: 20));
        featuresResult = await Process.run(
          core,
          <String>['features'],
          workingDirectory: File(core).parent.path,
        ).timeout(const Duration(seconds: 8));
      } on TimeoutException {
        throw const ServiceStartException(
          '服务组件',
          'HongdaService 自检超时',
          detail: 'Service 可执行文件存在，但 version/features 在限定时间内没有返回。',
        );
      }
      if (versionResult.exitCode != 0) {
        throw ServiceStartException(
          '服务组件',
          'HongdaService 无法正常运行',
          detail: _compactError(
            '${versionResult.stderr}\n${versionResult.stdout}',
          ),
        );
      }
      final versionText = '${versionResult.stdout}'.trim();
      if (!versionText.contains(
            'HongdaService ${CoreManager.serviceVersion}',
          ) ||
          !versionText.contains(CoreManager.version)) {
        throw ServiceStartException(
          '服务组件',
          'HongdaService 版本不匹配',
          detail: versionText.isEmpty ? 'version 没有返回版本信息' : versionText,
        );
      }
      if (featuresResult.exitCode != 0) {
        throw ServiceStartException(
          '服务组件',
          '无法读取 HongdaService 功能集',
          detail: _compactError(
            '${featuresResult.stderr}\n${featuresResult.stdout}',
          ),
        );
      }
      final featureText = '${featuresResult.stdout}'.trim().toLowerCase();
      const requiredFeatures = <String>[
        'vless',
        'reality',
        'hysteria2',
        'clash-api',
      ];
      final advertisedFeatures = featureText
          .split(',')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toSet();
      final missingFeatures = requiredFeatures
          .where((name) => !advertisedFeatures.contains(name))
          .toList();
      if (missingFeatures.isNotEmpty) {
        throw ServiceStartException(
          '服务组件',
          'HongdaService 功能集不完整',
          detail: '缺少：${missingFeatures.join('、')}',
        );
      }
      _appendLog('Service 版本通过：$versionText');
      _appendLog('Service 功能集通过：${featuresResult.stdout.toString().trim()}');
      if (settings.tailscaleEnabled) {
        throw const ServiceStartException(
          '功能设置',
          'HongdaCore 1.10 暂不支持 Tailscale endpoint',
          detail: '请先关闭 Tailscale 开关；该设置不会被静默忽略。',
        );
      }

      _setStartup(StartupStage.checkingPermissions, '检查 TUN / Tailscale 所需权限');
      if ((settings.tunEnabled || settings.tailscaleEnabled) &&
          !await WindowsIntegration.isAdministrator()) {
        throw const NeedsElevationException();
      }
      if (settings.tunEnabled) {
        // A localhost Windows proxy can break AppContainer/WebView clients
        // such as ChatGPT even while ordinary browsers work. TUN already
        // captures the traffic, so remove both the persisted flag and any
        // proxy left in the current Windows session.
        if (settings.systemProxyEnabled) {
          settings.systemProxyEnabled = false;
          await storage.saveSettings(settings);
        }
        await WindowsIntegration.setSystemProxy(
          enabled: false,
          port: settings.mixedPort,
        );
        await WindowsIntegration.setTunProxySuspended(true);
        _appendLog('TUN 模式：已暂停 Windows 系统代理，断开后将原样恢复');
      }

      _setStartup(StartupStage.checkingPorts, '为本地代理与 Clash API 选择可用端口');
      final preferredMixedPort = settings.mixedPort;
      final preferredApiPort = settings.apiPort;
      settings.mixedPort = await _findAvailablePort(
        preferredMixedPort,
        fallback: 7890,
      );
      settings.apiPort = await _findAvailablePort(
        preferredApiPort,
        fallback: 9090,
        reserved: <int>{settings.mixedPort},
      );
      if (settings.mixedPort != preferredMixedPort ||
          settings.apiPort != preferredApiPort) {
        await storage.saveSettings(settings);
        _appendLog(
          '端口自动避让：Mixed $preferredMixedPort -> ${settings.mixedPort}，API $preferredApiPort -> ${settings.apiPort}',
        );
      } else {
        _appendLog(
          '本地端口可用：Mixed ${settings.mixedPort}，API ${settings.apiPort}',
        );
      }

      _setStartup(StartupStage.buildingConfig, '生成节点、规则、TUN 与 DNS 配置');
      final allNodes = (nodes ?? <NodeProfile>[selectedNode])
          .where((n) => n.enabled)
          .toList();
      if (!allNodes.any((n) => n.id == selectedNode.id)) {
        allNodes.insert(0, selectedNode);
      }
      final skippedProtocols = allNodes
          .where((node) => !SingBoxConfigBuilder.supportsNode(node))
          .length;
      if (skippedProtocols > 0) {
        _appendLog('本次运行跳过 $skippedProtocols 个 HongdaCore 1.10 未支持协议节点');
      }
      final config = configBuilder.build(
        selectedNode: selectedNode,
        nodes: allNodes,
        groups: groups,
        rules: rules,
        settings: settings,
      );
      final configFile = await storage.writeRuntimeConfig(config);

      _setStartup(
        StartupStage.validatingConfig,
        '首次启动会校验并释放内嵌 HongdaCore ${CoreManager.version}',
      );
      _appendLog('Service Doctor：${configFile.path}');
      final doctor = await Process.run(
        core,
        <String>['doctor', '-c', configFile.path],
        workingDirectory: File(core).parent.path,
      ).timeout(const Duration(minutes: 4));
      if (doctor.exitCode != 0) {
        final parsed = _extractServiceError(
          '${doctor.stderr}\n${doctor.stdout}',
        );
        if (parsed != null) {
          throw ServiceStartException(
            _phaseTitle(parsed['phase']?.toString() ?? '配置校验'),
            parsed['message']?.toString() ?? 'Service Doctor 失败',
            detail: parsed['detail']?.toString() ?? '',
          );
        }
        final details = _compactError('${doctor.stderr}\n${doctor.stdout}');
        throw ServiceStartException(
          '配置校验',
          'Service Doctor 失败',
          detail: details,
        );
      }
      _appendLog('Service Doctor 通过');

      _setStartup(
        StartupStage.launchingService,
        '正在创建 HongdaService 与 HongdaCore 子进程',
      );
      _appendLog('启动 HongdaService（自包含 HongdaCore）…');
      _readyCompleter = Completer<void>();
      final process = await Process.start(core, <String>[
        'run',
        '-c',
        configFile.path,
      ], workingDirectory: File(core).parent.path);
      _process = process;

      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine);
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStderrLine);

      unawaited(
        process.exitCode.then((code) {
          if (_process == process && status != CoreStatus.stopping) {
            final details = _compactError(_stderrTail.join('\n'));
            _appendLog('HongdaService 已退出，代码 $code', error: code != 0);
            _process = null;
            status = code == 0 ? CoreStatus.stopped : CoreStatus.error;
            if (code != 0) {
              final structured = lastServiceError;
              if (structured != null) {
                final phase = _phaseTitle(
                  structured['phase']?.toString() ?? 'HongdaService',
                );
                final message =
                    structured['message']?.toString() ??
                    'HongdaService 异常退出：$code';
                final detail = structured['detail']?.toString() ?? '';
                lastError = detail.isEmpty
                    ? '$phase：$message'
                    : '$phase：$message · $detail';
              } else {
                lastError = details.isEmpty
                    ? 'HongdaService 异常退出：$code'
                    : 'HongdaService 异常退出：$code · $details';
              }
            }
            final pendingReady = _readyCompleter;
            if (pendingReady != null && !pendingReady.isCompleted) {
              pendingReady.completeError(
                StateError(lastError ?? 'HongdaService 已退出'),
              );
            }
            _stopMetrics();
            _stopIpc();
            unawaited(
              WindowsIntegration.setSystemProxy(
                enabled: false,
                port: settings.mixedPort,
              ),
            );
            unawaited(WindowsIntegration.setTunProxySuspended(false));
            notifyListeners();
          }
        }),
      );

      _setStartup(StartupStage.waitingCore, '等待 HongdaService READY 握手');
      await _waitForServiceReady(settings);
      // cache_file 会持久化 selector 选择。启动/重载后显式同步 UI 当前
      // 选择，避免界面显示新 VLESS、Core 实际仍沿用旧节点。
      await _selectProxyTag(
        settings,
        SingBoxConfigBuilder.nodeTag(selectedNode.id),
      );
      if (settings.tunEnabled) {
        _setStartup(StartupStage.waitingCore, '验证 HongdaTun 路由与真实 HTTPS 联网');
        await _verifyTunRouting(settings);
      }
      _setStartup(StartupStage.handshakingIpc, '验证 stdio JSON IPC');
      await _probeIpc(required: true);

      if (settings.systemProxyEnabled && !settings.tunEnabled) {
        _setStartup(StartupStage.enablingProxy, '写入 Windows 系统代理设置');
        await WindowsIntegration.setSystemProxy(
          enabled: true,
          port: settings.mixedPort,
        );
      }

      status = CoreStatus.running;
      _setStartup(StartupStage.connected, 'Service、Core、API 与 IPC 均已就绪');
      connectedAt = DateTime.now();
      totalUploadBytes = 0;
      totalDownloadBytes = 0;
      _lastTrafficSampleAt = null;
      _startMetrics(settings);
      _startIpcHeartbeat();
      _startTrafficPersistence();
      _appendLog('连接已建立：${selectedNode.name}');
      notifyListeners();
    } catch (e) {
      await _cleanupFailedStart(settings);
      status = CoreStatus.error;
      lastError = _cleanException(e);
      _setStartup(StartupStage.failed, lastError!);
      _appendLog(lastError!, error: true);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> stop(AppSettings settings) async {
    if (status == CoreStatus.stopped || status == CoreStatus.stopping) return;
    status = CoreStatus.stopping;
    notifyListeners();
    try {
      await WindowsIntegration.setSystemProxy(
        enabled: false,
        port: settings.mixedPort,
      );
      await WindowsIntegration.setTunProxySuspended(false);
      _stopMetrics();
      _stopIpc();
      _stopTrafficPersistence();
      await _persistTraffic();
      final process = _process;
      _process = null;
      if (process != null) {
        try {
          final id = _nextIpcId();
          process.stdin.writeln(
            jsonEncode(<String, dynamic>{'id': id, 'method': 'stop'}),
          );
          await process.stdin.flush();
          await process.exitCode.timeout(const Duration(seconds: 7));
        } catch (_) {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 2));
          } catch (_) {
            process.kill(ProcessSignal.sigkill);
          }
        }
      }
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
      _stdoutSub = null;
      _stderrSub = null;
      uploadBytesPerSecond = 0;
      downloadBytesPerSecond = 0;
      activeConnections = 0;
      activeNodeTag = null;
      tunRoutingVerified = null;
      tunRoutingDetail = 'TUN 未启用';
      connectedAt = null;
      ipcConnected = false;
      serviceInfo = <String, dynamic>{};
      status = CoreStatus.stopped;
      _setStartup(StartupStage.idle, '已断开连接');
      _appendLog('已停止连接');
    } finally {
      notifyListeners();
    }
  }

  Future<int?> testNode(
    NodeProfile node,
    AppSettings settings, {
    String? url,
  }) async {
    testingNodeIds.add(node.id);
    notifyListeners();
    try {
      if (isRunning) {
        final tag = SingBoxConfigBuilder.nodeTag(node.id);
        final target = Uri.encodeQueryComponent(url ?? settings.urlTestUrl);
        final path =
            '/proxies/${Uri.encodeComponent(tag)}/delay?timeout=5000&url=$target';
        try {
          final json = await _apiJson(settings, 'GET', path);
          final delay = int.tryParse(json['delay']?.toString() ?? '');
          if (delay != null && delay > 0) {
            node.latencyMs = delay;
            node.lastLatencyTest = DateTime.now();
            node.testError = null;
            node.probeStatus = NodeProbeStatus.proxyAvailable;
            notifyListeners();
            return delay;
          }
          // Some Clash-compatible APIs use 0 as a failed/unknown delay. Never
          // present that as a real 0 ms result. The TCP probe below is only a
          // reachability diagnostic and is never stored as proxy latency.
          node.testError = delay == null ? '未返回 delay' : 'API 返回无效延迟：$delay ms';
        } catch (e) {
          node.testError = _cleanException(e);
        }
      }

      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(
          node.server,
          node.port,
          timeout: const Duration(seconds: 4),
        );
        sw.stop();
        socket.destroy();
        final elapsedUs = sw.elapsedMicroseconds;
        final elapsedMs = elapsedUs <= 0 ? 1 : (elapsedUs + 999) ~/ 1000;
        node.latencyMs = elapsedMs;
        node.lastLatencyTest = DateTime.now();
        node.testError = null;
        node.probeStatus = NodeProbeStatus.tcpReachable;
        notifyListeners();
        return elapsedMs;
      } catch (e) {
        node.latencyMs = null;
        node.lastLatencyTest = DateTime.now();
        node.testError = _cleanException(e);
        node.probeStatus = NodeProbeStatus.failed;
        notifyListeners();
        return null;
      }
    } finally {
      testingNodeIds.remove(node.id);
      notifyListeners();
    }
  }

  Future<void> selectNodeRuntime(NodeProfile node, AppSettings settings) async {
    if (!isRunning) return;
    if (!node.enabled) throw StateError('目标节点已禁用');
    final tag = SingBoxConfigBuilder.nodeTag(node.id);
    await _selectProxyTag(settings, tag);
    _appendLog('运行时切换已验证：${node.name} -> $tag');
  }

  Future<void> _selectProxyTag(AppSettings settings, String tag) async {
    final before = await _apiJson(settings, 'GET', '/proxies/proxy');
    final previous = before['now']?.toString() ?? '';
    final all =
        (before['all'] as List?)?.map((item) => item.toString()).toSet() ??
        <String>{};
    if (all.isEmpty) {
      throw StateError('Core selector 没有返回可用节点');
    }
    if (!all.contains(tag)) {
      throw StateError('当前运行配置未包含目标节点，需要重载 Core');
    }

    try {
      await _apiJson(
        settings,
        'PUT',
        '/proxies/proxy',
        body: <String, dynamic>{'name': tag},
      );

      String active = '';
      for (var attempt = 0; attempt < 10; attempt++) {
        final after = await _apiJson(settings, 'GET', '/proxies/proxy');
        active = after['now']?.toString() ?? '';
        if (active == tag) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (active != tag) {
        throw StateError(
          active.isEmpty
              ? 'Core selector 没有返回当前节点'
              : 'Core 未切换到目标节点（当前：$active）',
        );
      }

      // The selector requests interruption itself, but explicitly closing
      // Clash connections also covers long-lived HTTP/2, WebSocket and QUIC
      // sessions that otherwise keep the old egress alive in applications.
      var connectionsCleared = false;
      try {
        await _apiJson(settings, 'DELETE', '/connections');
        connectionsCleared = true;
      } catch (error) {
        _appendLog('清理旧连接未完成：${_cleanException(error)}');
      }

      final target = settings.urlTestUrl.trim().isEmpty
          ? 'https://www.gstatic.com/generate_204'
          : settings.urlTestUrl.trim();
      final delay = await _apiJson(
        settings,
        'GET',
        '/proxies/proxy/delay?timeout=8000&url=${Uri.encodeComponent(target)}',
      );
      final delayMs = _metricInt(delay['delay']) ?? 0;
      if (delayMs <= 0) {
        throw StateError('Core 已选择目标节点，但代理链路验证失败');
      }
      final confirmed = await _apiJson(settings, 'GET', '/proxies/proxy');
      if (confirmed['now']?.toString() != tag) {
        throw StateError('代理链路测试后 selector 状态发生变化');
      }
      activeNodeTag = tag;
      _appendLog(
        'Selector 确认：$tag · ${delayMs}ms · '
        '${connectionsCleared ? '旧连接已提交清理' : '旧连接清理请求超时'}',
      );
      notifyListeners();
    } catch (_) {
      if (previous.isNotEmpty && previous != tag && all.contains(previous)) {
        try {
          await _apiJson(
            settings,
            'PUT',
            '/proxies/proxy',
            body: <String, dynamic>{'name': previous},
          );
          activeNodeTag = previous;
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> requestServiceStatus() async {
    final reply = await _sendIpc('status');
    final result = reply['result'];
    serviceInfo = result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{};
    ipcConnected = reply['ok'] == true;
    notifyListeners();
    return serviceInfo;
  }

  Future<void> _waitForServiceReady(AppSettings settings) async {
    final ready = _readyCompleter;
    if (ready == null) throw StateError('Service 启动握手未初始化');

    try {
      await ready.future.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      final stderr = _compactError(_stderrTail.join('\n'));
      throw ServiceStartException(
        '核心启动',
        '12 秒内未收到 HONGDA_READY',
        detail: stderr,
      );
    }

    _setStartup(
      StartupStage.waitingApi,
      'HongdaService 已启动，等待 Clash API ${settings.apiPort}',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    Object? lastProbeError;
    while (DateTime.now().isBefore(deadline)) {
      if (_process == null) {
        final structured = lastServiceError;
        if (structured != null) {
          throw ServiceStartException(
            _phaseTitle(structured['phase']?.toString() ?? '核心启动'),
            structured['message']?.toString() ?? 'HongdaCore 已退出',
            detail: structured['detail']?.toString() ?? '',
          );
        }
        throw StateError(lastError ?? 'HongdaService 启动后立即退出');
      }
      try {
        await _apiJson(settings, 'GET', '/version');
        _appendLog('Clash API 已就绪：127.0.0.1:${settings.apiPort}');
        return;
      } catch (e) {
        lastProbeError = e;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    final stderr = _compactError(_stderrTail.join('\n'));
    final probe = lastProbeError == null ? '' : _cleanException(lastProbeError);
    throw ServiceStartException(
      'Clash API',
      '核心进程已启动，但 API 在 15 秒内没有就绪',
      detail: <String>[
        if (stderr.isNotEmpty) stderr,
        if (probe.isNotEmpty) probe,
      ].join(' · '),
    );
  }

  Future<bool> _isPortAvailable(int port) async {
    if (port < 1 || port > 65535) return false;
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
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
      final candidate = base + offset <= 65535
          ? base + offset
          : 1024 + (base + offset - 65536);
      if (reserved.contains(candidate)) continue;
      if (await _isPortAvailable(candidate)) return candidate;
    }

    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      if (reserved.contains(socket.port)) {
        throw StateError('系统分配的本地端口发生冲突，请重试');
      }
      return socket.port;
    } on SocketException catch (e) {
      throw StateError('无法分配本地监听端口：${e.message}');
    } finally {
      await socket?.close();
    }
  }

  Future<void> _cleanupFailedStart(AppSettings settings) async {
    try {
      await WindowsIntegration.setSystemProxy(
        enabled: false,
        port: settings.mixedPort,
      );
    } catch (_) {}
    try {
      await WindowsIntegration.setTunProxySuspended(false);
    } catch (_) {}
    _stopMetrics();
    _stopTrafficPersistence();

    final process = _process;
    if (process != null) {
      try {
        final id = _nextIpcId();
        process.stdin.writeln(
          jsonEncode(<String, dynamic>{'id': id, 'method': 'stop'}),
        );
        await process.stdin.flush();
        await process.exitCode.timeout(const Duration(seconds: 4));
      } catch (_) {
        try {
          process.kill();
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      }
    }
    _process = null;
    activeNodeTag = null;
    tunRoutingVerified = null;
    tunRoutingDetail = 'TUN 未启用';
    _stopIpc();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
  }

  void _handleStderrLine(String line) {
    final cleaned = _stripAnsi(line).trim();
    if (cleaned.isEmpty) return;

    final lower = cleaned.toLowerCase();
    final isServiceError = cleaned.startsWith('HONGDA_ERROR ');
    final isActualError =
        isServiceError ||
        lower.contains(' error[') ||
        lower.contains(' fatal[') ||
        lower.contains(' panic') ||
        lower.contains(' level=error');

    _stderrTail.add(cleaned);
    if (_stderrTail.length > 18) _stderrTail.removeAt(0);

    if (isServiceError) {
      final payload = cleaned.substring('HONGDA_ERROR '.length).trim();
      try {
        final decoded = jsonDecode(payload);
        if (decoded is Map) {
          final incoming = Map<String, dynamic>.from(decoded);
          if (_shouldReplaceServiceError(lastServiceError, incoming)) {
            lastServiceError = incoming;
          }
          final selected = lastServiceError ?? incoming;
          final phase = _phaseTitle(selected['phase']?.toString() ?? 'Service');
          final message = selected['message']?.toString() ?? '未知错误';
          final detail = selected['detail']?.toString() ?? '';
          startupDetail = detail.isEmpty
              ? '$phase：$message'
              : '$phase：$message · $detail';
        }
      } catch (_) {}
    }

    // HongdaService deliberately forwards HongdaCore stdout/stderr through its
    // stderr pipe so stdout stays reserved for READY/IPC frames. Therefore a
    // line arriving on stderr is not automatically an error. Also suppress
    // per-packet INFO chatter unless the user explicitly selected debug/trace.
    final verbose = _runtimeLogLevel == 'debug' || _runtimeLogLevel == 'trace';
    final routineTraffic =
        lower.contains('inbound packet connection') ||
        lower.contains('outbound packet connection') ||
        lower.contains('inbound connection from') ||
        lower.contains('inbound connection to') ||
        lower.contains('outbound connection to');
    if (routineTraffic && !verbose && !isActualError) return;

    _appendLog(cleaned, error: isActualError);
  }

  void _handleStdoutLine(String line) {
    if (line.startsWith('HONGDA_IPC ')) {
      try {
        final payload = jsonDecode(line.substring('HONGDA_IPC '.length));
        if (payload is Map) {
          final map = Map<String, dynamic>.from(payload);
          final id = map['id']?.toString();
          if (id != null) {
            final completer = _ipcPending.remove(id);
            if (completer != null && !completer.isCompleted) {
              completer.complete(map);
            }
          }
          ipcConnected = true;
          notifyListeners();
          return;
        }
      } catch (_) {
        // Malformed IPC is surfaced as a normal log line below.
      }
    }
    if (line.startsWith('HONGDA_READY')) {
      final ready = _readyCompleter;
      if (ready != null && !ready.isCompleted) ready.complete();
      _appendLog('HongdaService 已就绪');
      return;
    }
    _appendLog(line);
  }

  Future<void> _probeIpc({bool required = false}) async {
    try {
      final reply = await _sendIpc('ping', timeout: const Duration(seconds: 3));
      ipcConnected = reply['ok'] == true;
      if (!ipcConnected) throw StateError('IPC ping 返回失败');
      await requestServiceStatus();
      _appendLog('Service IPC 已连接');
    } catch (e) {
      ipcConnected = false;
      if (required) {
        throw StateError('Service IPC 握手失败：${_cleanException(e)}');
      }
      _appendLog('Service IPC 未响应', error: true);
    }
  }

  void _startIpcHeartbeat() {
    _ipcTimer?.cancel();
    _ipcTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (_process == null) return;
      try {
        final reply = await _sendIpc(
          'ping',
          timeout: const Duration(seconds: 2),
        );
        final connected = reply['ok'] == true;
        if (ipcConnected != connected) {
          ipcConnected = connected;
          notifyListeners();
        }
      } catch (_) {
        if (ipcConnected) {
          ipcConnected = false;
          notifyListeners();
        }
      }
    });
  }

  void _stopIpc() {
    _ipcTimer?.cancel();
    _ipcTimer = null;
    for (final completer in _ipcPending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Service IPC stopped'));
      }
    }
    _ipcPending.clear();
    ipcConnected = false;
  }

  Future<Map<String, dynamic>> _sendIpc(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final process = _process;
    if (process == null) throw StateError('HongdaService 未运行');
    final id = _nextIpcId();
    final completer = Completer<Map<String, dynamic>>();
    _ipcPending[id] = completer;
    process.stdin.writeln(
      jsonEncode(<String, dynamic>{
        'id': id,
        'method': method,
        if (params != null) 'params': params,
      }),
    );
    await process.stdin.flush();
    try {
      return await completer.future.timeout(timeout);
    } finally {
      _ipcPending.remove(id);
    }
  }

  String _nextIpcId() =>
      'ipc-${DateTime.now().microsecondsSinceEpoch}-${_ipcSequence++}';

  String _stripAnsi(String value) =>
      value.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');

  void _appendLog(String line, {bool error = false}) {
    final now = DateTime.now().toIso8601String();
    final clock = now.length >= 19 ? now.substring(11, 19) : now;
    final text = '[$clock] ${error ? '[ERR] ' : ''}$line';
    logs.add(text);
    if (logs.length > 1500) logs.removeRange(0, logs.length - 1200);
    notifyListeners();
  }

  void _startMetrics(AppSettings settings) {
    _stopMetrics();
    final generation = ++_metricsGeneration;
    unawaited(_connectTraffic(settings, generation));
    _apiTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollConnections(settings),
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
    _lastWebSocketTrafficAt = null;
    _lastFallbackTrafficAt = null;
    _lastConnectionSampleAt = null;
    _lastConnectionTotalsAt = null;
    _connectionCounter.reset();
    _connectionUploadTotals = <String, int>{};
    _connectionDownloadTotals = <String, int>{};
    _trafficFallbackLogged = false;
  }

  void _startTrafficPersistence() {
    _trafficPersistTimer?.cancel();
    _trafficPersistTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_persistTraffic()),
    );
  }

  void _stopTrafficPersistence() {
    _trafficPersistTimer?.cancel();
    _trafficPersistTimer = null;
  }

  Future<void> _persistTraffic() async {
    try {
      await storage.saveTrafficStats(trafficStats);
    } catch (_) {
      // Traffic persistence should never disconnect the tunnel.
    }
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
      // Clash/mihomo WebSocket authentication uses a `token` query parameter,
      // not an Authorization header (browsers cannot set headers on WS).
      final query = settings.clashApiSecret.isEmpty
          ? ''
          : '?token=${Uri.encodeQueryComponent(settings.clashApiSecret)}';
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${settings.apiPort}/traffic$query',
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
            final payload = data is List<int>
                ? utf8.decode(data, allowMalformed: true)
                : data.toString();
            final json = jsonDecode(payload);
            if (json is Map) {
              final now = DateTime.now();
              _lastWebSocketTrafficAt = now;
              final previous = _lastTrafficSampleAt ?? now;
              final elapsed = now.difference(previous).inMilliseconds / 1000.0;
              _lastTrafficSampleAt = now;
              final websocketUpload = _metricNumber(json['up']);
              final websocketDownload = _metricNumber(json['down']);
              final keepFallback =
                  websocketUpload == 0 &&
                  websocketDownload == 0 &&
                  _lastFallbackTrafficAt != null &&
                  now.difference(_lastFallbackTrafficAt!) <
                      const Duration(seconds: 3);
              if (!keepFallback) {
                uploadBytesPerSecond = websocketUpload;
                downloadBytesPerSecond = websocketDownload;
              }
              // /connections exposes authoritative cumulative byte counters.
              // Only integrate WebSocket speeds when those counters are not
              // available, otherwise every byte would be counted twice.
              final cumulativeFresh =
                  _lastConnectionTotalsAt != null &&
                  now.difference(_lastConnectionTotalsAt!) <
                      const Duration(seconds: 5);
              if (!cumulativeFresh) {
                final boundedElapsed = elapsed.clamp(0.25, 3.0);
                final up = (uploadBytesPerSecond * boundedElapsed).round();
                final down = (downloadBytesPerSecond * boundedElapsed).round();
                totalUploadBytes += up;
                totalDownloadBytes += down;
                trafficStats.add(upload: up, download: down, at: now);
              }
              notifyListeners();
            }
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
        final connections = json['connections'] as List;
        activeConnections = connections.length;
        final now = DateTime.now();
        final previousAt = _lastConnectionSampleAt;
        final cumulativeDelta = _connectionCounter.sample(json);
        final hasRootTotals = cumulativeDelta != null;
        var uploadDelta = 0;
        var downloadDelta = 0;
        final nextUploadTotals = <String, int>{};
        final nextDownloadTotals = <String, int>{};
        var connectionIndex = 0;
        for (final item in connections) {
          if (item is! Map) continue;
          final id =
              item['id']?.toString() ?? 'connection-${connectionIndex++}';
          final upload = _metricInt(item['upload']) ?? 0;
          final download = _metricInt(item['download']) ?? 0;
          final previousUpload = _connectionUploadTotals[id];
          final previousDownload = _connectionDownloadTotals[id];
          if (!hasRootTotals && previousUpload != null) {
            uploadDelta += math.max(0, upload - previousUpload).toInt();
          }
          if (!hasRootTotals && previousDownload != null) {
            downloadDelta += math.max(0, download - previousDownload).toInt();
          }
          nextUploadTotals[id] = upload;
          nextDownloadTotals[id] = download;
        }

        if (hasRootTotals) {
          uploadDelta = cumulativeDelta.upload;
          downloadDelta = cumulativeDelta.download;
          _lastConnectionTotalsAt = now;
        }

        final websocketStale =
            _lastWebSocketTrafficAt == null ||
            now.difference(_lastWebSocketTrafficAt!) >
                const Duration(seconds: 4);
        if (previousAt != null) {
          final seconds = now.difference(previousAt).inMilliseconds / 1000.0;
          final hasTraffic = uploadDelta > 0 || downloadDelta > 0;
          if (seconds > 0 &&
              (websocketStale ||
                  ((uploadBytesPerSecond == 0 && downloadBytesPerSecond == 0) &&
                      hasTraffic))) {
            uploadBytesPerSecond = uploadDelta / seconds;
            downloadBytesPerSecond = downloadDelta / seconds;
            _lastFallbackTrafficAt = now;
          }

          // Top-level Clash counters include connections that opened and
          // closed between polls. Per-connection sums miss those short-lived
          // requests and were the reason the graph stayed at zero.
          if (hasRootTotals && hasTraffic) {
            totalUploadBytes += uploadDelta;
            totalDownloadBytes += downloadDelta;
            trafficStats.add(
              upload: uploadDelta,
              download: downloadDelta,
              at: now,
            );
          } else if (!hasRootTotals && websocketStale && hasTraffic) {
            totalUploadBytes += uploadDelta;
            totalDownloadBytes += downloadDelta;
            trafficStats.add(
              upload: uploadDelta,
              download: downloadDelta,
              at: now,
            );
          }
          if ((websocketStale || !hasRootTotals) &&
              hasTraffic &&
              !_trafficFallbackLogged) {
            _trafficFallbackLogged = true;
            _appendLog('实时流量使用 Clash connections 累计计数');
          }
          if (websocketStale && !hasTraffic) {
            uploadBytesPerSecond = 0;
            downloadBytesPerSecond = 0;
          }
        }
        _lastConnectionSampleAt = now;
        _connectionUploadTotals = nextUploadTotals;
        _connectionDownloadTotals = nextDownloadTotals;
        notifyListeners();
      }
    } catch (_) {
      // Metrics are optional; a failed poll must not affect the tunnel.
    }
  }

  Future<void> _verifyTunRouting(AppSettings settings) async {
    WindowsTunRoutingStatus? latest;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        latest = await WindowsIntegration.inspectTunRouting();
        tunRoutingVerified = latest.ready;
        tunRoutingDetail = latest.detail;
        notifyListeners();
        if (latest.ready) {
          _appendLog('TUN 路由表验证通过：${latest.detail}');
          break;
        }
      } catch (error) {
        tunRoutingVerified = false;
        tunRoutingDetail = '无法读取 TUN 路由：${_cleanException(error)}';
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    if (latest?.ready != true) {
      throw ServiceStartException(
        'TUN 路由',
        'HongdaTun 未接管 Windows 系统流量',
        detail: latest?.detail ?? tunRoutingDetail,
      );
    }

    final error = await _probeTunHttps(settings);
    if (error != null) {
      tunRoutingVerified = false;
      tunRoutingDetail = '路由存在，但 TUN HTTPS 探针失败：$error';
      notifyListeners();
      throw ServiceStartException(
        'TUN 联网',
        'HongdaTun 已建立但无法通过代理访问互联网',
        detail: error,
      );
    }
    tunRoutingVerified = true;
    tunRoutingDetail = '${latest!.detail}；HTTPS 联网通过';
    _appendLog('TUN 真实联网验证通过');
    notifyListeners();
  }

  Future<String?> _probeTunHttps(AppSettings settings) async {
    final configured = Uri.tryParse(settings.urlTestUrl.trim());
    final targets = <Uri>{
      if (configured != null && configured.scheme == 'https') configured,
      Uri.parse('https://www.gstatic.com/generate_204'),
      Uri.parse('https://cp.cloudflare.com/generate_204'),
    };
    Object? lastError;
    for (final target in targets) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..findProxy = (_) => 'DIRECT';
      try {
        final request = await client
            .getUrl(target)
            .timeout(const Duration(seconds: 7));
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.headers.set(HttpHeaders.connectionHeader, 'close');
        final response = await request.close().timeout(
          const Duration(seconds: 9),
        );
        await response.drain<void>();
        if (response.statusCode >= 200 && response.statusCode < 400) {
          return null;
        }
        lastError = 'HTTP ${response.statusCode} (${target.host})';
      } catch (error) {
        lastError = error;
      } finally {
        client.close(force: true);
      }
    }
    return _cleanException(lastError ?? '所有 HTTPS 探针均失败');
  }

  double _metricNumber(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  int? _metricInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
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
          break;
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

  void _setStartup(StartupStage stage, String detail) {
    startupStage = stage;
    startupDetail = detail;
    notifyListeners();
  }

  Map<String, dynamic>? _extractServiceError(String text) {
    Map<String, dynamic>? selected;
    for (final raw in text.replaceAll('\r', '').split('\n')) {
      final line = raw.trim();
      if (!line.startsWith('HONGDA_ERROR ')) continue;
      try {
        final decoded = jsonDecode(line.substring('HONGDA_ERROR '.length));
        if (decoded is Map) {
          final incoming = Map<String, dynamic>.from(decoded);
          if (_shouldReplaceServiceError(selected, incoming))
            selected = incoming;
        }
      } catch (_) {}
    }
    return selected;
  }

  bool _shouldReplaceServiceError(
    Map<String, dynamic>? current,
    Map<String, dynamic> incoming,
  ) {
    if (current == null) return true;
    return _serviceErrorPriority(incoming['phase']?.toString() ?? '') >=
        _serviceErrorPriority(current['phase']?.toString() ?? '');
  }

  int _serviceErrorPriority(String phase) {
    switch (phase) {
      case 'service':
        return 0;
      case 'core_exit':
        return 2;
      case 'core_extract':
      case 'config_path':
      case 'config_missing':
      case 'config_check':
      case 'core_pipe':
      case 'core_start':
      case 'core_supervision':
        return 3;
      default:
        return 1;
    }
  }

  String _phaseTitle(String phase) {
    switch (phase) {
      case 'core_extract':
        return '内嵌核心释放';
      case 'config_path':
        return '配置路径';
      case 'config_missing':
        return '配置文件';
      case 'config_check':
        return '配置校验';
      case 'core_pipe':
        return '核心管道';
      case 'core_start':
        return '核心启动';
      case 'core_exit':
        return '核心进程';
      case 'core_supervision':
        return '核心进程监管';
      case 'service':
        return 'HongdaService';
      default:
        return phase.isEmpty ? 'HongdaService' : phase;
    }
  }

  String _compactError(String text) {
    final lines = text
        .replaceAll('\r', '')
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (lines.isEmpty) return '';
    final joined = lines.take(5).join(' | ');
    return joined.length > 420 ? '${joined.substring(0, 420)}…' : joined;
  }

  String _cleanException(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');

  @override
  void dispose() {
    _stopMetrics();
    _stopIpc();
    _stopTrafficPersistence();
    final process = _process;
    _process = null;
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    super.dispose();
  }
}

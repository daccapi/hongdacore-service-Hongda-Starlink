import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'clash_traffic_counter.dart';
import 'core_manager.dart';
import 'latency_metrics.dart';
import 'models.dart';
import 'node_health.dart';
import 'tun_watchdog_health.dart';
import 'singbox_config_builder.dart';
import 'selector_delay_probe.dart';
import 'storage.dart';
import 'windows_integration.dart';

enum CoreStatus { stopped, starting, running, stopping, error }

class ConnectionLogEntry {
  const ConnectionLogEntry({
    required this.id,
    required this.network,
    required this.source,
    required this.destination,
    required this.domain,
    required this.route,
    required this.outbound,
    required this.rule,
    required this.startedAt,
    required this.closedAt,
    required this.active,
    required this.upload,
    required this.download,
  });

  factory ConnectionLogEntry.fromJson(Map<String, dynamic> json) {
    DateTime? parseTime(dynamic value) {
      final parsed = DateTime.tryParse(value?.toString() ?? '');
      return parsed?.toLocal();
    }

    int parseBytes(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return ConnectionLogEntry(
      id: json['id']?.toString() ?? '',
      network: json['network']?.toString().toUpperCase() ?? '',
      source: json['source']?.toString() ?? '',
      destination: json['destination']?.toString() ?? '',
      domain: json['domain']?.toString() ?? '',
      route: json['route']?.toString() ?? '',
      outbound: json['outbound']?.toString() ?? '',
      rule: json['rule']?.toString() ?? '',
      startedAt: parseTime(json['startedAt']),
      closedAt: parseTime(json['closedAt']),
      active: json['status']?.toString() != 'closed',
      upload: parseBytes(json['upload']),
      download: parseBytes(json['download']),
    );
  }

  final String id;
  final String network;
  final String source;
  final String destination;
  final String domain;
  final String route;
  final String outbound;
  final String rule;
  final DateTime? startedAt;
  final DateTime? closedAt;
  final bool active;
  final int upload;
  final int download;

  String get target => domain.isEmpty ? destination : domain;
  int get total => upload + download;
}

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
  Future<void> _logWriteQueue = Future<void>.value();

  CoreStatus status = CoreStatus.stopped;
  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  Timer? _apiTimer;
  Timer? _ipcTimer;
  Timer? _trafficPersistTimer;
  Timer? _trafficReconnectTimer;
  Timer? _connectionReconnectTimer;
  Timer? _tunWatchdogTimer;
  int _tunWatchdogFailures = 0;
  final _tunWatchdogHealth = TunWatchdogHealth();
  int _tunWatchdogGeneration = 0;
  bool _tunWatchdogChecking = false;
  bool _tunWatchdogIssueLogged = false;
  WebSocket? _trafficSocket;
  WebSocket? _connectionSocket;
  bool _connectionConnecting = false;
  DateTime? _lastTrafficSampleAt;
  DateTime? _lastWebSocketTrafficAt;
  DateTime? _lastConnectionWebSocketAt;
  DateTime? _lastFallbackTrafficAt;
  DateTime? _lastConnectionSampleAt;
  DateTime? _lastConnectionTotalsAt;
  final ClashTrafficCounter _connectionCounter = ClashTrafficCounter();
  Map<String, int> _connectionUploadTotals = <String, int>{};
  Map<String, int> _connectionDownloadTotals = <String, int>{};
  bool _trafficFallbackLogged = false;
  bool _connectionStreamLogged = false;
  int _metricsGeneration = 0;
  int _ipcSequence = 0;
  Completer<void>? _readyCompleter;
  final Map<String, Completer<Map<String, dynamic>>> _ipcPending =
      <String, Completer<Map<String, dynamic>>>{};
  Map<String, String> _connectionNodeNames = <String, String>{};
  final List<String> _stderrTail = <String>[];
  String _runtimeLogLevel = 'warn';

  final List<String> logs = <String>[];
  List<ConnectionLogEntry> connectionLogs = <ConnectionLogEntry>[];
  int _connectionLogCursor = 0;
  DateTime? _lastConnectionLogRefreshAt;
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
  int unexpectedExitSerial = 0;

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
    _stopTunWatchdog();
    activeNodeTag = null;
    tunRoutingVerified = settings.tunEnabled ? false : null;
    tunRoutingDetail = settings.tunEnabled ? '等待 HongdaTun 路由' : 'TUN 未启用';
    _stderrTail.clear();
    _runtimeLogLevel = settings.logLevel.trim().toLowerCase();
    final availableNodes = nodes ?? <NodeProfile>[selectedNode];
    _connectionNodeNames = <String, String>{
      for (final node in availableNodes)
        SingBoxConfigBuilder.nodeTag(node.id): node.name,
    };
    status = CoreStatus.starting;
    _setStartup(StartupStage.locatingService, '正在定位 HongdaService.exe');

    try {
      final selectedUnsupportedReason =
          SingBoxConfigBuilder.unsupportedNodeReason(selectedNode);
      if (selectedUnsupportedReason != null) {
        throw ServiceStartException(
          '节点协议',
          'HongdaCore 1.10：$selectedUnsupportedReason',
          detail: '请选择参数兼容的 VLESS、Trojan、Hysteria2 或 TUIC 节点。',
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
        'hysteria2-salamander',
        'dns-route-cache',
        'tls-sni-sniff',
        'clash-api',
        'connection-log',
        'connection-log-delta',
        'connection-stream',
        'rule-set-fallback',
        'rule-set-offline-start',
        'rule-set-prefix-trie',
        'loopback-api',
        'dns-cache-persistent',
        'dns-cache-dpapi',
        'urltest-tolerance',
        'delay-phase-metrics',
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
      if (settings.allowInsecureTls) {
        _appendLog('TLS 兼容模式：已跳过代理节点入口证书校验；目标网站 HTTPS 证书仍严格验证');
      }
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
      final skippedNodes = allNodes
          .where((node) => !SingBoxConfigBuilder.supportsNode(node))
          .toList();
      if (skippedNodes.isNotEmpty) {
        final examples = skippedNodes
            .take(3)
            .map(
              (node) =>
                  '${node.name}（${SingBoxConfigBuilder.unsupportedNodeReason(node)}）',
            )
            .join('、');
        _appendLog(
          '本次运行跳过 ${skippedNodes.length} 个不兼容节点：$examples'
          '${skippedNodes.length > 3 ? ' 等' : ''}',
        );
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
        process.exitCode.then((code) async {
          if (_process == process && status != CoreStatus.stopping) {
            final details = _compactError(_stderrTail.join('\n'));
            _appendLog('HongdaService 意外退出，代码 $code', error: true);
            _process = null;
            status = CoreStatus.error;
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
            final pendingReady = _readyCompleter;
            if (pendingReady != null && !pendingReady.isCompleted) {
              pendingReady.completeError(
                StateError(lastError ?? 'HongdaService 已退出'),
              );
            }
            _stopMetrics();
            _stopIpc();
            _stopTunWatchdog();
            try {
              await WindowsIntegration.setSystemProxy(
                enabled: false,
                port: settings.mixedPort,
              );
            } catch (_) {}
            try {
              await WindowsIntegration.setTunProxySuspended(false);
            } catch (_) {}
            await storage.deleteRuntimeConfig();
            unexpectedExitSerial++;
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
        node: selectedNode,
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
      if (settings.tunEnabled) _startTunWatchdog(settings);
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
    if (status == CoreStatus.stopped) {
      await storage.deleteRuntimeConfig();
      return;
    }
    if (status == CoreStatus.stopping) return;
    status = CoreStatus.stopping;
    notifyListeners();
    try {
      try {
        await WindowsIntegration.setSystemProxy(
          enabled: false,
          port: settings.mixedPort,
        );
      } catch (error) {
        _appendLog('恢复 Windows 系统代理失败：${_cleanException(error)}', error: true);
      }
      try {
        await WindowsIntegration.setTunProxySuspended(false);
      } catch (error) {
        _appendLog('恢复 TUN 前代理快照失败：${_cleanException(error)}', error: true);
      }
      _stopMetrics();
      _stopIpc();
      _stopTrafficPersistence();
      _stopTunWatchdog();
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
      await storage.deleteRuntimeConfig();
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
      final endpointRttFuture = _measureNodeRtt(node);
      node.testError = null;
      if (isRunning) {
        final tag = SingBoxConfigBuilder.nodeTag(node.id);
        final target = Uri.encodeQueryComponent(url ?? settings.urlTestUrl);
        final path =
            '/proxies/${Uri.encodeComponent(tag)}/delay?timeout=5000&url=$target';
        try {
          final json = await _apiJson(settings, 'GET', path);
          final proxyMetrics = ProxyDelayMetrics.fromJson(json);
          if (proxyMetrics.succeeded) {
            final endpointRtt = await endpointRttFuture;
            final displayed = displayedNodeLatency(
              endpointRttMs: endpointRtt,
              proxy: proxyMetrics,
            );
            node.latencyMs = displayed;
            node.proxyConnectDelayMs = proxyMetrics.connectDelayMs;
            node.proxyTotalDelayMs = proxyMetrics.totalDelayMs;
            node.lastLatencyTest = DateTime.now();
            node.testError = null;
            node.probeStatus = NodeProbeStatus.proxyAvailable;
            notifyListeners();
            return displayed;
          }
          // Some Clash-compatible APIs use 0 as a failed/unknown delay. Never
          // present that as a real 0 ms result. The endpoint RTT below remains
          // a reachability diagnostic if the full proxy URLTest failed.
          node.testError = 'API 未返回有效代理延迟';
        } catch (e) {
          node.testError = _cleanException(e);
        }
      }

      final elapsedMs = await endpointRttFuture;
      if (elapsedMs != null) {
        node.latencyMs = elapsedMs;
        node.proxyConnectDelayMs = null;
        node.proxyTotalDelayMs = null;
        node.lastLatencyTest = DateTime.now();
        node.probeStatus = NodeProbeStatus.tcpReachable;
        notifyListeners();
        return elapsedMs;
      }
      node.latencyMs = null;
      node.proxyConnectDelayMs = null;
      node.proxyTotalDelayMs = null;
      node.lastLatencyTest = DateTime.now();
      final tcpProbeSupported = supportsEndpointTcpProbe(node);
      node.testError ??= tcpProbeSupported
          ? '节点服务器 TCP 连接超时'
          : '此协议使用 QUIC/UDP，请连接后进行真实代理测速';
      node.probeStatus = !isRunning && !tcpProbeSupported
          ? NodeProbeStatus.untested
          : NodeProbeStatus.failed;
      notifyListeners();
      return null;
    } finally {
      testingNodeIds.remove(node.id);
      notifyListeners();
    }
  }

  Future<void> selectNodeRuntime(NodeProfile node, AppSettings settings) async {
    if (!isRunning) return;
    if (!node.enabled) throw StateError('目标节点已禁用');
    final tag = SingBoxConfigBuilder.nodeTag(node.id);
    await _selectProxyTag(settings, tag, node: node);
    _appendLog('运行时切换已验证：${node.name} -> $tag');
  }

  Future<void> _selectProxyTag(
    AppSettings settings,
    String tag, {
    NodeProfile? node,
  }) async {
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

      // Selector state and URLTest latency are two different signals. A
      // certificate problem on one public test URL must not roll back a
      // selector that Core has already confirmed, nor tear down the service.
      // Real TUN HTTPS validation still runs below in _verifyTunRouting and
      // keeps normal certificate verification enabled.
      final endpointRttFuture = node == null
          ? Future<int?>.value(null)
          : _measureNodeRtt(node);
      final delayProbe = await probeSelectorDelay(
        configuredUrl: settings.urlTestUrl,
        request: (target) => _apiJson(
          settings,
          'GET',
          '/proxies/proxy/delay?timeout=5000&url=${Uri.encodeComponent(target)}',
        ),
      );
      final confirmed = await _apiJson(settings, 'GET', '/proxies/proxy');
      if (confirmed['now']?.toString() != tag) {
        throw StateError('代理链路测试后 selector 状态发生变化');
      }
      activeNodeTag = tag;
      final connectionMessage = connectionsCleared ? '旧连接已提交清理' : '旧连接清理请求超时';
      if (delayProbe.succeeded) {
        final endpointRtt = await endpointRttFuture;
        final proxyMetrics = ProxyDelayMetrics(
          connectDelayMs: delayProbe.connectDelayMs,
          totalDelayMs: delayProbe.delayMs,
        );
        final displayed = displayedNodeLatency(
          endpointRttMs: endpointRtt,
          proxy: proxyMetrics,
        );
        if (node != null) {
          node.latencyMs = displayed;
          node.proxyConnectDelayMs = delayProbe.connectDelayMs;
          node.proxyTotalDelayMs = delayProbe.delayMs;
          node.lastLatencyTest = DateTime.now();
          node.testError = null;
          node.probeStatus = NodeProbeStatus.proxyAvailable;
        }
        final nodeLatencyText = endpointRtt == null
            ? '${displayed ?? '--'}ms（代理传输建立）'
            : '${endpointRtt}ms';
        _appendLog(
          'Selector 确认：$tag · 节点 RTT $nodeLatencyText · '
          '完整代理探针 ${delayProbe.delayMs}ms · $connectionMessage',
        );
      } else {
        _appendLog(
          'Selector 确认：$tag · $connectionMessage；延迟探针暂不可用（不影响连接）：'
          '${_cleanException(delayProbe.error ?? '未知错误')}',
        );
      }
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

  Future<int?> _measureNodeRtt(NodeProfile node) async {
    if (!supportsEndpointTcpProbe(node)) return null;
    final samples = <int>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      final stopwatch = Stopwatch()..start();
      Socket? socket;
      try {
        socket = await Socket.connect(
          node.server,
          node.port,
          timeout: const Duration(milliseconds: 1500),
        );
        stopwatch.stop();
        final elapsedUs = stopwatch.elapsedMicroseconds;
        samples.add(elapsedUs <= 0 ? 1 : (elapsedUs + 999) ~/ 1000);
      } catch (_) {
        stopwatch.stop();
      } finally {
        socket?.destroy();
      }
    }
    if (samples.isEmpty) return null;
    samples.sort();
    return samples[samples.length ~/ 2];
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
    _stopTunWatchdog();

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
    await storage.deleteRuntimeConfig();
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
    _logWriteQueue = _logWriteQueue
        .then<void>((_) async {
          await storage.appendClientLog(text);
        })
        .onError((_, _) {});
    notifyListeners();
  }

  void _startMetrics(AppSettings settings) {
    _stopMetrics();
    connectionLogs = <ConnectionLogEntry>[];
    _connectionLogCursor = 0;
    _lastConnectionLogRefreshAt = null;
    final generation = ++_metricsGeneration;
    unawaited(_connectTraffic(settings, generation));
    unawaited(_connectConnections(settings, generation));
    _apiTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshConnectionMetrics(settings)),
    );
  }

  void _stopMetrics() {
    _metricsGeneration++;
    _apiTimer?.cancel();
    _apiTimer = null;
    _trafficReconnectTimer?.cancel();
    _trafficReconnectTimer = null;
    _connectionReconnectTimer?.cancel();
    _connectionReconnectTimer = null;
    _trafficSocket?.close();
    _trafficSocket = null;
    _connectionSocket?.close();
    _connectionSocket = null;
    _connectionConnecting = false;
    _lastTrafficSampleAt = null;
    _lastWebSocketTrafficAt = null;
    _lastConnectionWebSocketAt = null;
    _lastFallbackTrafficAt = null;
    _lastConnectionSampleAt = null;
    _lastConnectionTotalsAt = null;
    _connectionCounter.reset();
    _connectionUploadTotals = <String, int>{};
    _connectionDownloadTotals = <String, int>{};
    _trafficFallbackLogged = false;
    _connectionStreamLogged = false;
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

  void _scheduleConnectionReconnect(AppSettings settings, int generation) {
    if (!isRunning || generation != _metricsGeneration) return;
    _connectionReconnectTimer?.cancel();
    _connectionReconnectTimer = Timer(const Duration(seconds: 1), () {
      if (isRunning && generation == _metricsGeneration) {
        unawaited(_connectConnections(settings, generation));
      }
    });
  }

  Future<void> _connectConnections(AppSettings settings, int generation) async {
    if (!isRunning ||
        generation != _metricsGeneration ||
        _connectionConnecting ||
        _connectionSocket != null) {
      return;
    }
    _connectionConnecting = true;
    try {
      final query = settings.clashApiSecret.isEmpty
          ? ''
          : '?token=${Uri.encodeQueryComponent(settings.clashApiSecret)}';
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:${settings.apiPort}/connections$query',
      );
      if (!isRunning || generation != _metricsGeneration) {
        await socket.close();
        return;
      }
      await _connectionSocket?.close();
      _connectionSocket = socket;
      socket.listen(
        (data) {
          try {
            final payload = data is List<int>
                ? utf8.decode(data, allowMalformed: true)
                : data.toString();
            final decoded = jsonDecode(payload);
            if (decoded is! Map) return;
            _lastConnectionWebSocketAt = DateTime.now();
            _applyConnectionsSnapshot(Map<String, dynamic>.from(decoded));
            if (!_connectionStreamLogged) {
              _connectionStreamLogged = true;
              _appendLog('连接监控已切换为 WebSocket 实时流');
            }
          } catch (_) {}
        },
        onDone: () {
          if (identical(_connectionSocket, socket)) {
            _connectionSocket = null;
          }
          _scheduleConnectionReconnect(settings, generation);
        },
        onError: (_) {
          if (identical(_connectionSocket, socket)) {
            _connectionSocket = null;
          }
          _scheduleConnectionReconnect(settings, generation);
        },
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleConnectionReconnect(settings, generation);
    } finally {
      _connectionConnecting = false;
    }
  }

  Future<void> _refreshConnectionMetrics(AppSettings settings) async {
    if (!isRunning) return;
    final now = DateTime.now();
    final streamStale =
        _lastConnectionWebSocketAt == null ||
        now.difference(_lastConnectionWebSocketAt!) >
            const Duration(seconds: 4);
    if (streamStale) await _pollConnections(settings);
    if (_lastConnectionLogRefreshAt == null ||
        now.difference(_lastConnectionLogRefreshAt!) >=
            const Duration(seconds: 5)) {
      await refreshConnectionLog(settings, notify: true);
    }
  }

  Future<void> _pollConnections(AppSettings settings) async {
    if (!isRunning) return;
    try {
      final json = await _apiJson(settings, 'GET', '/connections');
      _applyConnectionsSnapshot(json);
    } catch (_) {
      // Metrics are optional; a failed poll must not affect the tunnel.
    }
  }

  void _applyConnectionsSnapshot(Map<String, dynamic> json) {
    if (json['connections'] is! List) return;
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
      final id = item['id']?.toString() ?? 'connection-${connectionIndex++}';
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

    final trafficWebSocketStale =
        _lastWebSocketTrafficAt == null ||
        now.difference(_lastWebSocketTrafficAt!) > const Duration(seconds: 4);
    if (previousAt != null) {
      final seconds = now.difference(previousAt).inMilliseconds / 1000.0;
      final hasTraffic = uploadDelta > 0 || downloadDelta > 0;
      if (seconds > 0 &&
          (trafficWebSocketStale ||
              ((uploadBytesPerSecond == 0 && downloadBytesPerSecond == 0) &&
                  hasTraffic))) {
        uploadBytesPerSecond = uploadDelta / seconds;
        downloadBytesPerSecond = downloadDelta / seconds;
        _lastFallbackTrafficAt = now;
      }

      // Top-level counters include streams that open and close between UI
      // frames. Per-connection sums alone miss those short-lived requests.
      if (hasRootTotals && hasTraffic) {
        totalUploadBytes += uploadDelta;
        totalDownloadBytes += downloadDelta;
        trafficStats.add(upload: uploadDelta, download: downloadDelta, at: now);
      } else if (!hasRootTotals && trafficWebSocketStale && hasTraffic) {
        totalUploadBytes += uploadDelta;
        totalDownloadBytes += downloadDelta;
        trafficStats.add(upload: uploadDelta, download: downloadDelta, at: now);
      }
      if ((trafficWebSocketStale || !hasRootTotals) &&
          hasTraffic &&
          !_trafficFallbackLogged) {
        _trafficFallbackLogged = true;
        _appendLog('实时流量使用 Clash connections 累计计数');
      }
      if (trafficWebSocketStale && !hasTraffic) {
        uploadBytesPerSecond = 0;
        downloadBytesPerSecond = 0;
      }
    }
    _lastConnectionSampleAt = now;
    _connectionUploadTotals = nextUploadTotals;
    _connectionDownloadTotals = nextDownloadTotals;
    notifyListeners();
  }

  Future<void> refreshConnectionLog(
    AppSettings settings, {
    bool notify = true,
  }) async {
    if (!isRunning) return;
    try {
      final json = await _apiJson(
        settings,
        'GET',
        '/connection-log?after=$_connectionLogCursor&limit=250',
      );
      final raw = json['connections'];
      if (raw is! List) return;
      final updates = raw
          .whereType<Map>()
          .map(
            (item) =>
                ConnectionLogEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
      final cursor = _metricInt(json['cursor']);
      if (cursor == null) {
        // Compatibility with older Core builds that returned a full snapshot.
        connectionLogs = updates;
      } else {
        final merged = <String, ConnectionLogEntry>{
          for (final entry in connectionLogs) entry.id: entry,
          for (final entry in updates) entry.id: entry,
        };
        connectionLogs = merged.values.toList()
          ..sort((a, b) {
            final left = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            final right = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
            return right.compareTo(left);
          });
        if (connectionLogs.length > 1000) {
          connectionLogs = connectionLogs.take(1000).toList();
        }
        _connectionLogCursor = cursor;
      }
      _lastConnectionLogRefreshAt = DateTime.now();
      if (notify) notifyListeners();
    } catch (_) {
      // Older/starting cores may not expose connection history yet.
    }
  }

  Future<void> clearConnectionLog(AppSettings settings) async {
    if (isRunning) {
      await _apiJson(settings, 'DELETE', '/connection-log');
      connectionLogs = <ConnectionLogEntry>[];
      _connectionLogCursor = 0;
      _lastConnectionLogRefreshAt = null;
      await refreshConnectionLog(settings, notify: false);
    } else {
      connectionLogs = connectionLogs.where((entry) => entry.active).toList();
    }
    notifyListeners();
  }

  String connectionOutboundLabel(ConnectionLogEntry entry) {
    if (entry.outbound == 'direct') return '直连';
    if (entry.outbound == 'block') return '拦截';
    return _connectionNodeNames[entry.outbound] ??
        (entry.outbound.isEmpty ? entry.route : entry.outbound);
  }

  void recordClientEvent(String message, {bool error = false}) {
    _appendLog(message, error: error);
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

  void _startTunWatchdog(AppSettings settings) {
    _stopTunWatchdog();
    if (!settings.tunEnabled) return;
    _tunWatchdogTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_runTunWatchdog(settings));
    });
  }

  void _stopTunWatchdog() {
    _tunWatchdogTimer?.cancel();
    _tunWatchdogTimer = null;
    _tunWatchdogFailures = 0;
    _tunWatchdogHealth.reset();
    _tunWatchdogGeneration++;
    _tunWatchdogChecking = false;
    _tunWatchdogIssueLogged = false;
  }

  Future<void> _runTunWatchdog(AppSettings settings) async {
    if (!isRunning || !settings.tunEnabled || _tunWatchdogChecking) return;
    final generation = _tunWatchdogGeneration;
    _tunWatchdogChecking = true;
    String? failure;
    WindowsTunRoutingStatus? route;
    try {
      route = await WindowsIntegration.inspectTunRouting();
      if (generation != _tunWatchdogGeneration) return;
      if (!route.ready) {
        failure = route.detail;
      } else {
        if (_tunWatchdogHealth.nextRouteHealthyCycleNeedsHttps()) {
          final probeError = await _probeTunHttps(settings);
          if (generation != _tunWatchdogGeneration) return;
          _tunWatchdogHealth.recordHttps(succeeded: probeError == null);
          if (probeError != null) failure = 'TUN HTTPS 巡检失败：$probeError';
        }
      }
    } catch (error) {
      failure = '无法检查 HongdaTun 路由：${_cleanException(error)}';
    } finally {
      if (generation == _tunWatchdogGeneration) _tunWatchdogChecking = false;
    }
    if (generation != _tunWatchdogGeneration ||
        !isRunning ||
        !settings.tunEnabled)
      return;

    if (failure != null) {
      _tunWatchdogFailures++;
      if (_tunWatchdogFailures < 2) {
        tunRoutingDetail = 'TUN 巡检发现异常，30 秒后复核：$failure';
        notifyListeners();
        return;
      }
      tunRoutingVerified = false;
      tunRoutingDetail = failure;
      if (!_tunWatchdogIssueLogged) {
        _appendLog('TUN 运行中巡检异常：$failure', error: true);
      }
      _tunWatchdogIssueLogged = true;
      notifyListeners();
      return;
    }

    if (_tunWatchdogFailures > 0 || tunRoutingVerified != true) {
      tunRoutingVerified = true;
      tunRoutingDetail = '${route?.detail ?? 'HongdaTun 路由正常'}；运行中巡检已恢复';
      if (_tunWatchdogIssueLogged) _appendLog('TUN 运行中巡检恢复正常');
      notifyListeners();
    }
    _tunWatchdogFailures = 0;
    _tunWatchdogIssueLogged = false;
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
    _stopTunWatchdog();
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
    unawaited(storage.deleteRuntimeConfig());
    super.dispose();
  }
}

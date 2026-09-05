import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_manager.dart';
import 'config_importer.dart';
import 'models.dart';
import 'node_parser.dart';
import 'singbox_controller.dart';
import 'storage.dart';
import 'subscription_service.dart';
import 'windows_integration.dart';

class AppBootstrap {
  AppBootstrap({
    required this.storage,
    required this.settings,
    required this.nodes,
    required this.subscriptions,
    required this.groups,
    required this.rules,
    required this.trafficStats,
  });

  final AppStorage storage;
  final AppSettings settings;
  final List<NodeProfile> nodes;
  final List<SubscriptionProfile> subscriptions;
  final List<ProxyGroupProfile> groups;
  final List<RouteRuleProfile> rules;
  final TrafficStats trafficStats;

  static Future<AppBootstrap> create() async {
    final storage = await AppStorage.create();
    final values = await Future.wait<dynamic>(<Future<dynamic>>[
      storage.loadSettings(),
      storage.loadNodes(),
      storage.loadSubscriptions(),
      storage.loadGroups(),
      storage.loadRules(),
      storage.loadTrafficStats(),
    ]);
    return AppBootstrap(
      storage: storage,
      settings: values[0] as AppSettings,
      nodes: values[1] as List<NodeProfile>,
      subscriptions: values[2] as List<SubscriptionProfile>,
      groups: values[3] as List<ProxyGroupProfile>,
      rules: values[4] as List<RouteRuleProfile>,
      trafficStats: values[5] as TrafficStats,
    );
  }
}

class HongdaStarlinkApp extends StatelessWidget {
  const HongdaStarlinkApp({
    super.key,
    required this.bootstrap,
    this.resumeConnectOnLaunch = false,
  });

  final AppBootstrap bootstrap;
  final bool resumeConnectOnLaunch;

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF1677FF);
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      surface: Colors.white,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '鸿达星轨智连',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF7FAFE),
        canvasColor: const Color(0xFFF7FAFE),
        fontFamilyFallback: const <String>[
          'Microsoft YaHei UI',
          'Microsoft YaHei',
          'Segoe UI Variable',
          'Segoe UI',
        ],
        splashFactory: InkSparkle.splashFactory,
        visualDensity: VisualDensity.standard,
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white.withOpacity(.96),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFDDE7F3)),
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xFFEDF1F6),
          thickness: 1,
          space: 1,
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          hintStyle: TextStyle(color: Color(0xFF9AA7BA), fontSize: 12),
          labelStyle: TextStyle(color: Color(0xFF667085), fontSize: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xFFD7E0EC)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xFFD7E0EC)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: primary, width: 1.4),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) => Colors.white),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? primary : const Color(0xFFD7DFEA)),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
            elevation: 0,
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF344054),
            side: const BorderSide(color: Color(0xFFD9E2ED)),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        dialogTheme: DialogThemeData(
          elevation: 24,
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          titleTextStyle: const TextStyle(
            color: Color(0xFF101828),
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF172033),
          contentTextStyle: const TextStyle(color: Colors.white, fontSize: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      home: MainShell(bootstrap: bootstrap, resumeConnectOnLaunch: resumeConnectOnLaunch),
    );
  }
}

enum AppPage {
  dashboard,
  nodes,
  subscriptions,
  serviceStatus,
  connection,
  systemProxy,
  networkTools,
  config,
  logs,
  settings,
  about,
}

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.bootstrap,
    this.resumeConnectOnLaunch = false,
  });

  final AppBootstrap bootstrap;
  final bool resumeConnectOnLaunch;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  late final AppStorage storage;
  late final AppSettings settings;
  late final List<NodeProfile> nodes;
  late final List<SubscriptionProfile> subscriptions;
  late final List<ProxyGroupProfile> groups;
  late final List<RouteRuleProfile> rules;
  late final TrafficStats trafficStats;
  late final CoreManager coreManager;
  late final SingBoxController controller;

  AppPage page = AppPage.dashboard;
  bool isAdmin = false;
  String? coreVersion;
  String? transientMessage;
  final List<double> uploadHistory = List<double>.filled(50, 0);
  final List<double> downloadHistory = List<double>.filled(50, 0);
  Timer? historyTimer;

  @override
  void initState() {
    super.initState();
    storage = widget.bootstrap.storage;
    settings = widget.bootstrap.settings;
    nodes = widget.bootstrap.nodes;
    subscriptions = widget.bootstrap.subscriptions;
    groups = widget.bootstrap.groups;
    rules = widget.bootstrap.rules;
    trafficStats = widget.bootstrap.trafficStats;
    coreManager = CoreManager(storage);
    controller = SingBoxController(
      storage: storage,
      coreManager: coreManager,
      trafficStats: trafficStats,
    )..addListener(_onControllerChanged);
    _refreshEnvironment();
    if (widget.resumeConnectOnLaunch) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (!mounted || controller.isRunning || controller.status == CoreStatus.starting) return;
        await _connectOrDisconnect();
      });
    }
    historyTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        uploadHistory.removeAt(0);
        uploadHistory.add(controller.uploadBytesPerSecond);
        downloadHistory.removeAt(0);
        downloadHistory.add(controller.downloadBytesPerSecond);
      });
    });
  }

  @override
  void dispose() {
    historyTimer?.cancel();
    controller.removeListener(_onControllerChanged);
    controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshEnvironment() async {
    final admin = await WindowsIntegration.isAdministrator();
    final version = await coreManager.queryVersion();
    if (!mounted) return;
    setState(() {
      isAdmin = admin;
      coreVersion = version;
    });
  }

  NodeProfile? get selectedNode {
    if (nodes.isEmpty) return null;
    for (final node in nodes) {
      if (node.id == settings.selectedNodeId) return node;
    }
    return nodes.first;
  }

  Future<void> _saveAll() async {
    await Future.wait(<Future<void>>[
      storage.saveSettings(settings),
      storage.saveNodes(nodes),
      storage.saveSubscriptions(subscriptions),
      storage.saveGroups(groups),
      storage.saveRules(rules),
      storage.saveTrafficStats(trafficStats),
    ]);
  }

  Future<void> _connectOrDisconnect() async {
    if (controller.isRunning || controller.status == CoreStatus.starting) {
      await controller.stop(settings);
      return;
    }
    final node = selectedNode;
    if (node == null) {
      _toast('请先添加并选择一个节点');
      setState(() => page = AppPage.nodes);
      return;
    }
    settings.selectedNodeId = node.id;
    if (!settings.tunEnabled && !settings.tailscaleEnabled && !settings.systemProxyEnabled) {
      settings.systemProxyEnabled = true;
      if (mounted) {
        _toast('TUN 未开启，已自动切换为 Windows 系统代理模式（无需管理员权限）');
      }
    }
    await storage.saveSettings(settings);
    try {
      await controller.start(node, settings, nodes: nodes, groups: groups, rules: rules);
    } on NeedsElevationException {
      if (!mounted) return;
      final restart = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('TUN 需要管理员权限'),
          content: const Text('当前不是管理员模式。是否以管理员身份重新启动鸿达星轨智连？'),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('管理员重启')),
          ],
        ),
      );
      if (restart == true) {
        final launched = await WindowsIntegration.restartAsAdministrator();
        if (!launched && mounted) {
          _toast('管理员重启没有启动：如果刚刚取消了 UAC，请重新点击连接后允许授权。');
        }
      }
    } catch (e) {
      await _showServiceFailureDialog(e);
    }
  }

  Future<void> _showServiceFailureDialog(Object error) async {
    if (!mounted) return;
    final message = controller.lastError ?? _cleanError(error);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭启动错误',
      barrierColor: const Color(0xFF0E172A).withOpacity(.28),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) => _ServiceFailureDialog(
        message: message,
        stage: controller.startupStage,
        detail: controller.startupDetail,
        onOpenLogs: () {
          Navigator.of(context).pop();
          setState(() => page = AppPage.logs);
        },
        onRetry: () {
          Navigator.of(context).pop();
          Future<void>.delayed(const Duration(milliseconds: 180), _connectOrDisconnect);
        },
      ),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(scale: Tween<double>(begin: .96, end: 1).animate(curved), child: child),
        );
      },
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    setState(() => transientMessage = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _cleanError(Object error) {
    return error.toString().replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
  }

  Future<void> _selectNode(NodeProfile node) async {
    final previousId = settings.selectedNodeId;
    setState(() => settings.selectedNodeId = node.id);
    await storage.saveSettings(settings);
    if (!controller.isRunning) return;
    try {
      await controller.selectNodeRuntime(node, settings);
    } catch (e) {
      settings.selectedNodeId = previousId;
      await storage.saveSettings(settings);
      if (mounted) setState(() {});
      _toast('切换节点失败：${_cleanError(e)}');
    }
  }

  Future<void> _testAllNodes() async {
    if (nodes.isEmpty) {
      _toast('当前没有可测试节点');
      return;
    }
    for (final node in nodes.where((node) => node.enabled)) {
      await controller.testNode(node, settings);
      if (mounted) setState(() {});
    }
    await storage.saveNodes(nodes);
    _toast('延迟测试完成');
  }

  Future<void> _autoSelectBestNode() async {
    final targets = nodes.where((node) => node.enabled).toList();
    if (targets.isEmpty) {
      _toast('当前没有可用节点');
      return;
    }
    for (final node in targets) {
      await controller.testNode(node, settings);
      if (mounted) setState(() {});
    }
    final available = targets.where((node) => node.latencyMs != null).toList()
      ..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    await storage.saveNodes(nodes);
    if (available.isEmpty) {
      _toast('没有检测到可连接节点');
      return;
    }
    await _selectNode(available.first);
    _toast('已选择最低延迟节点：${available.first.name} · ${available.first.latencyMs} ms');
  }

  Future<void> _clearRuntimeCache() async {
    if (controller.isRunning) {
      _toast('请先断开连接，再清理运行缓存');
      return;
    }
    try {
      if (await storage.runtimeDir.exists()) {
        await storage.runtimeDir.delete(recursive: true);
      }
      await storage.runtimeDir.create(recursive: true);
      _toast('运行缓存已清理');
    } catch (e) {
      _toast('缓存清理失败：${_cleanError(e)}');
    }
  }

  Future<void> _toggleFavorite(NodeProfile node) async {
    setState(() => node.favorite = !node.favorite);
    await storage.saveNodes(nodes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFE),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1280;
          final collapsedSidebar = constraints.maxWidth < 1100;
          final sidebarWidth = collapsedSidebar ? 82.0 : (compact ? 206.0 : 252.0);
          return DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFFFBFDFF), Color(0xFFF5F8FD)],
              ),
            ),
            child: Stack(
              children: <Widget>[
                Column(
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        children: <Widget>[
                          _Sidebar(
                            compact: compact,
                            collapsed: collapsedSidebar,
                            page: page,
                            controller: controller,
                            coreAvailable: coreVersion != null,
                            selectedNode: selectedNode,
                            onToggleConnection: _connectOrDisconnect,
                            onChanged: (value) => setState(() => page = value),
                          ),
                          Expanded(
                            child: Container(
                              margin: EdgeInsets.fromLTRB(
                                compact ? 12 : 18,
                                page == AppPage.dashboard ? (compact ? 44 : 50) : (compact ? 54 : 72),
                                compact ? 12 : 18,
                                page == AppPage.dashboard ? 6 : 10,
                              ),
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 230),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                transitionBuilder: (child, animation) {
                                  final slide = Tween<Offset>(
                                    begin: const Offset(.012, .012),
                                    end: Offset.zero,
                                  ).animate(animation);
                                  return FadeTransition(
                                    opacity: animation,
                                    child: SlideTransition(position: slide, child: child),
                                  );
                                },
                                child: KeyedSubtree(
                                  key: ValueKey<AppPage>(page),
                                  child: page == AppPage.dashboard
                                      ? _buildPage()
                                      : _PageFrame(
                                          title: _pageTitle(page),
                                          subtitle: _pageSubtitle(page),
                                          child: _buildPage(),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _StatusBar(
                      status: controller.status,
                      coreVersion: coreVersion,
                      selectedNode: selectedNode,
                      activeConnections: controller.activeConnections,
                      settings: settings,
                      uploadSpeed: controller.uploadBytesPerSecond,
                      downloadSpeed: controller.downloadBytesPerSecond,
                    ),
                  ],
                ),
                Positioned(
                  left: sidebarWidth + 10,
                  right: 154,
                  top: 0,
                  height: 38,
                  child: const _WindowDragRegion(),
                ),
                const Positioned(
                  right: 6,
                  top: 3,
                  child: _FloatingWindowChrome(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPage() {
    switch (page) {
      case AppPage.dashboard:
        return _DashboardPage(
          controller: controller,
          settings: settings,
          nodes: nodes,
          subscriptions: subscriptions,
          coreAvailable: coreVersion != null,
          selectedNode: selectedNode,
          uploadHistory: uploadHistory,
          downloadHistory: downloadHistory,
          onToggleConnection: _connectOrDisconnect,
          onSelectNode: _selectNode,
          onToggleFavorite: _toggleFavorite,
          onTestNodes: _testAllNodes,
          onAutoSelect: _autoSelectBestNode,
          onClearCache: _clearRuntimeCache,
          onOpenNodes: () => setState(() => page = AppPage.nodes),
          onOpenSubscriptions: () => setState(() => page = AppPage.subscriptions),
          onOpenSettings: () => setState(() => page = AppPage.connection),
        );
      case AppPage.nodes:
        return _NodesPage(
          nodes: nodes,
          selectedNode: selectedNode,
          controller: controller,
          settings: settings,
          onSelect: _selectNode,
          onChanged: () async {
            setState(() {});
            await storage.saveNodes(nodes);
          },
        );
      case AppPage.subscriptions:
        return _SubscriptionsPage(
          subscriptions: subscriptions,
          nodes: nodes,
          groups: groups,
          rules: rules,
          onChanged: () async {
            setState(() {});
            await _saveAll();
          },
        );
      case AppPage.serviceStatus:
        return _ServiceStatusPage(
          controller: controller,
          settings: settings,
          node: selectedNode,
          uploadHistory: uploadHistory,
          downloadHistory: downloadHistory,
          onToggle: _connectOrDisconnect,
          onChooseNode: () => setState(() => page = AppPage.nodes),
        );
      case AppPage.connection:
        return _ConnectionSettingsPage(
          settings: settings,
          isRunning: controller.isRunning,
          isAdmin: isAdmin,
          onChanged: () async {
            setState(() {});
            await storage.saveSettings(settings);
          },
          onRestartAdmin: WindowsIntegration.restartAsAdministrator,
        );
      case AppPage.systemProxy:
        return _SystemProxyPage(
          settings: settings,
          isRunning: controller.isRunning,
          onChanged: () async {
            await storage.saveSettings(settings);
            if (controller.isRunning) {
              await WindowsIntegration.setSystemProxy(
                enabled: settings.systemProxyEnabled,
                port: settings.mixedPort,
              );
            }
            setState(() {});
          },
        );
      case AppPage.networkTools:
        return _NetworkToolsPage(nodes: nodes, onNodesChanged: () async {
          setState(() {});
          await storage.saveNodes(nodes);
        });
      case AppPage.config:
        return _ConfigPage(
          node: selectedNode,
          settings: settings,
          nodes: nodes,
          groups: groups,
          rules: rules,
          onChanged: () async {
            if (settings.selectedNodeId.isEmpty && nodes.isNotEmpty) {
              settings.selectedNodeId = nodes.first.id;
            }
            await _saveAll();
            setState(() {});
          },
        );
      case AppPage.logs:
        return _LogsPage(controller: controller, storage: storage);
      case AppPage.settings:
        return _SettingsPage(
          settings: settings,
          storage: storage,
          coreManager: coreManager,
          coreVersion: coreVersion,
          isAdmin: isAdmin,
          onChanged: () async {
            await storage.saveSettings(settings);
            await WindowsIntegration.setStartWithWindows(settings.startWithWindows);
            setState(() {});
          },
          onCoreChanged: _refreshEnvironment,
        );
      case AppPage.about:
        return _AboutPage(coreVersion: coreVersion);
    }
  }
}

String _pageTitle(AppPage page) {
  switch (page) {
    case AppPage.dashboard: return '仪表盘';
    case AppPage.nodes: return '节点列表';
    case AppPage.subscriptions: return '订阅管理';
    case AppPage.serviceStatus: return '服务状态';
    case AppPage.connection: return '连接设置';
    case AppPage.systemProxy: return '系统代理';
    case AppPage.networkTools: return '网络工具';
    case AppPage.config: return '分流规则';
    case AppPage.logs: return '日志中心';
    case AppPage.settings: return '设置';
    case AppPage.about: return '关于我们';
  }
}

String _pageSubtitle(AppPage page) {
  switch (page) {
    case AppPage.dashboard: return '实时连接状态与网络概览';
    case AppPage.nodes: return '管理节点、收藏与延迟测试';
    case AppPage.subscriptions: return '管理订阅来源并同步节点';
    case AppPage.serviceStatus: return '查看核心、IPC 与实时运行状态';
    case AppPage.connection: return '配置 TUN、DNS 与路由行为';
    case AppPage.systemProxy: return '控制 Windows 系统代理设置';
    case AppPage.networkTools: return '批量测试节点延迟与连通性';
    case AppPage.config: return '智能分流、规则组、自定义规则与配置导入';
    case AppPage.logs: return '查看服务运行日志与错误信息';
    case AppPage.settings: return '常规、启动、端口与高级参数';
    case AppPage.about: return '版本信息与运行环境';
  }
}

class _WindowDragRegion extends StatelessWidget {
  const _WindowDragRegion();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => WindowsIntegration.startWindowDrag(),
      onDoubleTap: WindowsIntegration.toggleMaximizeWindow,
      child: const SizedBox.expand(),
    );
  }
}

class _FloatingWindowChrome extends StatelessWidget {
  const _FloatingWindowChrome();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const <Widget>[
          _WindowButton(
            tooltip: '最小化',
            icon: Icons.remove_rounded,
            onTap: WindowsIntegration.minimizeWindow,
          ),
          _WindowButton(
            tooltip: '最大化 / 还原',
            icon: Icons.crop_square_rounded,
            onTap: WindowsIntegration.toggleMaximizeWindow,
          ),
          _WindowButton(
            tooltip: '关闭',
            icon: Icons.close_rounded,
            close: true,
            onTap: WindowsIntegration.closeWindow,
          ),
        ],
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: const Color(0xFF1677FF),
          borderRadius: BorderRadius.circular(7),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x241677FF), blurRadius: 8, offset: Offset(0, 2)),
          ],
        ),
        child: const Text(
          'V1.6.3',
          style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800),
        ),
      );
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.close = false,
  });

  final String tooltip;
  final IconData icon;
  final Future<void> Function() onTap;
  final bool close;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final background = hovered
        ? (widget.close ? const Color(0xFFE81123) : const Color(0xFFEAF0F7))
        : Colors.transparent;
    final foreground = hovered && widget.close ? Colors.white : const Color(0xFF344054);
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 43,
            height: 34,
            color: background,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.icon == Icons.crop_square_rounded ? 15 : 18, color: foreground),
          ),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.compact,
    required this.collapsed,
    required this.page,
    required this.controller,
    required this.coreAvailable,
    required this.selectedNode,
    required this.onToggleConnection,
    required this.onChanged,
  });

  final bool compact;
  final bool collapsed;
  final AppPage page;
  final SingBoxController controller;
  final bool coreAvailable;
  final NodeProfile? selectedNode;
  final VoidCallback onToggleConnection;
  final ValueChanged<AppPage> onChanged;

  @override
  Widget build(BuildContext context) {
    final width = collapsed ? 82.0 : (compact ? 206.0 : 252.0);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: width,
      margin: EdgeInsets.zero,
      decoration: const BoxDecoration(
        color: Color(0xFFFDFEFF),
        border: Border(
          right: BorderSide(color: Color(0xFFE5EBF3)),
        ),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showConnectionCard = !collapsed && constraints.maxHeight >= 540;
          return Column(
            children: <Widget>[
              _SidebarBrand(collapsed: collapsed),
              if (!collapsed) const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(collapsed ? 8 : 10, 10, collapsed ? 8 : 10, 8),
                  children: <Widget>[
                    _NavItem(collapsed: collapsed, page: AppPage.dashboard, current: page, icon: Icons.home_rounded, text: '仪表盘', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.nodes, current: page, icon: Icons.hexagon_outlined, text: '节点列表', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.subscriptions, current: page, icon: Icons.inventory_2_outlined, text: '订阅管理', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.connection, current: page, icon: Icons.settings_input_component_outlined, text: '连接设置', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.systemProxy, current: page, icon: Icons.settings_input_antenna_rounded, text: '系统代理', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.networkTools, current: page, icon: Icons.network_check_rounded, text: '网络工具', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.config, current: page, icon: Icons.tune_rounded, text: '分流规则', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.logs, current: page, icon: Icons.article_outlined, text: '日志中心', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.settings, current: page, icon: Icons.settings_outlined, text: '设置', onChanged: onChanged),
                    _NavItem(collapsed: collapsed, page: AppPage.about, current: page, icon: Icons.info_outline_rounded, text: '关于我们', onChanged: onChanged),
                  ],
                ),
              ),
              if (showConnectionCard)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
                  child: _SidebarConnectionCard(
                    controller: controller,
                    node: selectedNode,
                    onToggle: onToggleConnection,
                  ),
                ),
              if (!collapsed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(15, 2, 15, 13),
                  child: Row(
                    children: <Widget>[
                      Text(
                        coreAvailable ? '核心：sing-box' : '核心：未安装',
                        style: TextStyle(
                          color: coreAvailable ? const Color(0xFF667085) : const Color(0xFFC2413B),
                          fontSize: 9.5,
                          fontWeight: coreAvailable ? FontWeight.w500 : FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        controller.ipcConnected ? 'IPC 正常' : (coreAvailable ? 'IPC 待机' : 'Core 缺失'),
                        style: TextStyle(
                          color: controller.ipcConnected
                              ? const Color(0xFF12A56A)
                              : (coreAvailable ? const Color(0xFF98A2B3) : const Color(0xFFC2413B)),
                          fontSize: 9.5,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand({required this.collapsed});
  final bool collapsed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => WindowsIntegration.startWindowDrag(),
      onDoubleTap: WindowsIntegration.toggleMaximizeWindow,
      child: SizedBox(
        height: collapsed ? 64 : 78,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 13 : 14),
          child: Row(
            mainAxisAlignment: collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  'assets/app_icon.png',
                  width: collapsed ? 38 : 42,
                  height: collapsed ? 38 : 42,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: collapsed ? 38 : 42,
                    height: collapsed ? 38 : 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: const LinearGradient(
                        colors: <Color>[Color(0xFF4C9BFF), Color(0xFF1769E8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: const Icon(Icons.public_rounded, color: Colors.white, size: 23),
                  ),
                ),
              ),
              if (!collapsed) ...<Widget>[
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(children: <Widget>[
                        Flexible(child: Text('鸿达星轨智连', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: Color(0xFF101828), letterSpacing: .2))),
                        SizedBox(width: 6),
                        _VersionBadge(),
                      ]),
                      SizedBox(height: 4),
                      Text('极速连接 · 智能路由', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9, color: Color(0xFF7B8798))),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.collapsed,
    required this.page,
    required this.current,
    required this.icon,
    required this.text,
    required this.onChanged,
  });

  final bool collapsed;
  final AppPage page;
  final AppPage current;
  final IconData icon;
  final String text;
  final ValueChanged<AppPage> onChanged;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.page == widget.current;
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: () => widget.onChanged(widget.page),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              height: 46,
              padding: EdgeInsets.symmetric(horizontal: widget.collapsed ? 8 : 13),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFFEEF5FF)
                    : hovered
                        ? const Color(0xFFF6F9FD)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: selected ? const Color(0xFFD9E9FF) : Colors.transparent),
              ),
              child: Row(
                mainAxisAlignment: widget.collapsed ? MainAxisAlignment.center : MainAxisAlignment.start,
                children: <Widget>[
                  AnimatedScale(
                    duration: const Duration(milliseconds: 150),
                    scale: hovered && !selected ? 1.06 : 1,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: selected ? const Color(0xFFE2EEFF) : Colors.transparent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(widget.icon, size: 19, color: selected ? const Color(0xFF1677FF) : const Color(0xFF27364A)),
                    ),
                  ),
                  if (!widget.collapsed) ...<Widget>[
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? const Color(0xFF1269D8) : const Color(0xFF1D2939),
                          fontSize: 12.5,
                          fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return widget.collapsed ? Tooltip(message: widget.text, waitDuration: const Duration(milliseconds: 350), child: content) : content;
  }
}

class _SidebarConnectionCard extends StatelessWidget {
  const _SidebarConnectionCard({required this.controller, required this.node, required this.onToggle});

  final SingBoxController controller;
  final NodeProfile? node;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final connected = controller.isRunning;
    final busy = controller.status == CoreStatus.starting || controller.status == CoreStatus.stopping;
    final duration = connected && controller.connectedAt != null
        ? DateTime.now().difference(controller.connectedAt!)
        : Duration.zero;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFDCE5EF)),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x09101828), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: connected ? const Color(0xFFE8FBF3) : const Color(0xFFF0F3F7),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Icon(
                  connected ? Icons.phonelink_ring_rounded : Icons.phonelink_off_rounded,
                  color: connected ? const Color(0xFF12A56A) : const Color(0xFF98A2B3),
                  size: 17,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                connected ? '已连接' : (controller.status == CoreStatus.starting ? startupStageLabel(controller.startupStage) : _shortStatus(controller.status)),
                style: TextStyle(
                  color: connected ? const Color(0xFF12A56A) : const Color(0xFF667085),
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            node?.name ?? '未选择节点',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF101828), fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          Text(
            node == null ? '--' : node!.protocol.toUpperCase(),
            style: const TextStyle(color: Color(0xFF667085), fontSize: 10.5),
          ),
          const SizedBox(height: 3),
          Text(
            connected ? _formatDuration(duration) : '00:00:00',
            style: const TextStyle(color: Color(0xFF667085), fontSize: 10.5),
          ),
          if (controller.status == CoreStatus.error && controller.lastError != null) ...<Widget>[
            const SizedBox(height: 8),
            Tooltip(
              message: controller.lastError!,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF2F1),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFFF6D0CD)),
                ),
                child: Text(
                  controller.lastError!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9.1, height: 1.35, color: Color(0xFFB42318)),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 34,
            child: FilledButton.icon(
              onPressed: busy ? null : onToggle,
              icon: busy
                  ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(connected ? Icons.stop_circle_outlined : Icons.power_settings_new_rounded, size: 15),
              label: Text(connected ? '断开连接' : '一键连接'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}


class _ServiceFailureDialog extends StatelessWidget {
  const _ServiceFailureDialog({
    required this.message,
    required this.stage,
    required this.detail,
    required this.onOpenLogs,
    required this.onRetry,
  });

  final String message;
  final StartupStage stage;
  final String detail;
  final VoidCallback onOpenLogs;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final stageText = startupStageLabel(stage);
    final showDetail = detail.trim().isNotEmpty && detail.trim() != message.trim();
    return SafeArea(
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 520,
            constraints: const BoxConstraints(maxWidth: 520),
            margin: const EdgeInsets.all(20),
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE5EAF1)),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x1A0F172A),
                  blurRadius: 44,
                  offset: Offset(0, 18),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFEFED),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(
                        Icons.error_outline_rounded,
                        color: Color(0xFFCF3D32),
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text(
                            '连接启动失败',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF101828),
                            ),
                          ),
                          const SizedBox(height: 4),
                          AnimatedSwitcher(
                            duration: Duration(milliseconds: 180),
                            child: Text(
                              stageText,
                              key: ValueKey<String>(stageText),
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFB54708),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, size: 19),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE7ECF2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        message,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.55,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF344054),
                        ),
                      ),
                      if (showDetail) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          detail,
                          style: const TextStyle(
                            fontSize: 10.2,
                            height: 1.5,
                            color: Color(0xFF667085),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: onOpenLogs,
                      icon: const Icon(Icons.article_outlined, size: 16),
                      label: const Text('查看日志'),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('重新尝试'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PageFrame extends StatelessWidget {
  const _PageFrame({required this.title, required this.subtitle, required this.child});

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(fontSize: 10.5, color: Color(0xFF7B8798))),
                ],
              ),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

String _shortStatus(CoreStatus status) {
  switch (status) {
    case CoreStatus.stopped: return '未连接';
    case CoreStatus.starting: return '启动中';
    case CoreStatus.running: return '已连接';
    case CoreStatus.stopping: return '断开中';
    case CoreStatus.error: return '服务异常';
  }
}


class _DashboardPage extends StatefulWidget {
  const _DashboardPage({
    required this.controller,
    required this.settings,
    required this.nodes,
    required this.subscriptions,
    required this.coreAvailable,
    required this.selectedNode,
    required this.uploadHistory,
    required this.downloadHistory,
    required this.onToggleConnection,
    required this.onSelectNode,
    required this.onToggleFavorite,
    required this.onTestNodes,
    required this.onAutoSelect,
    required this.onClearCache,
    required this.onOpenNodes,
    required this.onOpenSubscriptions,
    required this.onOpenSettings,
  });

  final SingBoxController controller;
  final AppSettings settings;
  final List<NodeProfile> nodes;
  final List<SubscriptionProfile> subscriptions;
  final bool coreAvailable;
  final NodeProfile? selectedNode;
  final List<double> uploadHistory;
  final List<double> downloadHistory;
  final VoidCallback onToggleConnection;
  final ValueChanged<NodeProfile> onSelectNode;
  final ValueChanged<NodeProfile> onToggleFavorite;
  final VoidCallback onTestNodes;
  final VoidCallback onAutoSelect;
  final VoidCallback onClearCache;
  final VoidCallback onOpenNodes;
  final VoidCallback onOpenSubscriptions;
  final VoidCallback onOpenSettings;

  @override
  State<_DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<_DashboardPage> {
  final searchController = TextEditingController();
  String filter = 'all';

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }

  List<NodeProfile> get visibleNodes {
    final query = searchController.text.trim().toLowerCase();
    var result = widget.nodes.where((node) {
      if (!node.enabled) return false;
      if (filter == 'favorite' && !node.favorite) return false;
      if (query.isEmpty) return true;
      return node.name.toLowerCase().contains(query) ||
          node.server.toLowerCase().contains(query) ||
          node.protocol.toLowerCase().contains(query);
    }).toList();
    if (filter == 'auto') {
      result.sort((a, b) {
        final av = a.latencyMs ?? 1 << 30;
        final bv = b.latencyMs ?? 1 << 30;
        return av.compareTo(bv);
      });
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final wide = width >= 1120;
        final medium = width >= 760;
        const gap = 10.0;

        final nodeCard = _DashboardNodeCard(
          nodes: visibleNodes,
          totalCount: widget.nodes.length,
          selectedNode: widget.selectedNode,
          filter: filter,
          searchController: searchController,
          onFilter: (value) => setState(() => filter = value),
          onSearch: () => setState(() {}),
          onSelect: widget.onSelectNode,
          onFavorite: widget.onToggleFavorite,
          onTest: widget.onTestNodes,
          testingNodeIds: widget.controller.testingNodeIds,
          onOpenAll: widget.onOpenNodes,
        );
        final trafficCard = _TrafficCard(
          upload: widget.uploadHistory,
          download: widget.downloadHistory,
        );
        final quickActions = _QuickActions(
          onConnect: widget.onToggleConnection,
          onAuto: widget.onAutoSelect,
          onTest: widget.onTestNodes,
          onClear: widget.onClearCache,
        );
        final subscriptionsCard = _DashboardSubscriptionsCard(
          subscriptions: widget.subscriptions,
          nodes: widget.nodes,
          onOpen: widget.onOpenSubscriptions,
        );
        final connectionCard = _DashboardConnectionSettingsCard(
          settings: widget.settings,
          onOpen: widget.onOpenSettings,
        );
        final systemCard = _DashboardSystemCard(
          controller: widget.controller,
          settings: widget.settings,
          coreAvailable: widget.coreAvailable,
        );

        Widget upperSection;
        if (wide) {
          upperSection = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 17, child: nodeCard),
              const SizedBox(width: gap),
              Expanded(
                flex: 11,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    trafficCard,
                    const SizedBox(height: gap),
                    quickActions,
                  ],
                ),
              ),
            ],
          );
        } else if (medium) {
          upperSection = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              nodeCard,
              const SizedBox(height: gap),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 3, child: trafficCard),
                  const SizedBox(width: gap),
                  Expanded(flex: 2, child: quickActions),
                ],
              ),
            ],
          );
        } else {
          upperSection = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              nodeCard,
              const SizedBox(height: gap),
              trafficCard,
              const SizedBox(height: gap),
              quickActions,
            ],
          );
        }

        Widget lowerSection;
        if (wide) {
          lowerSection = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(flex: 12, child: subscriptionsCard),
              const SizedBox(width: gap),
              Expanded(flex: 10, child: connectionCard),
              const SizedBox(width: gap),
              Expanded(flex: 9, child: systemCard),
            ],
          );
        } else if (medium) {
          lowerSection = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 11, child: subscriptionsCard),
                  const SizedBox(width: gap),
                  Expanded(flex: 10, child: connectionCard),
                ],
              ),
              const SizedBox(height: gap),
              systemCard,
            ],
          );
        } else {
          lowerSection = Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              subscriptionsCard,
              const SizedBox(height: gap),
              connectionCard,
              const SizedBox(height: gap),
              systemCard,
            ],
          );
        }

        return ClipRect(
          child: SingleChildScrollView(
            primary: true,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _ConnectionHeroCard(
                  controller: widget.controller,
                  settings: widget.settings,
                  node: widget.selectedNode,
                  uploadHistory: widget.uploadHistory,
                  downloadHistory: widget.downloadHistory,
                  onToggle: widget.onToggleConnection,
                ),
                const SizedBox(height: gap),
                upperSection,
                const SizedBox(height: gap),
                lowerSection,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ConnectionHeroCard extends StatelessWidget {
  const _ConnectionHeroCard({
    required this.controller,
    required this.settings,
    required this.node,
    required this.uploadHistory,
    required this.downloadHistory,
    required this.onToggle,
  });

  final SingBoxController controller;
  final AppSettings settings;
  final NodeProfile? node;
  final List<double> uploadHistory;
  final List<double> downloadHistory;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final connected = controller.isRunning;
    final duration = connected && controller.connectedAt != null
        ? DateTime.now().difference(controller.connectedAt!)
        : Duration.zero;
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final roomy = constraints.maxWidth >= 720;
          final status = Row(
            children: <Widget>[
              _PowerOrb(status: controller.status, onTap: onToggle),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      connected ? '已连接' : (controller.status == CoreStatus.starting ? startupStageLabel(controller.startupStage) : _shortStatus(controller.status)),
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                        color: connected ? const Color(0xFF1677FF) : const Color(0xFF344054),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      node?.name ?? '请选择节点',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828)),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Text(
                          node == null ? '--' : node!.protocol.toUpperCase(),
                          style: const TextStyle(fontSize: 11, color: Color(0xFF667085)),
                        ),
                        if (node?.latencyMs != null) ...<Widget>[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(color: const Color(0xFFE9F8EF), borderRadius: BorderRadius.circular(10)),
                            child: Text('+ ${node!.latencyMs} ms', style: const TextStyle(fontSize: 9.5, color: Color(0xFF119D5B), fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
          final metrics = <Widget>[
            _HeroMetric(label: '延迟', value: node?.latencyMs == null ? '--' : '${node!.latencyMs} ms', data: const <double>[]),
            _HeroMetric(label: '下载', value: _formatSpeed(controller.downloadBytesPerSecond), data: downloadHistory),
            _HeroMetric(label: '上传', value: _formatSpeed(controller.uploadBytesPerSecond), data: uploadHistory, green: true),
            _HeroMetric(label: '流量', value: _formatBytes(controller.totalTrafficBytes), data: downloadHistory, purple: true),
          ];
          final mainContent = roomy
              ? Row(
                    children: <Widget>[
                      SizedBox(width: constraints.maxWidth < 900 ? 285 : 360, child: status),
                      const SizedBox(width: 18),
                      for (var i = 0; i < metrics.length; i++) ...<Widget>[
                        Expanded(child: metrics[i]),
                        if (i != metrics.length - 1) const SizedBox(width: 10),
                      ],
                    ],
                  )
                : Column(
                    children: <Widget>[
                      status,
                      const SizedBox(height: 16),
                      GridView.count(
                        crossAxisCount: constraints.maxWidth >= 520 ? 4 : 2,
                        childAspectRatio: 1.7,
                        mainAxisSpacing: 9,
                        crossAxisSpacing: 9,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        children: metrics,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          _InlineStat(label: '连接时间', value: _formatDuration(duration)),
                          const SizedBox(width: 18),
                          _InlineStat(label: '本次使用', value: _formatBytes(controller.totalTrafficBytes)),
                          const SizedBox(width: 18),
                          _InlineStat(label: '总计使用', value: _formatBytes(controller.lifetimeTrafficBytes)),
                        ],
                      ),
                    ],
                  );
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                mainContent,
                if (roomy) ...<Widget>[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 18,
                      runSpacing: 6,
                      children: <Widget>[
                        _InlineStat(label: '路由模式', value: _routeModeText(settings.routeMode)),
                        _InlineStat(label: 'DNS', value: settings.dnsMode == 'doh' ? 'DoH' : '自动'),
                        _InlineStat(label: 'TUN', value: settings.tunEnabled ? '已启用' : '未启用'),
                        _InlineStat(label: '活动连接', value: '${controller.activeConnections}'),
                        _InlineStat(label: '连接时间', value: _formatDuration(duration)),
                        _InlineStat(label: '本次流量', value: _formatBytes(controller.totalTrafficBytes)),
                      ],
                    ),
                  ),
                ],
                if (controller.status == CoreStatus.starting) ...<Widget>[
                  const SizedBox(height: 16),
                  _StartupProgress(controller: controller),
                ],
                if (controller.status == CoreStatus.error && controller.lastError != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _ServiceErrorBanner(message: controller.lastError!, stage: controller.startupStage),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}


class _StartupProgress extends StatelessWidget {
  const _StartupProgress({required this.controller});
  final SingBoxController controller;

  @override
  Widget build(BuildContext context) {
    final progress = startupStageProgress(controller.startupStage).clamp(0.0, 1.0).toDouble();
    final percent = (progress * 100).round();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE9FB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1677FF),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, .12),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: Text(
                    controller.startupDetail,
                    key: ValueKey<String>(controller.startupDetail),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10.2,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF344054),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: progress),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                builder: (context, value, child) => Text(
                  '${(value * 100).round()}%',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF1677FF),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 9),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, value, child) => LinearProgressIndicator(
                minHeight: 5,
                value: value,
                backgroundColor: const Color(0xFFE6EEF9),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF1677FF)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              _StartupCheckpoint(
                label: 'Service',
                active: percent >= 13,
              ),
              _StartupCheckpoint(
                label: '配置',
                active: percent >= 52,
              ),
              _StartupCheckpoint(
                label: 'Core',
                active: percent >= 73,
              ),
              _StartupCheckpoint(
                label: 'API',
                active: percent >= 83,
              ),
              _StartupCheckpoint(
                label: 'IPC',
                active: percent >= 91,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StartupCheckpoint extends StatelessWidget {
  const _StartupCheckpoint({required this.label, required this.active});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) => Expanded(
        child: AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 180),
          style: TextStyle(
            fontSize: 8.6,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? const Color(0xFF1677FF) : const Color(0xFF98A2B3),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? const Color(0xFF1677FF) : const Color(0xFFD0D5DD),
                  boxShadow: active
                      ? const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x331677FF),
                            blurRadius: 7,
                            spreadRadius: 1,
                          ),
                        ]
                      : const <BoxShadow>[],
                ),
              ),
              const SizedBox(width: 4),
              Text(label),
            ],
          ),
        ),
      );
}

class _ServiceErrorBanner extends StatelessWidget {
  const _ServiceErrorBanner({required this.message, required this.stage});
  final String message;
  final StartupStage stage;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4F2),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0xFFF3D1CD)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.error_outline_rounded, size: 17, color: Color(0xFFB42318)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(startupStageLabel(stage), style: const TextStyle(fontSize: 10.2, fontWeight: FontWeight.w800, color: Color(0xFFB42318))),
                const SizedBox(height: 2),
                Text(message, style: const TextStyle(fontSize: 9.8, height: 1.4, color: Color(0xFF8F2D24))),
              ]),
            ),
          ],
        ),
      );
}

class _PowerOrb extends StatefulWidget {
  const _PowerOrb({required this.status, required this.onTap});
  final CoreStatus status;
  final VoidCallback onTap;

  @override
  State<_PowerOrb> createState() => _PowerOrbState();
}

class _PowerOrbState extends State<_PowerOrb> with SingleTickerProviderStateMixin {
  late final AnimationController pulse;
  bool hovered = false;

  @override
  void initState() {
    super.initState();
    pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1350))..repeat(reverse: true);
  }

  @override
  void dispose() {
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.status == CoreStatus.running;
    final busy = widget.status == CoreStatus.starting || widget.status == CoreStatus.stopping;
    return MouseRegion(
      cursor: busy ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: GestureDetector(
        onTap: busy ? null : widget.onTap,
        child: AnimatedScale(
          scale: hovered ? 1.035 : 1,
          duration: const Duration(milliseconds: 140),
          child: AnimatedBuilder(
            animation: pulse,
            builder: (context, child) {
              final glow = connected ? .12 + pulse.value * .12 : .08;
              return Container(
                width: 82,
                height: 82,
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF7FAFF),
                  border: Border.all(color: const Color(0xFFD7E5FF), width: 1.5),
                  boxShadow: <BoxShadow>[
                    BoxShadow(color: const Color(0xFF1677FF).withOpacity(glow), blurRadius: 22, spreadRadius: 2),
                  ],
                ),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: connected
                          ? const <Color>[Color(0xFF367EFF), Color(0xFF6B63F6)]
                          : const <Color>[Color(0xFFEAF1FC), Color(0xFFDCE7F8)],
                    ),
                  ),
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(19),
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF1677FF)),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: 35,
                          color: connected ? Colors.white : const Color(0xFF1677FF),
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeroMetric extends StatelessWidget {
  const _HeroMetric({required this.label, required this.value, required this.data, this.green = false, this.purple = false});
  final String label;
  final String value;
  final List<double> data;
  final bool green;
  final bool purple;

  @override
  Widget build(BuildContext context) {
    final color = green
        ? const Color(0xFF17B66B)
        : purple
            ? const Color(0xFF8B5CF6)
            : const Color(0xFF1677FF);
    return Container(
      height: 92,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 7),
      decoration: BoxDecoration(
        color: const Color(0xFFFCFDFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF667085))),
          const SizedBox(height: 6),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
          const Spacer(),
          SizedBox(height: 22, width: double.infinity, child: CustomPaint(painter: _SparkPainter(data: data, color: color))),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  const _SparkPainter({required this.data, required this.color});
  final List<double> data;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final values = data.length >= 2 ? data : const <double>[0, 0];
    var maxValue = values.fold<double>(0, (a, b) => math.max(a, b).toDouble());
    maxValue = math.max(maxValue, 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height - (values[i] / maxValue).clamp(0.0, 1.0) * (size.height - 3) - 1.5;
      if (i == 0) path.moveTo(x, y); else path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()..color = color.withOpacity(.48)..strokeWidth = 1.2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) => oldDelegate.data != data || oldDelegate.color != color;
}

class _InlineStat extends StatelessWidget {
  const _InlineStat({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$label  ', style: const TextStyle(fontSize: 9.5, color: Color(0xFF98A2B3))),
          Text(value, style: const TextStyle(fontSize: 10.5, color: Color(0xFF344054), fontWeight: FontWeight.w700)),
        ],
      );
}

class _DashboardNodeCard extends StatelessWidget {
  const _DashboardNodeCard({
    required this.nodes,
    required this.totalCount,
    required this.selectedNode,
    required this.filter,
    required this.searchController,
    required this.onFilter,
    required this.onSearch,
    required this.onSelect,
    required this.onFavorite,
    required this.onTest,
    required this.testingNodeIds,
    required this.onOpenAll,
  });

  final List<NodeProfile> nodes;
  final int totalCount;
  final NodeProfile? selectedNode;
  final String filter;
  final TextEditingController searchController;
  final ValueChanged<String> onFilter;
  final VoidCallback onSearch;
  final ValueChanged<NodeProfile> onSelect;
  final ValueChanged<NodeProfile> onFavorite;
  final VoidCallback onTest;
  final Set<String> testingNodeIds;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    final shown = nodes.take(5).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text('节点列表', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
                const Spacer(),
                TextButton(onPressed: onOpenAll, child: const Text('管理全部', style: TextStyle(fontSize: 10.5))),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 560;
                return compact
                    ? Column(
                        children: <Widget>[
                          Row(children: <Widget>[
                            _FilterButton(text: '全部', selected: filter == 'all', onTap: () => onFilter('all')),
                            _FilterButton(text: '收藏', selected: filter == 'favorite', onTap: () => onFilter('favorite')),
                            _FilterButton(text: '自动选择', selected: filter == 'auto', onTap: () => onFilter('auto')),
                          ]),
                          const SizedBox(height: 8),
                          Row(children: <Widget>[
                            Expanded(child: SizedBox(height: 36, child: TextField(controller: searchController, onChanged: (_) => onSearch(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded, size: 17), hintText: '搜索节点')))),
                            const SizedBox(width: 7),
                            _SquareToolButton(icon: Icons.refresh_rounded, tooltip: '测试全部延迟', onTap: onTest),
                          ]),
                        ],
                      )
                    : Row(
                        children: <Widget>[
                          _FilterButton(text: '全部', selected: filter == 'all', onTap: () => onFilter('all')),
                          _FilterButton(text: '收藏', selected: filter == 'favorite', onTap: () => onFilter('favorite')),
                          _FilterButton(text: '自动选择', selected: filter == 'auto', onTap: () => onFilter('auto')),
                          const Spacer(),
                          SizedBox(width: 210, height: 36, child: TextField(controller: searchController, onChanged: (_) => onSearch(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded, size: 17), hintText: '搜索节点'))),
                          const SizedBox(width: 7),
                          _SquareToolButton(icon: Icons.refresh_rounded, tooltip: '测试全部延迟', onTap: onTest),
                        ],
                      );
              },
            ),
            const SizedBox(height: 12),
            const _NodeTableHeader(),
            const SizedBox(height: 2),
            if (shown.isEmpty)
              const SizedBox(height: 238, child: Center(child: _EmptyState(icon: Icons.dns_outlined, title: '暂无节点', subtitle: '添加订阅或导入节点后会显示在这里。')))
            else
              for (final node in shown)
                _DashboardNodeRow(
                  node: node,
                  selected: node.id == selectedNode?.id,
                  testing: testingNodeIds.contains(node.id),
                  onSelect: () => onSelect(node),
                  onFavorite: () => onFavorite(node),
                ),
            const SizedBox(height: 7),
            Text('共 $totalCount 个节点，当前显示 ${shown.length} 个', style: const TextStyle(fontSize: 9.5, color: Color(0xFF7B8798))),
          ],
        ),
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.text, required this.selected, required this.onTap});
  final String text;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFEEF5FF) : const Color(0xFFFAFBFD),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: selected ? const Color(0xFF94BFFF) : const Color(0xFFE5EAF1)),
            ),
            child: Text(text, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: selected ? const Color(0xFF1677FF) : const Color(0xFF344054))),
          ),
        ),
      );
}

class _SquareToolButton extends StatelessWidget {
  const _SquareToolButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: const Color(0xFFFAFBFD), border: Border.all(color: const Color(0xFFDCE4EE)), borderRadius: BorderRadius.circular(7)),
            child: Icon(icon, size: 17, color: const Color(0xFF506078)),
          ),
        ),
      );
}

class _NodeTableHeader extends StatelessWidget {
  const _NodeTableHeader();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          children: <Widget>[
            Expanded(flex: 5, child: Text('节点名称', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
            Expanded(flex: 2, child: Text('类型', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
            Expanded(flex: 2, child: Text('延迟', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
            SizedBox(width: 55, child: Text('状态', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
            SizedBox(width: 72, child: Text('操作', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
          ],
        ),
      );
}

class _DashboardNodeRow extends StatefulWidget {
  const _DashboardNodeRow({required this.node, required this.selected, required this.testing, required this.onSelect, required this.onFavorite});
  final NodeProfile node;
  final bool selected;
  final bool testing;
  final VoidCallback onSelect;
  final VoidCallback onFavorite;

  @override
  State<_DashboardNodeRow> createState() => _DashboardNodeRowState();
}

class _DashboardNodeRowState extends State<_DashboardNodeRow> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: InkWell(
        onTap: widget.onSelect,
        borderRadius: BorderRadius.circular(7),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 40,
          margin: const EdgeInsets.only(bottom: 2),
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: widget.selected
                ? const Color(0xFFEEF5FF)
                : hovered
                    ? const Color(0xFFFAFCFF)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: widget.selected ? const Color(0xFFB8D4FF) : Colors.transparent),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                flex: 5,
                child: Row(children: <Widget>[
                  SizedBox(width: 27, child: Text(_nodeFlag(node), style: const TextStyle(fontSize: 16))),
                  const SizedBox(width: 4),
                  Expanded(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF1D2939)))),
                ]),
              ),
              Expanded(flex: 2, child: Text(node.protocol.toUpperCase(), style: const TextStyle(fontSize: 9.5, color: Color(0xFF53627A)))),
              Expanded(
                flex: 2,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: widget.testing
                      ? const SizedBox(key: ValueKey('testing'), width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 1.8, color: Color(0xFF1677FF)))
                      : Text(
                          node.latencyMs == null ? '--' : '${node.latencyMs} ms',
                          key: ValueKey(node.latencyMs),
                          style: TextStyle(fontSize: 9.5, color: node.latencyMs == null ? const Color(0xFF98A2B3) : _latencyColor(node.latencyMs!)),
                        ),
                ),
              ),
              SizedBox(
                width: 55,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: widget.testing
                      ? const Icon(Icons.sync_rounded, key: ValueKey('sync'), size: 16, color: Color(0xFF1677FF))
                      : Icon(node.testError == null ? Icons.check_rounded : Icons.close_rounded, key: ValueKey(node.testError == null), size: 16, color: node.testError == null ? const Color(0xFF0DB46C) : const Color(0xFFF04438)),
                ),
              ),
              SizedBox(
                width: 72,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
                      tooltip: node.favorite ? '取消收藏' : '收藏',
                      onPressed: widget.onFavorite,
                      icon: AnimatedScale(
                        scale: node.favorite ? 1.12 : 1,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutBack,
                        child: Icon(node.favorite ? Icons.star_rounded : Icons.star_border_rounded, size: 18, color: node.favorite ? const Color(0xFFFFB800) : const Color(0xFF95A2B5)),
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: '更多操作',
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.more_horiz_rounded, size: 18, color: Color(0xFF667085)),
                      onSelected: (value) {
                        if (value == 'copy') {
                          Clipboard.setData(ClipboardData(text: '${node.server}:${node.port}'));
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('节点地址已复制')));
                        } else if (value == 'details') {
                          showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(node.name),
                              content: SizedBox(
                                width: 520,
                                child: SelectableText(
                                  '${node.protocol.toUpperCase()}\n${node.server}:${node.port}\n\n${prettyJson(node.outbound)}',
                                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5, height: 1.45),
                                ),
                              ),
                              actions: <Widget>[TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
                            ),
                          );
                        }
                      },
                      itemBuilder: (_) => const <PopupMenuEntry<String>>[
                        PopupMenuItem(value: 'details', child: Text('节点详情')),
                        PopupMenuItem(value: 'copy', child: Text('复制地址')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.upload, required this.download});
  final List<double> upload;
  final List<double> download;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(children: <Widget>[
              const Text('实时流量', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
              const Spacer(),
              const _LegendDot(color: Color(0xFF1677FF), text: '下载 (MB/s)'),
              const SizedBox(width: 10),
              const _LegendDot(color: Color(0xFF16B66B), text: '上传 (MB/s)'),
              const SizedBox(width: 2),
              const Icon(Icons.more_horiz_rounded, size: 17, color: Color(0xFF667085)),
            ]),
            const SizedBox(height: 10),
            SizedBox(height: 145, width: double.infinity, child: CustomPaint(painter: _TrafficPainter(upload: upload, download: download))),
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: _trafficTimeLabels(DateTime.now())
                  .map((label) => Text(label, style: const TextStyle(fontSize: 8.5, color: Color(0xFF98A2B3))))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrafficPainter extends CustomPainter {
  _TrafficPainter({required this.upload, required this.download});
  final List<double> upload;
  final List<double> download;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xFFEDF2F7)..strokeWidth = .8;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 0; i <= 5; i++) {
      final x = size.width * i / 5;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final maxValue = math.max(1.0, <double>[...upload, ...download].fold<double>(0, (a, b) => math.max(a, b).toDouble()));
    _line(canvas, size, download, maxValue, const Color(0xFF1677FF));
    _line(canvas, size, upload, maxValue, const Color(0xFF16B66B));
  }

  void _line(Canvas canvas, Size size, List<double> values, double maxValue, Color color) {
    final data = values.length >= 2 ? values : const <double>[0, 0];
    final points = <Offset>[];
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final y = size.height - (data[i] / math.max(maxValue, 12)).clamp(0.0, 1.0) * (size.height - 16) - 8;
      points.add(Offset(x, y));
    }
    if (points.length < 2) return;
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length - 1; i++) {
      final current = points[i];
      final next = points[i + 1];
      path.quadraticBezierTo(current.dx, current.dy, (current.dx + next.dx) / 2, (current.dy + next.dy) / 2);
    }
    path.lineTo(points.last.dx, points.last.dy);
    canvas.drawPath(path, Paint()..color = color..strokeWidth = 1.8..style = PaintingStyle.stroke..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _TrafficPainter oldDelegate) => true;
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Container(width: 11, height: 2.4, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(fontSize: 8.5, color: Color(0xFF667085))),
      ]);
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onConnect, required this.onAuto, required this.onTest, required this.onClear});
  final VoidCallback onConnect;
  final VoidCallback onAuto;
  final VoidCallback onTest;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('快捷操作', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
            const SizedBox(height: 11),
            LayoutBuilder(builder: (context, constraints) {
              final narrow = constraints.maxWidth < 330;
              final children = <Widget>[
                _ActionTile(icon: Icons.bolt_rounded, text: '一键连接', color: const Color(0xFF1677FF), onTap: onConnect),
                _ActionTile(icon: Icons.hub_rounded, text: '自动选择', color: const Color(0xFF11A86B), onTap: onAuto),
                _ActionTile(icon: Icons.speed_rounded, text: '测试延迟', color: const Color(0xFF7857F6), onTap: onTest),
                _ActionTile(icon: Icons.delete_outline_rounded, text: '清除缓存', color: const Color(0xFFFF6B35), onTap: onClear),
              ];
              if (narrow) return Column(children: children.map((e) => Padding(padding: const EdgeInsets.only(bottom: 7), child: e)).toList());
              return GridView.count(
                crossAxisCount: 2,
                childAspectRatio: 3.1,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: children,
              );
            }),
          ]),
        ),
      );
}

class _ActionTile extends StatefulWidget {
  const _ActionTile({required this.icon, required this.text, required this.color, required this.onTap});
  final IconData icon;
  final String text;
  final Color color;
  final VoidCallback onTap;
  @override
  State<_ActionTile> createState() => _ActionTileState();
}

class _ActionTileState extends State<_ActionTile> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(9),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            transform: Matrix4.translationValues(0, hovered ? -1 : 0, 0),
            decoration: BoxDecoration(
              color: hovered ? const Color(0xFFF7FAFE) : const Color(0xFFFCFDFF),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: hovered ? const Color(0xFFCFDDF0) : const Color(0xFFE6EBF2)),
            ),
            child: Row(children: <Widget>[
              Icon(widget.icon, size: 18, color: widget.color),
              const SizedBox(width: 9),
              Expanded(child: Text(widget.text, style: const TextStyle(fontSize: 10.5, color: Color(0xFF344054), fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
      );
}

class _DashboardSubscriptionsCard extends StatelessWidget {
  const _DashboardSubscriptionsCard({required this.subscriptions, required this.nodes, required this.onOpen});
  final List<SubscriptionProfile> subscriptions;
  final List<NodeProfile> nodes;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final items = subscriptions.take(3).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            const Text('订阅管理', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
            const Spacer(),
            TextButton(onPressed: onOpen, child: const Text('管理订阅', style: TextStyle(fontSize: 10))),
          ]),
          const SizedBox(height: 4),
          if (items.isNotEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 0, 6, 5),
              child: Row(
                children: <Widget>[
                  Expanded(flex: 4, child: Text('订阅名称', style: TextStyle(fontSize: 8.6, color: Color(0xFF98A2B3)))),
                  Expanded(flex: 3, child: Text('更新日期', style: TextStyle(fontSize: 8.6, color: Color(0xFF98A2B3)))),
                  SizedBox(width: 30, child: Text('状态', style: TextStyle(fontSize: 8.6, color: Color(0xFF98A2B3)))),
                  SizedBox(width: 28, child: Text('操作', textAlign: TextAlign.right, style: TextStyle(fontSize: 8.6, color: Color(0xFF98A2B3)))),
                ],
              ),
            ),
          if (items.isEmpty)
            const SizedBox(height: 110, child: Center(child: Text('暂无订阅', style: TextStyle(fontSize: 10.5, color: Color(0xFF98A2B3)))))
          else
            for (final sub in items)
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFEEF2F6)))),
                child: Row(children: <Widget>[
                  Expanded(flex: 4, child: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.8, color: Color(0xFF344054), fontWeight: FontWeight.w600))),
                  Expanded(flex: 3, child: Text(sub.lastUpdated == null ? '尚未更新' : _dateTime(sub.lastUpdated!), style: const TextStyle(fontSize: 8.8, color: Color(0xFF667085)))),
                  const Icon(Icons.check_rounded, size: 15, color: Color(0xFF0DB46C)),
                  const SizedBox(width: 10),
                  const Icon(Icons.refresh_rounded, size: 14, color: Color(0xFF667085)),
                ]),
              ),
          const SizedBox(height: 9),
          Row(children: <Widget>[
            FilledButton.icon(onPressed: onOpen, icon: const Icon(Icons.add_rounded, size: 15), label: const Text('添加订阅')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onOpen, child: const Text('更新全部')),
            const Spacer(),
            Text('${nodes.length} 个节点', style: const TextStyle(fontSize: 9.5, color: Color(0xFF98A2B3))),
          ]),
        ]),
      ),
    );
  }
}

class _DashboardConnectionSettingsCard extends StatelessWidget {
  const _DashboardConnectionSettingsCard({required this.settings, required this.onOpen});
  final AppSettings settings;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[
              const Text('连接设置', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
              const Spacer(),
              IconButton(onPressed: onOpen, icon: const Icon(Icons.chevron_right_rounded, size: 18), tooltip: '打开设置'),
            ]),
            _DashboardToggle(icon: Icons.settings_input_antenna_rounded, title: '系统代理', subtitle: '自动配置系统代理', value: settings.systemProxyEnabled),
            _DashboardToggle(icon: Icons.rocket_launch_outlined, title: '开机自启', subtitle: '系统启动时自动运行', value: settings.startWithWindows),
            _DashboardToggle(icon: Icons.shield_outlined, title: 'TUN 模式', subtitle: '虚拟网卡模式', value: settings.tunEnabled),
            const SizedBox(height: 7),
            Row(children: <Widget>[
              const Icon(Icons.alt_route_rounded, size: 16, color: Color(0xFF344054)),
              const SizedBox(width: 8),
              const Text('路由模式', style: TextStyle(fontSize: 10, color: Color(0xFF344054), fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(_routeModeText(settings.routeMode), style: const TextStyle(fontSize: 9.5, color: Color(0xFF1677FF), fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            Row(children: <Widget>[
              const Icon(Icons.dns_outlined, size: 16, color: Color(0xFF344054)),
              const SizedBox(width: 8),
              const Text('DNS 模式', style: TextStyle(fontSize: 10, color: Color(0xFF344054), fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(settings.dnsMode == 'doh' ? 'DoH' : '自动', style: const TextStyle(fontSize: 9.5, color: Color(0xFF667085))),
            ]),
          ]),
        ),
      );
}


class _PremiumSwitch extends StatelessWidget {
  const _PremiumSwitch({required this.value});
  final bool value;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value ? 1 : 0),
      duration: const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Container(
          width: 36,
          height: 20,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: Color.lerp(
              const Color(0xFFD7DFEA),
              const Color(0xFF1677FF),
              t,
            ),
            boxShadow: t > .5
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x261677FF),
                      blurRadius: 8,
                      offset: Offset(0, 2),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Align(
            alignment: Alignment.lerp(
              Alignment.centerLeft,
              Alignment.centerRight,
              t,
            )!,
            child: Container(
              width: 16,
              height: 16,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Color(0x1A101828),
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashboardToggle extends StatelessWidget {
  const _DashboardToggle({required this.icon, required this.title, required this.subtitle, required this.value});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: <Widget>[
          Icon(icon, size: 16, color: const Color(0xFF344054)),
          const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 10, color: Color(0xFF344054), fontWeight: FontWeight.w600)),
            Text(subtitle, style: const TextStyle(fontSize: 8.3, color: Color(0xFF98A2B3))),
          ])),
          IgnorePointer(child: _PremiumSwitch(value: value)),
        ]),
      );
}

class _DashboardSystemCard extends StatelessWidget {
  const _DashboardSystemCard({required this.controller, required this.settings, required this.coreAvailable});
  final SingBoxController controller;
  final AppSettings settings;
  final bool coreAvailable;
  @override
  Widget build(BuildContext context) {
    final duration = controller.connectedAt == null ? Duration.zero : DateTime.now().difference(controller.connectedAt!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Text('系统状态', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
          const SizedBox(height: 9),
          _SystemLine(
            icon: Icons.memory_rounded,
            label: '核心状态',
            value: !coreAvailable ? 'HongdaService 缺失' : (controller.isRunning ? '运行中' : _shortStatus(controller.status)),
            green: controller.isRunning,
          ),
          _SystemLine(
            icon: Icons.settings_input_antenna_rounded,
            label: '服务模式',
            value: settings.tunEnabled ? 'TUN + 系统代理' : (settings.systemProxyEnabled ? '系统代理' : '核心代理'),
            green: controller.isRunning,
          ),
          _SystemLine(icon: Icons.input_rounded, label: '本地端口', value: '${settings.mixedPort}'),
          _SystemLine(icon: Icons.public_rounded, label: '路由模式', value: _routeModeText(settings.routeMode)),
          _SystemLine(icon: Icons.schedule_rounded, label: '运行时间', value: _formatDuration(duration)),
          _SystemLine(icon: Icons.data_usage_rounded, label: '流量统计', value: _formatBytes(controller.lifetimeTrafficBytes)),
        ]),
      ),
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.icon, required this.label, required this.value, this.green = false});
  final IconData icon;
  final String label;
  final String value;
  final bool green;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: <Widget>[
          Icon(icon, size: 14, color: const Color(0xFF53627A)),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(fontSize: 9.4, color: Color(0xFF667085))),
          const Spacer(),
          if (green) Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: const BoxDecoration(color: Color(0xFF11A86B), shape: BoxShape.circle)),
          Flexible(child: Text(value, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.4, color: green ? const Color(0xFF11A86B) : const Color(0xFF344054), fontWeight: FontWeight.w600))),
        ]),
      );
}

String _nodeFlag(NodeProfile node) {
  final text = '${node.name} ${node.server}'.toLowerCase();
  if (text.contains('香港') || text.contains('hong kong') || text.contains(' hk')) return '🇭🇰';
  if (text.contains('日本') || text.contains('japan') || text.contains('tokyo') || text.contains('jp')) return '🇯🇵';
  if (text.contains('新加坡') || text.contains('singapore') || text.contains('sg')) return '🇸🇬';
  if (text.contains('美国') || text.contains('united states') || text.contains('los angeles') || text.contains('san jose') || text.contains(' us')) return '🇺🇸';
  if (text.contains('台湾') || text.contains('taiwan') || text.contains('tw')) return '🇹🇼';
  if (text.contains('韩国') || text.contains('korea') || text.contains('kr')) return '🇰🇷';
  return '🌐';
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}


class _NodesPage extends StatefulWidget {
  const _NodesPage({
    required this.nodes,
    required this.selectedNode,
    required this.controller,
    required this.settings,
    required this.onSelect,
    required this.onChanged,
  });

  final List<NodeProfile> nodes;
  final NodeProfile? selectedNode;
  final SingBoxController controller;
  final AppSettings settings;
  final ValueChanged<NodeProfile> onSelect;
  final VoidCallback onChanged;

  @override
  State<_NodesPage> createState() => _NodesPageState();
}

class _NodesPageState extends State<_NodesPage> {
  final search = TextEditingController();
  final Set<String> testing = <String>{};
  String filter = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<NodeProfile> get filtered {
    final query = search.text.trim().toLowerCase();
    var result = widget.nodes.where((node) {
      if (filter == 'favorite' && !node.favorite) return false;
      if (query.isEmpty) return true;
      return node.name.toLowerCase().contains(query) ||
          node.server.toLowerCase().contains(query) ||
          node.protocol.toLowerCase().contains(query);
    }).toList();
    if (filter == 'auto') {
      result.sort((a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _ToolbarCard(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 900;
              final filters = Wrap(
                spacing: 4,
                runSpacing: 4,
                children: <Widget>[
                  _FilterButton(text: '全部', selected: filter == 'all', onTap: () => setState(() => filter = 'all')),
                  _FilterButton(text: '收藏', selected: filter == 'favorite', onTap: () => setState(() => filter = 'favorite')),
                  _FilterButton(text: '自动选择', selected: filter == 'auto', onTap: () => setState(() => filter = 'auto')),
                ],
              );
              final searchBox = SizedBox(
                height: 38,
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    hintText: '搜索节点名称、地址或协议',
                  ),
                ),
              );
              final actionButtons = <Widget>[
                OutlinedButton.icon(
                  onPressed: testing.isEmpty ? _testAll : null,
                  icon: testing.isEmpty
                      ? const Icon(Icons.speed_rounded, size: 16)
                      : const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                  label: Text(testing.isEmpty ? '测试全部' : '测速中'),
                ),
                FilledButton.icon(
                  onPressed: _showImportDialog,
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('添加节点'),
                ),
              ];
              if (!compact) {
                return Row(
                  children: <Widget>[
                    filters,
                    const SizedBox(width: 18),
                    Expanded(child: searchBox),
                    const SizedBox(width: 8),
                    actionButtons[0],
                    const SizedBox(width: 8),
                    actionButtons[1],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  filters,
                  const SizedBox(height: 10),
                  searchBox,
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: actionButtons,
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Card(
            child: Column(
              children: <Widget>[
                Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFBFCFE),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
                    border: Border(bottom: BorderSide(color: Color(0xFFE8EDF3))),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 760) {
                        return const Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                '节点',
                                style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)),
                              ),
                            ),
                            Text(
                              '延迟 / 操作',
                              style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)),
                            ),
                          ],
                        );
                      }
                      return const _FullNodeHeader();
                    },
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: _EmptyState(icon: Icons.dns_outlined, title: '没有匹配的节点', subtitle: '可以添加节点、更新订阅，或清除当前筛选条件。'))
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final node = filtered[index];
                            return _NodeManagementRow(
                              node: node,
                              selected: node.id == widget.selectedNode?.id,
                              testing: testing.contains(node.id),
                              onSelect: () => widget.onSelect(node),
                              onFavorite: () {
                                setState(() => node.favorite = !node.favorite);
                                widget.onChanged();
                              },
                              onTest: () => _testOne(node),
                              onDelete: () => _deleteNode(node),
                            );
                          },
                        ),
                ),
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE8EDF3)))),
                  child: Row(children: <Widget>[
                    Expanded(
                      child: Text(
                        '共 ${widget.nodes.length} 个节点 · 当前显示 ${filtered.length} 个',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)),
                      ),
                    ),
                    if (widget.controller.isRunning) ...<Widget>[
                      const SizedBox(width: 8),
                      const _Pill(text: '运行中可无缝切换', color: Color(0xFF0A9B5B), background: Color(0xFFEAF8F1)),
                    ],
                  ]),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _testAll() async {
    final targets = filtered.where((node) => node.enabled).toList();
    if (targets.isEmpty) return;
    setState(() => testing.addAll(targets.map((node) => node.id)));
    for (final node in targets) {
      await widget.controller.testNode(node, widget.settings);
      if (mounted) setState(() => testing.remove(node.id));
    }
    widget.onChanged();
  }

  Future<void> _testOne(NodeProfile node) async {
    setState(() => testing.add(node.id));
    await widget.controller.testNode(node, widget.settings);
    if (!mounted) return;
    setState(() => testing.remove(node.id));
    widget.onChanged();
  }

  Future<void> _deleteNode(NodeProfile node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除节点'),
        content: Text('确定删除“${node.name}”吗？此操作只删除本地节点记录。'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => widget.nodes.removeWhere((item) => item.id == node.id));
    widget.onChanged();
  }

  Future<void> _showImportDialog() async {
    final input = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: <Widget>[
          _DialogIcon(icon: Icons.add_link_rounded),
          SizedBox(width: 10),
          Text('添加节点'),
        ]),
        content: SizedBox(
          width: 650,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('粘贴分享链接，支持一次导入多行。', style: TextStyle(fontSize: 11.5, color: Color(0xFF667085))),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              autofocus: true,
              minLines: 7,
              maxLines: 11,
              decoration: const InputDecoration(
                hintText: 'vless://...\nvmess://...\ntrojan://...\nhysteria2://...\nss://...',
                alignLabelWithHint: true,
              ),
            ),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton.icon(onPressed: () => Navigator.pop(context, input.text), icon: const Icon(Icons.file_download_outlined, size: 16), label: const Text('导入节点')),
        ],
      ),
    );
    input.dispose();
    if (result == null || result.trim().isEmpty) return;
    final imported = NodeParser.parseMany(result);
    if (imported.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有识别到支持的节点链接')));
      return;
    }
    final fingerprints = widget.nodes.map((node) => node.fingerprint).toSet();
    final added = imported.where((node) => fingerprints.add(node.fingerprint)).toList();
    setState(() => widget.nodes.addAll(added));
    widget.onChanged();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 ${added.length} 个节点${added.length != imported.length ? '，已自动跳过重复节点' : ''}')));
  }
}

class _ToolbarCard extends StatelessWidget {
  const _ToolbarCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.94),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFDDE5EF)),
        ),
        child: child,
      );
}

class _DialogIcon extends StatelessWidget {
  const _DialogIcon({required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(color: const Color(0xFFEAF3FF), borderRadius: BorderRadius.circular(9)),
        child: Icon(icon, color: const Color(0xFF1677FF), size: 19),
      );
}

class _FullNodeHeader extends StatelessWidget {
  const _FullNodeHeader();
  @override
  Widget build(BuildContext context) => Row(children: const <Widget>[
        Expanded(flex: 5, child: Text('节点名称', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
        Expanded(flex: 2, child: Text('类型', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
        Expanded(flex: 4, child: Text('服务器', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
        Expanded(flex: 2, child: Text('延迟', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
        SizedBox(width: 60, child: Text('状态', style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
        SizedBox(width: 118, child: Text('操作', textAlign: TextAlign.right, style: TextStyle(fontSize: 9.5, color: Color(0xFF7B8798)))),
      ]);
}

class _NodeManagementRow extends StatefulWidget {
  const _NodeManagementRow({
    required this.node,
    required this.selected,
    required this.testing,
    required this.onSelect,
    required this.onFavorite,
    required this.onTest,
    required this.onDelete,
  });
  final NodeProfile node;
  final bool selected;
  final bool testing;
  final VoidCallback onSelect;
  final VoidCallback onFavorite;
  final VoidCallback onTest;
  final VoidCallback onDelete;

  @override
  State<_NodeManagementRow> createState() => _NodeManagementRowState();
}

class _NodeManagementRowState extends State<_NodeManagementRow> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        return MouseRegion(
          onEnter: (_) => setState(() => hovered = true),
          onExit: (_) => setState(() => hovered = false),
          child: InkWell(
            onTap: widget.onSelect,
            borderRadius: BorderRadius.circular(10),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 170),
              curve: Curves.easeOutCubic,
              height: compact ? 72 : 52,
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 10 : 8,
                vertical: compact ? 7 : 0,
              ),
              decoration: BoxDecoration(
                color: widget.selected
                    ? const Color(0xFFEEF5FF)
                    : hovered
                        ? const Color(0xFFF8FBFF)
                        : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: widget.selected
                      ? const Color(0xFFBCD6FF)
                      : const Color(0x00FFFFFF),
                ),
              ),
              child: compact ? _compactRow(node) : _desktopRow(node),
            ),
          ),
        );
      },
    );
  }

  Widget _compactRow(NodeProfile node) {
    return Row(
      children: <Widget>[
        Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF7FAFE),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE4EAF2)),
          ),
          child: Text(_nodeFlag(node), style: const TextStyle(fontSize: 19)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      node.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1D2939),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: node.enabled
                          ? const Color(0xFF11A86B)
                          : const Color(0xFF98A2B3),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                '${node.protocol.toUpperCase()} · ${node.server}:${node.port}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 9.1,
                  color: Color(0xFF667085),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 170),
          child: widget.testing
              ? const SizedBox(
                  key: ValueKey<String>('testing'),
                  width: 32,
                  height: 32,
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Container(
                  key: ValueKey<int?>(node.latencyMs),
                  constraints: const BoxConstraints(minWidth: 50),
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                  decoration: BoxDecoration(
                    color: node.latencyMs == null
                        ? const Color(0xFFF2F4F7)
                        : _latencyColor(node.latencyMs!).withOpacity(.09),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    node.latencyMs == null ? '--' : '${node.latencyMs} ms',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9.3,
                      fontWeight: FontWeight.w800,
                      color: node.latencyMs == null
                          ? const Color(0xFF98A2B3)
                          : _latencyColor(node.latencyMs!),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<String>(
          tooltip: '节点操作',
          icon: const Icon(Icons.more_horiz_rounded, size: 19),
          onSelected: (value) {
            switch (value) {
              case 'test':
                if (!widget.testing) widget.onTest();
                break;
              case 'favorite':
                widget.onFavorite();
                break;
              case 'delete':
                widget.onDelete();
                break;
            }
          },
          itemBuilder: (context) => <PopupMenuEntry<String>>[
            const PopupMenuItem<String>(
              value: 'test',
              child: Text('测试延迟'),
            ),
            PopupMenuItem<String>(
              value: 'favorite',
              child: Text(node.favorite ? '取消收藏' : '收藏节点'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'delete',
              child: Text('删除节点'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _desktopRow(NodeProfile node) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 5,
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 30,
                child: Text(_nodeFlag(node), style: const TextStyle(fontSize: 17)),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  node.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.8,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1D2939),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            node.protocol.toUpperCase(),
            style: const TextStyle(fontSize: 9.5, color: Color(0xFF53627A)),
          ),
        ),
        Expanded(
          flex: 4,
          child: Text(
            '${node.server}:${node.port}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 9.3, color: Color(0xFF667085)),
          ),
        ),
        Expanded(
          flex: 2,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            child: widget.testing
                ? const Align(
                    key: ValueKey<String>('testing'),
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : Text(
                    node.latencyMs == null ? '--' : '${node.latencyMs} ms',
                    key: ValueKey<int?>(node.latencyMs),
                    style: TextStyle(
                      fontSize: 9.5,
                      color: node.latencyMs == null
                          ? const Color(0xFF98A2B3)
                          : _latencyColor(node.latencyMs!),
                    ),
                  ),
          ),
        ),
        SizedBox(
          width: 60,
          child: Row(
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: node.enabled
                      ? const Color(0xFF11A86B)
                      : const Color(0xFF98A2B3),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                node.enabled ? '可用' : '禁用',
                style: const TextStyle(fontSize: 9, color: Color(0xFF667085)),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 118,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              IconButton(
                tooltip: '测试延迟',
                onPressed: widget.testing ? null : widget.onTest,
                icon: const Icon(Icons.speed_rounded, size: 17),
                constraints: const BoxConstraints.tightFor(width: 31, height: 31),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                tooltip: node.favorite ? '取消收藏' : '收藏',
                onPressed: widget.onFavorite,
                icon: Icon(
                  node.favorite ? Icons.star_rounded : Icons.star_border_rounded,
                  size: 18,
                  color: node.favorite
                      ? const Color(0xFFFFB800)
                      : const Color(0xFF8FA0B5),
                ),
                constraints: const BoxConstraints.tightFor(width: 31, height: 31),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                tooltip: '删除',
                onPressed: widget.onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 17,
                  color: Color(0xFF9B5C5C),
                ),
                constraints: const BoxConstraints.tightFor(width: 31, height: 31),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        ),
      ],
    );
  }
}


class _SubscriptionsPage extends StatefulWidget {
  const _SubscriptionsPage({
    required this.subscriptions,
    required this.nodes,
    required this.groups,
    required this.rules,
    required this.onChanged,
  });
  final List<SubscriptionProfile> subscriptions;
  final List<NodeProfile> nodes;
  final List<ProxyGroupProfile> groups;
  final List<RouteRuleProfile> rules;
  final VoidCallback onChanged;
  @override
  State<_SubscriptionsPage> createState() => _SubscriptionsPageState();
}

class _SubscriptionsPageState extends State<_SubscriptionsPage> {
  final Set<String> updating = <String>{};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _ToolbarCard(
          child: Row(children: <Widget>[
            const Expanded(
              child: Row(children: <Widget>[
                Icon(Icons.lock_outline_rounded, size: 16, color: Color(0xFF1677FF)),
                SizedBox(width: 8),
                Flexible(child: Text('订阅地址仅保存在本机；更新时会替换该订阅上一次导入的节点。', style: TextStyle(fontSize: 10.8, color: Color(0xFF667085)))),
              ]),
            ),
            OutlinedButton.icon(onPressed: updating.isEmpty && widget.subscriptions.isNotEmpty ? _updateAll : null, icon: const Icon(Icons.sync_rounded, size: 16), label: const Text('更新全部')),
            const SizedBox(width: 8),
            FilledButton.icon(onPressed: _addSubscription, icon: const Icon(Icons.add_rounded, size: 16), label: const Text('添加订阅')),
          ]),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Card(
            child: widget.subscriptions.isEmpty
                ? const Center(child: _EmptyState(icon: Icons.cloud_download_outlined, title: '暂无订阅', subtitle: '添加订阅 URL 后，可自动解析并同步节点。'))
                : ListView.builder(
                    padding: const EdgeInsets.all(10),
                    itemCount: widget.subscriptions.length,
                    itemBuilder: (context, index) {
                      final sub = widget.subscriptions[index];
                      return _SubscriptionTile(
                        sub: sub,
                        busy: updating.contains(sub.id),
                        onUpdate: () => _updateSubscription(sub),
                        onDelete: () => _deleteSubscription(sub),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _updateAll() async {
    for (final sub in List<SubscriptionProfile>.from(widget.subscriptions)) {
      await _updateSubscription(sub, showToast: false);
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('全部订阅已更新完成')));
  }

  Future<void> _addSubscription() async {
    final name = TextEditingController(text: '我的订阅');
    final url = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(children: <Widget>[
          _DialogIcon(icon: Icons.cloud_download_outlined),
          SizedBox(width: 10),
          Text('添加订阅'),
        ]),
        content: SizedBox(
          width: 600,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('支持 Clash / Mihomo / sing-box / Base64 节点订阅。', style: TextStyle(fontSize: 11, color: Color(0xFF667085))),
            const SizedBox(height: 14),
            TextField(controller: name, decoration: const InputDecoration(labelText: '订阅名称')),
            const SizedBox(height: 10),
            TextField(controller: url, decoration: const InputDecoration(labelText: '订阅 URL', hintText: 'https://example.com/subscription')),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton.icon(onPressed: () => Navigator.pop(context, true), icon: const Icon(Icons.download_rounded, size: 16), label: const Text('保存并更新')),
        ],
      ),
    );
    if (ok != true || url.text.trim().isEmpty) {
      name.dispose();
      url.dispose();
      return;
    }
    final sub = SubscriptionProfile(
      id: 'sub-${DateTime.now().microsecondsSinceEpoch}',
      name: name.text.trim().isEmpty ? '我的订阅' : name.text.trim(),
      url: url.text.trim(),
    );
    name.dispose();
    url.dispose();
    setState(() => widget.subscriptions.add(sub));
    widget.onChanged();
    await _updateSubscription(sub);
  }

  Future<void> _deleteSubscription(SubscriptionProfile sub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除订阅'),
        content: Text('删除“${sub.name}”并同时移除该订阅导入的节点、规则组和路由规则？'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE5484D)), onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      widget.subscriptions.removeWhere((item) => item.id == sub.id);
      widget.nodes.removeWhere((node) => node.source == sub.id);
      widget.groups.removeWhere((group) => group.source == sub.id);
      widget.rules.removeWhere((rule) => rule.source == sub.id);
    });
    widget.onChanged();
  }

  Future<void> _updateSubscription(SubscriptionProfile sub, {bool showToast = true}) async {
    setState(() => updating.add(sub.id));
    try {
      final result = await SubscriptionService.fetch(sub);
      final imported = result.imported;
      widget.nodes.removeWhere((node) => node.source == sub.id);
      widget.groups.removeWhere((group) => group.source == sub.id);
      widget.rules.removeWhere((rule) => rule.source == sub.id);
      widget.nodes.addAll(imported.nodes);
      widget.groups.addAll(imported.groups);
      widget.rules.addAll(imported.rules);
      sub.nodeCount = imported.nodes.length;
      sub.format = imported.format;
      sub.uploadBytes = result.uploadBytes;
      sub.downloadBytes = result.downloadBytes;
      sub.totalBytes = result.totalBytes;
      sub.expiresAt = result.expiresAt;
      sub.lastUpdated = DateTime.now();
      sub.lastError = null;
      widget.onChanged();
      if (mounted && showToast) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已更新 ${sub.name}：${imported.nodes.length} 节点 · ${imported.groups.length} 规则组 · ${imported.rules.length} 路由规则'),
        ));
      }
    } catch (e) {
      sub.lastError = e.toString();
      widget.onChanged();
      if (mounted && showToast) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('订阅更新失败：$e')));
    } finally {
      if (mounted) setState(() => updating.remove(sub.id));
    }
  }
}

class _SubscriptionTile extends StatefulWidget {
  const _SubscriptionTile({required this.sub, required this.busy, required this.onUpdate, required this.onDelete});
  final SubscriptionProfile sub;
  final bool busy;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;
  @override
  State<_SubscriptionTile> createState() => _SubscriptionTileState();
}

class _SubscriptionTileState extends State<_SubscriptionTile> {
  bool hovered = false;
  @override
  Widget build(BuildContext context) {
    final sub = widget.sub;
    final healthy = sub.lastError == null;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 130),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: hovered ? const Color(0xFFF8FBFF) : const Color(0xFFFCFDFF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hovered ? const Color(0xFFCFE0F6) : const Color(0xFFE5EAF1)),
        ),
        child: Row(children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: const Color(0xFFEAF3FF), borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.cloud_outlined, color: Color(0xFF1677FF), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Row(children: <Widget>[
                Flexible(child: Text(sub.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: Color(0xFF1D2939)))),
                const SizedBox(width: 8),
                _Pill(
                  text: healthy ? '${sub.nodeCount} 个节点' : '更新失败',
                  color: healthy ? const Color(0xFF0A9B5B) : const Color(0xFFC13D3D),
                  background: healthy ? const Color(0xFFEAF8F1) : const Color(0xFFFFEEEE),
                ),
              ]),
              const SizedBox(height: 5),
              Text(sub.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.7, color: Color(0xFF667085))),
              const SizedBox(height: 5),
              Wrap(
                spacing: 10,
                runSpacing: 3,
                children: <Widget>[
                  Text(sub.lastUpdated == null ? '尚未更新' : '最后更新 ${_dateTime(sub.lastUpdated!)}', style: const TextStyle(fontSize: 9.2, color: Color(0xFF98A2B3))),
                  Text('格式 ${sub.format}', style: const TextStyle(fontSize: 9.2, color: Color(0xFF7B8798))),
                  if (sub.totalBytes != null) Text('额度 ${_formatBytes((sub.uploadBytes ?? 0) + (sub.downloadBytes ?? 0))} / ${_formatBytes(sub.totalBytes!)}', style: const TextStyle(fontSize: 9.2, color: Color(0xFF7B8798))),
                  if (sub.expiresAt != null) Text('到期 ${_dateTime(sub.expiresAt!)}', style: const TextStyle(fontSize: 9.2, color: Color(0xFF7B8798))),
                ],
              ),
            ]),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: widget.busy ? null : widget.onUpdate,
            icon: widget.busy
                ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded, size: 15),
            label: Text(widget.busy ? '更新中' : '更新'),
          ),
          const SizedBox(width: 6),
          IconButton(tooltip: '删除订阅', onPressed: widget.busy ? null : widget.onDelete, icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Color(0xFF8C5960))),
        ]),
      ),
    );
  }
}


class _ServiceStatusPage extends StatelessWidget {
  const _ServiceStatusPage({
    required this.controller,
    required this.settings,
    required this.node,
    required this.uploadHistory,
    required this.downloadHistory,
    required this.onToggle,
    required this.onChooseNode,
  });

  final SingBoxController controller;
  final AppSettings settings;
  final NodeProfile? node;
  final List<double> uploadHistory;
  final List<double> downloadHistory;
  final VoidCallback onToggle;
  final VoidCallback onChooseNode;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        _ConnectionHeroCard(
          controller: controller,
          settings: settings,
          node: node,
          uploadHistory: uploadHistory,
          downloadHistory: downloadHistory,
          onToggle: onToggle,
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    const Text('Service IPC', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 12),
                    _SystemLine(icon: Icons.link_rounded, label: 'IPC 状态', value: controller.ipcConnected ? '已连接' : '未连接', green: controller.ipcConnected),
                    _SystemLine(icon: Icons.memory_rounded, label: '核心状态', value: _shortStatus(controller.status), green: controller.isRunning),
                    _SystemLine(icon: Icons.input_rounded, label: 'Mixed 端口', value: '${settings.mixedPort}'),
                    _SystemLine(icon: Icons.api_rounded, label: 'API 端口', value: '${settings.apiPort}'),
                    _SystemLine(icon: Icons.account_tree_outlined, label: '活动连接', value: '${controller.activeConnections}'),
                  ]),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _TrafficCard(upload: uploadHistory, download: downloadHistory)),
          ],
        ),
      ],
    );
  }
}


class _RouteModeSelector extends StatelessWidget {
  const _RouteModeSelector({
    required this.settings,
    required this.enabled,
    required this.onChanged,
  });

  final AppSettings settings;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final modes = <({String value, String title, String subtitle, IconData icon})>[
      (
        value: 'rule',
        title: '智能分流',
        subtitle: '国内直连 · 常用海外走代理',
        icon: Icons.alt_route_rounded,
      ),
      (
        value: 'global',
        title: '全局代理',
        subtitle: '所有流量使用当前节点',
        icon: Icons.public_rounded,
      ),
      (
        value: 'auto',
        title: '自动选择',
        subtitle: '全部走 URLTest 最优节点',
        icon: Icons.speed_rounded,
      ),
      (
        value: 'direct',
        title: '全部直连',
        subtitle: '不经过代理节点',
        icon: Icons.link_rounded,
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '路由模式',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF101828),
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '智能分流参考 Karing 的规则集思路：自定义规则优先，随后国内直连 / 代理列表，最后按模式兜底。',
                        style: TextStyle(fontSize: 9.6, color: Color(0xFF667085), height: 1.4),
                      ),
                    ],
                  ),
                ),
                if (!enabled)
                  const _Pill(
                    text: '断开后可切换',
                    color: Color(0xFF9A6700),
                    background: Color(0xFFFFF7D6),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final count = constraints.maxWidth >= 900 ? 4 : (constraints.maxWidth >= 520 ? 2 : 1);
                final width = (constraints.maxWidth - (count - 1) * 9) / count;
                return Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: modes.map((mode) {
                    final selected = settings.routeMode == mode.value;
                    return SizedBox(
                      width: width,
                      child: _RouteModeChoice(
                        icon: mode.icon,
                        title: mode.title,
                        subtitle: mode.subtitle,
                        selected: selected,
                        enabled: enabled,
                        onTap: () {
                          settings.routeMode = mode.value;
                          onChanged();
                        },
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            if (settings.routeMode == 'rule') ...<Widget>[
              const SizedBox(height: 12),
              const Divider(),
              const SizedBox(height: 2),
              _SettingSwitch(
                title: '国内域名 / IP 直连',
                subtitle: '启用 ChinaDomain、ChinaIp、LocalAreaNetwork 规则集',
                value: settings.smartCnDirect,
                enabled: enabled,
                onChanged: (v) {
                  settings.smartCnDirect = v;
                  onChanged();
                },
              ),
              _SettingSwitch(
                title: '常用海外站点代理',
                subtitle: '启用 ProxyLite 规则集，命中后走当前代理',
                value: settings.smartProxyList,
                enabled: enabled,
                onChanged: (v) {
                  settings.smartProxyList = v;
                  onChanged();
                },
              ),
              _SettingSwitch(
                title: '广告域名拦截',
                subtitle: '可选 BanAD 规则集；默认关闭，避免误伤个别站点功能',
                value: settings.smartAdBlock,
                enabled: enabled,
                onChanged: (v) {
                  settings.smartAdBlock = v;
                  onChanged();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RouteModeChoice extends StatefulWidget {
  const _RouteModeChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_RouteModeChoice> createState() => _RouteModeChoiceState();
}

class _RouteModeChoiceState extends State<_RouteModeChoice> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled;
    final selected = widget.selected;
    final border = selected ? const Color(0xFF9CC3FF) : const Color(0xFFE3EAF3);
    final background = selected
        ? const Color(0xFFEEF5FF)
        : (hovered && active ? const Color(0xFFF8FBFF) : const Color(0xFFFCFDFF));

    return MouseRegion(
      cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) {
        if (active) setState(() => hovered = true);
      },
      onExit: (_) {
        if (hovered) setState(() => hovered = false);
      },
      child: GestureDetector(
        onTap: active ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border),
            boxShadow: selected
                ? const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x151677FF),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ]
                : const <BoxShadow>[],
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: selected ? const Color(0xFF1677FF) : const Color(0xFFF0F4F9),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                  widget.icon,
                  size: 18,
                  color: selected ? Colors.white : const Color(0xFF5B6B81),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w800,
                        color: active ? const Color(0xFF1D2939) : const Color(0xFF98A2B3),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 8.5,
                        height: 1.25,
                        color: active ? const Color(0xFF667085) : const Color(0xFFB6BFCA),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 5),
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? const Color(0xFF1677FF) : Colors.transparent,
                  border: Border.all(
                    color: selected ? const Color(0xFF1677FF) : const Color(0xFFB8C4D4),
                    width: 1.4,
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check_rounded, size: 11, color: Colors.white)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionSettingsPage extends StatelessWidget {
  const _ConnectionSettingsPage({required this.settings, required this.isRunning, required this.isAdmin, required this.onChanged, required this.onRestartAdmin});
  final AppSettings settings;
  final bool isRunning;
  final bool isAdmin;
  final VoidCallback onChanged;
  final Future<bool> Function() onRestartAdmin;
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        _RouteModeSelector(settings: settings, enabled: !isRunning, onChanged: onChanged),
        const SizedBox(height: 16),
        _SettingsCard(title: '代理模式', children: <Widget>[
          _SettingSwitch(title: 'TUN 模式', subtitle: '接管 Windows 系统流量；开启后需要管理员权限', value: settings.tunEnabled, enabled: !isRunning, onChanged: (v) { settings.tunEnabled = v; onChanged(); }),
          if ((settings.tunEnabled || settings.tailscaleEnabled) && !isAdmin)
            Padding(padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12), child: Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: onRestartAdmin, icon: const Icon(Icons.admin_panel_settings_outlined), label: const Text('以管理员身份重启')))),
          _SettingSwitch(title: '严格路由', subtitle: 'Windows 下可降低多宿主 DNS 泄漏风险；个别虚拟机软件可能受影响', value: settings.strictRoute, enabled: !isRunning && settings.tunEnabled, onChanged: (v) { settings.strictRoute = v; onChanged(); }),
          _SettingSwitch(title: '局域网直连', subtitle: '私有 IP 地址不经过代理节点', value: settings.bypassLan, enabled: !isRunning, onChanged: (v) { settings.bypassLan = v; onChanged(); }),
        ]),
        const SizedBox(height: 16),
        _SettingsCard(title: 'Tailscale', children: <Widget>[
          _SettingSwitch(
            title: '启用 Tailscale Endpoint',
            subtitle: '由 sing-box Tailscale endpoint 创建 HongdaTail 系统接口；需要管理员权限',
            value: settings.tailscaleEnabled,
            enabled: !isRunning,
            onChanged: (v) { settings.tailscaleEnabled = v; onChanged(); },
          ),
          if (settings.tailscaleEnabled) ...<Widget>[
            _StringSetting(
              label: 'Auth Key',
              value: settings.tailscaleAuthKey,
              enabled: !isRunning,
              obscureText: true,
              hintText: 'tskey-auth-...（已登录过可留空）',
              onChanged: (v) { settings.tailscaleAuthKey = v; onChanged(); },
            ),
            _StringSetting(
              label: 'Hostname',
              value: settings.tailscaleHostname,
              enabled: !isRunning,
              hintText: 'hongda-starlink',
              onChanged: (v) { settings.tailscaleHostname = v; onChanged(); },
            ),
            _StringSetting(
              label: 'Control URL（可选）',
              value: settings.tailscaleControlUrl,
              enabled: !isRunning,
              hintText: '留空使用 Tailscale 官方控制面',
              onChanged: (v) { settings.tailscaleControlUrl = v; onChanged(); },
            ),
            _SettingSwitch(
              title: '接受 Tailnet 路由',
              subtitle: '接受其它节点发布的子网路由',
              value: settings.tailscaleAcceptRoutes,
              enabled: !isRunning,
              onChanged: (v) { settings.tailscaleAcceptRoutes = v; onChanged(); },
            ),
            _StringSetting(
              label: 'Exit Node（可选）',
              value: settings.tailscaleExitNode,
              enabled: !isRunning,
              hintText: '设备名或地址；留空不使用 Exit Node',
              onChanged: (v) { settings.tailscaleExitNode = v; onChanged(); },
            ),
            _SettingSwitch(
              title: 'Exit Node 时允许访问局域网',
              subtitle: '对应 exit_node_allow_lan_access',
              value: settings.tailscaleExitNodeAllowLanAccess,
              enabled: !isRunning,
              onChanged: (v) { settings.tailscaleExitNodeAllowLanAccess = v; onChanged(); },
            ),
          ],
        ]),
        const SizedBox(height: 16),
        _SettingsCard(title: '监听端口', children: <Widget>[
          _PortSetting(label: 'Mixed 代理端口', value: settings.mixedPort, enabled: !isRunning, onChanged: (v) { settings.mixedPort = v; onChanged(); }),
          _PortSetting(label: '本地控制 API 端口', value: settings.apiPort, enabled: !isRunning, onChanged: (v) { settings.apiPort = v; onChanged(); }),
        ]),
      ],
    );
  }
}

class _SystemProxyPage extends StatelessWidget {
  const _SystemProxyPage({required this.settings, required this.isRunning, required this.onChanged});
  final AppSettings settings;
  final bool isRunning;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) {
    return ListView(children: <Widget>[
      _SettingsCard(title: 'Windows 系统代理', children: <Widget>[
        _SettingSwitch(title: '连接后自动设置系统代理', subtitle: '将 Windows 当前用户代理指向 127.0.0.1:${settings.mixedPort}', value: settings.systemProxyEnabled, onChanged: (v) { settings.systemProxyEnabled = v; onChanged(); }),
        const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 16), child: Text('关闭连接时会主动清理本软件设置的代理状态，避免出现“代理残留导致无法联网”。', style: TextStyle(fontSize: 12, color: Color(0xFF667085)))),
      ]),
      const SizedBox(height: 16),
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Row(children: <Widget>[
        Icon(isRunning ? Icons.check_circle_rounded : Icons.info_outline_rounded, color: isRunning ? const Color(0xFF20A866) : const Color(0xFF7C8797)),
        const SizedBox(width: 10),
        Expanded(child: Text(isRunning ? '核心正在运行，系统代理设置可以即时切换。' : '当前未连接；设置将在下次连接时生效。')),
      ]))),
    ]);
  }
}

class _NetworkToolsPage extends StatefulWidget {
  const _NetworkToolsPage({required this.nodes, required this.onNodesChanged});
  final List<NodeProfile> nodes;
  final VoidCallback onNodesChanged;
  @override
  State<_NetworkToolsPage> createState() => _NetworkToolsPageState();
}

class _NetworkToolsPageState extends State<_NetworkToolsPage> {
  bool testing = false;
  String? publicIp;

  @override
  Widget build(BuildContext context) {
    return ListView(children: <Widget>[
      Row(children: <Widget>[
        Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const _SectionHeader(title: '节点 TCP 延迟'),
          const SizedBox(height: 8),
          const Text('测试到节点服务器端口的 TCP 建连时间，不伪造 ICMP 延迟。', style: TextStyle(color: Color(0xFF667085), fontSize: 12)),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: testing ? null : _testAll, icon: testing ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.speed_rounded), label: Text(testing ? '测试中…' : '测试全部节点')),
        ])))),
        const SizedBox(width: 16),
        Expanded(child: Card(child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const _SectionHeader(title: '公网地址'),
          const SizedBox(height: 8),
          Text(publicIp ?? '尚未检测', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          OutlinedButton.icon(onPressed: _checkPublicIp, icon: const Icon(Icons.public_rounded), label: const Text('检测当前出口')),
        ])))),
      ]),
      const SizedBox(height: 16),
      Card(child: widget.nodes.isEmpty ? const Padding(padding: EdgeInsets.all(30), child: _EmptyState(icon: Icons.network_check, title: '暂无节点', subtitle: '添加节点后可进行批量延迟测试。')) : ListView.separated(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), padding: const EdgeInsets.all(14), itemCount: widget.nodes.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (context, index) {
        final n = widget.nodes[index];
        return ListTile(title: Text(n.name), subtitle: Text('${n.server}:${n.port}'), trailing: Text(n.latencyMs == null ? '--' : '${n.latencyMs} ms', style: TextStyle(fontWeight: FontWeight.w700, color: n.latencyMs == null ? const Color(0xFF98A2B3) : _latencyColor(n.latencyMs!))));
      })),
    ]);
  }

  Future<void> _testAll() async {
    if (widget.nodes.isEmpty) return;
    setState(() => testing = true);
    for (final node in widget.nodes) {
      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(node.server, node.port, timeout: const Duration(seconds: 3));
        sw.stop();
        final elapsedUs = sw.elapsedMicroseconds;
        final elapsedMs = elapsedUs <= 0 ? 1 : (elapsedUs + 999) ~/ 1000;
        node.latencyMs = elapsedMs > 60000 ? 60000 : elapsedMs;
        socket.destroy();
      } catch (_) {
        node.latencyMs = null;
      }
      if (mounted) setState(() {});
    }
    widget.onNodesChanged();
    if (mounted) setState(() => testing = false);
  }

  Future<void> _checkPublicIp() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final request = await client.getUrl(Uri.parse('https://api.ipify.org'));
      final response = await request.close();
      final value = await response.transform(const Utf8Decoder()).join();
      if (mounted) setState(() => publicIp = value.trim());
    } catch (e) {
      if (mounted) setState(() => publicIp = '检测失败');
    } finally {
      client.close(force: true);
    }
  }
}

class _ConfigPage extends StatefulWidget {
  const _ConfigPage({
    required this.node,
    required this.settings,
    required this.nodes,
    required this.groups,
    required this.rules,
    required this.onChanged,
  });

  final NodeProfile? node;
  final AppSettings settings;
  final List<NodeProfile> nodes;
  final List<ProxyGroupProfile> groups;
  final List<RouteRuleProfile> rules;
  final VoidCallback onChanged;

  @override
  State<_ConfigPage> createState() => _ConfigPageState();
}

class _ConfigPageState extends State<_ConfigPage> {
  final editor = TextEditingController();
  ConfigImportResult? preview;
  String? parseError;

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: <Widget>[
          _RouteModeSelector(
            settings: widget.settings,
            enabled: true,
            onChanged: widget.onChanged,
          ),
          const SizedBox(height: 10),
          Card(
            margin: EdgeInsets.zero,
            child: const TabBar(
              tabs: <Widget>[
                Tab(icon: Icon(Icons.input_rounded, size: 17), text: '配置导入'),
                Tab(icon: Icon(Icons.hub_outlined, size: 17), text: '规则组'),
                Tab(icon: Icon(Icons.alt_route_rounded, size: 17), text: '路由规则'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: TabBarView(
              children: <Widget>[
                _buildImportTab(),
                _buildGroupsTab(),
                _buildRulesTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportTab() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: <Widget>[
            LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                const Text('Clash / Mihomo · sing-box · Base64 / 分享链接', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1D2939))),
                const SizedBox(height: 4),
                Text(
                  preview == null
                      ? '粘贴配置后先解析预览，确认节点、规则组和路由规则数量再导入。'
                      : '已识别 ${preview!.format} · ${preview!.nodes.length} 节点 · ${preview!.groups.length} 规则组 · ${preview!.rules.length} 路由规则',
                  style: TextStyle(fontSize: 10.5, color: parseError == null ? const Color(0xFF667085) : const Color(0xFFB42318)),
                ),
                if (parseError != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(parseError!, style: const TextStyle(fontSize: 10, color: Color(0xFFB42318)))),
              ]);
              final buttons = Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                OutlinedButton.icon(onPressed: _loadSelectedOutbound, icon: const Icon(Icons.code_rounded, size: 16), label: const Text('当前节点 JSON')),
                const SizedBox(width: 7),
                OutlinedButton.icon(onPressed: _previewImport, icon: const Icon(Icons.manage_search_rounded, size: 16), label: const Text('解析预览')),
                const SizedBox(width: 7),
                FilledButton.icon(onPressed: preview == null ? null : _applyImport, icon: const Icon(Icons.download_done_rounded, size: 16), label: const Text('全部导入')),
              ]);
              if (compact) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[info, const SizedBox(height: 10), SingleChildScrollView(scrollDirection: Axis.horizontal, child: buttons)]);
              return Row(children: <Widget>[Expanded(child: info), buttons]);
            }),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: editor,
                onChanged: (_) {
                  if (preview != null || parseError != null) setState(() { preview = null; parseError = null; });
                },
                expands: true,
                minLines: null,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11.5, height: 1.45),
                decoration: const InputDecoration(
                  hintText: 'proxies:\n  - name: ...\n\n或\n\n{ "outbounds": [...] }\n\n或 vless:// / vmess:// / trojan:// / hy2:// ...',
                  contentPadding: EdgeInsets.all(15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupsTab() {
    return Column(children: <Widget>[
      _ToolbarCard(child: Row(children: <Widget>[
        Expanded(child: Text('${widget.groups.length} 个规则组 · Selector / URLTest 可直接写入 sing-box 运行配置', style: const TextStyle(fontSize: 10.8, color: Color(0xFF667085)))),
        FilledButton.icon(onPressed: () => _editGroup(), icon: const Icon(Icons.add_rounded, size: 16), label: const Text('新建规则组')),
      ])),
      const SizedBox(height: 10),
      Expanded(child: Card(child: widget.groups.isEmpty
          ? const Center(child: _EmptyState(icon: Icons.hub_outlined, title: '暂无规则组', subtitle: '可以创建手动选择组或 URLTest 自动测速组。'))
          : ListView.separated(
              padding: const EdgeInsets.all(10),
              itemCount: widget.groups.length,
              separatorBuilder: (_, __) => const SizedBox(height: 7),
              itemBuilder: (context, index) {
                final group = widget.groups[index];
                return _ConfigListTile(
                  icon: group.type == 'urltest' ? Icons.speed_rounded : Icons.hub_outlined,
                  title: group.name,
                  subtitle: '${group.type == 'urltest' ? 'URLTest' : 'Selector'} · ${group.nodeIds.length} 节点${group.source == 'manual' ? '' : ' · ${group.source}'}',
                  enabled: group.enabled,
                  onToggle: (v) { setState(() => group.enabled = v); widget.onChanged(); },
                  onEdit: () => _editGroup(group),
                  onDelete: () => _deleteGroup(group),
                );
              },
            ))),
    ]);
  }

  Widget _buildRulesTab() {
    return Column(children: <Widget>[
      _ToolbarCard(child: Row(children: <Widget>[
        Expanded(child: Text('${widget.rules.length} 条路由规则 · 支持域名、后缀、关键词、CIDR、进程名和 TCP/UDP', style: const TextStyle(fontSize: 10.8, color: Color(0xFF667085)))),
        FilledButton.icon(onPressed: () => _editRule(), icon: const Icon(Icons.add_rounded, size: 16), label: const Text('新建规则')),
      ])),
      const SizedBox(height: 10),
      Expanded(child: Card(child: widget.rules.isEmpty
          ? const Center(child: _EmptyState(icon: Icons.alt_route_rounded, title: '暂无路由规则', subtitle: '规则将按列表顺序写入运行配置。'))
          : ReorderableListView.builder(
              padding: const EdgeInsets.all(10),
              itemCount: widget.rules.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final item = widget.rules.removeAt(oldIndex);
                  widget.rules.insert(newIndex, item);
                });
                widget.onChanged();
              },
              itemBuilder: (context, index) {
                final rule = widget.rules[index];
                return Padding(
                  key: ValueKey(rule.id),
                  padding: const EdgeInsets.only(bottom: 7),
                  child: _ConfigListTile(
                    icon: Icons.alt_route_rounded,
                    title: rule.name,
                    subtitle: '${_ruleSummary(rule)} → ${_outboundLabel(rule.outbound)}',
                    enabled: rule.enabled,
                    onToggle: (v) { setState(() => rule.enabled = v); widget.onChanged(); },
                    onEdit: () => _editRule(rule),
                    onDelete: () => _deleteRule(rule),
                    dragHandle: const Icon(Icons.drag_indicator_rounded, size: 18, color: Color(0xFF98A2B3)),
                  ),
                );
              },
            ))),
    ]);
  }

  void _loadSelectedOutbound() {
    final node = widget.node;
    if (node == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前没有选中节点')));
      return;
    }
    editor.text = prettyJson(<String, dynamic>{'outbounds': <Map<String, dynamic>>[<String, dynamic>{...node.outbound, 'tag': node.name}]});
    setState(() { preview = null; parseError = null; });
  }

  void _previewImport() {
    try {
      final value = ConfigImporter.parse(editor.text, source: 'manual-import');
      if (value.nodes.isEmpty && value.groups.isEmpty && value.rules.isEmpty) {
        setState(() { preview = null; parseError = '没有识别到可导入内容'; });
        return;
      }
      setState(() { preview = value; parseError = null; });
    } catch (e) {
      setState(() { preview = null; parseError = e.toString(); });
    }
  }

  void _applyImport() {
    final value = preview;
    if (value == null) return;
    final fingerprints = widget.nodes.map((e) => e.fingerprint).toSet();
    var addedNodes = 0;
    for (final node in value.nodes) {
      if (fingerprints.add(node.fingerprint)) {
        widget.nodes.add(node);
        addedNodes++;
      }
    }
    final groupIds = widget.groups.map((e) => e.id).toSet();
    for (final group in value.groups) {
      if (groupIds.add(group.id)) widget.groups.add(group);
    }
    final ruleIds = widget.rules.map((e) => e.id).toSet();
    for (final rule in value.rules) {
      if (ruleIds.add(rule.id)) widget.rules.add(rule);
    }
    widget.onChanged();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入完成：新增 $addedNodes 节点 · ${value.groups.length} 规则组 · ${value.rules.length} 路由规则')));
    setState(() => preview = null);
  }

  Future<void> _editGroup([ProxyGroupProfile? current]) async {
    final name = TextEditingController(text: current?.name ?? '自动选择');
    final url = TextEditingController(text: current?.testUrl ?? widget.settings.urlTestUrl);
    final interval = TextEditingController(text: (current?.intervalSeconds ?? widget.settings.urlTestIntervalSeconds).toString());
    final tolerance = TextEditingController(text: (current?.toleranceMs ?? widget.settings.urlTestToleranceMs).toString());
    var type = current?.type ?? 'urltest';
    final selectedIds = <String>{...?current?.nodeIds};
    String selectedNodeId = current?.selectedNodeId ?? '';
    final ok = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, setLocal) {
      return AlertDialog(
        title: Text(current == null ? '新建规则组' : '编辑规则组'),
        content: SizedBox(width: 650, height: 480, child: Column(children: <Widget>[
          Row(children: <Widget>[
            Expanded(child: TextField(controller: name, decoration: const InputDecoration(labelText: '规则组名称'))),
            const SizedBox(width: 10),
            SizedBox(width: 170, child: DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: '类型'), items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(value: 'selector', child: Text('手动选择 Selector')),
              DropdownMenuItem(value: 'urltest', child: Text('自动测速 URLTest')),
            ], onChanged: (v) { if (v != null) setLocal(() => type = v); })),
          ]),
          if (type == 'urltest') ...<Widget>[
            const SizedBox(height: 10),
            Row(children: <Widget>[
              Expanded(flex: 3, child: TextField(controller: url, decoration: const InputDecoration(labelText: '测速 URL'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: interval, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '间隔/秒'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: tolerance, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '容差/ms'))),
            ]),
          ],
          const SizedBox(height: 12),
          Align(alignment: Alignment.centerLeft, child: Text('成员节点（${selectedIds.length}/${widget.nodes.length}）', style: const TextStyle(fontWeight: FontWeight.w700))),
          const SizedBox(height: 7),
          Expanded(child: Card(margin: EdgeInsets.zero, child: ListView.builder(itemCount: widget.nodes.length, itemBuilder: (context, i) {
            final node = widget.nodes[i];
            final checked = selectedIds.contains(node.id);
            return CheckboxListTile(
              dense: true,
              value: checked,
              title: Text(node.name),
              subtitle: Text('${node.protocol.toUpperCase()} · ${node.server}:${node.port}', maxLines: 1, overflow: TextOverflow.ellipsis),
              secondary: type == 'selector' && checked ? Radio<String>(value: node.id, groupValue: selectedNodeId, onChanged: (v) => setLocal(() => selectedNodeId = v ?? '')) : null,
              onChanged: (v) => setLocal(() { if (v == true) { selectedIds.add(node.id); if (selectedNodeId.isEmpty) selectedNodeId = node.id; } else { selectedIds.remove(node.id); if (selectedNodeId == node.id) selectedNodeId = selectedIds.isEmpty ? '' : selectedIds.first; } }),
            );
          }))),
        ])),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: selectedIds.isEmpty ? null : () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      );
    }));
    if (ok == true) {
      final group = current ?? ProxyGroupProfile(id: 'group-${DateTime.now().microsecondsSinceEpoch}', name: name.text.trim().isEmpty ? '规则组' : name.text.trim());
      group.name = name.text.trim().isEmpty ? '规则组' : name.text.trim();
      group.type = type;
      group.nodeIds = selectedIds.toList();
      group.selectedNodeId = selectedNodeId;
      group.testUrl = url.text.trim().isEmpty ? widget.settings.urlTestUrl : url.text.trim();
      group.intervalSeconds = (int.tryParse(interval.text) ?? 180).clamp(10, 86400).toInt();
      group.toleranceMs = (int.tryParse(tolerance.text) ?? 50).clamp(0, 10000).toInt();
      if (current == null) widget.groups.add(group);
      widget.onChanged();
      setState(() {});
    }
    name.dispose(); url.dispose(); interval.dispose(); tolerance.dispose();
  }

  Future<void> _deleteGroup(ProxyGroupProfile group) async {
    final ok = await _confirm('删除规则组', '确定删除“${group.name}”？引用该组的路由规则会回退到默认代理。');
    if (!ok) return;
    setState(() => widget.groups.removeWhere((g) => g.id == group.id));
    for (final rule in widget.rules.where((r) => r.outbound == 'group:${group.id}')) rule.outbound = 'proxy';
    if (widget.settings.selectedGroupId == group.id) widget.settings.selectedGroupId = '';
    widget.onChanged();
  }

  Future<void> _editRule([RouteRuleProfile? current]) async {
    final name = TextEditingController(text: current?.name ?? '新规则');
    final domains = TextEditingController(text: current?.domains.join('\n') ?? '');
    final suffixes = TextEditingController(text: current?.domainSuffixes.join('\n') ?? '');
    final keywords = TextEditingController(text: current?.domainKeywords.join('\n') ?? '');
    final cidrs = TextEditingController(text: current?.ipCidrs.join('\n') ?? '');
    final processes = TextEditingController(text: current?.processNames.join('\n') ?? '');
    var network = current?.network ?? '';
    var outbound = current?.outbound ?? 'proxy';
    final validOutbounds = <String>{'proxy', 'auto', 'direct', 'block', ...widget.groups.map((g) => 'group:${g.id}'), ...widget.nodes.map((n) => 'node:${n.id}')};
    if (!validOutbounds.contains(outbound)) outbound = 'proxy';
    final ok = await showDialog<bool>(context: context, builder: (context) => StatefulBuilder(builder: (context, setLocal) => AlertDialog(
      title: Text(current == null ? '新建路由规则' : '编辑路由规则'),
      content: SizedBox(width: 680, child: SingleChildScrollView(child: Column(children: <Widget>[
        TextField(controller: name, decoration: const InputDecoration(labelText: '规则名称')),
        const SizedBox(height: 10),
        Row(children: <Widget>[
          Expanded(child: DropdownButtonFormField<String>(value: network, decoration: const InputDecoration(labelText: '网络'), items: const <DropdownMenuItem<String>>[
            DropdownMenuItem(value: '', child: Text('全部')),
            DropdownMenuItem(value: 'tcp', child: Text('TCP')),
            DropdownMenuItem(value: 'udp', child: Text('UDP')),
          ], onChanged: (v) => setLocal(() => network = v ?? ''))),
          const SizedBox(width: 10),
          Expanded(child: DropdownButtonFormField<String>(value: outbound, decoration: const InputDecoration(labelText: '出口'), items: <DropdownMenuItem<String>>[
            const DropdownMenuItem(value: 'proxy', child: Text('默认代理')),
            const DropdownMenuItem(value: 'auto', child: Text('自动 URLTest')),
            const DropdownMenuItem(value: 'direct', child: Text('直连')),
            const DropdownMenuItem(value: 'block', child: Text('阻止')),
            ...widget.groups.where((g) => g.enabled).map((g) => DropdownMenuItem(value: 'group:${g.id}', child: Text('组 · ${g.name}'))),
            ...widget.nodes.where((n) => n.enabled).map((n) => DropdownMenuItem(value: 'node:${n.id}', child: Text('节点 · ${n.name}'))),
          ], onChanged: (v) => setLocal(() => outbound = v ?? 'proxy'))),
        ]),
        const SizedBox(height: 10),
        _RuleEditorField(controller: domains, label: '精确域名', hint: 'example.com，每行一个'),
        _RuleEditorField(controller: suffixes, label: '域名后缀', hint: 'google.com，每行一个'),
        _RuleEditorField(controller: keywords, label: '域名关键词', hint: 'telegram，每行一个'),
        _RuleEditorField(controller: cidrs, label: 'IP / CIDR', hint: '1.1.1.0/24，每行一个'),
        _RuleEditorField(controller: processes, label: '进程名', hint: 'chrome.exe，每行一个'),
      ]))),
      actions: <Widget>[TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存'))],
    )));
    if (ok == true) {
      final rule = current ?? RouteRuleProfile(id: 'rule-${DateTime.now().microsecondsSinceEpoch}', name: name.text.trim().isEmpty ? '新规则' : name.text.trim());
      rule.name = name.text.trim().isEmpty ? '新规则' : name.text.trim();
      rule.domains = _lines(domains.text);
      rule.domainSuffixes = _lines(suffixes.text);
      rule.domainKeywords = _lines(keywords.text);
      rule.ipCidrs = _lines(cidrs.text);
      rule.processNames = _lines(processes.text);
      rule.network = network;
      rule.outbound = outbound;
      if (current == null) widget.rules.add(rule);
      widget.onChanged();
      setState(() {});
    }
    for (final c in <TextEditingController>[name, domains, suffixes, keywords, cidrs, processes]) c.dispose();
  }

  Future<void> _deleteRule(RouteRuleProfile rule) async {
    if (!await _confirm('删除路由规则', '确定删除“${rule.name}”？')) return;
    setState(() => widget.rules.removeWhere((r) => r.id == rule.id));
    widget.onChanged();
  }

  Future<bool> _confirm(String title, String body) async => (await showDialog<bool>(context: context, builder: (context) => AlertDialog(
    title: Text(title), content: Text(body), actions: <Widget>[TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定'))],
  ))) ?? false;

  List<String> _lines(String value) => value.split(RegExp(r'[\n,;]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();

  String _ruleSummary(RouteRuleProfile r) {
    if (r.name.toUpperCase().startsWith('FINAL')) return 'FINAL';
    final parts = <String>[];
    if (r.domains.isNotEmpty) parts.add('域名 ${r.domains.length}');
    if (r.domainSuffixes.isNotEmpty) parts.add('后缀 ${r.domainSuffixes.length}');
    if (r.domainKeywords.isNotEmpty) parts.add('关键词 ${r.domainKeywords.length}');
    if (r.ipCidrs.isNotEmpty) parts.add('CIDR ${r.ipCidrs.length}');
    if (r.processNames.isNotEmpty) parts.add('进程 ${r.processNames.length}');
    if (r.network.isNotEmpty) parts.add(r.network.toUpperCase());
    return parts.isEmpty ? '无匹配条件' : parts.join(' · ');
  }

  String _outboundLabel(String value) {
    if (value == 'proxy') return '代理';
    if (value == 'auto') return 'URLTest';
    if (value == 'direct') return '直连';
    if (value == 'block') return '阻止';
    if (value.startsWith('group:')) {
      final id = value.substring(6);
      for (final g in widget.groups) if (g.id == id) return g.name;
    }
    if (value.startsWith('node:')) {
      final id = value.substring(5);
      for (final n in widget.nodes) if (n.id == id) return n.name;
    }
    return '代理';
  }
}

class _ConfigListTile extends StatelessWidget {
  const _ConfigListTile({required this.icon, required this.title, required this.subtitle, required this.enabled, required this.onToggle, required this.onEdit, required this.onDelete, this.dragHandle});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Widget? dragHandle;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(color: const Color(0xFFFCFDFF), border: Border.all(color: const Color(0xFFE7ECF3)), borderRadius: BorderRadius.circular(10)),
    child: Row(children: <Widget>[
      if (dragHandle != null) ...<Widget>[dragHandle!, const SizedBox(width: 7)],
      Container(width: 34, height: 34, decoration: BoxDecoration(color: const Color(0xFFEEF5FF), borderRadius: BorderRadius.circular(9)), child: Icon(icon, size: 18, color: const Color(0xFF1677FF))),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color(0xFF1D2939))),
        const SizedBox(height: 3),
        Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.5, color: Color(0xFF667085))),
      ])),
      Transform.scale(scale: .76, child: Switch(value: enabled, onChanged: onToggle)),
      IconButton(tooltip: '编辑', onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 17)),
      IconButton(tooltip: '删除', onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded, size: 17, color: Color(0xFF9B5B64))),
    ]),
  );
}

class _RuleEditorField extends StatelessWidget {
  const _RuleEditorField({required this.controller, required this.label, required this.hint});
  final TextEditingController controller;
  final String label;
  final String hint;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: TextField(controller: controller, minLines: 1, maxLines: 3, decoration: InputDecoration(labelText: label, hintText: hint)),
  );
}

class _LogsPage extends StatelessWidget {
  const _LogsPage({required this.controller, required this.storage});
  final SingBoxController controller;
  final AppStorage storage;
  @override
  Widget build(BuildContext context) {
    return Column(children: <Widget>[
      Row(children: <Widget>[
        Expanded(child: Text('实时日志 · ${controller.logs.length} 行', style: const TextStyle(color: Color(0xFF667085)))),
        OutlinedButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: controller.logs.join('\n'))), icon: const Icon(Icons.copy_rounded), label: const Text('复制日志')),
        const SizedBox(width: 8),
        OutlinedButton.icon(onPressed: () => WindowsIntegration.openFolder(storage.baseDir.path), icon: const Icon(Icons.folder_open_rounded), label: const Text('打开数据目录')),
      ]),
      const SizedBox(height: 12),
      Expanded(child: Card(child: controller.logs.isEmpty ? const Center(child: _EmptyState(icon: Icons.receipt_long_outlined, title: '暂无日志', subtitle: '启动连接后，这里显示 sing-box 标准输出和错误信息。')) : ListView.builder(reverse: true, padding: const EdgeInsets.all(14), itemCount: controller.logs.length, itemBuilder: (context, index) {
        final text = controller.logs[controller.logs.length - 1 - index];
        final error = text.contains('[ERR]');
        return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: SelectableText(text, style: TextStyle(fontFamily: 'Consolas', fontSize: 11, height: 1.35, color: error ? const Color(0xFFB42318) : const Color(0xFF344054))));
      }))),
    ]);
  }
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.settings, required this.storage, required this.coreManager, required this.coreVersion, required this.isAdmin, required this.onChanged, required this.onCoreChanged});
  final AppSettings settings;
  final AppStorage storage;
  final CoreManager coreManager;
  final String? coreVersion;
  final bool isAdmin;
  final VoidCallback onChanged;
  final VoidCallback onCoreChanged;
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return ListView(children: <Widget>[
      _SettingsCard(title: '应用', children: <Widget>[
        _SettingSwitch(title: '开机启动', subtitle: '登录 Windows 后自动启动鸿达星轨智连', value: widget.settings.startWithWindows, onChanged: (v) { widget.settings.startWithWindows = v; widget.onChanged(); }),
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 14), child: DropdownButtonFormField<String>(value: widget.settings.logLevel, decoration: const InputDecoration(labelText: '日志等级'), items: const <DropdownMenuItem<String>>[
          DropdownMenuItem(value: 'debug', child: Text('Debug')),
          DropdownMenuItem(value: 'info', child: Text('Info')),
          DropdownMenuItem(value: 'warn', child: Text('Warn')),
          DropdownMenuItem(value: 'error', child: Text('Error')),
        ], onChanged: (v) { if (v != null) { widget.settings.logLevel = v; widget.onChanged(); } })),
      ]),
      const SizedBox(height: 16),
      _SettingsCard(title: '本地数据', children: <Widget>[
        ListTile(
          leading: const Icon(Icons.folder_copy_outlined, color: Color(0xFF1677FF)),
          title: const Text('应用数据目录', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: SelectableText(
            widget.storage.baseDir.path,
            style: const TextStyle(fontSize: 10.5, color: Color(0xFF667085)),
          ),
          trailing: OutlinedButton.icon(
            onPressed: () => WindowsIntegration.openFolder(widget.storage.baseDir.path),
            icon: const Icon(Icons.folder_open_rounded, size: 15),
            label: const Text('打开目录'),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Text(
            '节点保存在 nodes.json，订阅保存在 subscriptions.json。删除源码目录或 build 目录不会清掉这些用户数据。',
            style: TextStyle(fontSize: 10.5, color: Color(0xFF667085), height: 1.45),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      _SettingsCard(title: 'HongdaService · sing-box', children: <Widget>[
        ListTile(
          leading: const Icon(Icons.memory_rounded, color: Color(0xFF0B72E7)),
          title: Text(widget.coreVersion ?? '服务未构建/缺失', style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(widget.coreVersion == null
              ? '未检测到 HongdaService.exe。V1.6 正常发布包应自带约 55 MB 的自包含 Service，请检查 runtime/service 是否完整。'
              : 'Windows x64 · HongdaService 运行时已检测到'),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            '界面能力：VLESS · VMess · Trojan · Shadowsocks · Hysteria2 · Reality · URLTest · Clash API · TUN / DNS',
            style: TextStyle(fontSize: 11, color: Color(0xFF667085)),
          ),
        ),
      ]),
      const SizedBox(height: 16),
      Card(child: Padding(padding: const EdgeInsets.all(18), child: Row(children: <Widget>[
        Icon(widget.isAdmin ? Icons.verified_user_rounded : Icons.shield_outlined, color: widget.isAdmin ? const Color(0xFF20A866) : const Color(0xFF667085)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(widget.isAdmin ? '当前为管理员权限' : '当前为标准权限', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          const Text('只有使用 TUN 时才需要管理员权限；普通系统代理模式不强制 UAC。', style: TextStyle(fontSize: 12, color: Color(0xFF667085))),
        ])),
      ]))),
    ]);
  }

}

class _AboutPage extends StatelessWidget {
  const _AboutPage({required this.coreVersion});
  final String? coreVersion;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
              ClipRRect(borderRadius: BorderRadius.circular(20), child: Image.asset('assets/app_icon.png', width: 76, height: 76, fit: BoxFit.cover)),
              const SizedBox(height: 16),
              const Text('鸿达星轨智连', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
              const SizedBox(height: 5),
              const Text('V1.6.3 · Windows x64', style: TextStyle(color: Color(0xFF667085))),
              const SizedBox(height: 22),
              Text(
                coreVersion == null
                    ? '鸿达星轨智连 Windows 桌面网络连接工具。当前源码包已包含 HongdaService.exe，并内嵌 sing-box 1.13.18 核心。'
                    : '鸿达星轨智连 Windows 桌面网络连接工具。内置 HongdaService 与 sing-box 核心，支持系统代理、TUN 与智能分流。',
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.6, color: Color(0xFF475467)),
              ),
              const SizedBox(height: 22),
              const Divider(),
              const SizedBox(height: 12),
              const _AboutRow(label: '开发者', value: '李鸿达'),
              const _AboutRow(label: '邮箱', value: 'li519582271@gmail.com'),
            ]),
          ),
        ),
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: <Widget>[SizedBox(width: 120, child: Text(label, style: const TextStyle(color: Color(0xFF667085)))), Expanded(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700)))]));
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: <Widget>[
                Container(width: 3, height: 16, decoration: BoxDecoration(color: const Color(0xFF1677FF), borderRadius: BorderRadius.circular(2))),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF101828))),
              ]),
              const SizedBox(height: 9),
              for (var i = 0; i < children.length; i++) ...<Widget>[
                children[i],
                if (i != children.length - 1) const Divider(),
              ],
            ],
          ),
        ),
      );
}

class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({required this.title, required this.subtitle, required this.value, required this.onChanged, this.enabled = true});
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: enabled ? 1 : .55,
        child: InkWell(
          onTap: enabled ? () => onChanged(!value) : null,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Row(children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(title, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF1D2939))),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(fontSize: 9.5, height: 1.35, color: Color(0xFF7B8798))),
                ]),
              ),
              const SizedBox(width: 12),
              IgnorePointer(child: Transform.scale(scale: .82, child: Switch(value: value, onChanged: enabled ? (_) {} : null))),
            ]),
          ),
        ),
      );
}

class _StringSetting extends StatefulWidget {
  const _StringSetting({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.hintText,
    this.obscureText = false,
  });

  final String label;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  final String? hintText;
  final bool obscureText;

  @override
  State<_StringSetting> createState() => _StringSettingState();
}

class _StringSettingState extends State<_StringSetting> {
  late final TextEditingController controller;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _StringSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && controller.text != widget.value) {
      controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: TextField(
          enabled: widget.enabled,
          controller: controller,
          obscureText: widget.obscureText,
          decoration: InputDecoration(labelText: widget.label, hintText: widget.hintText),
          onChanged: widget.onChanged,
        ),
      );
}

class _PortSetting extends StatefulWidget {
  const _PortSetting({required this.label, required this.value, required this.enabled, required this.onChanged});
  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;
  @override
  State<_PortSetting> createState() => _PortSettingState();
}

class _PortSettingState extends State<_PortSetting> {
  late final TextEditingController controller;
  @override
  void initState() { super.initState(); controller = TextEditingController(text: widget.value.toString()); }
  @override
  void didUpdateWidget(covariant _PortSetting oldWidget) { super.didUpdateWidget(oldWidget); if (oldWidget.value != widget.value && controller.text != widget.value.toString()) controller.text = widget.value.toString(); }
  @override
  void dispose() { controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 10), child: TextField(enabled: widget.enabled, controller: controller, keyboardType: TextInputType.number, inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(labelText: widget.label), onSubmitted: (value) { final parsed = int.tryParse(value); if (parsed != null && parsed > 0 && parsed < 65536) widget.onChanged(parsed); }));
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.status,
    required this.coreVersion,
    required this.selectedNode,
    required this.activeConnections,
    required this.settings,
    required this.uploadSpeed,
    required this.downloadSpeed,
  });

  final CoreStatus status;
  final String? coreVersion;
  final NodeProfile? selectedNode;
  final int activeConnections;
  final AppSettings settings;
  final double uploadSpeed;
  final double downloadSpeed;

  @override
  Widget build(BuildContext context) {
    final connected = status == CoreStatus.running;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: const BoxDecoration(
        color: Color(0xFFFBFCFE),
        border: Border(top: BorderSide(color: Color(0xFFE1E7EF))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1040;
          return Row(children: <Widget>[
            _BottomStatusItem(icon: connected ? Icons.hub_rounded : Icons.hub_outlined, text: '连接类型：${selectedNode?.protocol.toUpperCase() ?? '--'}'),
            if (!compact) ...<Widget>[
              const SizedBox(width: 24),
              _BottomStatusItem(icon: Icons.cloud_outlined, text: '代理模式：${_routeModeText(settings.routeMode)}'),
              const SizedBox(width: 24),
              _BottomStatusItem(icon: Icons.shield_outlined, text: '系统代理：${settings.systemProxyEnabled ? '已启用' : '未启用'}'),
              const SizedBox(width: 24),
              _BottomStatusItem(icon: Icons.security_rounded, text: 'TUN 模式：${settings.tunEnabled ? '已启用' : '未启用'}'),
            ],
            const Spacer(),
            _BottomStatusItem(icon: Icons.north_rounded, text: _formatSpeed(uploadSpeed)),
            const SizedBox(width: 18),
            _BottomStatusItem(icon: Icons.south_rounded, text: _formatSpeed(downloadSpeed)),
            if (!compact) ...<Widget>[
              const SizedBox(width: 22),
              _BottomStatusItem(icon: Icons.account_tree_outlined, text: '$activeConnections 个连接'),
              const SizedBox(width: 22),
              _BottomStatusItem(icon: Icons.memory_rounded, text: coreVersion == null ? 'Core 缺失' : 'Core Ready'),
            ],
          ]);
        },
      ),
    );
  }
}

class _BottomStatusItem extends StatelessWidget {
  const _BottomStatusItem({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
        Icon(icon, size: 13, color: const Color(0xFF344054)),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(fontSize: 9.5, color: Color(0xFF475467), fontWeight: FontWeight.w500)),
      ]);
}

String _routeModeText(String mode) {
  switch (mode) {
    case 'global': return '全局代理';
    case 'direct': return '全部直连';
    case 'auto': return '自动选择';
    case 'group': return '规则组';
    default: return '智能分流';
  }
}

List<String> _trafficTimeLabels(DateTime now) {
  return List<String>.generate(5, (index) {
    final value = now.subtract(Duration(minutes: 4 - index));
    return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  });
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.actionText, this.onAction});
  final String title;
  final String? actionText;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Row(children: <Widget>[
    Expanded(child: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF344054)))),
    if (actionText != null) TextButton(onPressed: onAction, style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), minimumSize: Size.zero), child: Text(actionText!, style: const TextStyle(fontSize: 10.5))),
  ]);
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
    Icon(icon, size: 42, color: const Color(0xFFB4BECA)),
    const SizedBox(height: 10),
    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
    const SizedBox(height: 5),
    Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Color(0xFF8993A2), height: 1.5)),
  ]));
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, required this.color, required this.background});
  final String text;
  final Color color;
  final Color background;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(20)), child: Text(text, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700)));
}

String _formatSpeed(double bytes) {
  if (bytes < 1024) return '${bytes.toStringAsFixed(0)} B/s';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB/s';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB/s';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB/s';
}

String _formatDuration(Duration value) {
  final h = value.inHours.toString().padLeft(2, '0');
  final m = (value.inMinutes % 60).toString().padLeft(2, '0');
  final s = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String _dateTime(DateTime value) => '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _protocolGlyph(String protocol) {
  switch (protocol.toLowerCase()) {
    case 'vless': return 'VL';
    case 'vmess': return 'VM';
    case 'trojan': return 'TR';
    case 'hysteria2': return 'H2';
    case 'shadowsocks': return 'SS';
    case 'tuic': return 'TU';
    default: return protocol.isEmpty ? '?' : protocol.substring(0, protocol.length < 2 ? protocol.length : 2).toUpperCase();
  }
}

Color _latencyColor(int value) {
  if (value < 100) return const Color(0xFF18A05E);
  if (value < 250) return const Color(0xFFE69A17);
  return const Color(0xFFD44444);
}

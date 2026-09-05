import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_runtime.dart';
import 'app.dart' show AppBootstrap;
import 'models.dart';
import 'node_parser.dart';
import 'storage.dart';
import 'subscription_service.dart';

const _blue = Color(0xFF176BFF);
const _ink = Color(0xFF14213D);
const _muted = Color(0xFF7B89A6);
const _canvas = Color(0xFFF7FAFF);

class HongdaStarlinkAndroidApp extends StatelessWidget {
  const HongdaStarlinkAndroidApp({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _blue,
      brightness: Brightness.light,
      surface: Colors.white,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '鸿达星轨智连',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: _canvas,
        fontFamilyFallback: const <String>[
          'Noto Sans CJK SC',
          'Noto Sans SC',
          'Microsoft YaHei',
          'sans-serif',
        ],
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE8EEF8)),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: const WidgetStatePropertyAll(Colors.white),
          trackColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? _blue : const Color(0xFFD8E1EF),
          ),
          trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: _blue,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFFF6F9FE),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE8EEF8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: _blue, width: 1.3),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF18243D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      home: AndroidMainShell(bootstrap: bootstrap),
    );
  }
}

class AndroidMainShell extends StatefulWidget {
  const AndroidMainShell({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  State<AndroidMainShell> createState() => _AndroidMainShellState();
}

class _AndroidMainShellState extends State<AndroidMainShell> {
  late final AppStorage storage;
  late final AppSettings settings;
  late final List<NodeProfile> nodes;
  late final List<SubscriptionProfile> subscriptions;
  late final List<ProxyGroupProfile> groups;
  late final List<RouteRuleProfile> rules;
  late final TrafficStats trafficStats;
  late final AndroidRuntimeController controller;

  final List<double> uploadHistory = List<double>.filled(36, 0);
  final List<double> downloadHistory = List<double>.filled(36, 0);
  Timer? historyTimer;
  int tabIndex = 0;
  bool updatingSubscriptions = false;

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
    controller = AndroidRuntimeController(storage: storage, trafficStats: trafficStats)
      ..addListener(_onRuntimeChanged);
    unawaited(controller.initialize());
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
    controller.removeListener(_onRuntimeChanged);
    controller.dispose();
    super.dispose();
  }

  void _onRuntimeChanged() {
    if (mounted) setState(() {});
  }

  NodeProfile? get selectedNode {
    if (nodes.isEmpty) return null;
    for (final node in nodes) {
      if (node.id == settings.selectedNodeId && node.enabled) return node;
    }
    for (final node in nodes) {
      if (node.enabled) return node;
    }
    return null;
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

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleConnection() async {
    if (controller.isRunning || controller.status == AndroidConnectionStatus.preparing) {
      await controller.stop();
      return;
    }
    final node = selectedNode;
    if (node == null) {
      _toast('请先添加并选择一个节点');
      setState(() => tabIndex = 1);
      return;
    }
    settings.selectedNodeId = node.id;
    settings.tunEnabled = true;
    await storage.saveSettings(settings);
    try {
      await controller.start(
        node: node,
        settings: settings,
        nodes: nodes,
        groups: groups,
        rules: rules,
      );
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Android 核心未就绪'),
          content: Text(controller.lastError ?? e.toString()),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了')),
          ],
        ),
      );
    }
  }

  Future<void> _selectNode(NodeProfile node) async {
    if (!node.enabled) {
      _toast('该节点已禁用，无法切换');
      return;
    }
    if (settings.selectedNodeId == node.id) return;
    final previousId = settings.selectedNodeId;

    if (!controller.isRunning) {
      setState(() => settings.selectedNodeId = node.id);
      await storage.saveSettings(settings);
      _toast('已切换：${node.name}');
      return;
    }

    try {
      await controller.selectNodeRuntime(node, settings);
      settings.selectedNodeId = node.id;
      await storage.saveSettings(settings);
      if (mounted) setState(() {});
      _toast('已切换节点：${node.name}');
    } catch (_) {
      _toast('正在重载到 ${node.name}…');
      try {
        await controller.stop();
        settings.selectedNodeId = node.id;
        await storage.saveSettings(settings);
        await controller.start(
          node: node,
          settings: settings,
          nodes: nodes,
          groups: groups,
          rules: rules,
        );
        if (mounted) setState(() {});
        _toast('已切换节点：${node.name}');
      } catch (e) {
        settings.selectedNodeId = previousId;
        await storage.saveSettings(settings);
        if (mounted) setState(() {});
        _toast('切换节点失败：${e.toString().replaceFirst('Bad state: ', '')}');
      }
    }
  }

  Future<void> _toggleFavorite(NodeProfile node) async {
    setState(() => node.favorite = !node.favorite);
    await storage.saveNodes(nodes);
  }

  Future<void> _testNode(NodeProfile node) async {
    await controller.testNode(node, settings);
    await storage.saveNodes(nodes);
    if (!mounted) return;
    if (node.latencyMs != null) {
      _toast('${node.name} · ${node.latencyMs} ms');
    } else {
      _toast('${node.name} · ${node.testError ?? '测试失败'}');
    }
  }

  Future<void> _testAllNodes() async {
    final targets = nodes.where((node) => node.enabled).toList();
    if (targets.isEmpty) {
      _toast('没有可测试节点');
      return;
    }
    for (final node in targets) {
      await controller.testNode(node, settings);
    }
    await storage.saveNodes(nodes);
    _toast('节点延迟测试完成');
  }

  Future<void> _autoSelect() async {
    final targets = nodes.where((node) => node.enabled).toList();
    if (targets.isEmpty) {
      _toast('没有可用节点');
      return;
    }
    for (final node in targets) {
      await controller.testNode(node, settings);
    }
    final available = targets.where((node) => node.latencyMs != null).toList()
      ..sort((a, b) => a.latencyMs!.compareTo(b.latencyMs!));
    await storage.saveNodes(nodes);
    if (available.isEmpty) {
      _toast('没有检测到可连接节点');
      return;
    }
    await _selectNode(available.first);
  }

  Future<void> _updateSubscriptions() async {
    if (updatingSubscriptions) return;
    if (subscriptions.isEmpty) {
      _toast('当前没有订阅');
      setState(() => tabIndex = 2);
      return;
    }
    setState(() => updatingSubscriptions = true);
    var success = 0;
    try {
      for (final sub in subscriptions) {
        try {
          final result = await SubscriptionService.fetch(sub);
          final oldByFingerprint = <String, NodeProfile>{
            for (final n in nodes.where((n) => n.source == sub.id)) n.fingerprint: n,
          };
          nodes.removeWhere((n) => n.source == sub.id);
          groups.removeWhere((g) => g.source == sub.id);
          rules.removeWhere((r) => r.source == sub.id);
          for (final node in result.imported.nodes) {
            final old = oldByFingerprint[node.fingerprint];
            if (old != null) {
              node.favorite = old.favorite;
              node.latencyMs = old.latencyMs;
              node.lastLatencyTest = old.lastLatencyTest;
            }
            nodes.add(node);
          }
          groups.addAll(result.imported.groups);
          rules.addAll(result.imported.rules);
          sub
            ..nodeCount = result.imported.nodes.length
            ..format = result.imported.format
            ..lastUpdated = DateTime.now()
            ..lastError = null
            ..uploadBytes = result.uploadBytes
            ..downloadBytes = result.downloadBytes
            ..totalBytes = result.totalBytes
            ..expiresAt = result.expiresAt;
          success++;
        } catch (e) {
          sub.lastError = e.toString().replaceFirst('Exception: ', '');
        }
      }
      if (settings.selectedNodeId.isEmpty || !nodes.any((n) => n.id == settings.selectedNodeId)) {
        settings.selectedNodeId = nodes.isEmpty ? '' : nodes.first.id;
      }
      await _saveAll();
      _toast('订阅更新完成：$success/${subscriptions.length}');
    } finally {
      if (mounted) setState(() => updatingSubscriptions = false);
    }
  }

  Future<void> _addManualNodes() async {
    final textController = TextEditingController();
    final value = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('添加节点', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 6),
            const Text('支持 VLESS / VMess / Trojan / Hysteria2 / Shadowsocks / SOCKS。', style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(height: 14),
            TextField(
              controller: textController,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(hintText: '每行粘贴一个节点链接，或粘贴 Base64 订阅内容'),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, textController.text),
                child: const Text('导入节点'),
              ),
            ),
          ],
        ),
      ),
    );
    textController.dispose();
    if (value == null || value.trim().isEmpty) return;
    final imported = NodeParser.parseMany(value, source: 'manual');
    if (imported.isEmpty) {
      _toast('没有识别到支持的节点');
      return;
    }
    setState(() {
      nodes.addAll(imported);
      settings.selectedNodeId = settings.selectedNodeId.isEmpty ? imported.first.id : settings.selectedNodeId;
    });
    await _saveAll();
    _toast('已导入 ${imported.length} 个节点');
  }

  Future<void> _addSubscription() async {
    final nameController = TextEditingController(text: '我的订阅');
    final urlController = TextEditingController();
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 18, 20, MediaQuery.viewInsetsOf(context).bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('添加订阅', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 14),
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '订阅名称')),
            const SizedBox(height: 10),
            TextField(controller: urlController, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: '订阅 URL')),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存并更新')),
            ),
          ],
        ),
      ),
    );
    if (result != true) {
      nameController.dispose();
      urlController.dispose();
      return;
    }
    final url = urlController.text.trim();
    final name = nameController.text.trim().isEmpty ? '订阅' : nameController.text.trim();
    nameController.dispose();
    urlController.dispose();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _toast('请输入 http:// 或 https:// 订阅地址');
      return;
    }
    setState(() {
      subscriptions.add(SubscriptionProfile(
        id: 'sub-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        url: url,
        userAgent: 'HongdaStarlink/1.6.4 Android',
      ));
    });
    await storage.saveSubscriptions(subscriptions);
    await _updateSubscriptions();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        body: IndexedStack(
          index: tabIndex,
          children: <Widget>[
            _AndroidHomePage(
              controller: controller,
              settings: settings,
              nodes: nodes,
              subscriptions: subscriptions,
              selectedNode: selectedNode,
              uploadHistory: uploadHistory,
              downloadHistory: downloadHistory,
              updatingSubscriptions: updatingSubscriptions,
              onToggleConnection: _toggleConnection,
              onChooseNode: () => setState(() => tabIndex = 1),
              onUpdateSubscriptions: _updateSubscriptions,
              onOpenSubscriptions: () => setState(() => tabIndex = 2),
              onOpenAllNodes: () => setState(() => tabIndex = 1),
              onSelectNode: _selectNode,
              onToggleFavorite: _toggleFavorite,
              onTunChanged: (value) async {
                setState(() => settings.tunEnabled = value);
                await storage.saveSettings(settings);
              },
              onDnsChanged: (value) async {
                setState(() => settings.dnsMode = value ? 'doh' : 'local');
                await storage.saveSettings(settings);
              },
              onSystemProxyChanged: (value) async {
                setState(() => settings.systemProxyEnabled = value);
                await storage.saveSettings(settings);
              },
              onAutoChanged: (value) async {
                setState(() => settings.routeMode = value ? 'auto' : 'rule');
                await storage.saveSettings(settings);
                if (value) unawaited(_autoSelect());
              },
            ),
            _AndroidNodesPage(
              nodes: nodes,
              selectedNode: selectedNode,
              testingIds: controller.testingNodeIds,
              onSelect: _selectNode,
              onFavorite: _toggleFavorite,
              onTest: _testNode,
              onTestAll: _testAllNodes,
              onAdd: _addManualNodes,
            ),
            _AndroidSubscriptionsPage(
              subscriptions: subscriptions,
              updating: updatingSubscriptions,
              onUpdateAll: _updateSubscriptions,
              onAdd: _addSubscription,
              onDelete: (sub) async {
                setState(() {
                  subscriptions.remove(sub);
                  nodes.removeWhere((n) => n.source == sub.id);
                  groups.removeWhere((g) => g.source == sub.id);
                  rules.removeWhere((r) => r.source == sub.id);
                  if (!nodes.any((n) => n.id == settings.selectedNodeId)) {
                    settings.selectedNodeId = nodes.isEmpty ? '' : nodes.first.id;
                  }
                });
                await _saveAll();
              },
            ),
            _AndroidToolsPage(
              settings: settings,
              controller: controller,
              onChanged: () async {
                setState(() {});
                await storage.saveSettings(settings);
              },
              onTestAll: _testAllNodes,
              onAutoSelect: _autoSelect,
            ),
            _AndroidSettingsPage(
              settings: settings,
              coreAvailable: controller.coreAvailable,
              logs: controller.logs,
              onChanged: () async {
                setState(() {});
                await storage.saveSettings(settings);
              },
            ),
          ],
        ),
        bottomNavigationBar: _BottomNavigation(
          index: tabIndex,
          onChanged: (index) => setState(() => tabIndex = index),
        ),
      ),
    );
  }
}

class _AndroidHomePage extends StatelessWidget {
  const _AndroidHomePage({
    required this.controller,
    required this.settings,
    required this.nodes,
    required this.subscriptions,
    required this.selectedNode,
    required this.uploadHistory,
    required this.downloadHistory,
    required this.updatingSubscriptions,
    required this.onToggleConnection,
    required this.onChooseNode,
    required this.onUpdateSubscriptions,
    required this.onOpenSubscriptions,
    required this.onOpenAllNodes,
    required this.onSelectNode,
    required this.onToggleFavorite,
    required this.onTunChanged,
    required this.onDnsChanged,
    required this.onSystemProxyChanged,
    required this.onAutoChanged,
  });

  final AndroidRuntimeController controller;
  final AppSettings settings;
  final List<NodeProfile> nodes;
  final List<SubscriptionProfile> subscriptions;
  final NodeProfile? selectedNode;
  final List<double> uploadHistory;
  final List<double> downloadHistory;
  final bool updatingSubscriptions;
  final VoidCallback onToggleConnection;
  final VoidCallback onChooseNode;
  final VoidCallback onUpdateSubscriptions;
  final VoidCallback onOpenSubscriptions;
  final VoidCallback onOpenAllNodes;
  final ValueChanged<NodeProfile> onSelectNode;
  final ValueChanged<NodeProfile> onToggleFavorite;
  final ValueChanged<bool> onTunChanged;
  final ValueChanged<bool> onDnsChanged;
  final ValueChanged<bool> onSystemProxyChanged;
  final ValueChanged<bool> onAutoChanged;

  @override
  Widget build(BuildContext context) {
    final recent = <NodeProfile>[];
    if (selectedNode != null) recent.add(selectedNode!);
    for (final node in nodes) {
      if (recent.length >= 3) break;
      if (!recent.any((n) => n.id == node.id)) recent.add(node);
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFFF8FBFF), Color(0xFFF5F8FF)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const _HomeHeader(),
              const SizedBox(height: 14),
              _ConnectionHero(
                controller: controller,
                node: selectedNode,
                onToggle: onToggleConnection,
                onChooseNode: onChooseNode,
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(child: _MetricCard(label: '延迟', value: selectedNode?.latencyMs?.toString() ?? '--', unit: 'ms', icon: Icons.graphic_eq_rounded, accent: const Color(0xFF2AB67D))),
                  const SizedBox(width: 8),
                  Expanded(child: _MetricCard(label: '下载', value: _speedValue(controller.downloadBytesPerSecond), unit: _speedUnit(controller.downloadBytesPerSecond), icon: Icons.arrow_downward_rounded, accent: const Color(0xFF1E73F0))),
                  const SizedBox(width: 8),
                  Expanded(child: _MetricCard(label: '上传', value: _speedValue(controller.uploadBytesPerSecond), unit: _speedUnit(controller.uploadBytesPerSecond), icon: Icons.arrow_upward_rounded, accent: const Color(0xFF8A58F4))),
                  const SizedBox(width: 8),
                  Expanded(child: _MetricCard(label: '总流量', value: _trafficValue(controller.totalTrafficBytes), unit: _trafficUnit(controller.totalTrafficBytes), icon: Icons.pie_chart_rounded, accent: const Color(0xFF1F6FF2))),
                ],
              ),
              const SizedBox(height: 10),
              _TrafficCard(download: downloadHistory, upload: uploadHistory),
              const SizedBox(height: 16),
              const Text('快捷设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(child: _QuickToggle(icon: Icons.view_in_ar_rounded, label: 'TUN', value: settings.tunEnabled, iconColor: const Color(0xFF3182F6), onChanged: onTunChanged)),
                  const SizedBox(width: 8),
                  Expanded(child: _QuickToggle(icon: Icons.verified_user_outlined, label: 'DNS', value: settings.dnsMode == 'doh', iconColor: const Color(0xFF27B77C), onChanged: onDnsChanged)),
                  const SizedBox(width: 8),
                  Expanded(child: _QuickToggle(icon: Icons.language_rounded, label: '系统代理', value: settings.systemProxyEnabled, iconColor: const Color(0xFF8C5CF5), onChanged: onSystemProxyChanged)),
                  const SizedBox(width: 8),
                  Expanded(child: _QuickToggle(icon: Icons.auto_awesome_rounded, label: '自动选择', value: settings.routeMode == 'auto', iconColor: const Color(0xFFFF981F), onChanged: onAutoChanged)),
                ],
              ),
              const SizedBox(height: 12),
              _SubscriptionSummaryCard(
                subscriptions: subscriptions,
                updating: updatingSubscriptions,
                onTap: onOpenSubscriptions,
                onUpdate: onUpdateSubscriptions,
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  const Expanded(child: Text('近期节点', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink))),
                  TextButton.icon(
                    onPressed: onOpenAllNodes,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const Text('更多'),
                    style: TextButton.styleFrom(foregroundColor: _muted, padding: EdgeInsets.zero),
                  ),
                ],
              ),
              _RecentNodeCard(
                nodes: recent,
                selectedNode: selectedNode,
                onSelect: onSelectNode,
                onFavorite: onToggleFavorite,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('鸿达星轨智连', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: _ink)),
                SizedBox(height: 2),
                Text('Hongda Starlink', style: TextStyle(fontSize: 13, color: _muted, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          _HeaderButton(icon: Icons.notifications_none_rounded),
          SizedBox(width: 8),
          _HeaderButton(icon: Icons.more_vert_rounded),
        ],
      );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFEEF2F8)),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x0D1D3557), blurRadius: 14, offset: Offset(0, 6))],
        ),
        child: Icon(icon, color: _ink, size: 23),
      );
}

class _ConnectionHero extends StatelessWidget {
  const _ConnectionHero({required this.controller, required this.node, required this.onToggle, required this.onChooseNode});

  final AndroidRuntimeController controller;
  final NodeProfile? node;
  final VoidCallback onToggle;
  final VoidCallback onChooseNode;

  @override
  Widget build(BuildContext context) {
    final connected = controller.isRunning;
    final preparing = controller.status == AndroidConnectionStatus.preparing;
    final statusText = connected ? '已连接' : (preparing ? '连接中' : '未连接');
    return Container(
      height: 176,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0D60F7), Color(0xFF176BFF), Color(0xFF0D79F7)],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Color(0x33166BFF), blurRadius: 24, offset: Offset(0, 10)),
        ],
      ),
      child: Stack(
        children: <Widget>[
          const Positioned.fill(child: CustomPaint(painter: _HeroSpacePainter())),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 135,
                  child: Center(
                    child: _ConnectionOrb(
                      connected: connected,
                      preparing: preparing,
                      statusText: statusText,
                      duration: controller.connectedAt == null ? Duration.zero : DateTime.now().difference(controller.connectedAt!),
                      onTap: onToggle,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(color: Colors.white.withOpacity(.12), borderRadius: BorderRadius.circular(8)),
                        child: const Text('当前节点', style: TextStyle(color: Color(0xFFDCEBFF), fontSize: 11, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        node?.name ?? '请选择节点',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 19, height: 1.08, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: <Widget>[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white.withOpacity(.18)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(Icons.signal_cellular_alt_rounded, color: Color(0xFF47F39B), size: 16),
                                const SizedBox(width: 5),
                                Text('${node?.latencyMs ?? '--'} ms', style: const TextStyle(color: Color(0xFF65F6A8), fontSize: 12, fontWeight: FontWeight.w700)),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Material(
                              color: Colors.white.withOpacity(.11),
                              borderRadius: BorderRadius.circular(20),
                              child: InkWell(
                                onTap: onChooseNode,
                                borderRadius: BorderRadius.circular(20),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Text('切换节点', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                                      SizedBox(width: 2),
                                      Icon(Icons.chevron_right_rounded, color: Colors.white, size: 17),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Icon(connected ? Icons.verified_user_rounded : Icons.shield_outlined, color: const Color(0xFFE7F0FF), size: 16),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              connected
                                  ? '连接稳定，网络通畅'
                                  : (controller.coreAvailable ? '点击左侧按钮开始连接' : 'UI 已就绪 · Android Core 待接入'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xFFE5EEFF), fontSize: 10.5, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionOrb extends StatefulWidget {
  const _ConnectionOrb({required this.connected, required this.preparing, required this.statusText, required this.duration, required this.onTap});

  final bool connected;
  final bool preparing;
  final String statusText;
  final Duration duration;
  final VoidCallback onTap;

  @override
  State<_ConnectionOrb> createState() => _ConnectionOrbState();
}

class _ConnectionOrbState extends State<_ConnectionOrb> with SingleTickerProviderStateMixin {
  late final AnimationController animation;

  @override
  void initState() {
    super.initState();
    animation = AnimationController(vsync: this, duration: const Duration(seconds: 5))..repeat();
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, child) => CustomPaint(
            painter: _ConnectionRingPainter(progress: animation.value, active: widget.connected || widget.preparing),
            child: SizedBox(
              width: 132,
              height: 132,
              child: Center(
                child: Container(
                  width: 103,
                  height: 103,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const RadialGradient(colors: <Color>[Color(0xFF2F91FF), Color(0xFF1778FF)]),
                    boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x664FD4FF), blurRadius: 26, spreadRadius: 2)],
                    border: Border.all(color: Colors.white.withOpacity(.28), width: 1.2),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Container(
                        width: 38,
                        height: 38,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                        child: widget.preparing
                            ? const Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2.5, color: _blue))
                            : Icon(widget.connected ? Icons.check_rounded : Icons.power_settings_new_rounded, color: _blue, size: 25),
                      ),
                      const SizedBox(height: 7),
                      Text(widget.statusText, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 1),
                      Text(_formatDuration(widget.duration), style: const TextStyle(color: Color(0xFFDCEAFF), fontSize: 10.5, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value, required this.unit, required this.icon, required this.accent});

  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) => Container(
        height: 86,
        padding: const EdgeInsets.fromLTRB(10, 10, 8, 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8EEF8)),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x0A193B69), blurRadius: 15, offset: Offset(0, 7))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF5D6B86), fontWeight: FontWeight.w600))),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: accent.withOpacity(.09), shape: BoxShape.circle),
                  child: Icon(icon, size: 16, color: accent),
                ),
              ],
            ),
            const Spacer(),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(value, style: TextStyle(fontSize: 22, height: 1, fontWeight: FontWeight.w700, color: accent)),
                  const SizedBox(width: 3),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(unit, style: const TextStyle(fontSize: 9.5, color: Color(0xFF6F7C96), fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(label == '延迟' ? '实时延迟' : (label == '总流量' ? '本次连接' : '当前速度'), style: const TextStyle(fontSize: 9.5, color: Color(0xFF9BA7BA))),
          ],
        ),
      );
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.download, required this.upload});

  final List<double> download;
  final List<double> upload;

  @override
  Widget build(BuildContext context) => Container(
        height: 150,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.94),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE8EEF8)),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x0B193B69), blurRadius: 16, offset: Offset(0, 7))],
        ),
        child: Column(
          children: <Widget>[
            const Row(
              children: <Widget>[
                Expanded(child: Text('实时流量', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink))),
                _LegendDot(color: Color(0xFF1C73F3), label: '下载速度'),
                SizedBox(width: 12),
                _LegendDot(color: Color(0xFF8F5DF6), label: '上传速度'),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: CustomPaint(painter: _TrafficPainter(download: download, upload: upload), child: const SizedBox.expand())),
          ],
        ),
      );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 9.5, color: _muted)),
        ],
      );
}

class _QuickToggle extends StatelessWidget {
  const _QuickToggle({required this.icon, required this.label, required this.value, required this.iconColor, required this.onChanged});

  final IconData icon;
  final String label;
  final bool value;
  final Color iconColor;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.94),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE8EEF8)),
        ),
        child: Column(
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 29,
                  height: 29,
                  decoration: BoxDecoration(color: iconColor.withOpacity(.08), shape: BoxShape.circle),
                  child: Icon(icon, size: 18, color: iconColor),
                ),
                const SizedBox(width: 4),
                Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: _ink, fontWeight: FontWeight.w600))),
              ],
            ),
            const Spacer(),
            Transform.scale(scale: .78, child: Switch(value: value, onChanged: onChanged)),
          ],
        ),
      );
}

class _SubscriptionSummaryCard extends StatelessWidget {
  const _SubscriptionSummaryCard({required this.subscriptions, required this.updating, required this.onTap, required this.onUpdate});

  final List<SubscriptionProfile> subscriptions;
  final bool updating;
  final VoidCallback onTap;
  final VoidCallback onUpdate;

  @override
  Widget build(BuildContext context) {
    final latest = subscriptions.where((s) => s.lastUpdated != null).map((s) => s.lastUpdated!).fold<DateTime?>(null, (value, item) => value == null || item.isAfter(value) ? item : value);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 92,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: <Color>[Color(0xFFF8FBFF), Color(0xFFF2F7FF)]),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE3EBF8)),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: <Color>[Color(0xFF8FC2FF), Color(0xFF2E75F6)]),
                boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x332E75F6), blurRadius: 14, offset: Offset(0, 7))],
              ),
              child: const Icon(Icons.folder_copy_rounded, color: Colors.white, size: 29),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('订阅管理', style: TextStyle(fontSize: 14, color: _ink, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 3),
                  Text('${subscriptions.length} 个订阅', style: const TextStyle(fontSize: 12, color: _blue, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(latest == null ? '尚未更新' : '最近更新：${_formatDateTime(latest)}', style: const TextStyle(fontSize: 9.5, color: _muted)),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: updating ? null : onUpdate,
              icon: updating
                  ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync_rounded, size: 17),
              label: Text(updating ? '更新中' : '立即更新', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11))),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentNodeCard extends StatelessWidget {
  const _RecentNodeCard({required this.nodes, required this.selectedNode, required this.onSelect, required this.onFavorite});

  final List<NodeProfile> nodes;
  final NodeProfile? selectedNode;
  final ValueChanged<NodeProfile> onSelect;
  final ValueChanged<NodeProfile> onFavorite;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) {
      return Container(
        height: 92,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE8EEF8))),
        child: const Text('暂无节点，请到“节点”页添加', style: TextStyle(color: _muted, fontSize: 12)),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EEF8)),
        boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x09193B69), blurRadius: 15, offset: Offset(0, 7))],
      ),
      child: Column(
        children: <Widget>[
          for (var i = 0; i < nodes.length; i++) ...<Widget>[
            _RecentNodeRow(node: nodes[i], selected: selectedNode?.id == nodes[i].id, onSelect: () => onSelect(nodes[i]), onFavorite: () => onFavorite(nodes[i])),
            if (i != nodes.length - 1) const Divider(height: 1, color: Color(0xFFF0F3F8)),
          ],
        ],
      ),
    );
  }
}

class _RecentNodeRow extends StatelessWidget {
  const _RecentNodeRow({required this.node, required this.selected, required this.onSelect, required this.onFavorite});

  final NodeProfile node;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 54,
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: const Color(0xFFF8FAFD), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE7ECF4))),
                child: Text(_nodeFlag(node), style: const TextStyle(fontSize: 20)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: _ink, fontWeight: FontWeight.w700))),
                        if (selected) ...<Widget>[
                          const SizedBox(width: 5),
                          Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: BoxDecoration(color: const Color(0xFFE8F1FF), borderRadius: BorderRadius.circular(5)), child: const Text('当前', style: TextStyle(fontSize: 8.5, color: _blue, fontWeight: FontWeight.w700))),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('${node.protocol.toUpperCase()}  |  ${_nodeFeature(node)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9.5, color: _muted)),
                  ],
                ),
              ),
              Text(node.latencyMs == null ? '-- ms' : '${node.latencyMs} ms', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: _latencyColor(node.latencyMs))),
              const SizedBox(width: 8),
              const Icon(Icons.signal_cellular_alt_rounded, color: Color(0xFF37BB7A), size: 17),
              IconButton(onPressed: onFavorite, visualDensity: VisualDensity.compact, icon: Icon(node.favorite ? Icons.star_rounded : Icons.star_border_rounded, color: node.favorite ? const Color(0xFFFFA91F) : const Color(0xFF8794AA), size: 21)),
            ],
          ),
        ),
      );
}

class _AndroidNodesPage extends StatefulWidget {
  const _AndroidNodesPage({required this.nodes, required this.selectedNode, required this.testingIds, required this.onSelect, required this.onFavorite, required this.onTest, required this.onTestAll, required this.onAdd});

  final List<NodeProfile> nodes;
  final NodeProfile? selectedNode;
  final Set<String> testingIds;
  final ValueChanged<NodeProfile> onSelect;
  final ValueChanged<NodeProfile> onFavorite;
  final ValueChanged<NodeProfile> onTest;
  final VoidCallback onTestAll;
  final VoidCallback onAdd;

  @override
  State<_AndroidNodesPage> createState() => _AndroidNodesPageState();
}

class _AndroidNodesPageState extends State<_AndroidNodesPage> {
  final search = TextEditingController();
  String filter = 'all';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final visible = widget.nodes.where((n) {
      if (filter == 'favorite' && !n.favorite) return false;
      return query.isEmpty || n.name.toLowerCase().contains(query) || n.server.toLowerCase().contains(query) || n.protocol.toLowerCase().contains(query);
    }).toList();
    if (filter == 'latency') {
      visible.sort((a, b) => (a.latencyMs ?? 1 << 30).compareTo(b.latencyMs ?? 1 << 30));
    }
    return _MobilePageScaffold(
      title: '节点',
      subtitle: '${widget.nodes.length} 个节点',
      actions: <Widget>[
        IconButton(onPressed: widget.onTestAll, icon: const Icon(Icons.network_check_rounded)),
        IconButton(onPressed: widget.onAdd, icon: const Icon(Icons.add_rounded)),
      ],
      child: Column(
        children: <Widget>[
          TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: '搜索节点名称 / 地址 / 协议'),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _FilterChip(label: '全部', selected: filter == 'all', onTap: () => setState(() => filter = 'all')),
              const SizedBox(width: 7),
              _FilterChip(label: '收藏', selected: filter == 'favorite', onTap: () => setState(() => filter = 'favorite')),
              const SizedBox(width: 7),
              _FilterChip(label: '低延迟', selected: filter == 'latency', onTap: () => setState(() => filter = 'latency')),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('没有匹配的节点', style: TextStyle(color: _muted)))
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final node = visible[index];
                      final selected = widget.selectedNode?.id == node.id;
                      final testing = widget.testingIds.contains(node.id);
                      return _NodeListCard(
                        node: node,
                        selected: selected,
                        testing: testing,
                        onSelect: () => widget.onSelect(node),
                        onFavorite: () => widget.onFavorite(node),
                        onTest: () => widget.onTest(node),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(color: selected ? _blue : Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: selected ? _blue : const Color(0xFFE1E8F2))),
          child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Colors.white : const Color(0xFF52607A))),
        ),
      );
}

class _NodeListCard extends StatelessWidget {
  const _NodeListCard({required this.node, required this.selected, required this.testing, required this.onSelect, required this.onFavorite, required this.onTest});

  final NodeProfile node;
  final bool selected;
  final bool testing;
  final VoidCallback onSelect;
  final VoidCallback onFavorite;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: selected ? const Color(0xFF99BEFF) : const Color(0xFFE8EEF7), width: selected ? 1.4 : 1),
              boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x08193B69), blurRadius: 12, offset: Offset(0, 5))],
            ),
            child: Row(
              children: <Widget>[
                Container(width: 45, height: 38, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFFF7F9FC), borderRadius: BorderRadius.circular(10)), child: Text(_nodeFlag(node), style: const TextStyle(fontSize: 24))),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink))),
                          if (selected) Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: const Color(0xFFE8F1FF), borderRadius: BorderRadius.circular(6)), child: const Text('当前', style: TextStyle(fontSize: 9, color: _blue, fontWeight: FontWeight.w700))),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text('${node.protocol.toUpperCase()} · ${node.server}:${node.port}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: _muted)),
                      if (node.testError != null) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(node.testError!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 9, color: Color(0xFF9A6A35))),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: onTest,
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
                    child: testing
                        ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2.1, color: _blue))
                        : Text(node.latencyMs == null ? '测试' : '${node.latencyMs} ms', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: node.latencyMs == null ? _blue : _latencyColor(node.latencyMs))),
                  ),
                ),
                IconButton(onPressed: onFavorite, visualDensity: VisualDensity.compact, icon: Icon(node.favorite ? Icons.star_rounded : Icons.star_border_rounded, color: node.favorite ? const Color(0xFFFFA51F) : const Color(0xFF8A96AA))),
              ],
            ),
          ),
        ),
      );
}

class _AndroidSubscriptionsPage extends StatelessWidget {
  const _AndroidSubscriptionsPage({required this.subscriptions, required this.updating, required this.onUpdateAll, required this.onAdd, required this.onDelete});

  final List<SubscriptionProfile> subscriptions;
  final bool updating;
  final VoidCallback onUpdateAll;
  final VoidCallback onAdd;
  final ValueChanged<SubscriptionProfile> onDelete;

  @override
  Widget build(BuildContext context) => _MobilePageScaffold(
        title: '订阅',
        subtitle: '${subscriptions.length} 个订阅源',
        actions: <Widget>[
          IconButton(onPressed: updating ? null : onUpdateAll, icon: updating ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)) : const Icon(Icons.sync_rounded)),
          IconButton(onPressed: onAdd, icon: const Icon(Icons.add_rounded)),
        ],
        child: subscriptions.isEmpty
            ? _EmptyState(icon: Icons.folder_copy_outlined, title: '还没有订阅', subtitle: '添加 Clash / sing-box / URI 订阅地址', buttonText: '添加订阅', onPressed: onAdd)
            : ListView.separated(
                physics: const BouncingScrollPhysics(),
                itemCount: subscriptions.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final sub = subscriptions[index];
                  final used = (sub.uploadBytes ?? 0) + (sub.downloadBytes ?? 0);
                  final total = sub.totalBytes ?? 0;
                  final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
                  return Container(
                    padding: const EdgeInsets.all(15),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE7EDF7))),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFFEAF2FF), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.cloud_download_outlined, color: _blue)),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                Text(sub.name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink)),
                                const SizedBox(height: 2),
                                Text('${sub.nodeCount} 个节点 · ${sub.format}', style: const TextStyle(fontSize: 10.5, color: _muted)),
                              ]),
                            ),
                            PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'delete') onDelete(sub);
                              },
                              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                                PopupMenuItem(value: 'delete', child: Text('删除订阅')),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(value: ratio, minHeight: 7, backgroundColor: const Color(0xFFEDF2F8), valueColor: const AlwaysStoppedAnimation<Color>(_blue)),
                        ),
                        const SizedBox(height: 7),
                        Row(
                          children: <Widget>[
                            Expanded(child: Text(total > 0 ? '已用 ${_formatBytes(used)} / ${_formatBytes(total)}' : '未提供流量信息', style: const TextStyle(fontSize: 10, color: _muted))),
                            Text(sub.lastUpdated == null ? '未更新' : _formatDateTime(sub.lastUpdated!), style: const TextStyle(fontSize: 10, color: _muted)),
                          ],
                        ),
                        if (sub.lastError != null) ...<Widget>[
                          const SizedBox(height: 8),
                          Container(width: double.infinity, padding: const EdgeInsets.all(9), decoration: BoxDecoration(color: const Color(0xFFFFF5F3), borderRadius: BorderRadius.circular(10)), child: Text(sub.lastError!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: Color(0xFFB3473B)))),
                        ],
                      ],
                    ),
                  );
                },
              ),
      );
}

class _AndroidToolsPage extends StatelessWidget {
  const _AndroidToolsPage({required this.settings, required this.controller, required this.onChanged, required this.onTestAll, required this.onAutoSelect});

  final AppSettings settings;
  final AndroidRuntimeController controller;
  final VoidCallback onChanged;
  final VoidCallback onTestAll;
  final VoidCallback onAutoSelect;

  @override
  Widget build(BuildContext context) => _MobilePageScaffold(
        title: '工具',
        subtitle: '连接、路由与网络工具',
        child: ListView(
          physics: const BouncingScrollPhysics(),
          children: <Widget>[
            _ToolActionCard(icon: Icons.network_check_rounded, title: '批量延迟测试', subtitle: '测试全部启用节点的连接延迟', color: const Color(0xFF2E7BF5), onTap: onTestAll),
            const SizedBox(height: 9),
            _ToolActionCard(icon: Icons.auto_awesome_rounded, title: '自动选择最佳节点', subtitle: '测试后自动切换到当前最低延迟节点', color: const Color(0xFFFF9C28), onTap: onAutoSelect),
            const SizedBox(height: 14),
            const _SectionTitle('连接设置'),
            _SettingSwitchTile(icon: Icons.view_in_ar_rounded, title: 'TUN 模式', subtitle: 'Android VPN 模式建议保持开启', value: settings.tunEnabled, onChanged: (value) { settings.tunEnabled = value; onChanged(); }),
            _SettingSwitchTile(icon: Icons.route_rounded, title: '严格路由', subtitle: '减少流量绕过 TUN 的可能性', value: settings.strictRoute, onChanged: (value) { settings.strictRoute = value; onChanged(); }),
            _SettingSwitchTile(icon: Icons.public_rounded, title: 'IPv6', subtitle: '允许 IPv6 地址与路由', value: settings.ipv6Enabled, onChanged: (value) { settings.ipv6Enabled = value; onChanged(); }),
            const SizedBox(height: 14),
            const _SectionTitle('DNS'),
            _ChoiceTile(
              title: 'DNS 模式',
              value: settings.dnsMode == 'doh' ? 'DoH' : '本地 DNS',
              options: const <String, String>{'local': '本地 DNS', 'doh': 'DoH'},
              current: settings.dnsMode,
              onSelected: (value) { settings.dnsMode = value; onChanged(); },
            ),
            const SizedBox(height: 8),
            TextFormField(
              initialValue: settings.dnsPrimary,
              onChanged: (value) => settings.dnsPrimary = value.trim(),
              onFieldSubmitted: (value) { settings.dnsPrimary = value.trim(); onChanged(); },
              decoration: const InputDecoration(labelText: 'DoH 地址', hintText: 'https://1.1.1.1/dns-query'),
            ),
            const SizedBox(height: 14),
            const _SectionTitle('路由模式'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final entry in const <String, String>{'rule': '规则', 'global': '全局', 'auto': '自动', 'direct': '直连'}.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: settings.routeMode == entry.key,
                    onSelected: (_) { settings.routeMode = entry.key; onChanged(); },
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(color: controller.coreAvailable ? const Color(0xFFECFBF4) : const Color(0xFFFFF8EC), borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: <Widget>[
                  Icon(controller.coreAvailable ? Icons.check_circle_outline_rounded : Icons.info_outline_rounded, color: controller.coreAvailable ? const Color(0xFF21966A) : const Color(0xFFD28B21)),
                  const SizedBox(width: 9),
                  Expanded(child: Text(controller.coreAvailable ? 'Android libbox 核心已检测到' : '当前源码未打包 libbox.aar，连接功能会给出明确提示，不会再显示 Windows Service 异常。', style: const TextStyle(fontSize: 10.5, color: Color(0xFF5C667B), height: 1.4))),
                ],
              ),
            ),
          ],
        ),
      );
}

class _AndroidSettingsPage extends StatelessWidget {
  const _AndroidSettingsPage({required this.settings, required this.coreAvailable, required this.logs, required this.onChanged});

  final AppSettings settings;
  final bool coreAvailable;
  final List<String> logs;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => _MobilePageScaffold(
        title: '设置',
        subtitle: '应用与高级参数',
        child: ListView(
          physics: const BouncingScrollPhysics(),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: <Color>[Color(0xFF176BFF), Color(0xFF3588FF)]),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: <Widget>[
                  Container(width: 52, height: 52, decoration: BoxDecoration(color: Colors.white.withOpacity(.15), borderRadius: BorderRadius.circular(15)), child: const Icon(Icons.satellite_alt_rounded, color: Colors.white, size: 30)),
                  const SizedBox(width: 13),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    const Text('鸿达星轨智连', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    const Text('Android Edition · v1.6.4', style: TextStyle(color: Color(0xFFD9E8FF), fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(coreAvailable ? 'libbox runtime ready' : 'UI / Data mode', style: const TextStyle(color: Color(0xFFBBD7FF), fontSize: 9.5)),
                  ])),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SectionTitle('网络'),
            _SettingSwitchTile(icon: Icons.router_outlined, title: '绕过局域网', subtitle: '本地网段优先直连', value: settings.bypassLan, onChanged: (value) { settings.bypassLan = value; onChanged(); }),
            _SettingSwitchTile(icon: Icons.shield_moon_outlined, title: 'FakeIP', subtitle: '按规则使用 FakeIP DNS', value: settings.fakeIpEnabled, onChanged: (value) { settings.fakeIpEnabled = value; onChanged(); }),
            const SizedBox(height: 12),
            const _SectionTitle('端口与 URLTest'),
            Row(
              children: <Widget>[
                Expanded(child: _NumberField(label: 'Mixed Port', value: settings.mixedPort, onChanged: (value) { settings.mixedPort = value; onChanged(); })),
                const SizedBox(width: 9),
                Expanded(child: _NumberField(label: 'Clash API', value: settings.apiPort, onChanged: (value) { settings.apiPort = value; onChanged(); })),
              ],
            ),
            const SizedBox(height: 9),
            TextFormField(
              initialValue: settings.urlTestUrl,
              onFieldSubmitted: (value) { settings.urlTestUrl = value.trim(); onChanged(); },
              decoration: const InputDecoration(labelText: 'URLTest 地址'),
            ),
            const SizedBox(height: 12),
            const _SectionTitle('日志级别'),
            _ChoiceTile(
              title: '运行日志',
              value: settings.logLevel,
              options: const <String, String>{'debug': 'debug', 'info': 'info', 'warn': 'warn', 'error': 'error'},
              current: settings.logLevel,
              onSelected: (value) { settings.logLevel = value; onChanged(); },
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              title: const Text('运行日志', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: _ink)),
              subtitle: Text('${logs.length} 条', style: const TextStyle(fontSize: 10, color: _muted)),
              children: <Widget>[
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFF111827), borderRadius: BorderRadius.circular(14)),
                  child: SingleChildScrollView(
                    child: SelectableText(logs.isEmpty ? '暂无日志' : logs.reversed.take(80).toList().reversed.join('\n'), style: const TextStyle(color: Color(0xFFD8E3F4), fontSize: 9.5, fontFamily: 'monospace', height: 1.5)),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _MobilePageScaffold extends StatelessWidget {
  const _MobilePageScaffold({required this.title, required this.subtitle, required this.child, this.actions = const <Widget>[]});

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 8),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text(title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: _ink)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: const TextStyle(fontSize: 11, color: _muted)),
                  ])),
                  ...actions,
                ],
              ),
              const SizedBox(height: 14),
              Expanded(child: child),
            ],
          ),
        ),
      );
}

class _BottomNavigation extends StatelessWidget {
  const _BottomNavigation({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String)>[
      (Icons.home_rounded, '首页'),
      (Icons.dns_outlined, '节点'),
      (Icons.folder_copy_outlined, '订阅'),
      (Icons.business_center_outlined, '工具'),
      (Icons.settings_outlined, '设置'),
    ];
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE9EEF6))),
        boxShadow: <BoxShadow>[BoxShadow(color: Color(0x0C17233E), blurRadius: 16, offset: Offset(0, -5))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 66,
          child: Row(
            children: <Widget>[
              for (var i = 0; i < items.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onChanged(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 190),
                          width: 38,
                          height: 30,
                          decoration: BoxDecoration(color: index == i ? const Color(0xFFEAF2FF) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                          child: Icon(items[i].$1, size: 22, color: index == i ? _blue : const Color(0xFF7E8CA7)),
                        ),
                        const SizedBox(height: 2),
                        Text(items[i].$2, style: TextStyle(fontSize: 10, color: index == i ? _blue : const Color(0xFF7E8CA7), fontWeight: index == i ? FontWeight.w800 : FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolActionCard extends StatelessWidget {
  const _ToolActionCard({required this.icon, required this.title, required this.subtitle, required this.color, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(17),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), border: Border.all(color: const Color(0xFFE8EEF7))),
            child: Row(children: <Widget>[
              Container(width: 44, height: 44, decoration: BoxDecoration(color: color.withOpacity(.09), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: color)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(title, style: const TextStyle(fontSize: 13.5, color: _ink, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3),
                Text(subtitle, style: const TextStyle(fontSize: 10, color: _muted)),
              ])),
              const Icon(Icons.chevron_right_rounded, color: _muted),
            ]),
          ),
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Align(alignment: Alignment.centerLeft, child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _ink))),
      );
}

class _SettingSwitchTile extends StatelessWidget {
  const _SettingSwitchTile({required this.icon, required this.title, required this.subtitle, required this.value, required this.onChanged});
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 9, 9, 9),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFE8EEF7))),
        child: Row(children: <Widget>[
          Container(width: 38, height: 38, decoration: BoxDecoration(color: const Color(0xFFF0F5FD), borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: _blue, size: 20)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 2),
            Text(subtitle, style: const TextStyle(fontSize: 9.5, color: _muted)),
          ])),
          Transform.scale(scale: .82, child: Switch(value: value, onChanged: onChanged)),
        ]),
      );
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({required this.title, required this.value, required this.options, required this.current, required this.onSelected});
  final String title;
  final String value;
  final Map<String, String> options;
  final String current;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFE8EEF7))),
        child: PopupMenuButton<String>(
          onSelected: onSelected,
          itemBuilder: (_) => options.entries.map((entry) => PopupMenuItem<String>(value: entry.key, child: Row(children: <Widget>[
            Icon(current == entry.key ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, size: 18, color: current == entry.key ? _blue : _muted),
            const SizedBox(width: 8),
            Text(entry.value),
          ]))).toList(),
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(children: <Widget>[
              Expanded(child: Text(title, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _ink))),
              Text(value, style: const TextStyle(fontSize: 11, color: _blue, fontWeight: FontWeight.w700)),
              const SizedBox(width: 5),
              const Icon(Icons.expand_more_rounded, color: _muted),
            ]),
          ),
        ),
      );
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.label, required this.value, required this.onChanged});
  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: value.toString(),
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
        onFieldSubmitted: (text) {
          final parsed = int.tryParse(text);
          if (parsed != null) onChanged(parsed);
        },
        decoration: InputDecoration(labelText: label),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.subtitle, required this.buttonText, required this.onPressed});
  final IconData icon;
  final String title;
  final String subtitle;
  final String buttonText;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(width: 76, height: 76, decoration: const BoxDecoration(color: Color(0xFFEAF2FF), shape: BoxShape.circle), child: Icon(icon, size: 34, color: _blue)),
            const SizedBox(height: 14),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _ink)),
            const SizedBox(height: 5),
            Text(subtitle, style: const TextStyle(fontSize: 11, color: _muted)),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: onPressed, icon: const Icon(Icons.add_rounded), label: Text(buttonText)),
          ],
        ),
      );
}

class _HeroSpacePainter extends CustomPainter {
  const _HeroSpacePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final rng = math.Random(6);
    final starPaint = Paint()..color = Colors.white.withOpacity(.68);
    for (var i = 0; i < 34; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final r = i % 7 == 0 ? 1.2 : .65;
      canvas.drawCircle(Offset(x, y), r, starPaint);
    }
    final center = Offset(size.width * .87, size.height * .84);
    final planet = Paint()
      ..shader = const RadialGradient(
        center: Alignment(-.45, -.45),
        colors: <Color>[Color(0xFF9EE8FF), Color(0xFF3A9BFF), Color(0xFF1C64DA)],
      ).createShader(Rect.fromCircle(center: center, radius: size.width * .13));
    canvas.drawCircle(center, size.width * .13, planet);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.1
      ..color = Colors.white.withOpacity(.72);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-.25);
    canvas.scale(1.45, .34);
    canvas.drawCircle(Offset.zero, size.width * .15, ring);
    canvas.restore();
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ConnectionRingPainter extends CustomPainter {
  _ConnectionRingPainter({required this.progress, required this.active});
  final double progress;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 5;
    canvas.drawCircle(center, radius, Paint()..color = Colors.white.withOpacity(.12)..style = PaintingStyle.stroke..strokeWidth = 1);
    final base = Paint()
      ..color = Colors.white.withOpacity(.88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.1
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - 7), -math.pi / 2, math.pi * 1.5, false, base);
    final glowAngle = progress * math.pi * 2;
    final point = Offset(center.dx + math.cos(glowAngle) * (radius - 7), center.dy + math.sin(glowAngle) * (radius - 7));
    if (active) {
      canvas.drawCircle(point, 8, Paint()..color = const Color(0xFF7EECFF).withOpacity(.20));
      canvas.drawCircle(point, 3, Paint()..color = const Color(0xFF89F3FF));
    }
  }

  @override
  bool shouldRepaint(covariant _ConnectionRingPainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.active != active;
}

class _TrafficPainter extends CustomPainter {
  _TrafficPainter({required this.download, required this.upload});
  final List<double> download;
  final List<double> upload;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xFFE6EDF7)..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = size.height * i / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final all = <double>[...download, ...upload];
    final maxValue = math.max(1024.0, all.isEmpty ? 1024.0 : all.reduce((a, b) => a > b ? a : b));
    _drawSeries(canvas, size, download, maxValue, const Color(0xFF1B73F3));
    _drawSeries(canvas, size, upload, maxValue, const Color(0xFF8E5BF5));
  }

  void _drawSeries(Canvas canvas, Size size, List<double> data, double maxValue, Color color) {
    if (data.length < 2) return;
    final points = <Offset>[];
    for (var i = 0; i < data.length; i++) {
      final x = size.width * i / (data.length - 1);
      final normalized = (data[i] / maxValue).clamp(0.0, 1.0);
      final y = size.height - (normalized * size.height * .82 + size.height * .08);
      points.add(Offset(x, y));
    }
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final cur = points[i];
      final midX = (prev.dx + cur.dx) / 2;
      path.cubicTo(midX, prev.dy, midX, cur.dy, cur.dx, cur.dy);
    }
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2.1..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _TrafficPainter oldDelegate) => true;
}

String _formatDuration(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _formatDateTime(DateTime value) => '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

String _speedValue(double bytes) {
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toStringAsFixed(1);
  if (bytes >= 1024) return (bytes / 1024).toStringAsFixed(1);
  return bytes.toStringAsFixed(0);
}

String _speedUnit(double bytes) {
  if (bytes >= 1024 * 1024) return 'MB/s';
  if (bytes >= 1024) return 'KB/s';
  return 'B/s';
}

String _trafficValue(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return (bytes / 1024 / 1024 / 1024).toStringAsFixed(2);
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toStringAsFixed(1);
  if (bytes >= 1024) return (bytes / 1024).toStringAsFixed(1);
  return bytes.toString();
}

String _trafficUnit(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return 'GB';
  if (bytes >= 1024 * 1024) return 'MB';
  if (bytes >= 1024) return 'KB';
  return 'B';
}

String _formatBytes(int bytes) => '${_trafficValue(bytes)} ${_trafficUnit(bytes)}';

String _nodeFlag(NodeProfile node) {
  final text = '${node.name} ${node.server}'.toLowerCase();
  if (text.contains('japan') || text.contains('日本') || text.contains('tokyo') || text.contains(' jp')) return '🇯🇵';
  if (text.contains('united states') || text.contains('美国') || text.contains('los angeles') || text.contains('san jose') || text.contains(' us')) return '🇺🇸';
  if (text.contains('singapore') || text.contains('新加坡') || text.contains(' sg')) return '🇸🇬';
  if (text.contains('hong kong') || text.contains('香港') || text.contains(' hk')) return '🇭🇰';
  if (text.contains('taiwan') || text.contains('台湾') || text.contains(' tw')) return '🇹🇼';
  if (text.contains('korea') || text.contains('韩国') || text.contains(' kr')) return '🇰🇷';
  return '🌐';
}

String _nodeFeature(NodeProfile node) {
  final tls = node.outbound['tls'];
  if (tls is Map && tls['reality'] is Map) return 'Reality';
  if (node.protocol.toLowerCase() == 'hysteria2') return 'Hysteria2';
  final transport = node.outbound['transport'];
  if (transport is Map && transport['type'] != null) return transport['type'].toString().toUpperCase();
  return node.protocol.toUpperCase();
}

Color _latencyColor(int? latency) {
  if (latency == null) return _muted;
  if (latency <= 80) return const Color(0xFF24A96F);
  if (latency <= 180) return const Color(0xFFF08B24);
  return const Color(0xFFE04F5F);
}

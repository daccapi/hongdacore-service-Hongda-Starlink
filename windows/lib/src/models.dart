import 'dart:convert';

class NodeProfile {
  NodeProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.server,
    required this.port,
    required this.outbound,
    this.source = 'manual',
    this.latencyMs,
    this.lastLatencyTest,
    this.testError,
    this.favorite = false,
    this.enabled = true,
  });

  String id;
  String name;
  final String protocol;
  final String server;
  final int port;
  final Map<String, dynamic> outbound;
  final String source;
  int? latencyMs;
  DateTime? lastLatencyTest;
  String? testError;
  bool favorite;
  bool enabled;

  String get fingerprint {
    final canonical = jsonEncode(_canonicalJsonValue(outbound));
    return '$protocol|$server|$port|$canonical';
  }

  String get identityKey =>
      '${protocol.toLowerCase()}|${server.toLowerCase()}|$port|${name.trim().toLowerCase()}';

  String get endpointKey =>
      '${protocol.toLowerCase()}|${server.toLowerCase()}|$port';

  static dynamic _canonicalJsonValue(dynamic value) {
    if (value is Map) {
      final entries =
          value.entries
              .map((entry) => MapEntry(entry.key.toString(), entry.value))
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      return <String, dynamic>{
        for (final entry in entries)
          entry.key: _canonicalJsonValue(entry.value),
      };
    }
    if (value is List) return value.map(_canonicalJsonValue).toList();
    return value;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'protocol': protocol,
    'server': server,
    'port': port,
    'outbound': outbound,
    'source': source,
    'latencyMs': latencyMs,
    'lastLatencyTest': lastLatencyTest?.toIso8601String(),
    'testError': testError,
    'favorite': favorite,
    'enabled': enabled,
  };

  factory NodeProfile.fromJson(Map<String, dynamic> json) {
    return NodeProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未命名节点',
      protocol: json['protocol']?.toString() ?? 'unknown',
      server: json['server']?.toString() ?? '',
      port: _intValue(json['port']),
      outbound: Map<String, dynamic>.from(
        (json['outbound'] as Map?) ?? const <String, dynamic>{},
      ),
      source: json['source']?.toString() ?? 'manual',
      latencyMs: json['latencyMs'] == null
          ? null
          : _intValue(json['latencyMs']),
      lastLatencyTest: DateTime.tryParse(
        json['lastLatencyTest']?.toString() ?? '',
      ),
      testError: json['testError']?.toString(),
      favorite: json['favorite'] == true,
      enabled: json['enabled'] != false,
    );
  }

  static int _intValue(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class SubscriptionProfile {
  SubscriptionProfile({
    required this.id,
    required this.name,
    required this.url,
    this.lastUpdated,
    this.nodeCount = 0,
    this.format = 'auto',
    this.userAgent = 'HongdaStarlink/1.1',
    this.lastError,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
  });

  final String id;
  String name;
  String url;
  DateTime? lastUpdated;
  int nodeCount;
  String format;
  String userAgent;
  String? lastError;
  int? uploadBytes;
  int? downloadBytes;
  int? totalBytes;
  DateTime? expiresAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'url': url,
    'lastUpdated': lastUpdated?.toIso8601String(),
    'nodeCount': nodeCount,
    'format': format,
    'userAgent': userAgent,
    'lastError': lastError,
    'uploadBytes': uploadBytes,
    'downloadBytes': downloadBytes,
    'totalBytes': totalBytes,
    'expiresAt': expiresAt?.toIso8601String(),
  };

  factory SubscriptionProfile.fromJson(Map<String, dynamic> json) {
    return SubscriptionProfile(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '订阅',
      url: json['url']?.toString() ?? '',
      lastUpdated: DateTime.tryParse(json['lastUpdated']?.toString() ?? ''),
      nodeCount: int.tryParse(json['nodeCount']?.toString() ?? '') ?? 0,
      format: json['format']?.toString() ?? 'auto',
      userAgent: json['userAgent']?.toString() ?? 'HongdaStarlink/1.1',
      lastError: json['lastError']?.toString(),
      uploadBytes: _nullableInt(json['uploadBytes']),
      downloadBytes: _nullableInt(json['downloadBytes']),
      totalBytes: _nullableInt(json['totalBytes']),
      expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
    );
  }

  static int? _nullableInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    return int.tryParse(value.toString());
  }
}

class ProxyGroupProfile {
  ProxyGroupProfile({
    required this.id,
    required this.name,
    this.type = 'selector',
    List<String>? nodeIds,
    this.selectedNodeId = '',
    this.testUrl = 'https://www.gstatic.com/generate_204',
    this.intervalSeconds = 180,
    this.toleranceMs = 50,
    this.enabled = true,
    this.source = 'manual',
  }) : nodeIds = nodeIds ?? <String>[];

  final String id;
  String name;
  String type; // selector | urltest
  List<String> nodeIds;
  String selectedNodeId;
  String testUrl;
  int intervalSeconds;
  int toleranceMs;
  bool enabled;
  String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'type': type,
    'nodeIds': nodeIds,
    'selectedNodeId': selectedNodeId,
    'testUrl': testUrl,
    'intervalSeconds': intervalSeconds,
    'toleranceMs': toleranceMs,
    'enabled': enabled,
    'source': source,
  };

  factory ProxyGroupProfile.fromJson(Map<String, dynamic> json) =>
      ProxyGroupProfile(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '代理组',
        type: json['type']?.toString() == 'urltest' ? 'urltest' : 'selector',
        nodeIds:
            (json['nodeIds'] as List?)?.map((e) => e.toString()).toList() ??
            <String>[],
        selectedNodeId: json['selectedNodeId']?.toString() ?? '',
        testUrl:
            json['testUrl']?.toString() ??
            'https://www.gstatic.com/generate_204',
        intervalSeconds:
            int.tryParse(json['intervalSeconds']?.toString() ?? '') ?? 180,
        toleranceMs: int.tryParse(json['toleranceMs']?.toString() ?? '') ?? 50,
        enabled: json['enabled'] != false,
        source: json['source']?.toString() ?? 'manual',
      );
}

class RouteRuleProfile {
  RouteRuleProfile({
    required this.id,
    required this.name,
    this.enabled = true,
    List<String>? domains,
    List<String>? domainSuffixes,
    List<String>? domainKeywords,
    List<String>? ipCidrs,
    List<String>? processNames,
    this.network = '',
    this.outbound = 'proxy',
    this.source = 'manual',
  }) : domains = domains ?? <String>[],
       domainSuffixes = domainSuffixes ?? <String>[],
       domainKeywords = domainKeywords ?? <String>[],
       ipCidrs = ipCidrs ?? <String>[],
       processNames = processNames ?? <String>[];

  final String id;
  String name;
  bool enabled;
  List<String> domains;
  List<String> domainSuffixes;
  List<String> domainKeywords;
  List<String> ipCidrs;
  List<String> processNames;
  String network; // '', tcp, udp, icmp
  String outbound; // proxy, auto, direct, block, group:<id>, node:<id>
  String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'enabled': enabled,
    'domains': domains,
    'domainSuffixes': domainSuffixes,
    'domainKeywords': domainKeywords,
    'ipCidrs': ipCidrs,
    'processNames': processNames,
    'network': network,
    'outbound': outbound,
    'source': source,
  };

  factory RouteRuleProfile.fromJson(Map<String, dynamic> json) =>
      RouteRuleProfile(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '路由规则',
        enabled: json['enabled'] != false,
        domains: _stringList(json['domains']),
        domainSuffixes: _stringList(json['domainSuffixes']),
        domainKeywords: _stringList(json['domainKeywords']),
        ipCidrs: _stringList(json['ipCidrs']),
        processNames: _stringList(json['processNames']),
        network: json['network']?.toString() ?? '',
        outbound: json['outbound']?.toString() ?? 'proxy',
        source: json['source']?.toString() ?? 'manual',
      );

  static List<String> _stringList(dynamic value) =>
      (value as List?)
          ?.map((e) => e.toString())
          .where((e) => e.trim().isNotEmpty)
          .toList() ??
      <String>[];
}

class TrafficStats {
  TrafficStats({
    this.totalUploadBytes = 0,
    this.totalDownloadBytes = 0,
    Map<String, int>? dailyUploadBytes,
    Map<String, int>? dailyDownloadBytes,
  }) : dailyUploadBytes = dailyUploadBytes ?? <String, int>{},
       dailyDownloadBytes = dailyDownloadBytes ?? <String, int>{};

  int totalUploadBytes;
  int totalDownloadBytes;
  final Map<String, int> dailyUploadBytes;
  final Map<String, int> dailyDownloadBytes;

  int get totalBytes => totalUploadBytes + totalDownloadBytes;

  void add({required int upload, required int download, DateTime? at}) {
    if (upload <= 0 && download <= 0) return;
    final now = at ?? DateTime.now();
    final day =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final safeUpload = upload < 0 ? 0 : upload;
    final safeDownload = download < 0 ? 0 : download;
    totalUploadBytes += safeUpload;
    totalDownloadBytes += safeDownload;
    dailyUploadBytes[day] = (dailyUploadBytes[day] ?? 0) + safeUpload;
    dailyDownloadBytes[day] = (dailyDownloadBytes[day] ?? 0) + safeDownload;
    _trimDaily();
  }

  void _trimDaily() {
    final keys = <String>{
      ...dailyUploadBytes.keys,
      ...dailyDownloadBytes.keys,
    }.toList()..sort();
    if (keys.length <= 90) return;
    for (final key in keys.take(keys.length - 90)) {
      dailyUploadBytes.remove(key);
      dailyDownloadBytes.remove(key);
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'totalUploadBytes': totalUploadBytes,
    'totalDownloadBytes': totalDownloadBytes,
    'dailyUploadBytes': dailyUploadBytes,
    'dailyDownloadBytes': dailyDownloadBytes,
  };

  factory TrafficStats.fromJson(Map<String, dynamic> json) {
    Map<String, int> readMap(dynamic value) {
      if (value is! Map) return <String, int>{};
      return <String, int>{
        for (final entry in value.entries)
          entry.key.toString(): int.tryParse(entry.value.toString()) ?? 0,
      };
    }

    return TrafficStats(
      totalUploadBytes:
          int.tryParse(json['totalUploadBytes']?.toString() ?? '') ?? 0,
      totalDownloadBytes:
          int.tryParse(json['totalDownloadBytes']?.toString() ?? '') ?? 0,
      dailyUploadBytes: readMap(json['dailyUploadBytes']),
      dailyDownloadBytes: readMap(json['dailyDownloadBytes']),
    );
  }
}

class AppSettings {
  AppSettings({
    this.mixedPort = 7890,
    this.apiPort = 9090,
    this.tunEnabled = false,
    this.strictRoute = true,
    this.systemProxyEnabled = true,
    this.bypassLan = true,
    this.startWithWindows = false,
    this.selectedNodeId = '',
    this.selectedGroupId = '',
    this.routeMode = 'rule',
    this.smartCnDirect = true,
    this.smartProxyList = true,
    this.smartAdBlock = false,
    this.logLevel = 'warn',
    this.tunStack = 'system',
    this.tunMtu = 9000,
    this.ipv6Enabled = true,
    this.dnsMode = 'local',
    this.dnsPrimary = 'https://1.1.1.1/dns-query',
    this.dnsDirect = 'local',
    this.dnsStrategy = 'prefer_ipv4',
    this.fakeIpEnabled = false,
    this.urlTestUrl = 'https://www.gstatic.com/generate_204',
    this.urlTestIntervalSeconds = 180,
    this.urlTestToleranceMs = 50,
    this.clashApiSecret = '',
    this.tailscaleEnabled = false,
    this.tailscaleAuthKey = '',
    this.tailscaleControlUrl = '',
    this.tailscaleHostname = 'hongda-starlink',
    this.tailscaleAcceptRoutes = true,
    this.tailscaleExitNode = '',
    this.tailscaleExitNodeAllowLanAccess = true,
  });

  int mixedPort;
  int apiPort;
  bool tunEnabled;
  bool strictRoute;
  bool systemProxyEnabled;
  bool bypassLan;
  bool startWithWindows;
  String selectedNodeId;
  String selectedGroupId;
  String routeMode; // rule | global | direct | auto | group
  bool smartCnDirect;
  bool smartProxyList;
  bool smartAdBlock;
  String logLevel;
  String tunStack;
  int tunMtu;
  bool ipv6Enabled;
  String dnsMode; // local | doh
  String dnsPrimary;
  String dnsDirect;
  String dnsStrategy;
  bool fakeIpEnabled;
  String urlTestUrl;
  int urlTestIntervalSeconds;
  int urlTestToleranceMs;
  String clashApiSecret;
  bool tailscaleEnabled;
  String tailscaleAuthKey;
  String tailscaleControlUrl;
  String tailscaleHostname;
  bool tailscaleAcceptRoutes;
  String tailscaleExitNode;
  bool tailscaleExitNodeAllowLanAccess;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'mixedPort': mixedPort,
    'apiPort': apiPort,
    'tunEnabled': tunEnabled,
    'strictRoute': strictRoute,
    'systemProxyEnabled': systemProxyEnabled,
    'bypassLan': bypassLan,
    'startWithWindows': startWithWindows,
    'selectedNodeId': selectedNodeId,
    'selectedGroupId': selectedGroupId,
    'routeMode': routeMode,
    'smartCnDirect': smartCnDirect,
    'smartProxyList': smartProxyList,
    'smartAdBlock': smartAdBlock,
    'logLevel': logLevel,
    'tunStack': tunStack,
    'tunMtu': tunMtu,
    'ipv6Enabled': ipv6Enabled,
    'dnsMode': dnsMode,
    'dnsPrimary': dnsPrimary,
    'dnsDirect': dnsDirect,
    'dnsStrategy': dnsStrategy,
    'fakeIpEnabled': fakeIpEnabled,
    'urlTestUrl': urlTestUrl,
    'urlTestIntervalSeconds': urlTestIntervalSeconds,
    'urlTestToleranceMs': urlTestToleranceMs,
    'clashApiSecret': clashApiSecret,
    'tailscaleEnabled': tailscaleEnabled,
    'tailscaleAuthKey': tailscaleAuthKey,
    'tailscaleControlUrl': tailscaleControlUrl,
    'tailscaleHostname': tailscaleHostname,
    'tailscaleAcceptRoutes': tailscaleAcceptRoutes,
    'tailscaleExitNode': tailscaleExitNode,
    'tailscaleExitNodeAllowLanAccess': tailscaleExitNodeAllowLanAccess,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      mixedPort: int.tryParse(json['mixedPort']?.toString() ?? '') ?? 7890,
      apiPort: int.tryParse(json['apiPort']?.toString() ?? '') ?? 9090,
      tunEnabled: json['tunEnabled'] == true,
      strictRoute: json['strictRoute'] != false,
      systemProxyEnabled: json['systemProxyEnabled'] != false,
      bypassLan: json['bypassLan'] != false,
      startWithWindows: json['startWithWindows'] == true,
      selectedNodeId: json['selectedNodeId']?.toString() ?? '',
      selectedGroupId: json['selectedGroupId']?.toString() ?? '',
      routeMode: json['routeMode']?.toString() ?? 'rule',
      smartCnDirect: json['smartCnDirect'] != false,
      smartProxyList: json['smartProxyList'] != false,
      smartAdBlock: json['smartAdBlock'] == true,
      logLevel: json['logLevel']?.toString() ?? 'warn',
      tunStack: json['tunStack']?.toString() ?? 'system',
      tunMtu: int.tryParse(json['tunMtu']?.toString() ?? '') ?? 9000,
      ipv6Enabled: json['ipv6Enabled'] != false,
      dnsMode: json['dnsMode']?.toString() ?? 'local',
      dnsPrimary: json['dnsPrimary']?.toString() ?? 'https://1.1.1.1/dns-query',
      dnsDirect: json['dnsDirect']?.toString() ?? 'local',
      dnsStrategy: json['dnsStrategy']?.toString() ?? 'prefer_ipv4',
      fakeIpEnabled: json['fakeIpEnabled'] == true,
      urlTestUrl:
          json['urlTestUrl']?.toString() ??
          'https://www.gstatic.com/generate_204',
      urlTestIntervalSeconds:
          int.tryParse(json['urlTestIntervalSeconds']?.toString() ?? '') ?? 180,
      urlTestToleranceMs:
          int.tryParse(json['urlTestToleranceMs']?.toString() ?? '') ?? 50,
      clashApiSecret: json['clashApiSecret']?.toString() ?? '',
      tailscaleEnabled: json['tailscaleEnabled'] == true,
      tailscaleAuthKey: json['tailscaleAuthKey']?.toString() ?? '',
      tailscaleControlUrl: json['tailscaleControlUrl']?.toString() ?? '',
      tailscaleHostname:
          json['tailscaleHostname']?.toString() ?? 'hongda-starlink',
      tailscaleAcceptRoutes: json['tailscaleAcceptRoutes'] != false,
      tailscaleExitNode: json['tailscaleExitNode']?.toString() ?? '',
      tailscaleExitNodeAllowLanAccess:
          json['tailscaleExitNodeAllowLanAccess'] != false,
    );
  }
}

String prettyJson(Object value) =>
    const JsonEncoder.withIndent('  ').convert(value);

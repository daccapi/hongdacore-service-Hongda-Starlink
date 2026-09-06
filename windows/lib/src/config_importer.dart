import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'models.dart';
import 'node_parser.dart';

class ConfigImportResult {
  ConfigImportResult({
    required this.nodes,
    List<ProxyGroupProfile>? groups,
    List<RouteRuleProfile>? rules,
    this.format = 'links',
  }) : groups = groups ?? <ProxyGroupProfile>[],
       rules = rules ?? <RouteRuleProfile>[];

  final List<NodeProfile> nodes;
  final List<ProxyGroupProfile> groups;
  final List<RouteRuleProfile> rules;
  final String format;
}

class ConfigImporter {
  static ConfigImportResult parse(String content, {String source = 'manual'}) {
    final text = content.trim();
    if (text.isEmpty) return ConfigImportResult(nodes: <NodeProfile>[]);

    // sing-box JSON / generic JSON first.
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final result = _parseSingBox(
            Map<String, dynamic>.from(decoded),
            source,
          );
          if (result.nodes.isNotEmpty ||
              result.groups.isNotEmpty ||
              result.rules.isNotEmpty) {
            return result;
          }
        }
      } catch (_) {
        // Continue with other formats.
      }
    }

    // Clash / Mihomo YAML.
    if (RegExp(r'(?m)^\s*(proxies|proxy-groups|rules)\s*:').hasMatch(text)) {
      try {
        final yaml = loadYaml(text);
        if (yaml is YamlMap) {
          final result = _parseClash(
            _plain(yaml) as Map<String, dynamic>,
            source,
          );
          if (result.nodes.isNotEmpty ||
              result.groups.isNotEmpty ||
              result.rules.isNotEmpty) {
            return result;
          }
        }
      } catch (_) {
        // Continue with URI/base64 parsing.
      }
    }

    return ConfigImportResult(
      nodes: _dedupe(NodeParser.parseMany(text, source: source)),
      format: text.contains('://') ? 'links' : 'base64',
    );
  }

  static ConfigImportResult _parseSingBox(
    Map<String, dynamic> root,
    String source,
  ) {
    final rawOutbounds = (root['outbounds'] as List?) ?? const <dynamic>[];
    final nodes = <NodeProfile>[];
    final tagToNode = <String, NodeProfile>{};
    final groupDefs = <Map<String, dynamic>>[];

    for (final raw in rawOutbounds) {
      if (raw is! Map) continue;
      final outbound = Map<String, dynamic>.from(raw);
      final type = outbound['type']?.toString() ?? '';
      if (type == 'selector' || type == 'urltest') {
        groupDefs.add(outbound);
        continue;
      }
      if (!_proxyTypes.contains(type)) continue;
      final tag = outbound['tag']?.toString() ?? '';
      final server = outbound['server']?.toString() ?? '';
      final port = int.tryParse(outbound['server_port']?.toString() ?? '') ?? 0;
      if (server.isEmpty || port <= 0) continue;
      final clean = Map<String, dynamic>.from(outbound)..remove('tag');
      final node = NodeProfile(
        id: _stableId(source, '$type|$tag|$server|$port|${jsonEncode(clean)}'),
        name: tag.isEmpty ? '$type $server:$port' : tag,
        protocol: type,
        server: server,
        port: port,
        outbound: clean,
        source: source,
      );
      nodes.add(node);
      if (tag.isNotEmpty) tagToNode[tag] = node;
    }

    final groups = <ProxyGroupProfile>[];
    final tagToGroupId = <String, String>{};
    final groupByTag = <String, Map<String, dynamic>>{};
    for (final raw in groupDefs) {
      final tag = raw['tag']?.toString() ?? '代理组';
      tagToGroupId[tag] = _stableId(source, 'group|$tag');
      groupByTag[tag] = raw;
    }

    late List<String> Function(String, Set<String>) resolveGroupMembers;
    resolveGroupMembers = (String tag, Set<String> visiting) {
      if (!visiting.add(tag)) return <String>[];
      final raw = groupByTag[tag];
      if (raw == null) {
        visiting.remove(tag);
        return <String>[];
      }
      final result = <String>{};
      for (final memberTag
          in (raw['outbounds'] as List?)?.map((e) => e.toString()) ??
              const <String>[]) {
        final node = tagToNode[memberTag];
        if (node != null) {
          result.add(node.id);
          continue;
        }
        if (groupByTag.containsKey(memberTag)) {
          result.addAll(resolveGroupMembers(memberTag, visiting));
        }
      }
      visiting.remove(tag);
      return result.toList();
    };

    for (final raw in groupDefs) {
      final tag = raw['tag']?.toString() ?? '代理组';
      final groupId = tagToGroupId[tag]!;
      final memberIds = resolveGroupMembers(tag, <String>{});
      final defaultTag = raw['default']?.toString() ?? '';
      var selectedNodeId = tagToNode[defaultTag]?.id ?? '';
      if (selectedNodeId.isEmpty && groupByTag.containsKey(defaultTag)) {
        final resolvedDefault = resolveGroupMembers(defaultTag, <String>{});
        if (resolvedDefault.isNotEmpty) selectedNodeId = resolvedDefault.first;
      }
      groups.add(
        ProxyGroupProfile(
          id: groupId,
          name: tag,
          type: raw['type']?.toString() == 'urltest' ? 'urltest' : 'selector',
          nodeIds: memberIds,
          selectedNodeId: selectedNodeId,
          testUrl:
              raw['url']?.toString() ?? 'https://www.gstatic.com/generate_204',
          intervalSeconds: _durationSeconds(raw['interval']?.toString(), 180),
          toleranceMs: int.tryParse(raw['tolerance']?.toString() ?? '') ?? 50,
          source: source,
        ),
      );
    }

    final rules = <RouteRuleProfile>[];
    final rawRules =
        ((root['route'] as Map?)?['rules'] as List?) ?? const <dynamic>[];
    var index = 0;
    for (final raw in rawRules) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final action = map['action']?.toString() ?? 'route';
      var outbound = map['outbound']?.toString() ?? 'proxy';
      if (action == 'reject') outbound = 'block';
      if (tagToGroupId.containsKey(outbound))
        outbound = 'group:${tagToGroupId[outbound]}';
      if (tagToNode.containsKey(outbound))
        outbound = 'node:${tagToNode[outbound]!.id}';
      final rule = RouteRuleProfile(
        id: _stableId(source, 'rule|${index++}|${jsonEncode(map)}'),
        name: '导入规则 ${index}',
        domains: _strings(map['domain']),
        domainSuffixes: _strings(map['domain_suffix']),
        domainKeywords: _strings(map['domain_keyword']),
        ipCidrs: _strings(map['ip_cidr']),
        processNames: _strings(map['process_name']),
        network: map['network']?.toString() ?? '',
        outbound: outbound,
        source: source,
      );
      if (_hasMatchers(rule)) rules.add(rule);
    }

    final route = root['route'];
    if (route is Map) {
      var finalTarget = route['final']?.toString() ?? '';
      if (finalTarget.isNotEmpty) {
        if (tagToGroupId.containsKey(finalTarget)) {
          finalTarget = 'group:${tagToGroupId[finalTarget]}';
        } else if (tagToNode.containsKey(finalTarget)) {
          finalTarget = 'node:${tagToNode[finalTarget]!.id}';
        } else if (finalTarget != 'direct' &&
            finalTarget != 'block' &&
            finalTarget != 'proxy' &&
            finalTarget != 'auto') {
          finalTarget = 'proxy';
        }
        rules.add(
          RouteRuleProfile(
            id: _stableId(source, 'route-final|$finalTarget'),
            name: 'FINAL → $finalTarget',
            outbound: finalTarget,
            source: source,
          ),
        );
      }
    }

    return ConfigImportResult(
      nodes: _dedupe(nodes),
      groups: groups,
      rules: rules,
      format: 'sing-box',
    );
  }

  static ConfigImportResult _parseClash(
    Map<String, dynamic> root,
    String source,
  ) {
    final nodes = <NodeProfile>[];
    final nameToNode = <String, NodeProfile>{};
    final rawProxies = (root['proxies'] as List?) ?? const <dynamic>[];
    for (final raw in rawProxies) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final node = _clashProxy(map, source);
      if (node != null) {
        nodes.add(node);
        nameToNode[node.name] = node;
      }
    }

    final groups = <ProxyGroupProfile>[];
    final rawGroups = (root['proxy-groups'] as List?) ?? const <dynamic>[];
    final groupByName = <String, Map<String, dynamic>>{};
    final groupNameToId = <String, String>{};
    for (final raw in rawGroups) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final name = map['name']?.toString() ?? '代理组';
      final type = map['type']?.toString().toLowerCase() ?? 'select';
      if (type != 'select' && type != 'url-test' && type != 'fallback')
        continue;
      groupByName[name] = map;
      groupNameToId[name] = _stableId(source, 'group|$name');
    }

    late List<String> Function(String, Set<String>) resolveClashGroupMembers;
    resolveClashGroupMembers = (String name, Set<String> visiting) {
      if (!visiting.add(name)) return <String>[];
      final map = groupByName[name];
      if (map == null) {
        visiting.remove(name);
        return <String>[];
      }
      final result = <String>{};
      for (final member in _strings(map['proxies'])) {
        final node = nameToNode[member];
        if (node != null) {
          result.add(node.id);
          continue;
        }
        if (groupByName.containsKey(member)) {
          result.addAll(resolveClashGroupMembers(member, visiting));
        }
      }
      visiting.remove(name);
      return result.toList();
    };

    for (final entry in groupByName.entries) {
      final name = entry.key;
      final map = entry.value;
      final type = map['type']?.toString().toLowerCase() ?? 'select';
      groups.add(
        ProxyGroupProfile(
          id: groupNameToId[name]!,
          name: name,
          type: type == 'select' ? 'selector' : 'urltest',
          nodeIds: resolveClashGroupMembers(name, <String>{}),
          testUrl:
              map['url']?.toString() ?? 'https://www.gstatic.com/generate_204',
          intervalSeconds:
              int.tryParse(map['interval']?.toString() ?? '') ?? 180,
          toleranceMs: int.tryParse(map['tolerance']?.toString() ?? '') ?? 50,
          source: source,
        ),
      );
    }

    final rules = <RouteRuleProfile>[];
    var index = 0;
    for (final raw in (root['rules'] as List?) ?? const <dynamic>[]) {
      final line = raw.toString().trim();
      if (line.isEmpty) continue;
      final parts = line.split(',').map((e) => e.trim()).toList();
      if (parts.length < 2) continue;
      final kind = parts[0].toUpperCase();
      final isFinal = kind == 'MATCH' || kind == 'FINAL';
      if (!isFinal && parts.length < 3) continue;
      // Clash rules can end with modifiers such as `no-resolve`. The policy
      // target is field 2 for MATCH/FINAL and field 3 for normal rules, not
      // necessarily the last comma-separated token.
      final target = isFinal ? parts[1] : parts[2];
      final outbound = _clashTarget(target, groupNameToId, nameToNode);
      final rule = RouteRuleProfile(
        id: _stableId(source, 'clash-rule|${index++}|$line'),
        name: line,
        outbound: outbound,
        source: source,
      );
      switch (kind) {
        case 'DOMAIN':
          rule.domains.add(parts[1]);
          break;
        case 'DOMAIN-SUFFIX':
          rule.domainSuffixes.add(parts[1]);
          break;
        case 'DOMAIN-KEYWORD':
          rule.domainKeywords.add(parts[1]);
          break;
        case 'IP-CIDR':
        case 'IP-CIDR6':
          rule.ipCidrs.add(parts[1]);
          break;
        case 'PROCESS-NAME':
          rule.processNames.add(parts[1]);
          break;
        case 'NETWORK':
          rule.network = parts[1].toLowerCase();
          break;
        case 'MATCH':
        case 'FINAL':
          // Final target is represented by a catch-all rule; leave matchers empty.
          rule.name = 'FINAL → $target';
          break;
        default:
          continue;
      }
      rules.add(rule);
    }

    return ConfigImportResult(
      nodes: _dedupe(nodes),
      groups: groups,
      rules: rules,
      format: 'clash',
    );
  }

  static NodeProfile? _clashProxy(Map<String, dynamic> p, String source) {
    final name = p['name']?.toString() ?? '未命名节点';
    final clashType = p['type']?.toString().toLowerCase() ?? '';
    final server = p['server']?.toString() ?? '';
    final port = int.tryParse(p['port']?.toString() ?? '') ?? 0;
    if (server.isEmpty || port <= 0) return null;

    String type = clashType;
    if (type == 'ss') type = 'shadowsocks';
    if (type == 'socks5') type = 'socks';
    if (type == 'hy2') type = 'hysteria2';
    if (!_proxyTypes.contains(type)) return null;

    final out = <String, dynamic>{
      'type': type,
      'server': server,
      'server_port': port,
    };
    switch (type) {
      case 'vless':
        out['uuid'] = p['uuid']?.toString() ?? '';
        if ((p['flow']?.toString() ?? '').isNotEmpty)
          out['flow'] = p['flow'].toString();
        _clashTls(out, p, reality: p['reality-opts'] is Map);
        _clashTransport(out, p);
        break;
      case 'vmess':
        out['uuid'] = p['uuid']?.toString() ?? '';
        out['security'] = p['cipher']?.toString() ?? 'auto';
        out['alter_id'] =
            int.tryParse(
              p['alterId']?.toString() ?? p['alter-id']?.toString() ?? '',
            ) ??
            0;
        _clashTls(out, p);
        _clashTransport(out, p);
        break;
      case 'trojan':
        out['password'] = p['password']?.toString() ?? '';
        _clashTls(out, p, force: true);
        _clashTransport(out, p);
        break;
      case 'shadowsocks':
        out['method'] = p['cipher']?.toString() ?? '';
        out['password'] = p['password']?.toString() ?? '';
        break;
      case 'hysteria2':
        out['password'] =
            p['password']?.toString() ?? p['auth']?.toString() ?? '';
        _clashTls(out, p, force: true);
        final obfs = p['obfs']?.toString() ?? '';
        if (obfs.isNotEmpty) {
          out['obfs'] = <String, dynamic>{
            'type': obfs,
            if ((p['obfs-password']?.toString() ?? '').isNotEmpty)
              'password': p['obfs-password'].toString(),
          };
        }
        break;
      case 'tuic':
        out['uuid'] = p['uuid']?.toString() ?? '';
        out['password'] = p['password']?.toString() ?? '';
        if ((p['congestion-controller']?.toString() ?? '').isNotEmpty)
          out['congestion_control'] = p['congestion-controller'].toString();
        if ((p['udp-relay-mode']?.toString() ?? '').isNotEmpty)
          out['udp_relay_mode'] = p['udp-relay-mode'].toString();
        _clashTls(out, p, force: true);
        break;
      case 'anytls':
        out['password'] = p['password']?.toString() ?? '';
        _clashTls(out, p, force: true);
        break;
      case 'socks':
      case 'http':
        if ((p['username']?.toString() ?? '').isNotEmpty)
          out['username'] = p['username'].toString();
        if ((p['password']?.toString() ?? '').isNotEmpty)
          out['password'] = p['password'].toString();
        if (type == 'socks') out['version'] = '5';
        break;
    }

    return NodeProfile(
      id: _stableId(source, '$type|$name|$server|$port|${jsonEncode(out)}'),
      name: name,
      protocol: type,
      server: server,
      port: port,
      outbound: out,
      source: source,
    );
  }

  static void _clashTls(
    Map<String, dynamic> out,
    Map<String, dynamic> p, {
    bool force = false,
    bool reality = false,
  }) {
    final enabled = force || p['tls'] == true || reality;
    if (!enabled) return;
    final tls = <String, dynamic>{'enabled': true};
    final sni = p['servername']?.toString() ?? p['sni']?.toString() ?? '';
    if (sni.isNotEmpty) tls['server_name'] = sni;
    if (p['skip-cert-verify'] == true) tls['insecure'] = true;
    final fp = p['client-fingerprint']?.toString() ?? '';
    if (fp.isNotEmpty)
      tls['utls'] = <String, dynamic>{'enabled': true, 'fingerprint': fp};
    final realityOpts = p['reality-opts'];
    if (realityOpts is Map) {
      final r = Map<String, dynamic>.from(realityOpts);
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        if ((r['public-key']?.toString() ?? '').isNotEmpty)
          'public_key': r['public-key'].toString(),
        if ((r['short-id']?.toString() ?? '').isNotEmpty)
          'short_id': r['short-id'].toString(),
      };
    }
    out['tls'] = tls;
  }

  static void _clashTransport(
    Map<String, dynamic> out,
    Map<String, dynamic> p,
  ) {
    final network = p['network']?.toString().toLowerCase() ?? '';
    if (network == 'ws') {
      final opts = p['ws-opts'] is Map
          ? Map<String, dynamic>.from(p['ws-opts'] as Map)
          : const <String, dynamic>{};
      final headers = opts['headers'] is Map
          ? Map<String, dynamic>.from(
              opts['headers'] as Map,
            ).map((k, v) => MapEntry(k, v.toString()))
          : <String, String>{};
      out['transport'] = <String, dynamic>{
        'type': 'ws',
        if ((opts['path']?.toString() ?? '').isNotEmpty)
          'path': opts['path'].toString(),
        if (headers.isNotEmpty) 'headers': headers,
      };
    } else if (network == 'grpc') {
      final opts = p['grpc-opts'] is Map
          ? Map<String, dynamic>.from(p['grpc-opts'] as Map)
          : const <String, dynamic>{};
      out['transport'] = <String, dynamic>{
        'type': 'grpc',
        if ((opts['grpc-service-name']?.toString() ?? '').isNotEmpty)
          'service_name': opts['grpc-service-name'].toString(),
      };
    } else if (network == 'http') {
      out['transport'] = <String, dynamic>{'type': 'http'};
    }
  }

  static String _clashTarget(
    String target,
    Map<String, String> groupNameToId,
    Map<String, NodeProfile> nameToNode,
  ) {
    final upper = target.toUpperCase();
    if (upper == 'DIRECT') return 'direct';
    if (upper == 'REJECT' || upper == 'REJECT-DROP') return 'block';
    if (groupNameToId.containsKey(target))
      return 'group:${groupNameToId[target]}';
    if (nameToNode.containsKey(target)) return 'node:${nameToNode[target]!.id}';
    return 'proxy';
  }

  static bool _hasMatchers(RouteRuleProfile r) =>
      r.domains.isNotEmpty ||
      r.domainSuffixes.isNotEmpty ||
      r.domainKeywords.isNotEmpty ||
      r.ipCidrs.isNotEmpty ||
      r.processNames.isNotEmpty ||
      r.network.isNotEmpty;

  static List<String> _strings(dynamic value) {
    if (value == null) return <String>[];
    if (value is List)
      return value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    return <String>[value.toString()];
  }

  static dynamic _plain(dynamic value) {
    if (value is YamlMap)
      return <String, dynamic>{
        for (final e in value.entries) e.key.toString(): _plain(e.value),
      };
    if (value is YamlList) return value.map(_plain).toList();
    return value;
  }

  static int _durationSeconds(String? value, int fallback) {
    if (value == null || value.isEmpty) return fallback;
    final m = RegExp(r'^(\d+)(s|m|h)?$').firstMatch(value.trim());
    if (m == null) return fallback;
    final n = int.tryParse(m.group(1)!) ?? fallback;
    switch (m.group(2)) {
      case 'h':
        return n * 3600;
      case 'm':
        return n * 60;
      default:
        return n;
    }
  }

  static List<NodeProfile> _dedupe(List<NodeProfile> input) {
    final seen = <String>{};
    return input.where((n) => seen.add(n.fingerprint)).toList();
  }

  static String _stableId(String source, String material) {
    var hash = 0xcbf29ce484222325;
    for (final unit in utf8.encode('$source|$material')) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return 'id-${hash.toRadixString(16).padLeft(16, '0')}';
  }

  static const Set<String> _proxyTypes = <String>{
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria',
    'hysteria2',
    'tuic',
    'socks',
    'http',
    'naive',
    'shadowtls',
    'anytls',
  };
}

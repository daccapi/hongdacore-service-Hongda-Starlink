import 'dart:io';

import 'models.dart';
import 'storage.dart';

class SingBoxConfigBuilder {
  SingBoxConfigBuilder(this.storage);

  final AppStorage storage;

  static String nodeTag(String nodeId) => 'node-${_safe(nodeId)}';
  static String groupTag(String groupId) => 'group-${_safe(groupId)}';

  Map<String, dynamic> build({
    required NodeProfile selectedNode,
    required List<NodeProfile> nodes,
    required List<ProxyGroupProfile> groups,
    required List<RouteRuleProfile> rules,
    required AppSettings settings,
  }) {
    final enabledNodes = nodes.where((n) => n.enabled).toList();
    if (!enabledNodes.any((n) => n.id == selectedNode.id))
      enabledNodes.insert(0, selectedNode);

    final outbounds = <Map<String, dynamic>>[];
    final tagByNodeId = <String, String>{};
    for (final node in enabledNodes) {
      final tag = nodeTag(node.id);
      tagByNodeId[node.id] = tag;
      outbounds.add(
        Map<String, dynamic>.from(node.outbound)
          ..remove('tag')
          ..['tag'] = tag,
      );
    }
    final selectedTag =
        tagByNodeId[selectedNode.id] ?? nodeTag(selectedNode.id);
    final nodeTags = tagByNodeId.values.toList();

    if (nodeTags.isNotEmpty) {
      outbounds.add(<String, dynamic>{
        'type': 'urltest',
        'tag': 'auto',
        'outbounds': nodeTags,
        'url': settings.urlTestUrl.trim().isEmpty
            ? 'https://www.gstatic.com/generate_204'
            : settings.urlTestUrl.trim(),
        'interval': '${settings.urlTestIntervalSeconds.clamp(10, 86400)}s',
        'tolerance': settings.urlTestToleranceMs.clamp(0, 10000),
        'interrupt_exist_connections': false,
      });
      outbounds.add(<String, dynamic>{
        'type': 'selector',
        'tag': 'proxy',
        'outbounds': <String>[...nodeTags, 'auto'],
        'default': selectedTag,
        'interrupt_exist_connections': true,
      });
    }

    final effectiveGroupIds = <String>{};
    for (final group in groups.where((g) => g.enabled)) {
      final members = group.nodeIds
          .map((id) => tagByNodeId[id])
          .whereType<String>()
          .toSet()
          .toList();
      if (members.isEmpty) continue;
      effectiveGroupIds.add(group.id);
      final tag = groupTag(group.id);
      if (group.type == 'urltest') {
        outbounds.add(<String, dynamic>{
          'type': 'urltest',
          'tag': tag,
          'outbounds': members,
          'url': group.testUrl.trim().isEmpty
              ? settings.urlTestUrl
              : group.testUrl.trim(),
          'interval': '${group.intervalSeconds.clamp(10, 86400)}s',
          'tolerance': group.toleranceMs.clamp(0, 10000),
          'interrupt_exist_connections': false,
        });
      } else {
        final defaultTag = tagByNodeId[group.selectedNodeId];
        outbounds.add(<String, dynamic>{
          'type': 'selector',
          'tag': tag,
          'outbounds': members,
          if (defaultTag != null && members.contains(defaultTag))
            'default': defaultTag,
          'interrupt_exist_connections': true,
        });
      }
    }

    outbounds.add(<String, dynamic>{'type': 'direct', 'tag': 'direct'});

    final inbounds = <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': settings.mixedPort,
      },
    ];
    if (settings.tunEnabled) {
      final addresses = <String>['172.19.0.1/30'];
      if (settings.ipv6Enabled) addresses.add('fdfe:dcba:9876::1/126');
      inbounds.add(<String, dynamic>{
        'type': 'tun',
        'tag': 'tun-in',
        'interface_name': 'HongdaTun',
        'address': addresses,
        'mtu': settings.tunMtu.clamp(1280, 9000),
        'auto_route': true,
        'strict_route': settings.strictRoute,
        'stack': settings.tunStack,
        // Split default routes are more reliable than replacing 0/0 on
        // Windows systems with VPN, Hyper-V or vendor network filters.
        'route_address': <String>[
          '0.0.0.0/1',
          '128.0.0.0/1',
          if (settings.ipv6Enabled) '::/1',
          if (settings.ipv6Enabled) '8000::/1',
        ],
      });
    }

    final endpoints = <Map<String, dynamic>>[];
    if (settings.tailscaleEnabled) {
      final tailscaleState = Directory(
        '${storage.baseDir.path}${Platform.pathSeparator}tailscale',
      );
      endpoints.add(<String, dynamic>{
        'type': 'tailscale',
        'tag': 'tailscale',
        'state_directory': tailscaleState.path,
        if (settings.tailscaleAuthKey.trim().isNotEmpty)
          'auth_key': settings.tailscaleAuthKey.trim(),
        if (settings.tailscaleControlUrl.trim().isNotEmpty)
          'control_url': settings.tailscaleControlUrl.trim(),
        if (settings.tailscaleHostname.trim().isNotEmpty)
          'hostname': settings.tailscaleHostname.trim(),
        'accept_routes': settings.tailscaleAcceptRoutes,
        if (settings.tailscaleExitNode.trim().isNotEmpty)
          'exit_node': settings.tailscaleExitNode.trim(),
        'exit_node_allow_lan_access': settings.tailscaleExitNodeAllowLanAccess,
        'system_interface': true,
        'system_interface_name': 'HongdaTail',
      });
    }

    final routeRules = <Map<String, dynamic>>[];
    if (settings.tunEnabled) {
      // DNS must be hijacked before the synthetic TUN peer guard. With
      // 172.19.0.1/30, sing-box uses the adjacent address for TUN DNS handling;
      // rejecting the entire /30 first can block DNS-dependent downloads.
      routeRules.add(<String, dynamic>{'port': 53, 'action': 'hijack-dns'});
    }
    if (settings.bypassLan) {
      routeRules.add(<String, dynamic>{
        'ip_is_private': true,
        'action': 'route',
        'outbound': 'direct',
      });
    }
    if (settings.routeMode == 'rule' || settings.routeMode == 'group') {
      for (final rule in rules.where((r) => r.enabled)) {
        final built = _buildRule(rule, effectiveGroupIds, tagByNodeId);
        if (built != null) routeRules.add(built);
      }
    }

    final routeRuleSets = <Map<String, dynamic>>[];
    if (settings.routeMode == 'rule') {
      if (settings.smartAdBlock) {
        routeRuleSets.add(_remoteRuleSet('karing-ban-ad', 'BanAD.srs'));
        routeRules.add(<String, dynamic>{
          'rule_set': 'karing-ban-ad',
          'action': 'reject',
        });
      }
      if (settings.smartCnDirect) {
        routeRuleSets.addAll(<Map<String, dynamic>>[
          _remoteRuleSet('karing-lan', 'LocalAreaNetwork.srs'),
          _remoteRuleSet('karing-cn-domain', 'ChinaDomain.srs'),
          _remoteRuleSet('karing-cn-ip', 'ChinaIp.srs'),
        ]);
        // Domain-only direct rules are evaluated before the proxy list. This
        // keeps blocked domains such as Google/Facebook/Twitter on the proxy
        // path even when a polluted resolver turns them into a China IP.
        routeRules.add(<String, dynamic>{
          'rule_set': <String>['karing-lan', 'karing-cn-domain'],
          'action': 'route',
          'outbound': 'direct',
        });
      }
      if (settings.smartProxyList) {
        routeRuleSets.add(_remoteRuleSet('karing-proxy-lite', 'ProxyLite.srs'));
        routeRules.add(<String, dynamic>{
          'rule_set': 'karing-proxy-lite',
          'action': 'route',
          'outbound': 'proxy',
        });
      }
      if (settings.smartCnDirect) {
        // China-IP fallback runs after the proxy list so IP-only traffic that
        // belongs to China still goes direct without hijacking domain matches.
        routeRules.add(<String, dynamic>{
          'rule_set': 'karing-cn-ip',
          'action': 'route',
          'outbound': 'direct',
        });
      }
    }

    final dns = _buildDns(settings);
    final finalOutbound = _finalOutbound(settings, effectiveGroupIds);

    return <String, dynamic>{
      'log': <String, dynamic>{'level': settings.logLevel, 'timestamp': true},
      'dns': dns,
      if (endpoints.isNotEmpty) 'endpoints': endpoints,
      'inbounds': inbounds,
      'outbounds': outbounds,
      'route': <String, dynamic>{
        'auto_detect_interface': true,
        'default_domain_resolver': 'local-dns',
        if (routeRuleSets.isNotEmpty) 'rule_set': routeRuleSets,
        'rules': routeRules,
        'final': finalOutbound,
      },
      'experimental': <String, dynamic>{
        'cache_file': <String, dynamic>{
          'enabled': true,
          'path': '${storage.runtimeDir.path}${Platform.pathSeparator}cache.db',
          'store_fakeip': settings.fakeIpEnabled,
        },
        'clash_api': <String, dynamic>{
          'external_controller': '127.0.0.1:${settings.apiPort}',
          'secret': settings.clashApiSecret,
        },
      },
    };
  }

  Map<String, dynamic> _remoteRuleSet(String tag, String fileName) {
    return <String, dynamic>{
      'type': 'remote',
      'tag': tag,
      'format': 'binary',
      'url':
          'https://fastly.jsdelivr.net/gh/karingX/karing-ruleset@sing/ACL4SSR/$fileName',
      'download_detour': 'proxy',
      'update_interval': '1d',
    };
  }

  Map<String, dynamic> _buildDns(AppSettings settings) {
    final servers = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'local', 'tag': 'local-dns', 'prefer_go': true},
    ];
    var finalTag = 'local-dns';

    if (settings.dnsMode == 'doh') {
      final uri = Uri.tryParse(settings.dnsPrimary.trim());
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) {
        servers.add(<String, dynamic>{
          'type': 'https',
          'tag': 'remote-dns',
          'server': uri.host,
          'server_port': uri.hasPort ? uri.port : 443,
          'path': uri.path.isEmpty ? '/dns-query' : uri.path,
          'tls': <String, dynamic>{'enabled': true, 'server_name': uri.host},
          'domain_resolver': 'local-dns',
          'detour': 'proxy',
        });
        finalTag = 'remote-dns';
      }
    }

    if (settings.fakeIpEnabled) {
      final upstream = finalTag;
      servers.add(<String, dynamic>{
        'type': 'fakeip',
        'tag': 'fakeip-dns',
        'server': upstream,
        'inet4_range': '198.18.0.0/15',
        if (settings.ipv6Enabled) 'inet6_range': 'fc00::/18',
      });
      finalTag = 'fakeip-dns';
    }

    return <String, dynamic>{
      'servers': servers,
      'strategy': settings.ipv6Enabled ? settings.dnsStrategy : 'ipv4_only',
      'final': finalTag,
      'independent_cache': true,
    };
  }

  Map<String, dynamic>? _buildRule(
    RouteRuleProfile rule,
    Set<String> effectiveGroupIds,
    Map<String, String> tagByNodeId,
  ) {
    final result = <String, dynamic>{};
    if (rule.domains.isNotEmpty) result['domain'] = rule.domains;
    if (rule.domainSuffixes.isNotEmpty)
      result['domain_suffix'] = rule.domainSuffixes;
    if (rule.domainKeywords.isNotEmpty)
      result['domain_keyword'] = rule.domainKeywords;
    if (rule.ipCidrs.isNotEmpty) result['ip_cidr'] = rule.ipCidrs;
    if (rule.processNames.isNotEmpty)
      result['process_name'] = rule.processNames;
    if (rule.network.isNotEmpty) result['network'] = rule.network;

    final hasMatcher = result.isNotEmpty;
    if (!hasMatcher && !rule.name.toUpperCase().startsWith('FINAL'))
      return null;

    if (rule.outbound == 'block') {
      result['action'] = 'reject';
    } else {
      result['action'] = 'route';
      result['outbound'] = _resolveOutbound(
        rule.outbound,
        effectiveGroupIds,
        tagByNodeId,
      );
    }
    return result;
  }

  String _finalOutbound(AppSettings settings, Set<String> effectiveGroupIds) {
    switch (settings.routeMode) {
      case 'direct':
        return 'direct';
      case 'auto':
        return 'auto';
      case 'group':
        if (effectiveGroupIds.contains(settings.selectedGroupId)) {
          return groupTag(settings.selectedGroupId);
        }
        return 'proxy';
      case 'global':
        return 'proxy';
      case 'rule':
      default:
        return 'proxy';
    }
  }

  String _resolveOutbound(
    String value,
    Set<String> effectiveGroupIds,
    Map<String, String> tagByNodeId,
  ) {
    if (value == 'direct' || value == 'auto' || value == 'proxy') return value;
    if (value.startsWith('group:')) {
      final id = value.substring('group:'.length);
      if (effectiveGroupIds.contains(id)) return groupTag(id);
    }
    if (value.startsWith('node:')) {
      final id = value.substring('node:'.length);
      final tag = tagByNodeId[id];
      if (tag != null) return tag;
    }
    return 'proxy';
  }

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}

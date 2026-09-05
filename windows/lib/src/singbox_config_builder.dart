import 'dart:io';

import 'models.dart';
import 'storage.dart';

class SingBoxConfigBuilder {
  SingBoxConfigBuilder(this.storage);

  final AppStorage storage;

  static String nodeTag(String nodeId) => 'node-${_safe(nodeId)}';
  static String groupTag(String groupId) => 'group-${_safe(groupId)}';

  static const Set<String> supportedProtocols = <String>{
    'vless',
    'trojan',
    'hysteria2',
    'tuic',
  };

  static bool supportsNode(NodeProfile node) =>
      supportedProtocols.contains(node.protocol.trim().toLowerCase());

  Map<String, dynamic> build({
    required NodeProfile selectedNode,
    required List<NodeProfile> nodes,
    required List<ProxyGroupProfile> groups,
    required List<RouteRuleProfile> rules,
    required AppSettings settings,
  }) {
    final enabledNodes = nodes
        .where((node) => node.enabled && supportsNode(node))
        .toList();
    if (!supportsNode(selectedNode)) {
      throw UnsupportedError(
        'HongdaCore 1.10 does not support ${selectedNode.protocol}',
      );
    }
    if (!enabledNodes.any((n) => n.id == selectedNode.id))
      enabledNodes.insert(0, selectedNode);

    final outbounds = <Map<String, dynamic>>[];
    final tagByNodeId = <String, String>{};
    for (final node in enabledNodes) {
      final tag = nodeTag(node.id);
      tagByNodeId[node.id] = tag;
      final outbound = Map<String, dynamic>.from(node.outbound)
        ..remove('tag')
        ..['tag'] = tag;
      if (settings.allowInsecureTls) {
        final rawTls = outbound['tls'];
        if (rawTls is Map) {
          outbound['tls'] = Map<String, dynamic>.from(rawTls)
            ..['insecure'] = true;
        }
      }
      outbounds.add(outbound);
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
      // Always capture IPv6 at the Windows routing layer. In IPv4-only mode
      // the route rules below reject it, which prevents physical-NIC leaks and
      // lets Happy Eyeballs fall back to the tunnelled IPv4 connection.
      addresses.add('fdfe:dcba:9876::1/126');
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
          '::/1',
          '8000::/1',
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
    if (settings.tunEnabled) {
      routeRules.add(<String, dynamic>{
        'ip_cidr': <String>['::/0'],
        'action': 'reject',
      });
    }
    if (settings.tunEnabled) {
      // Many VLESS servers do not provide reliable QUIC forwarding. Rejecting
      // only UDP/443 makes browsers immediately retry YouTube/Google over
      // TCP/TLS, which still follows the normal domain split rules.
      routeRules.add(<String, dynamic>{
        'network': 'udp',
        'port': 443,
        'action': 'reject',
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
      if (settings.smartProxyList) {
        routeRuleSets.addAll(<Map<String, dynamic>>[
          _remoteRuleSet('karing-proxy-lite', 'ProxyLite.srs'),
          _remoteRuleSet('karing-proxy-gfw', 'ProxyGFWlist.srs'),
        ]);
        // Keep critical OpenAI, Google and YouTube domains local to the
        // generated config. The larger lists contain most of them, but these
        // services must not depend on a remote list being complete.
        routeRules.add(<String, dynamic>{
          'domain_suffix': <String>[
            'openai.com',
            'chatgpt.com',
            'oaistatic.com',
            'oaiusercontent.com',
            'google.com',
            'googleapis.com',
            'gstatic.com',
            'googlevideo.com',
            'googleusercontent.com',
            'ggpht.com',
            'youtube.com',
            'youtube-nocookie.com',
            'youtu.be',
            'ytimg.com',
          ],
          'action': 'route',
          'outbound': 'proxy',
        });
      }
      if (settings.smartCnDirect) {
        routeRuleSets.addAll(<Map<String, dynamic>>[
          _remoteRuleSet('karing-lan', 'LocalAreaNetwork.srs'),
          _remoteRuleSet('karing-cn-domain', 'ChinaDomain.srs'),
          _remoteRuleSet('karing-cn-ip', 'ChinaIp.srs'),
          _remoteRuleSet('karing-download', 'Download.srs'),
        ]);
        // Windows Delivery Optimization can open dozens of parallel streams.
        // ProxyLite/GFW occasionally classify its CDN hostnames as proxy and
        // V1.6.18 consequently sent hundreds of megabytes of updates through
        // the selected VLESS node. Karing's Download group is direct and must
        // run before the broad proxy lists.
        routeRules.add(<String, dynamic>{
          'domain_suffix': <String>[
            'windowsupdate.com',
            'delivery.mp.microsoft.com',
            'update.microsoft.com',
            'download.microsoft.com',
            'officecdn.microsoft.com',
            'msftconnecttest.com',
            'msftncsi.com',
          ],
          'action': 'route',
          'outbound': 'direct',
        });
        routeRules.add(<String, dynamic>{
          'rule_set': 'karing-download',
          'action': 'route',
          'outbound': 'direct',
        });
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
        routeRules.add(<String, dynamic>{
          'rule_set': <String>['karing-proxy-lite', 'karing-proxy-gfw'],
          'action': 'route',
          'outbound': 'proxy',
        });
      }
      if (settings.smartCnDirect) {
        // China-IP fallback runs after the proxy list so IP-only traffic that
        // belongs to China still goes direct without hijacking domain matches.
        routeRules.add(<String, dynamic>{
          'rule_set': <String>['karing-cn-ip'],
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
      'download_fallback_url': <String>[
        'https://cdn.jsdelivr.net/gh/karingX/karing-ruleset@sing/ACL4SSR/$fileName',
        'https://raw.githubusercontent.com/karingX/karing-ruleset/sing/ACL4SSR/$fileName',
      ],
      // The route final remains the selected proxy. If a first-install rule
      // download is temporarily unavailable, an empty optional set therefore
      // keeps networking usable instead of blocking Core startup.
      'download_optional': true,
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
      });
      finalTag = 'fakeip-dns';
    }

    return <String, dynamic>{
      'servers': servers,
      // Windows TUN V1.6.14 deliberately runs IPv4-only. Stored settings from
      // older releases must never re-enable AAAA and bypass this guarantee.
      'strategy': settings.tunEnabled ? 'ipv4_only' : settings.dnsStrategy,
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
        // Karing-style routing: known China/download traffic is direct and all
        // remaining destinations use the selected node. Leaving unmatched
        // foreign resources direct caused long browser timeouts in V1.6.18.
        return 'proxy';
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

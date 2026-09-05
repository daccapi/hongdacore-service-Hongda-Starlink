import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongda_starlink/src/clash_traffic_counter.dart';
import 'package:hongda_starlink/src/models.dart';
import 'package:hongda_starlink/src/node_region.dart';
import 'package:hongda_starlink/src/singbox_config_builder.dart';
import 'package:hongda_starlink/src/singbox_controller.dart';
import 'package:hongda_starlink/src/selector_delay_probe.dart';
import 'package:hongda_starlink/src/storage.dart';
import 'package:hongda_starlink/src/windows_integration.dart';

NodeProfile _node({String name = 'vless-da', String? regionCode}) =>
    NodeProfile(
      id: 'node-1',
      name: name,
      protocol: 'vless',
      server: '192.0.2.10',
      port: 443,
      outbound: <String, dynamic>{
        'type': 'vless',
        'server': '192.0.2.10',
        'server_port': 443,
        'uuid': '00000000-0000-0000-0000-000000000000',
      },
      regionCode: regionCode,
    );

void main() {
  group('node region regression', () {
    test('recognizes country code concatenated with provider suffix', () {
      expect(nodeRegion(_node(name: 'vless-jpda')).code, 'JP');
      expect(nodeRegion(_node(name: 'HK01 Reality')).code, 'HK');
    });

    test('does not guess an ambiguous node and accepts explicit override', () {
      expect(nodeRegion(_node()).code, 'ZZ');
      expect(nodeRegion(_node(regionCode: 'US')).code, 'US');
      final located = _node(regionCode: 'CH')..regionName = '瑞士';
      expect(nodeRegion(located).name, '瑞士');
    });

    test('does not guess common English words as regions', () {
      expect(nodeRegion(_node(name: 'free-trial')).code, 'ZZ');
      expect(nodeRegion(_node(name: 'this-node')).code, 'ZZ');
      expect(nodeRegion(_node(name: 'phone-live')).code, 'ZZ');
      expect(nodeRegion(_node(name: 'running-hk')).code, 'HK');
    });
  });

  test('migrates V1.6.5 TCP reachability from red error state', () {
    final node = NodeProfile.fromJson(<String, dynamic>{
      'id': 'legacy',
      'name': 'vless-jpda',
      'protocol': 'vless',
      'server': '192.0.2.10',
      'port': 443,
      'outbound': <String, dynamic>{'type': 'vless'},
      'lastLatencyTest': '2026-08-13T01:32:03',
      'testError': 'TCP 端口可达（3 ms），但未完成代理握手；连接后可进行真实 URLTest',
    });

    expect(node.probeStatus, NodeProbeStatus.tcpReachable);
    expect(node.latencyMs, 3);
    expect(node.testError, isNull);
  });

  test('builds strict dual-stack Windows TUN without localhost proxy', () {
    final temp = Directory.systemTemp.createTempSync('hongda-config-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final settings = AppSettings(tunEnabled: true);
    final node = _node(name: 'vless-jpda');

    final config = builder.build(
      selectedNode: node,
      nodes: <NodeProfile>[node],
      groups: const <ProxyGroupProfile>[],
      rules: const <RouteRuleProfile>[],
      settings: settings,
    );
    final inbounds = config['inbounds'] as List<dynamic>;
    final tun = Map<String, dynamic>.from(inbounds[1] as Map);
    final route = Map<String, dynamic>.from(config['route'] as Map);
    final rules = route['rules'] as List<dynamic>;

    expect(tun['stack'], 'mixed');
    expect(tun['mtu'], 4064);
    expect(tun['strict_route'], isTrue);
    expect(tun['address'], <String>['172.19.0.1/30', 'fdfe:dcba:9876::1/126']);
    expect(tun['route_address'], <String>[
      '0.0.0.0/1',
      '128.0.0.0/1',
      '::/1',
      '8000::/1',
    ]);
    expect(settings.systemProxyEnabled, isFalse);
    expect(
      rules.whereType<Map>().any(
        (rule) => rule['ip_cidr']?.toString().contains('172.19.0.2') == true,
      ),
      isFalse,
    );
  });

  test('accepts endpoint-exclusion routes without literal split rows', () {
    const status = WindowsTunRoutingStatus(
      adapterFound: true,
      adapterUp: true,
      defaultRoute: false,
      splitRouteCount: 0,
      lowHalfRoute: true,
      highHalfRoute: true,
      effectiveRoute: true,
      ready: true,
    );

    expect(status.detail, contains('端点绕行分段路由'));
    expect(status.detail, isNot(contains('缺少')));
  });

  test('rejects a TUN route that captures only half of IPv4', () {
    const status = WindowsTunRoutingStatus(
      adapterFound: true,
      adapterUp: true,
      defaultRoute: false,
      splitRouteCount: 1,
      lowHalfRoute: true,
      highHalfRoute: false,
      effectiveRoute: false,
      ready: false,
    );

    expect(status.detail, contains('128.0.0.0/1'));
    expect(status.detail, contains('接管不完整'));
  });

  test('counts traffic from Clash totals after short connections close', () {
    final counter = ClashTrafficCounter();
    expect(
      counter.sample(<String, dynamic>{
        'uploadTotal': 100,
        'downloadTotal': 200,
        'connections': const <dynamic>[],
      })?.hasTraffic,
      isFalse,
    );

    final delta = counter.sample(<String, dynamic>{
      'uploadTotal': '350',
      'downloadTotal': 900,
      'connections': const <dynamic>[],
    });
    expect(delta?.upload, 250);
    expect(delta?.download, 700);

    final reset = counter.sample(<String, dynamic>{
      'uploadTotal': 5,
      'downloadTotal': 9,
    });
    expect(reset?.hasTraffic, isFalse);
  });

  test('builds only protocols implemented by HongdaCore 1.10', () {
    final temp = Directory.systemTemp.createTempSync('hongda-protocol-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final selected = _node();
    final unsupported = NodeProfile(
      id: 'ss-1',
      name: 'legacy shadowsocks',
      protocol: 'shadowsocks',
      server: '192.0.2.20',
      port: 443,
      outbound: <String, dynamic>{'type': 'shadowsocks'},
    );
    final config = builder.build(
      selectedNode: selected,
      nodes: <NodeProfile>[selected, unsupported],
      groups: const <ProxyGroupProfile>[],
      rules: const <RouteRuleProfile>[],
      settings: AppSettings(mixedPort: 17891, apiPort: 19091),
    );
    final outbounds = (config['outbounds'] as List<dynamic>)
        .whereType<Map>()
        .map((item) => item['tag']?.toString())
        .toList();
    expect(outbounds, contains(SingBoxConfigBuilder.nodeTag(selected.id)));
    expect(
      outbounds,
      isNot(contains(SingBoxConfigBuilder.nodeTag(unsupported.id))),
    );
    final inbound = Map<String, dynamic>.from(
      (config['inbounds'] as List<dynamic>).first as Map,
    );
    expect(inbound['listen_port'], 17891);
    final clash = Map<String, dynamic>.from(
      (Map<String, dynamic>.from(config['experimental'] as Map))['clash_api']
          as Map,
    );
    expect(clash['external_controller'], '127.0.0.1:19091');
  });

  test('TLS compatibility is opt-in and only changes proxy entry TLS', () {
    final temp = Directory.systemTemp.createTempSync('hongda-insecure-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final node = _node();
    node.outbound['tls'] = <String, dynamic>{
      'enabled': true,
      'server_name': 'expired.example',
    };

    Map<String, dynamic> nodeOutbound(bool enabled) {
      final config = builder.build(
        selectedNode: node,
        nodes: <NodeProfile>[node],
        groups: const <ProxyGroupProfile>[],
        rules: const <RouteRuleProfile>[],
        settings: AppSettings(allowInsecureTls: enabled),
      );
      return (config['outbounds'] as List<dynamic>)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .firstWhere((item) => item['type'] == 'vless');
    }

    expect(
      Map<String, dynamic>.from(nodeOutbound(false)['tls'] as Map)['insecure'],
      isNull,
    );
    expect(
      Map<String, dynamic>.from(nodeOutbound(true)['tls'] as Map)['insecure'],
      isTrue,
    );
    expect(
      Map<String, dynamic>.from(node.outbound['tls'] as Map)['insecure'],
      isNull,
    );
  });

  test('uses Karing-style China/download direct with proxy final fallback', () {
    final temp = Directory.systemTemp.createTempSync('hongda-route-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final node = _node();
    final config = builder.build(
      selectedNode: node,
      nodes: <NodeProfile>[node],
      groups: const <ProxyGroupProfile>[],
      rules: const <RouteRuleProfile>[],
      settings: AppSettings(
        routeMode: 'rule',
        smartCnDirect: true,
        smartProxyList: true,
        ipv6Enabled: false,
      ),
    );
    final route = Map<String, dynamic>.from(config['route'] as Map);
    final ruleSets = (route['rule_set'] as List<dynamic>)
        .whereType<Map>()
        .map((item) => item['tag']?.toString())
        .toList();
    final rules = (route['rules'] as List<dynamic>).whereType<Map>().toList();

    int ruleIndex(String tag) => rules.indexWhere((rule) {
      final value = rule['rule_set'];
      return value == tag || (value is List && value.contains(tag));
    });

    expect(route['final'], 'proxy');
    expect(
      ruleSets,
      containsAll(<String>[
        'karing-proxy-lite',
        'karing-proxy-gfw',
        'karing-cn-domain',
        'karing-cn-ip',
        'karing-download',
      ]),
    );
    final openAiIndex = rules.indexWhere((rule) {
      final suffixes = rule['domain_suffix'];
      return suffixes is List && suffixes.contains('chatgpt.com');
    });
    expect(openAiIndex, isNonNegative);
    final criticalDomains =
        rules[openAiIndex]['domain_suffix'] as List<dynamic>;
    expect(
      criticalDomains,
      containsAll(<String>[
        'google.com',
        'googlevideo.com',
        'youtube.com',
        'ytimg.com',
      ]),
    );
    expect(openAiIndex, lessThan(ruleIndex('karing-cn-domain')));
    expect(ruleIndex('karing-download'), isNonNegative);
    expect(
      ruleIndex('karing-download'),
      lessThan(ruleIndex('karing-proxy-gfw')),
    );
    expect(
      ruleIndex('karing-cn-domain'),
      lessThan(ruleIndex('karing-proxy-gfw')),
    );
    expect(ruleIndex('karing-proxy-gfw'), lessThan(ruleIndex('karing-cn-ip')));
  });

  test('TUN captures IPv6, rejects leaks, and forces QUIC TCP fallback', () {
    final temp = Directory.systemTemp.createTempSync('hongda-ipv6-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final node = _node();
    final config = builder.build(
      selectedNode: node,
      nodes: <NodeProfile>[node],
      groups: const <ProxyGroupProfile>[],
      rules: const <RouteRuleProfile>[],
      settings: AppSettings(tunEnabled: true, ipv6Enabled: false),
    );
    final inbound = (config['inbounds'] as List<dynamic>)
        .whereType<Map>()
        .firstWhere((item) => item['type'] == 'tun');
    expect(inbound['address'], contains('fdfe:dcba:9876::1/126'));
    expect(inbound['route_address'], containsAll(<String>['::/1', '8000::/1']));

    final rules =
        (Map<String, dynamic>.from(config['route'] as Map)['rules']
                as List<dynamic>)
            .whereType<Map>()
            .toList();
    expect(
      rules.any((rule) {
        final cidr = rule['ip_cidr'];
        return cidr is List &&
            cidr.contains('::/0') &&
            rule['action'] == 'reject';
      }),
      isTrue,
    );
    expect(
      rules.any(
        (rule) =>
            rule['network'] == 'udp' &&
            rule['port'] == 443 &&
            rule['action'] == 'reject',
      ),
      isTrue,
    );
    final dns = Map<String, dynamic>.from(config['dns'] as Map);
    expect(dns['strategy'], 'ipv4_only');
  });

  test('stored IPv6 preferences cannot override Windows TUN IPv4-only', () {
    final temp = Directory.systemTemp.createTempSync('hongda-ipv4-only-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final node = _node();
    final config = builder.build(
      selectedNode: node,
      nodes: <NodeProfile>[node],
      groups: const <ProxyGroupProfile>[],
      rules: const <RouteRuleProfile>[],
      settings: AppSettings(
        tunEnabled: true,
        ipv6Enabled: true,
        dnsStrategy: 'prefer_ipv4',
      ),
    );
    final dns = Map<String, dynamic>.from(config['dns'] as Map);
    expect(dns['strategy'], 'ipv4_only');
    final route = Map<String, dynamic>.from(config['route'] as Map);
    final ruleSetTags = (route['rule_set'] as List<dynamic>)
        .whereType<Map>()
        .map((item) => item['tag'])
        .toList();
    expect(ruleSetTags, isNot(contains('karing-cn-ipv6')));
    final rules = (route['rules'] as List<dynamic>).whereType<Map>();
    expect(
      rules.any((rule) {
        final cidr = rule['ip_cidr'];
        return cidr is List && cidr.contains('::/0');
      }),
      isTrue,
    );
  });

  test('parses detailed connection log metadata', () {
    final entry = ConnectionLogEntry.fromJson(<String, dynamic>{
      'id': '42',
      'network': 'tcp',
      'source': '172.19.0.2:50000',
      'destination': '142.250.72.14:443',
      'domain': 'www.youtube.com',
      'route': 'proxy',
      'outbound': 'node-test',
      'rule': '规则 5 · 域名',
      'startedAt': '2026-08-21T01:02:03Z',
      'status': 'active',
      'upload': 1234,
      'download': 5678,
    });
    expect(entry.network, 'TCP');
    expect(entry.target, 'www.youtube.com');
    expect(entry.active, isTrue);
    expect(entry.total, 6912);
    expect(entry.startedAt, isNotNull);
  });

  test(
    'falls back when one selector HTTPS delay target has a bad certificate',
    () async {
      final attempted = <String>[];
      final result = await probeSelectorDelay(
        configuredUrl: 'https://www.gstatic.com/generate_204',
        request: (target) async {
          attempted.add(target);
          if (target.contains('gstatic.com') && target.startsWith('https://')) {
            throw const HttpException('x509: certificate has expired');
          }
          return <String, dynamic>{'delay': 86};
        },
      );

      expect(result.succeeded, isTrue);
      expect(result.delayMs, 86);
      expect(attempted, <String>[
        'https://www.gstatic.com/generate_204',
        'https://cp.cloudflare.com/generate_204',
      ]);
    },
  );

  test(
    'all selector delay failures return a warning result instead of throwing',
    () async {
      final result = await probeSelectorDelay(
        configuredUrl: 'https://www.gstatic.com/generate_204',
        request: (_) async =>
            throw const HttpException('temporary probe failure'),
      );

      expect(result.succeeded, isFalse);
      expect(result.delayMs, isNull);
      expect(result.error, contains('temporary probe failure'));
    },
  );

  test('native exit recovery rejects dead localhost proxy snapshots', () {
    final source = File('windows/runner/flutter_window.cpp').readAsStringSync();
    expect(source, contains('CanRestoreEnabledProxy'));
    expect(source, contains('IsTcpPortListening'));
    expect(source, contains('current_server == previous_server'));
    expect(source, contains('SetSystemProxy(false, L"", L"");'));
  });

  test('migrates unsupported Tailscale switch off', () async {
    final temp = Directory.systemTemp.createTempSync('hongda-settings-test-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final storage = AppStorage.forDirectory(temp);
    await storage.saveSettings(
      AppSettings(tailscaleEnabled: true, fakeIpEnabled: true),
    );
    final loaded = await storage.loadSettings();
    expect(loaded.tailscaleEnabled, isFalse);
    expect(loaded.fakeIpEnabled, isFalse);
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongda_starlink/src/clash_traffic_counter.dart';
import 'package:hongda_starlink/src/models.dart';
import 'package:hongda_starlink/src/node_region.dart';
import 'package:hongda_starlink/src/singbox_config_builder.dart';
import 'package:hongda_starlink/src/storage.dart';

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
    expect(tun['mtu'], 1500);
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
}

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongda_starlink/src/latency_metrics.dart';
import 'package:hongda_starlink/src/models.dart';
import 'package:hongda_starlink/src/node_health.dart';
import 'package:hongda_starlink/src/singbox_config_builder.dart';
import 'package:hongda_starlink/src/storage.dart';
import 'package:hongda_starlink/src/tun_watchdog_health.dart';

NodeProfile node(String id, {String protocol = 'vless'}) => NodeProfile(
  id: id,
  name: id,
  protocol: protocol,
  server: '192.0.2.1',
  port: 443,
  outbound: {
    'type': protocol,
    'server': '192.0.2.1',
    'server_port': 443,
    'uuid': '00000000-0000-0000-0000-000000000001',
    'password': 'test-only',
  },
);

void main() {
  test('automatic selection requires working proxy and ranks full probe', () {
    final tcp = node('tcp')
      ..latencyMs = 1
      ..probeStatus = NodeProbeStatus.tcpReachable;
    final slow = node('slow')
      ..latencyMs = 10
      ..proxyTotalDelayMs = 800
      ..probeStatus = NodeProbeStatus.proxyAvailable;
    final fast = node('fast')
      ..latencyMs = 50
      ..proxyTotalDelayMs = 200
      ..probeStatus = NodeProbeStatus.proxyAvailable;
    final legacy = node('legacy')
      ..latencyMs = 1
      ..probeStatus = NodeProbeStatus.proxyAvailable;
    final disabled = node('disabled')
      ..proxyTotalDelayMs = 2
      ..probeStatus = NodeProbeStatus.proxyAvailable
      ..enabled = false;
    expect(
      verifiedProxyCandidates([
        tcp,
        slow,
        fast,
        legacy,
        disabled,
      ]).map((n) => n.id),
      ['fast', 'slow'],
    );
  });
  test('QUIC nodes never use a TCP endpoint probe', () {
    expect(supportsEndpointTcpProbe(node('vless')), isTrue);
    expect(
      supportsEndpointTcpProbe(node('trojan', protocol: 'trojan')),
      isTrue,
    );
    expect(
      supportsEndpointTcpProbe(node('hy2', protocol: 'hysteria2')),
      isFalse,
    );
    expect(supportsEndpointTcpProbe(node('tuic', protocol: 'tuic')), isFalse);
  });
  test(
    'HTTPS failure retries next cycle and cannot recover on routes alone',
    () {
      final health = TunWatchdogHealth();
      for (var i = 0; i < 9; i++) {
        expect(health.nextRouteHealthyCycleNeedsHttps(), isFalse);
      }
      expect(health.nextRouteHealthyCycleNeedsHttps(), isTrue);
      health.recordHttps(succeeded: false);
      for (var i = 0; i < 3; i++) {
        expect(health.nextRouteHealthyCycleNeedsHttps(), isTrue);
        health.recordHttps(succeeded: false);
      }
      health.recordHttps(succeeded: true);
      expect(health.nextRouteHealthyCycleNeedsHttps(), isFalse);
      health.reset();
      expect(health.nextRouteHealthyCycleNeedsHttps(), isFalse);
    },
  );
  test('API failure status is not a successful latency measurement', () {
    for (final status in [301, 403, 503]) {
      expect(
        ProxyDelayMetrics.fromJson({'delay': 20, 'status': status}).succeeded,
        isFalse,
      );
    }
    expect(
      ProxyDelayMetrics.fromJson({'delay': 20, 'status': 204}).succeeded,
      isTrue,
    );
  });
  test('malformed unselected nodes cannot poison a valid config', () {
    final temp = Directory.systemTemp.createTempSync('hongda-1625-health-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final selected = node('valid');
    final invalids = [
      node('uuid')..outbound['uuid'] = 'not-a-uuid',
      node('server')..outbound['server'] = '',
      node('port')..outbound['server_port'] = 65536,
      node('type')..outbound['type'] = 'tuic',
      node('password', protocol: 'trojan')..outbound.remove('password'),
    ];
    for (final invalid in invalids) {
      expect(SingBoxConfigBuilder.supportsNode(invalid), isFalse);
    }
    final builder = SingBoxConfigBuilder(AppStorage.forDirectory(temp));
    final config = builder.build(
      selectedNode: selected,
      nodes: [selected, ...invalids],
      groups: [],
      rules: [],
      settings: AppSettings(),
    );
    final tags = (config['outbounds'] as List).whereType<Map>().map(
      (o) => o['tag'],
    );
    expect(tags, contains(SingBoxConfigBuilder.nodeTag(selected.id)));
    for (final invalid in invalids) {
      expect(tags, isNot(contains(SingBoxConfigBuilder.nodeTag(invalid.id))));
    }
  });
}

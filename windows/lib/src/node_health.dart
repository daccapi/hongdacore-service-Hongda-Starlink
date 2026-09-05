import 'models.dart';
import 'singbox_config_builder.dart';

bool supportsEndpointTcpProbe(NodeProfile node) =>
    const {'vless', 'trojan'}.contains(node.protocol.trim().toLowerCase());

List<NodeProfile> verifiedProxyCandidates(Iterable<NodeProfile> nodes) =>
    nodes
        .where(
          (node) =>
              node.enabled &&
              SingBoxConfigBuilder.supportsNode(node) &&
              node.probeStatus == NodeProbeStatus.proxyAvailable &&
              node.proxyTotalDelayMs != null &&
              node.proxyTotalDelayMs! > 0,
        )
        .toList()
      ..sort((a, b) => a.proxyTotalDelayMs!.compareTo(b.proxyTotalDelayMs!));

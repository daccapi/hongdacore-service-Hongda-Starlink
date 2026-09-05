import 'latency_metrics.dart';

class SelectorDelayProbeResult {
  const SelectorDelayProbeResult({
    required this.delayMs,
    required this.connectDelayMs,
    required this.target,
    required this.error,
  });

  final int? delayMs;
  final int? connectDelayMs;
  final String? target;
  final String? error;

  bool get succeeded => delayMs != null && delayMs! > 0;
}

typedef SelectorDelayRequest =
    Future<Map<String, dynamic>> Function(String target);

List<String> selectorDelayTargets(String configuredUrl) {
  final targets = <String>{};
  final configured = configuredUrl.trim();
  final parsed = Uri.tryParse(configured);
  if (parsed != null &&
      parsed.host.isNotEmpty &&
      (parsed.scheme == 'http' || parsed.scheme == 'https')) {
    targets.add(configured);
  }
  targets.addAll(const <String>[
    'https://cp.cloudflare.com/generate_204',
    'https://www.gstatic.com/generate_204',
    // This final probe is deliberately HTTP. It is only a latency/reachability
    // fallback when a single HTTPS test certificate is bad; it is never used
    // to weaken TLS validation for real application traffic.
    'http://www.gstatic.com/generate_204',
  ]);
  return targets.toList(growable: false);
}

Future<SelectorDelayProbeResult> probeSelectorDelay({
  required String configuredUrl,
  required SelectorDelayRequest request,
}) async {
  Object? lastError;
  for (final target in selectorDelayTargets(configuredUrl)) {
    try {
      final response = await request(target);
      final metrics = ProxyDelayMetrics.fromJson(response);
      if (metrics.succeeded) {
        return SelectorDelayProbeResult(
          delayMs: metrics.totalDelayMs,
          connectDelayMs: metrics.connectDelayMs,
          target: target,
          error: null,
        );
      }
      lastError = 'API 未返回有效延迟';
    } catch (error) {
      lastError = error;
    }
  }
  return SelectorDelayProbeResult(
    delayMs: null,
    connectDelayMs: null,
    target: null,
    error: lastError?.toString() ?? '所有延迟探针均失败',
  );
}

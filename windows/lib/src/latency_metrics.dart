class ProxyDelayMetrics {
  const ProxyDelayMetrics({
    required this.connectDelayMs,
    required this.totalDelayMs,
  });

  final int? connectDelayMs;
  final int? totalDelayMs;

  bool get succeeded => totalDelayMs != null;

  factory ProxyDelayMetrics.fromJson(Map<String, dynamic> json) {
    final clashDelay = _positiveInt(json['delay']);
    return ProxyDelayMetrics(
      connectDelayMs: _positiveInt(json['connectDelay']),
      totalDelayMs: _positiveInt(json['totalDelay']) ?? clashDelay,
    );
  }
}

int? displayedNodeLatency({
  required int? endpointRttMs,
  required ProxyDelayMetrics proxy,
}) {
  return _positiveInt(endpointRttMs) ??
      proxy.connectDelayMs ??
      proxy.totalDelayMs;
}

int? _positiveInt(dynamic value) {
  final parsed = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

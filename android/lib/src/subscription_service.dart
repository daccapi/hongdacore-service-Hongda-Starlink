import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config_importer.dart';
import 'models.dart';

class SubscriptionFetchResult {
  SubscriptionFetchResult({
    required this.imported,
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expiresAt,
  });

  final ConfigImportResult imported;
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final DateTime? expiresAt;
}

class SubscriptionService {
  static Future<SubscriptionFetchResult> fetch(SubscriptionProfile subscription) async {
    final uri = Uri.tryParse(subscription.url.trim());
    if (uri == null || !uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const FormatException('订阅 URL 必须是 http:// 或 https://');
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..userAgent = subscription.userAgent.trim().isEmpty ? 'HongdaStarlink/1.1' : subscription.userAgent.trim();
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptHeader, 'text/plain, application/json, application/yaml, text/yaml, */*');
      request.headers.set('Profile-Update-Interval', '24');
      final response = await request.close().timeout(const Duration(seconds: 35));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final content = await response.transform(const Utf8Decoder(allowMalformed: true)).join();
      final imported = ConfigImporter.parse(content, source: subscription.id);
      if (imported.nodes.isEmpty) {
        throw const FormatException('订阅已下载，但没有识别到支持的节点');
      }

      final info = _parseUserInfo(response.headers.value('subscription-userinfo'));
      return SubscriptionFetchResult(
        imported: imported,
        uploadBytes: info['upload'],
        downloadBytes: info['download'],
        totalBytes: info['total'],
        expiresAt: info['expire'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(info['expire']! * 1000, isUtc: true).toLocal(),
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<List<NodeProfile>> fetchNodes(SubscriptionProfile subscription) async {
    return (await fetch(subscription)).imported.nodes;
  }

  static Map<String, int> _parseUserInfo(String? header) {
    final result = <String, int>{};
    if (header == null || header.trim().isEmpty) return result;
    for (final part in header.split(';')) {
      final pair = part.trim().split('=');
      if (pair.length != 2) continue;
      final key = pair.first.trim().toLowerCase();
      final value = int.tryParse(pair.last.trim());
      if (value != null && <String>{'upload', 'download', 'total', 'expire'}.contains(key)) {
        result[key] = value;
      }
    }
    return result;
  }
}

import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'node_region.dart';

class NodeGeolocationService {
  const NodeGeolocationService();

  Future<bool> resolve(NodeProfile node, {bool force = false}) async {
    if (node.regionSource == 'manual') return false;
    if (!force && node.regionCode != null) return false;
    if (!force && nodeRegion(node).isKnown) return false;
    final lastLookup = node.regionLookupAt;
    if (!force &&
        lastLookup != null &&
        DateTime.now().difference(lastLookup) < const Duration(days: 1)) {
      return false;
    }

    node.regionLookupAt = DateTime.now();
    try {
      final address = await _publicAddress(node.server);
      if (address == null) {
        node.regionLookupError = '服务器没有可用于定位的公网 IP';
        return false;
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..userAgent = 'HongdaStarlink/1.6.8 Windows';
      try {
        final uri = Uri.https(
          'ipwho.is',
          '/${address.address}',
          <String, String>{'lang': 'zh-CN'},
        );
        final request = await client.getUrl(uri);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(
          const Duration(seconds: 7),
        );
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}', uri: uri);
        }
        final decoded = jsonDecode(body);
        if (decoded is! Map || decoded['success'] == false) {
          throw FormatException(
            decoded is Map
                ? decoded['message']?.toString() ?? '定位服务返回失败'
                : '定位服务返回格式无效',
          );
        }
        final code = decoded['country_code']?.toString().trim().toUpperCase();
        if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
          throw const FormatException('定位服务没有返回国家代码');
        }
        node.regionCode = code;
        final country = decoded['country']?.toString().trim();
        node.regionName = country == null || country.isEmpty ? null : country;
        node.regionSource = 'geoip';
        node.regionLookupError = null;
        return true;
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      node.regionLookupError = error
          .toString()
          .replaceFirst('HttpException: ', '')
          .replaceFirst('FormatException: ', '');
      return false;
    }
  }

  Future<InternetAddress?> _publicAddress(String server) async {
    final literal = InternetAddress.tryParse(server.trim());
    final addresses = literal == null
        ? await InternetAddress.lookup(
            server.trim(),
          ).timeout(const Duration(seconds: 5))
        : <InternetAddress>[literal];
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv4 && _isPublicV4(address)) {
        return address;
      }
    }
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv6 && _isPublicV6(address)) {
        return address;
      }
    }
    return null;
  }

  bool _isPublicV4(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 4) return false;
    final a = bytes[0];
    final b = bytes[1];
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    return true;
  }

  bool _isPublicV6(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length != 16) return false;
    final allZeroExceptLast = bytes.take(15).every((value) => value == 0);
    if (allZeroExceptLast && bytes.last <= 1) return false;
    if ((bytes[0] & 0xFE) == 0xFC) return false;
    if (bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80) return false;
    if (bytes[0] == 0xFF) return false;
    return true;
  }
}

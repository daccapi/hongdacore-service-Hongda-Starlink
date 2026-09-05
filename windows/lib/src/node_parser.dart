import 'dart:convert';
import 'dart:math';

import 'models.dart';

class NodeParser {
  static final Random _random = Random.secure();

  static List<NodeProfile> parseMany(
    String content, {
    String source = 'manual',
  }) {
    var normalized = content.trim();
    if (normalized.isEmpty) return <NodeProfile>[];

    if (!normalized.contains('://') &&
        !normalized.startsWith('{') &&
        !normalized.startsWith('[')) {
      final decoded = _tryBase64Decode(normalized);
      if (decoded != null && decoded.contains('://')) normalized = decoded;
    }

    if (normalized.startsWith('{')) {
      try {
        final json = jsonDecode(normalized);
        if (json is Map && json['outbounds'] is List) {
          final result = <NodeProfile>[];
          for (final item in json['outbounds'] as List<dynamic>) {
            if (item is! Map) continue;
            final outbound = Map<String, dynamic>.from(item);
            final type = outbound['type']?.toString() ?? '';
            if (_isProxyType(type)) {
              result.add(_fromOutbound(outbound, source: source));
            }
          }
          return result;
        }
      } catch (_) {}
    }

    final result = <NodeProfile>[];
    final lines = normalized
        .split(RegExp(r'[\r\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty && !e.startsWith('#'));
    for (final line in lines) {
      final node = parseOne(line, source: source);
      if (node != null) result.add(node);
    }
    return result;
  }

  static NodeProfile? parseOne(String value, {String source = 'manual'}) {
    final input = value.trim();
    if (input.isEmpty) return null;
    final lower = input.toLowerCase();
    if (lower.startsWith('vmess://')) return _parseVmess(input, source);
    if (lower.startsWith('ss://')) return _parseShadowsocks(input, source);

    Uri uri;
    try {
      uri = Uri.parse(input);
    } catch (_) {
      return null;
    }

    switch (uri.scheme.toLowerCase()) {
      case 'vless':
        return _parseVless(uri, source);
      case 'trojan':
        return _parseTrojan(uri, source);
      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(uri, source);
      case 'socks':
      case 'socks5':
        return _parseSocks(uri, source);
      default:
        return null;
    }
  }

  static NodeProfile _parseVless(Uri uri, String source) {
    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'vless',
      'server': uri.host,
      'server_port': uri.port == 0 ? 443 : uri.port,
      'uuid': uri.userInfo,
    };
    final flow = q['flow'];
    if (flow != null && flow.isNotEmpty) outbound['flow'] = flow;
    _applyTlsAndTransport(
      outbound,
      q,
      defaultTls: q['security'] == 'tls' || q['security'] == 'reality',
    );
    return _nodeFromUri(uri, 'vless', outbound, source);
  }

  static NodeProfile _parseTrojan(Uri uri, String source) {
    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'trojan',
      'server': uri.host,
      'server_port': uri.port == 0 ? 443 : uri.port,
      'password': Uri.decodeComponent(uri.userInfo),
    };
    _applyTlsAndTransport(outbound, q, defaultTls: true);
    return _nodeFromUri(uri, 'trojan', outbound, source);
  }

  static NodeProfile _parseHysteria2(Uri uri, String source) {
    final q = uri.queryParameters;
    final outbound = <String, dynamic>{
      'type': 'hysteria2',
      'server': uri.host,
      'server_port': uri.port == 0 ? 443 : uri.port,
      'password': Uri.decodeComponent(uri.userInfo),
    };
    _applyTls(outbound, q, defaultTls: true);
    final obfs = q['obfs'];
    final obfsPassword = q['obfs-password'] ?? q['obfsPassword'];
    if (obfs != null && obfs.isNotEmpty) {
      outbound['obfs'] = <String, dynamic>{
        'type': obfs,
        if (obfsPassword != null && obfsPassword.isNotEmpty)
          'password': obfsPassword,
      };
    }
    return _nodeFromUri(uri, 'hysteria2', outbound, source);
  }

  static NodeProfile _parseSocks(Uri uri, String source) {
    final outbound = <String, dynamic>{
      'type': 'socks',
      'server': uri.host,
      'server_port': uri.port == 0 ? 1080 : uri.port,
      'version': '5',
    };
    if (uri.userInfo.isNotEmpty) {
      final parts = uri.userInfo.split(':');
      outbound['username'] = Uri.decodeComponent(parts.first);
      if (parts.length > 1)
        outbound['password'] = Uri.decodeComponent(parts.sublist(1).join(':'));
    }
    return _nodeFromUri(uri, 'socks', outbound, source);
  }

  static NodeProfile? _parseVmess(String input, String source) {
    try {
      final raw = input.substring('vmess://'.length);
      final decoded = _decodeBase64(raw);
      final json = Map<String, dynamic>.from(jsonDecode(decoded) as Map);
      final server = json['add']?.toString() ?? '';
      final port = int.tryParse(json['port']?.toString() ?? '') ?? 443;
      if (server.isEmpty) return null;
      final outbound = <String, dynamic>{
        'type': 'vmess',
        'server': server,
        'server_port': port,
        'uuid': json['id']?.toString() ?? '',
        'security': (json['scy']?.toString() ?? '').isNotEmpty
            ? json['scy'].toString()
            : 'auto',
        'alter_id': int.tryParse(json['aid']?.toString() ?? '') ?? 0,
      };
      final tls = json['tls']?.toString();
      final q = <String, String>{
        'security': tls == 'tls' ? 'tls' : 'none',
        'sni': json['sni']?.toString() ?? '',
        'type': json['net']?.toString() ?? '',
        'path': json['path']?.toString() ?? '',
        'host': json['host']?.toString() ?? '',
        'serviceName': json['path']?.toString() ?? '',
      };
      _applyTlsAndTransport(outbound, q, defaultTls: tls == 'tls');
      return NodeProfile(
        id: _id(),
        name: (json['ps']?.toString() ?? '').isNotEmpty
            ? json['ps'].toString()
            : '$server:$port',
        protocol: 'vmess',
        server: server,
        port: port,
        outbound: outbound,
        source: source,
      );
    } catch (_) {
      return null;
    }
  }

  static NodeProfile? _parseShadowsocks(String input, String source) {
    try {
      var rest = input.substring('ss://'.length);
      String name = 'Shadowsocks';
      final hash = rest.indexOf('#');
      if (hash >= 0) {
        name = Uri.decodeComponent(rest.substring(hash + 1));
        rest = rest.substring(0, hash);
      }
      final question = rest.indexOf('?');
      if (question >= 0) rest = rest.substring(0, question);

      String userInfo;
      String hostPort;
      final at = rest.lastIndexOf('@');
      if (at >= 0) {
        userInfo = rest.substring(0, at);
        hostPort = rest.substring(at + 1);
        if (!userInfo.contains(':')) userInfo = _decodeBase64(userInfo);
      } else {
        final decoded = _decodeBase64(rest);
        final decodedAt = decoded.lastIndexOf('@');
        if (decodedAt < 0) return null;
        userInfo = decoded.substring(0, decodedAt);
        hostPort = decoded.substring(decodedAt + 1);
      }
      final split = userInfo.indexOf(':');
      if (split < 0) return null;
      final method = userInfo.substring(0, split);
      final password = userInfo.substring(split + 1);

      final hp = Uri.parse('ss://x@$hostPort');
      final server = hp.host;
      final port = hp.port;
      if (server.isEmpty || port == 0) return null;
      return NodeProfile(
        id: _id(),
        name: name.isEmpty ? '$server:$port' : name,
        protocol: 'shadowsocks',
        server: server,
        port: port,
        outbound: <String, dynamic>{
          'type': 'shadowsocks',
          'server': server,
          'server_port': port,
          'method': method,
          'password': password,
        },
        source: source,
      );
    } catch (_) {
      return null;
    }
  }

  static NodeProfile _fromOutbound(
    Map<String, dynamic> outbound, {
    required String source,
  }) {
    final type = outbound['type']?.toString() ?? 'unknown';
    final server = outbound['server']?.toString() ?? '';
    final port = int.tryParse(outbound['server_port']?.toString() ?? '') ?? 0;
    return NodeProfile(
      id: _id(),
      name: (outbound['tag']?.toString() ?? '').isNotEmpty
          ? outbound['tag'].toString()
          : '$type $server:$port',
      protocol: type,
      server: server,
      port: port,
      outbound: Map<String, dynamic>.from(outbound)..remove('tag'),
      source: source,
    );
  }

  static NodeProfile _nodeFromUri(
    Uri uri,
    String protocol,
    Map<String, dynamic> outbound,
    String source,
  ) {
    final port = outbound['server_port'] as int;
    final fragment = Uri.decodeComponent(uri.fragment);
    return NodeProfile(
      id: _id(),
      name: fragment.isEmpty ? '${uri.host}:$port' : fragment,
      protocol: protocol,
      server: uri.host,
      port: port,
      outbound: outbound,
      source: source,
    );
  }

  static void _applyTlsAndTransport(
    Map<String, dynamic> outbound,
    Map<String, String> q, {
    required bool defaultTls,
  }) {
    _applyTls(outbound, q, defaultTls: defaultTls);
    final type = q['type'] ?? q['network'] ?? '';
    if (type == 'ws') {
      outbound['transport'] = <String, dynamic>{
        'type': 'ws',
        if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
        if ((q['host'] ?? '').isNotEmpty)
          'headers': <String, String>{'Host': q['host']!},
      };
    } else if (type == 'grpc') {
      outbound['transport'] = <String, dynamic>{
        'type': 'grpc',
        if ((q['serviceName'] ?? q['service_name'] ?? '').isNotEmpty)
          'service_name': q['serviceName'] ?? q['service_name'],
      };
    } else if (type == 'http') {
      outbound['transport'] = <String, dynamic>{
        'type': 'http',
        if ((q['path'] ?? '').isNotEmpty) 'path': q['path'],
        if ((q['host'] ?? '').isNotEmpty) 'host': <String>[q['host']!],
      };
    }
  }

  static void _applyTls(
    Map<String, dynamic> outbound,
    Map<String, String> q, {
    required bool defaultTls,
  }) {
    final security = q['security'] ?? '';
    final enabled = defaultTls || security == 'tls' || security == 'reality';
    if (!enabled) return;
    final tls = <String, dynamic>{'enabled': true};
    final sni = q['sni'] ?? q['peer'] ?? '';
    if (sni.isNotEmpty) tls['server_name'] = sni;
    final insecure =
        q['allowInsecure'] == '1' ||
        q['insecure'] == '1' ||
        q['insecure'] == 'true';
    if (insecure) tls['insecure'] = true;
    final alpn = q['alpn'];
    if (alpn != null && alpn.isNotEmpty) tls['alpn'] = alpn.split(',');
    final fp = q['fp'] ?? q['fingerprint'];
    if (fp != null && fp.isNotEmpty && fp != 'none') {
      tls['utls'] = <String, dynamic>{'enabled': true, 'fingerprint': fp};
    }
    final pbk = q['pbk'] ?? q['publicKey'];
    if (security == 'reality' || (pbk != null && pbk.isNotEmpty)) {
      tls['reality'] = <String, dynamic>{
        'enabled': true,
        if (pbk != null && pbk.isNotEmpty) 'public_key': pbk,
        if ((q['sid'] ?? q['shortId'] ?? '').isNotEmpty)
          'short_id': q['sid'] ?? q['shortId'],
      };
    }
    outbound['tls'] = tls;
  }

  static bool _isProxyType(String type) {
    return <String>{
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'hysteria',
      'hysteria2',
      'tuic',
      'socks',
      'http',
      'naive',
      'shadowtls',
      'anytls',
    }.contains(type);
  }

  static String? _tryBase64Decode(String input) {
    try {
      return _decodeBase64(input);
    } catch (_) {
      return null;
    }
  }

  static String _decodeBase64(String input) {
    var normalized = input.trim().replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    return utf8.decode(base64Decode(normalized));
  }

  static String _id() {
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$now-${_random.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  }
}

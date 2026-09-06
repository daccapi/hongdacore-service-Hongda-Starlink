import 'models.dart';

class NodeRegion {
  const NodeRegion({required this.code, required this.name});

  final String code;
  final String name;

  static const unknown = NodeRegion(code: 'ZZ', name: '未知地区');

  String get emoji {
    if (code.length != 2 || code == 'ZZ') return '🌐';
    final chars = code.toUpperCase().codeUnits;
    return String.fromCharCodes(<int>[
      0x1F1E6 + chars[0] - 0x41,
      0x1F1E6 + chars[1] - 0x41,
    ]);
  }
}

class _RegionPattern {
  const _RegionPattern(this.region, this.pattern);
  final NodeRegion region;
  final RegExp pattern;
}

_RegionPattern _region(String code, String name, String source) =>
    _RegionPattern(
      NodeRegion(code: code, name: name),
      RegExp(source, caseSensitive: false),
    );

final List<_RegionPattern> _patterns = <_RegionPattern>[
  _region(
    'HK',
    '香港',
    r'香港|hong[ ._-]?kong|hongkong|(?:^|[^a-z])hk(?:[^a-z]|$)|(?:^|[^a-z])hkg(?:[^a-z]|$)|\.hk(?:\b|$)',
  ),
  _region(
    'JP',
    '日本',
    r'日本|japan|tokyo|osaka|东京|大阪|(?:^|[^a-z])jp(?:[^a-z]|$)|(?:^|[^a-z])jpn(?:[^a-z]|$)|(?:^|[^a-z])nrt(?:[^a-z]|$)|\.jp(?:\b|$)',
  ),
  _region(
    'SG',
    '新加坡',
    r'新加坡|singapore|(?:^|[^a-z])sg(?:[^a-z]|$)|(?:^|[^a-z])sgp(?:[^a-z]|$)|\.sg(?:\b|$)',
  ),
  _region(
    'US',
    '美国',
    r'美国|美國|united[ ._-]?states|america|usa|los[ ._-]?angeles|san[ ._-]?jose|seattle|new[ ._-]?york|dallas|chicago|洛杉矶|圣何塞|西雅图|纽约|(?:^|[^a-z])us(?:[^a-z]|$)|\.us(?:\b|$)',
  ),
  _region(
    'TW',
    '台湾',
    r'台湾|台灣|taiwan|taipei|台北|(?:^|[^a-z])tw(?:[^a-z]|$)|\.tw(?:\b|$)',
  ),
  _region(
    'KR',
    '韩国',
    r'韩国|韓國|korea|seoul|首尔|首爾|(?:^|[^a-z])kr(?:[^a-z]|$)|\.kr(?:\b|$)',
  ),
  _region(
    'CN',
    '中国大陆',
    r'中国大陆|中國大陸|china|beijing|shanghai|guangzhou|shenzhen|北京|上海|广州|深圳|(?:^|[^a-z])cn(?:[^a-z]|$)|\.cn(?:\b|$)',
  ),
  _region(
    'MO',
    '澳门',
    r'澳门|澳門|macau|macao|(?:^|[^a-z])mo(?:[^a-z]|$)|\.mo(?:\b|$)',
  ),
  _region(
    'DE',
    '德国',
    r'德国|德國|germany|frankfurt|法兰克福|(?:^|[^a-z])de(?:[^a-z]|$)|\.de(?:\b|$)',
  ),
  _region(
    'GB',
    '英国',
    r'英国|英國|united[ ._-]?kingdom|britain|england|london|伦敦|倫敦|(?:^|[^a-z])(?:uk|gb)(?:[^a-z]|$)|\.uk(?:\b|$)',
  ),
  _region(
    'FR',
    '法国',
    r'法国|法國|france|paris|巴黎|(?:^|[^a-z])fr(?:[^a-z]|$)|\.fr(?:\b|$)',
  ),
  _region(
    'CA',
    '加拿大',
    r'加拿大|canada|toronto|vancouver|多伦多|温哥华|溫哥華|(?:^|[^a-z])ca(?:[^a-z]|$)|\.ca(?:\b|$)',
  ),
  _region(
    'AU',
    '澳大利亚',
    r'澳大利亚|澳大利亞|澳洲|australia|sydney|melbourne|悉尼|墨尔本|(?:^|[^a-z])au(?:[^a-z]|$)|\.au(?:\b|$)',
  ),
  _region(
    'NL',
    '荷兰',
    r'荷兰|荷蘭|netherlands|holland|amsterdam|阿姆斯特丹|(?:^|[^a-z])nl(?:[^a-z]|$)|\.nl(?:\b|$)',
  ),
  _region(
    'RU',
    '俄罗斯',
    r'俄罗斯|俄羅斯|russia|moscow|莫斯科|(?:^|[^a-z])ru(?:[^a-z]|$)|\.ru(?:\b|$)',
  ),
  _region(
    'IN',
    '印度',
    r'印度|india|mumbai|delhi|孟买|德里|(?:^|[^a-z])in(?:[^a-z]|$)|\.in(?:\b|$)',
  ),
  _region(
    'TH',
    '泰国',
    r'泰国|泰國|thailand|bangkok|曼谷|(?:^|[^a-z])th(?:[^a-z]|$)|\.th(?:\b|$)',
  ),
  _region(
    'MY',
    '马来西亚',
    r'马来西亚|馬來西亞|malaysia|kuala[ ._-]?lumpur|吉隆坡|(?:^|[^a-z])my(?:[^a-z]|$)|\.my(?:\b|$)',
  ),
  _region(
    'VN',
    '越南',
    r'越南|vietnam|hanoi|ho[ ._-]?chi[ ._-]?minh|河内|胡志明|(?:^|[^a-z])vn(?:[^a-z]|$)|\.vn(?:\b|$)',
  ),
  _region(
    'PH',
    '菲律宾',
    r'菲律宾|菲律賓|philippines|manila|马尼拉|馬尼拉|(?:^|[^a-z])ph(?:[^a-z]|$)|\.ph(?:\b|$)',
  ),
  _region(
    'ID',
    '印度尼西亚',
    r'印度尼西亚|印尼|indonesia|jakarta|雅加达|雅加達|(?:^|[^a-z])id(?:[^a-z]|$)|\.id(?:\b|$)',
  ),
  _region(
    'TR',
    '土耳其',
    r'土耳其|turkey|turkiye|istanbul|伊斯坦布尔|(?:^|[^a-z])tr(?:[^a-z]|$)|\.tr(?:\b|$)',
  ),
  _region(
    'BR',
    '巴西',
    r'巴西|brazil|sao[ ._-]?paulo|(?:^|[^a-z])br(?:[^a-z]|$)|\.br(?:\b|$)',
  ),
];

NodeRegion nodeRegion(NodeProfile node) {
  final explicit = _extractFlagCode(node.name);
  if (explicit != null) {
    for (final candidate in _patterns) {
      if (candidate.region.code == explicit) return candidate.region;
    }
    return NodeRegion(code: explicit, name: '其他地区');
  }
  final text = '${node.name} ${node.server} ${node.outbound['tag'] ?? ''}';
  for (final candidate in _patterns) {
    if (candidate.pattern.hasMatch(text)) return candidate.region;
  }
  return NodeRegion.unknown;
}

String? _extractFlagCode(String value) {
  const base = 0x1F1E6;
  const last = 0x1F1FF;
  final runes = value.runes.toList(growable: false);
  for (var i = 0; i + 1 < runes.length; i++) {
    if (runes[i] < base ||
        runes[i] > last ||
        runes[i + 1] < base ||
        runes[i + 1] > last)
      continue;
    return String.fromCharCodes(<int>[
      0x41 + runes[i] - base,
      0x41 + runes[i + 1] - base,
    ]);
  }
  return null;
}

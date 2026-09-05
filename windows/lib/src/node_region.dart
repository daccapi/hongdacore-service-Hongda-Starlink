import 'models.dart';

class NodeRegion {
  const NodeRegion({required this.code, required this.name});

  final String code;
  final String name;

  bool get isKnown => code != 'ZZ';

  static const unknown = NodeRegion(code: 'ZZ', name: '未设置');
}

class _RegionPattern {
  const _RegionPattern(this.region, this.pattern);

  final NodeRegion region;
  final RegExp pattern;
}

final List<_RegionPattern> _regionPatterns = <_RegionPattern>[
  _region(
    'HK',
    '香港',
    r'香港|hong[ ._-]?kong|hongkong|(?:^|[^a-z])hk(?:[^a-z]|$)|(?:^|[^a-z])hkg(?:[^a-z]|$)|\.hk(?:\b|$)',
  ),
  _region(
    'JP',
    '日本',
    r'日本|japan|tokyo|osaka|东京|大阪|(?:^|[^a-z])jp(?:[^a-z]|$)|(?:^|[^a-z])jpn(?:[^a-z]|$)|(?:^|[^a-z])nrt(?:[^a-z]|$)|(?:^|[^a-z])hnd(?:[^a-z]|$)|\.jp(?:\b|$)',
  ),
  _region(
    'SG',
    '新加坡',
    r'新加坡|singapore|(?:^|[^a-z])sg(?:[^a-z]|$)|(?:^|[^a-z])sgp(?:[^a-z]|$)|\.sg(?:\b|$)',
  ),
  _region(
    'US',
    '美国',
    r'美国|美國|united[ ._-]?states|america|usa|los[ ._-]?angeles|san[ ._-]?jose|seattle|new[ ._-]?york|dallas|chicago|洛杉矶|圣何塞|西雅图|纽约|(?:^|[^a-z])us(?:[^a-z]|$)|(?:^|[^a-z])lax(?:[^a-z]|$)|(?:^|[^a-z])sjc(?:[^a-z]|$)|\.us(?:\b|$)',
  ),
  _region(
    'TW',
    '台湾',
    r'台湾|台灣|taiwan|taipei|台北|(?:^|[^a-z])tw(?:[^a-z]|$)|(?:^|[^a-z])twn(?:[^a-z]|$)|(?:^|[^a-z])tpe(?:[^a-z]|$)|\.tw(?:\b|$)',
  ),
  _region(
    'KR',
    '韩国',
    r'韩国|韓國|korea|seoul|首尔|首爾|(?:^|[^a-z])kr(?:[^a-z]|$)|(?:^|[^a-z])kor(?:[^a-z]|$)|(?:^|[^a-z])icn(?:[^a-z]|$)|\.kr(?:\b|$)',
  ),
  _region(
    'CN',
    '中国大陆',
    r'中国大陆|中國大陸|china|beijing|shanghai|guangzhou|shenzhen|北京|上海|广州|深圳|(?:^|[^a-z])cn(?:[^a-z]|$)|(?:^|[^a-z])chn(?:[^a-z]|$)|\.cn(?:\b|$)',
  ),
  _region(
    'MO',
    '澳门',
    r'澳门|澳門|macau|macao|(?:^|[^a-z])mo(?:[^a-z]|$)|(?:^|[^a-z])mfm(?:[^a-z]|$)|\.mo(?:\b|$)',
  ),
  _region(
    'DE',
    '德国',
    r'德国|德國|germany|frankfurt|法兰克福|(?:^|[^a-z])de(?:[^a-z]|$)|(?:^|[^a-z])deu(?:[^a-z]|$)|(?:^|[^a-z])fra(?:[^a-z]|$)|\.de(?:\b|$)',
  ),
  _region(
    'GB',
    '英国',
    r'英国|英國|united[ ._-]?kingdom|britain|england|london|伦敦|倫敦|(?:^|[^a-z])(?:uk|gb)(?:[^a-z]|$)|(?:^|[^a-z])gbr(?:[^a-z]|$)|\.uk(?:\b|$)',
  ),
  _region(
    'FR',
    '法国',
    r'法国|法國|france|paris|巴黎|(?:^|[^a-z])fr(?:[^a-z]|$)|(?:^|[^a-z])fra(?:[^a-z]|$)|\.fr(?:\b|$)',
  ),
  _region(
    'CA',
    '加拿大',
    r'加拿大|canada|toronto|vancouver|多伦多|温哥华|溫哥華|(?:^|[^a-z])ca(?:[^a-z]|$)|(?:^|[^a-z])can(?:[^a-z]|$)|\.ca(?:\b|$)',
  ),
  _region(
    'AU',
    '澳大利亚',
    r'澳大利亚|澳大利亞|澳洲|australia|sydney|melbourne|悉尼|墨尔本|(?:^|[^a-z])au(?:[^a-z]|$)|(?:^|[^a-z])aus(?:[^a-z]|$)|\.au(?:\b|$)',
  ),
  _region(
    'NL',
    '荷兰',
    r'荷兰|荷蘭|netherlands|holland|amsterdam|阿姆斯特丹|(?:^|[^a-z])nl(?:[^a-z]|$)|(?:^|[^a-z])nld(?:[^a-z]|$)|\.nl(?:\b|$)',
  ),
  _region(
    'RU',
    '俄罗斯',
    r'俄罗斯|俄羅斯|russia|moscow|莫斯科|(?:^|[^a-z])ru(?:[^a-z]|$)|(?:^|[^a-z])rus(?:[^a-z]|$)|\.ru(?:\b|$)',
  ),
  _region(
    'IN',
    '印度',
    r'印度|india|mumbai|delhi|孟买|德里|(?:^|[^a-z])in(?:[^a-z]|$)|(?:^|[^a-z])ind(?:[^a-z]|$)|\.in(?:\b|$)',
  ),
  _region(
    'TH',
    '泰国',
    r'泰国|泰國|thailand|bangkok|曼谷|(?:^|[^a-z])th(?:[^a-z]|$)|(?:^|[^a-z])tha(?:[^a-z]|$)|\.th(?:\b|$)',
  ),
  _region(
    'MY',
    '马来西亚',
    r'马来西亚|馬來西亞|malaysia|kuala[ ._-]?lumpur|吉隆坡|(?:^|[^a-z])my(?:[^a-z]|$)|(?:^|[^a-z])mys(?:[^a-z]|$)|\.my(?:\b|$)',
  ),
  _region(
    'VN',
    '越南',
    r'越南|vietnam|hanoi|ho[ ._-]?chi[ ._-]?minh|河内|胡志明|(?:^|[^a-z])vn(?:[^a-z]|$)|(?:^|[^a-z])vnm(?:[^a-z]|$)|\.vn(?:\b|$)',
  ),
  _region(
    'PH',
    '菲律宾',
    r'菲律宾|菲律賓|philippines|manila|马尼拉|馬尼拉|(?:^|[^a-z])ph(?:[^a-z]|$)|(?:^|[^a-z])phl(?:[^a-z]|$)|\.ph(?:\b|$)',
  ),
  _region(
    'ID',
    '印度尼西亚',
    r'印度尼西亚|印尼|indonesia|jakarta|雅加达|雅加達|(?:^|[^a-z])id(?:[^a-z]|$)|(?:^|[^a-z])idn(?:[^a-z]|$)|\.id(?:\b|$)',
  ),
  _region(
    'TR',
    '土耳其',
    r'土耳其|turkey|turkiye|istanbul|伊斯坦布尔|(?:^|[^a-z])tr(?:[^a-z]|$)|(?:^|[^a-z])tur(?:[^a-z]|$)|\.tr(?:\b|$)',
  ),
  _region(
    'BR',
    '巴西',
    r'巴西|brazil|sao[ ._-]?paulo|(?:^|[^a-z])br(?:[^a-z]|$)|(?:^|[^a-z])bra(?:[^a-z]|$)|\.br(?:\b|$)',
  ),
];

_RegionPattern _region(String code, String name, String source) =>
    _RegionPattern(
      NodeRegion(code: code, name: name),
      RegExp(source, caseSensitive: false),
    );

NodeRegion nodeRegion(NodeProfile node) {
  try {
    final override = node.regionCode?.trim().toUpperCase();
    if (override != null && RegExp(r'^[A-Z]{2}$').hasMatch(override)) {
      final storedName = node.regionName?.trim();
      if (storedName != null && storedName.isNotEmpty) {
        return NodeRegion(code: override, name: storedName);
      }
      return _regionByCode(override);
    }

    final explicitCode = _extractFlagCode(node.name);
    if (explicitCode != null) return _regionByCode(explicitCode);

    final raw = <String>[
      node.name,
      node.server,
      node.outbound['tag']?.toString() ?? '',
    ].join(' ');
    for (final candidate in _regionPatterns) {
      if (candidate.pattern.hasMatch(raw)) return candidate.region;
    }

    // Subscription providers often concatenate a country code and a line
    // suffix (hk01, jp01, uspro). Only accept unambiguous tokens so ordinary
    // English words such as "free", "this" or "phone" are never guessed.
    final tokens = raw
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((token) => token.length >= 3 && token.length <= 8);
    for (final token in tokens) {
      // "code + digit" is unambiguous (hk01, jp01, us01).
      final digitMatch = RegExp(r'^([a-z]{2})\d').firstMatch(token);
      if (digitMatch != null) {
        final code = digitMatch.group(1)!;
        for (final candidate in _regionPatterns) {
          if (candidate.region.code.toLowerCase() == code) {
            return candidate.region;
          }
        }
        continue;
      }
      // Pure-letter concatenations (jpda, uspro) are accepted only when the
      // token is not a common English word that happens to start with a
      // country code.
      if (_commonEnglishTokens.contains(token)) continue;
      for (final candidate in _regionPatterns) {
        final code = candidate.region.code.toLowerCase();
        if (token.startsWith(code)) return candidate.region;
      }
    }
  } catch (_) {
    // Region detection is presentation-only and must not hide a valid node.
  }
  return NodeRegion.unknown;
}

List<NodeRegion> get supportedNodeRegions =>
    List<NodeRegion>.unmodifiable(_regionPatterns.map((item) => item.region));

NodeRegion _regionByCode(String code) {
  for (final candidate in _regionPatterns) {
    if (candidate.region.code == code) return candidate.region;
  }
  return NodeRegion(code: code, name: '其他地区');
}

const Set<String> _commonEnglishTokens = <String>{
  'free',
  'from',
  'fresh',
  'frame',
  'frank',
  'friend',
  'front',
  'fruit',
  'freeze',
  'fragment',
  'frequency',
  'frontend',
  'this',
  'that',
  'the',
  'then',
  'them',
  'there',
  'these',
  'three',
  'through',
  'thread',
  'throw',
  'think',
  'thing',
  'thank',
  'theme',
  'third',
  'thumb',
  'theory',
  'threshold',
  'phone',
  'photo',
  'photos',
  'phase',
  'physics',
  'physical',
  'php',
  'run',
  'running',
  'rule',
  'rules',
  'runtime',
  'rural',
  'ruby',
  'user',
  'using',
  'used',
  'use',
  'usage',
  'usb',
  'userid',
  'username',
  'idle',
  'idea',
  'index',
  'input',
  'identity',
  'inside',
  'identifier',
  'inbox',
  'inline',
  'invoice',
  'insert',
  'interval',
  'invalid',
  'include',
  'incoming',
  'internal',
  'integer',
  'integration',
  'card',
  'cache',
  'call',
  'case',
  'cat',
  'can',
  'car',
  'camera',
  'category',
  'calendar',
  'cancel',
  'calculate',
  'capacity',
  'capture',
  'traffic',
  'trace',
  'track',
  'trade',
  'train',
  'true',
  'try',
  'trick',
  'trial',
  'truck',
  'trust',
  'tree',
  'travel',
  'transfer',
  'translate',
  'transaction',
  'transport',
  'trigger',
  'audio',
  'audit',
  'august',
  'author',
  'auto',
  'automatic',
  'authentication',
  'auth',
  'myself',
  'mysql',
  'myapp',
  'mybatis',
  'default',
  'delete',
  'delay',
  'debug',
  'demo',
  'design',
  'detail',
  'device',
  'desktop',
  'delivery',
  'define',
  'debugging',
  'definition',
  'deployment',
  'dependency',
  'describe',
  'destroy',
  'info',
  'install',
  'instance',
  'interface',
  'internet',
  'brother',
  'break',
  'bridge',
  'browser',
  'brand',
  'broadcast',
  'broadband',
  'mobile',
  'model',
  'module',
  'money',
  'monitor',
  'month',
  'mouse',
  'move',
  'modify',
  'two',
  'tweet',
  'twitter',
  'twice',
  'twin',
  'jpeg',
  'jpg',
};

String? _extractFlagCode(String value) {
  const regionalBase = 0x1F1E6;
  const regionalLast = 0x1F1FF;
  final runes = value.runes.toList(growable: false);
  for (var i = 0; i + 1 < runes.length; i++) {
    final first = runes[i];
    final second = runes[i + 1];
    if (first < regionalBase ||
        first > regionalLast ||
        second < regionalBase ||
        second > regionalLast)
      continue;
    return String.fromCharCodes(<int>[
      0x41 + first - regionalBase,
      0x41 + second - regionalBase,
    ]);
  }
  return null;
}

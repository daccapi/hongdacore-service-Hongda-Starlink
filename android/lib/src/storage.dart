import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

class AppStorage {
  AppStorage._(this.baseDir);

  final Directory baseDir;
  Future<void> _writeQueue = Future<void>.value();

  static Future<AppStorage> create() async {
    Directory base;
    if (Platform.isAndroid) {
      const channel = MethodChannel('hongda_starlink/android');
      String? nativeDataDir;
      try {
        nativeDataDir = await channel.invokeMethod<String>('getDataDir');
      } catch (_) {
        nativeDataDir = null;
      }
      final root = nativeDataDir == null || nativeDataDir.isEmpty
          ? Directory.systemTemp.path
          : nativeDataDir;
      base = Directory('$root${Platform.pathSeparator}HongdaStarlink');
    } else {
      final appData = Platform.environment['APPDATA'];
      base = Directory(
        appData == null || appData.isEmpty
            ? '${Directory.current.path}${Platform.pathSeparator}.hongda-starlink'
            : '$appData${Platform.pathSeparator}HongdaStarlink',
      );
    }
    await base.create(recursive: true);
    return AppStorage._(base);
  }

  Directory get coreDir => Directory('${baseDir.path}${Platform.pathSeparator}core');
  Directory get runtimeDir => Directory('${baseDir.path}${Platform.pathSeparator}runtime');
  File get settingsFile => File('${baseDir.path}${Platform.pathSeparator}settings.json');
  File get nodesFile => File('${baseDir.path}${Platform.pathSeparator}nodes.json');
  File get subscriptionsFile => File('${baseDir.path}${Platform.pathSeparator}subscriptions.json');
  File get groupsFile => File('${baseDir.path}${Platform.pathSeparator}groups.json');
  File get rulesFile => File('${baseDir.path}${Platform.pathSeparator}rules.json');
  File get trafficFile => File('${baseDir.path}${Platform.pathSeparator}traffic.json');

  Future<AppSettings> loadSettings() async {
    try {
      final decoded = await _readJsonWithRecovery(settingsFile);
      return AppSettings.fromJson(Map<String, dynamic>.from(decoded as Map));
    } catch (_) {
      return AppSettings();
    }
  }

  Future<List<NodeProfile>> loadNodes() async {
    try {
      final decoded = await _readJsonWithRecovery(nodesFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map((Map item) => NodeProfile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <NodeProfile>[];
    }
  }

  Future<List<SubscriptionProfile>> loadSubscriptions() async {
    try {
      final decoded = await _readJsonWithRecovery(subscriptionsFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map((Map item) => SubscriptionProfile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <SubscriptionProfile>[];
    }
  }


  Future<List<ProxyGroupProfile>> loadGroups() async {
    try {
      final decoded = await _readJsonWithRecovery(groupsFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map((Map item) => ProxyGroupProfile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <ProxyGroupProfile>[];
    }
  }

  Future<List<RouteRuleProfile>> loadRules() async {
    try {
      final decoded = await _readJsonWithRecovery(rulesFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map((Map item) => RouteRuleProfile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return <RouteRuleProfile>[];
    }
  }

  Future<TrafficStats> loadTrafficStats() async {
    try {
      final decoded = await _readJsonWithRecovery(trafficFile);
      return TrafficStats.fromJson(Map<String, dynamic>.from(decoded as Map));
    } catch (_) {
      return TrafficStats();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    await _atomicWrite(settingsFile, prettyJson(settings.toJson()));
  }

  Future<void> saveNodes(List<NodeProfile> nodes) async {
    await _atomicWrite(nodesFile, prettyJson(nodes.map((e) => e.toJson()).toList()));
  }

  Future<void> saveSubscriptions(List<SubscriptionProfile> subscriptions) async {
    await _atomicWrite(
      subscriptionsFile,
      prettyJson(subscriptions.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveGroups(List<ProxyGroupProfile> groups) async {
    await _atomicWrite(groupsFile, prettyJson(groups.map((e) => e.toJson()).toList()));
  }

  Future<void> saveRules(List<RouteRuleProfile> rules) async {
    await _atomicWrite(rulesFile, prettyJson(rules.map((e) => e.toJson()).toList()));
  }

  Future<void> saveTrafficStats(TrafficStats stats) async {
    await _atomicWrite(trafficFile, prettyJson(stats.toJson()));
  }

  Future<File> writeRuntimeConfig(Map<String, dynamic> config) async {
    await runtimeDir.create(recursive: true);
    final file = File('${runtimeDir.path}${Platform.pathSeparator}config.json');
    await _atomicWrite(file, prettyJson(config));
    return file;
  }

  Future<dynamic> _readJsonWithRecovery(File file) async {
    final candidates = <File>[
      file,
      File('${file.path}.bak'),
      File('${file.path}.tmp'),
    ];
    Object? lastError;
    for (final candidate in candidates) {
      if (!await candidate.exists()) continue;
      try {
        final decoded = jsonDecode(await candidate.readAsString());
        if (candidate.path != file.path) {
          try {
            if (await file.exists()) await file.delete();
            await candidate.copy(file.path);
          } catch (_) {
            // Recovery data is still usable even when restoring the primary
            // file is blocked by antivirus/indexing or a transient lock.
          }
        }
        return decoded;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    throw const FormatException('No readable JSON storage file');
  }

  Future<void> _atomicWrite(File file, String content) {
    final operation = _writeQueue.then<void>(
      (_) => _atomicWriteNow(file, content),
      onError: (Object _, StackTrace __) => _atomicWriteNow(file, content),
    );
    _writeQueue = operation;
    return operation;
  }

  Future<void> _atomicWriteNow(File file, String content) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await temp.exists()) await temp.delete();
    await temp.writeAsString(content, flush: true);

    if (await file.exists()) {
      if (await backup.exists()) await backup.delete();
      await file.copy(backup.path);
    }

    try {
      if (await file.exists()) await file.delete();
      await temp.rename(file.path);
    } catch (_) {
      if (!await file.exists() && await backup.exists()) {
        try {
          await backup.copy(file.path);
        } catch (_) {}
      }
      rethrow;
    }
  }
}

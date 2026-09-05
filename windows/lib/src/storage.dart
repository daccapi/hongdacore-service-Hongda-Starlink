import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'windows_integration.dart';

abstract interface class StorageProtector {
  Future<String> protect(String value);
  Future<String> unprotect(String value);
}

class WindowsStorageProtector implements StorageProtector {
  const WindowsStorageProtector();

  @override
  Future<String> protect(String value) => WindowsIntegration.protectData(value);

  @override
  Future<String> unprotect(String value) =>
      WindowsIntegration.unprotectData(value);
}

class AppStorage {
  AppStorage._(this.baseDir, {this.protector});

  factory AppStorage.forDirectory(
    Directory baseDir, {
    StorageProtector? protector,
  }) => AppStorage._(baseDir, protector: protector);

  final Directory baseDir;
  final StorageProtector? protector;
  Future<void> _writeQueue = Future<void>.value();

  static Future<AppStorage> create() async {
    final appData = Platform.environment['APPDATA'];
    final base = Directory(
      appData == null || appData.isEmpty
          ? '${Directory.current.path}${Platform.pathSeparator}.hongda-starlink'
          : '$appData${Platform.pathSeparator}HongdaStarlink',
    );
    await base.create(recursive: true);
    return AppStorage._(
      base,
      protector: Platform.isWindows ? const WindowsStorageProtector() : null,
    );
  }

  Directory get coreDir =>
      Directory('${baseDir.path}${Platform.pathSeparator}core');
  Directory get runtimeDir =>
      Directory('${baseDir.path}${Platform.pathSeparator}runtime');
  File get settingsFile =>
      File('${baseDir.path}${Platform.pathSeparator}settings.json');
  File get nodesFile =>
      File('${baseDir.path}${Platform.pathSeparator}nodes.json');
  File get subscriptionsFile =>
      File('${baseDir.path}${Platform.pathSeparator}subscriptions.json');
  File get groupsFile =>
      File('${baseDir.path}${Platform.pathSeparator}groups.json');
  File get rulesFile =>
      File('${baseDir.path}${Platform.pathSeparator}rules.json');
  File get trafficFile =>
      File('${baseDir.path}${Platform.pathSeparator}traffic.json');
  File get clientLogFile =>
      File('${runtimeDir.path}${Platform.pathSeparator}client.log');

  Future<void> appendClientLog(
    String line, {
    int maxBytes = 10 * 1024 * 1024,
    int retainedFiles = 3,
  }) async {
    await runtimeDir.create(recursive: true);
    final encoded = utf8.encode('$line\n');
    if (maxBytes > 0 &&
        await clientLogFile.exists() &&
        await clientLogFile.length() + encoded.length > maxBytes) {
      await _rotateClientLog(retainedFiles);
    }
    await clientLogFile.writeAsBytes(
      encoded,
      mode: FileMode.append,
      flush: false,
    );
  }

  Future<void> _rotateClientLog(int retainedFiles) async {
    if (retainedFiles <= 0) {
      if (await clientLogFile.exists()) await clientLogFile.delete();
      return;
    }
    final oldest = File('${clientLogFile.path}.$retainedFiles');
    if (await oldest.exists()) await oldest.delete();
    for (var index = retainedFiles - 1; index >= 1; index--) {
      final source = File('${clientLogFile.path}.$index');
      if (!await source.exists()) continue;
      await source.rename('${clientLogFile.path}.${index + 1}');
    }
    if (await clientLogFile.exists()) {
      await clientLogFile.rename('${clientLogFile.path}.1');
    }
  }

  Future<AppSettings> loadSettings() async {
    try {
      final decoded = await _readSensitiveJson(settingsFile);
      final settings = AppSettings.fromJson(
        Map<String, dynamic>.from(decoded as Map),
      );
      // HongdaCore 1.10 deliberately rejects unsupported endpoints/FakeIP
      // instead of pretending they are active. Migrate old switches off.
      var migrated = false;
      if (settings.tailscaleEnabled) {
        settings.tailscaleEnabled = false;
        migrated = true;
      }
      if (settings.fakeIpEnabled) {
        settings.fakeIpEnabled = false;
        migrated = true;
      }
      if (migrated) {
        await saveSettings(settings);
      }
      return settings;
    } catch (_) {
      return AppSettings();
    }
  }

  Future<List<NodeProfile>> loadNodes() async {
    try {
      final decoded = await _readSensitiveJson(nodesFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map(
            (Map item) => NodeProfile.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList();
    } catch (_) {
      return <NodeProfile>[];
    }
  }

  Future<List<SubscriptionProfile>> loadSubscriptions() async {
    try {
      final decoded =
          await _readSensitiveJson(subscriptionsFile) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map(
            (Map item) =>
                SubscriptionProfile.fromJson(Map<String, dynamic>.from(item)),
          )
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
          .map(
            (Map item) =>
                ProxyGroupProfile.fromJson(Map<String, dynamic>.from(item)),
          )
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
          .map(
            (Map item) =>
                RouteRuleProfile.fromJson(Map<String, dynamic>.from(item)),
          )
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
    await _writeSensitiveJson(settingsFile, settings.toJson());
  }

  Future<void> saveNodes(List<NodeProfile> nodes) async {
    await _writeSensitiveJson(nodesFile, nodes.map((e) => e.toJson()).toList());
  }

  Future<void> saveSubscriptions(
    List<SubscriptionProfile> subscriptions,
  ) async {
    await _writeSensitiveJson(
      subscriptionsFile,
      subscriptions.map((e) => e.toJson()).toList(),
    );
  }

  Future<void> saveGroups(List<ProxyGroupProfile> groups) async {
    await _atomicWrite(
      groupsFile,
      prettyJson(groups.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> saveRules(List<RouteRuleProfile> rules) async {
    await _atomicWrite(
      rulesFile,
      prettyJson(rules.map((e) => e.toJson()).toList()),
    );
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

  Future<void> deleteRuntimeConfig() async {
    await _writeQueue.catchError((_) {});
    final path = '${runtimeDir.path}${Platform.pathSeparator}config.json';
    for (final suffix in const <String>['', '.bak', '.tmp']) {
      final file = File('$path$suffix');
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Antivirus/indexing can briefly retain the file. A future cleanup or
        // the next atomic write will safely retry without affecting shutdown.
      }
    }
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

  Future<dynamic> _readSensitiveJson(File file) async {
    final decoded = await _readJsonWithRecovery(file);
    if (decoded is Map && decoded['format'] == 'hongda-dpapi-v1') {
      final activeProtector = protector;
      final payload = decoded['data']?.toString() ?? '';
      if (activeProtector == null || payload.isEmpty) {
        throw const FormatException('受保护的本地数据无法在当前平台解密');
      }
      return jsonDecode(await activeProtector.unprotect(payload));
    }
    if (protector != null) {
      try {
        await _writeSensitiveJson(file, decoded);
      } catch (_) {
        // Keep legacy plaintext readable when the OS key store is temporarily
        // unavailable. A later successful save retries the migration.
      }
    }
    return decoded;
  }

  Future<void> _writeSensitiveJson(File file, dynamic value) async {
    final content = prettyJson(value);
    final activeProtector = protector;
    if (activeProtector == null) {
      await _atomicWrite(file, content);
      return;
    }
    final protected = await activeProtector.protect(content);
    await _atomicWrite(
      file,
      prettyJson(<String, dynamic>{
        'format': 'hongda-dpapi-v1',
        'scope': 'current-user',
        'data': protected,
      }),
      secureBackup: true,
    );
  }

  Future<void> _atomicWrite(
    File file,
    String content, {
    bool secureBackup = false,
  }) {
    final operation = _writeQueue.then<void>(
      (_) => _atomicWriteNow(file, content, secureBackup: secureBackup),
      onError: (Object _, StackTrace __) =>
          _atomicWriteNow(file, content, secureBackup: secureBackup),
    );
    _writeQueue = operation;
    return operation;
  }

  Future<void> _atomicWriteNow(
    File file,
    String content, {
    required bool secureBackup,
  }) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    if (await temp.exists()) await temp.delete();
    await temp.writeAsString(content, flush: true);

    if (secureBackup) {
      if (await backup.exists()) await backup.delete();
      try {
        if (await file.exists()) await file.delete();
        await temp.rename(file.path);
      } catch (_) {
        if (!await file.exists() && await temp.exists()) {
          try {
            await temp.copy(file.path);
          } catch (_) {}
        }
        rethrow;
      }
      try {
        await file.copy(backup.path);
      } catch (_) {
        // The protected primary file is already durable. Backup creation may
        // be retried by the next save if antivirus briefly holds the path.
      }
      return;
    }

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

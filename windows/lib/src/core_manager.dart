import 'dart:io';

import 'storage.dart';

/// Locates the Hongda Windows service runtime.
///
/// The class name is kept as CoreManager to avoid a broad public API rename in
/// Earlier versions used this name; the executable it manages is now
/// HongdaService.exe with HongdaCore embedded inside it. There is no
/// separate user-facing hongda-core.exe.
class CoreManager {
  CoreManager(this.storage);

  final AppStorage storage;

  static const String version = '1.10.6';
  static const String serviceVersion = '1.5.6';

  Future<String?> findCore() async {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final bundled = File(
      '${exeDir.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}service${Platform.pathSeparator}HongdaService.exe',
    );
    if (await bundled.exists()) return bundled.path;

    // Development tree fallback.
    final dev = File(
      '${Directory.current.path}${Platform.pathSeparator}runtime${Platform.pathSeparator}service${Platform.pathSeparator}HongdaService.exe',
    );
    if (await dev.exists()) return dev.path;
    return null;
  }

  Future<String?> queryVersion() async {
    final path = await findCore();
    if (path == null) return null;
    try {
      final result = await Process.run(path, const <String>[
        'version',
      ]).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return null;
      final lines = result.stdout
          .toString()
          .trim()
          .split(RegExp(r'[\r\n]+'))
          .where((e) => e.trim().isNotEmpty)
          .toList();
      return lines.isEmpty ? null : lines.first.trim();
    } catch (_) {
      return null;
    }
  }

  Future<String?> queryFeatures() async {
    final path = await findCore();
    if (path == null) return null;
    try {
      final result = await Process.run(path, const <String>[
        'features',
      ]).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) return null;
      return result.stdout.toString().trim();
    } catch (_) {
      return null;
    }
  }
}

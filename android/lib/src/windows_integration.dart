import 'dart:io';

import 'package:flutter/services.dart';

class WindowsIntegration {
  static const MethodChannel _channel = MethodChannel('hongda_starlink/windows');

  static Future<bool> isAdministrator() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isAdministrator') ?? false;
  }

  static Future<bool> restartAsAdministrator() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('restartAsAdministrator') ?? false;
  }

  static Future<void> setSystemProxy({
    required bool enabled,
    required int port,
  }) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('setSystemProxy', <String, dynamic>{
      'enabled': enabled,
      'server': '127.0.0.1:$port',
      'bypass': '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*',
    });
  }

  static Future<Map<String, dynamic>> getSystemProxy() async {
    if (!Platform.isWindows) return const <String, dynamic>{};
    final value = await _channel.invokeMapMethod<String, dynamic>('getSystemProxy');
    return value ?? const <String, dynamic>{};
  }

  static Future<void> setStartWithWindows(bool enabled) async {
    if (!Platform.isWindows) return;
    final exe = Platform.resolvedExecutable;
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    if (enabled) {
      await Process.run('reg.exe', <String>[
        'add', key, '/v', 'HongdaStarlink', '/t', 'REG_SZ', '/d', '"$exe" --startup', '/f'
      ]);
    } else {
      await Process.run('reg.exe', <String>[
        'delete', key, '/v', 'HongdaStarlink', '/f'
      ]);
    }
  }


  static Future<void> startWindowDrag() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('startWindowDrag');
  }

  static Future<void> minimizeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{'action': 'minimize'});
  }

  static Future<void> toggleMaximizeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{'action': 'toggleMaximize'});
  }

  static Future<void> closeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{'action': 'close'});
  }

  static Future<bool> isWindowMaximized() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isWindowMaximized') ?? false;
  }

  static Future<void> openFolder(String path) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', <String>[path], mode: ProcessStartMode.detached);
  }
}

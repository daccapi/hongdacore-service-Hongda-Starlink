import 'dart:io';

import 'package:flutter/services.dart';

class WindowsTunRoutingStatus {
  const WindowsTunRoutingStatus({
    required this.adapterFound,
    required this.adapterUp,
    required this.defaultRoute,
    required this.splitRouteCount,
    required this.lowHalfRoute,
    required this.highHalfRoute,
    required this.effectiveRoute,
    required this.ready,
  });

  final bool adapterFound;
  final bool adapterUp;
  final bool defaultRoute;
  final int splitRouteCount;
  final bool lowHalfRoute;
  final bool highHalfRoute;
  final bool effectiveRoute;
  final bool ready;

  String get detail {
    if (!adapterFound) return '未找到 HongdaTun 网卡';
    if (!adapterUp) return 'HongdaTun 网卡未启动';
    if (!lowHalfRoute || !highHalfRoute) {
      final missing = <String>[
        if (!lowHalfRoute) '0.0.0.0/1',
        if (!highHalfRoute) '128.0.0.0/1',
      ].join(' + ');
      return 'HongdaTun IPv4 接管不完整：$missing 最优路由未指向 TUN';
    }
    if (!effectiveRoute) return 'Windows 实际最优路由没有指向 HongdaTun';
    if (!defaultRoute && splitRouteCount < 2) {
      return 'HongdaTun 端点绕行分段路由与 Windows 最优路由已就绪';
    }
    return 'HongdaTun 网卡与 Windows 最优路由已就绪';
  }
}

class WindowsIntegration {
  static const MethodChannel _channel = MethodChannel(
    'hongda_starlink/windows',
  );

  static Future<bool> isAdministrator() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isAdministrator') ?? false;
  }

  static Future<bool> restartAsAdministrator() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('restartAsAdministrator') ?? false;
  }

  static Future<WindowsTunRoutingStatus> inspectTunRouting() async {
    if (!Platform.isWindows) {
      return const WindowsTunRoutingStatus(
        adapterFound: false,
        adapterUp: false,
        defaultRoute: false,
        splitRouteCount: 0,
        lowHalfRoute: false,
        highHalfRoute: false,
        effectiveRoute: false,
        ready: false,
      );
    }
    final value =
        await _channel.invokeMapMethod<String, dynamic>('inspectTunRouting') ??
        const <String, dynamic>{};
    return WindowsTunRoutingStatus(
      adapterFound: value['adapterFound'] == true,
      adapterUp: value['adapterUp'] == true,
      defaultRoute: value['defaultRoute'] == true,
      splitRouteCount:
          int.tryParse(value['splitRouteCount']?.toString() ?? '') ?? 0,
      lowHalfRoute: value['lowHalfRoute'] == true,
      highHalfRoute: value['highHalfRoute'] == true,
      effectiveRoute: value['effectiveRoute'] == true,
      ready: value['ready'] == true,
    );
  }

  static Future<void> setSystemProxy({
    required bool enabled,
    required int port,
  }) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('setSystemProxy', <String, dynamic>{
      'enabled': enabled,
      'server': '127.0.0.1:$port',
      'bypass':
          '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*',
    });
  }

  static Future<void> setTunProxySuspended(bool suspended) async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<bool>('setTunProxySuspended', <String, dynamic>{
      'suspended': suspended,
    });
  }

  static Future<Map<String, dynamic>> getSystemProxy() async {
    if (!Platform.isWindows) return const <String, dynamic>{};
    final value = await _channel.invokeMapMethod<String, dynamic>(
      'getSystemProxy',
    );
    return value ?? const <String, dynamic>{};
  }

  static Future<void> setStartWithWindows(bool enabled) async {
    if (!Platform.isWindows) return;
    final exe = Platform.resolvedExecutable;
    const key = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
    if (enabled) {
      await Process.run('reg.exe', <String>[
        'add',
        key,
        '/v',
        'HongdaStarlink',
        '/t',
        'REG_SZ',
        '/d',
        '"$exe" --startup',
        '/f',
      ]);
    } else {
      await Process.run('reg.exe', <String>[
        'delete',
        key,
        '/v',
        'HongdaStarlink',
        '/f',
      ]);
    }
  }

  static Future<void> startWindowDrag() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('startWindowDrag');
  }

  static Future<void> minimizeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{
      'action': 'minimize',
    });
  }

  static Future<void> toggleMaximizeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{
      'action': 'toggleMaximize',
    });
  }

  static Future<void> closeWindow() async {
    if (!Platform.isWindows) return;
    await _channel.invokeMethod<void>('windowAction', <String, dynamic>{
      'action': 'close',
    });
  }

  static Future<bool> isWindowMaximized() async {
    if (!Platform.isWindows) return false;
    return await _channel.invokeMethod<bool>('isWindowMaximized') ?? false;
  }

  static Future<void> openFolder(String path) async {
    if (!Platform.isWindows) return;
    await Process.start('explorer.exe', <String>[
      path,
    ], mode: ProcessStartMode.detached);
  }
}

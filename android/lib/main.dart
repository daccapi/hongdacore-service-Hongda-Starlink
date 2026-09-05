import 'dart:io';

import 'package:flutter/material.dart';

import 'src/android_app.dart';
import 'src/app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = await AppBootstrap.create();
  if (Platform.isAndroid) {
    runApp(HongdaStarlinkAndroidApp(bootstrap: bootstrap));
    return;
  }
  runApp(HongdaStarlinkApp(
    bootstrap: bootstrap,
    resumeConnectOnLaunch: args.contains('--resume-connect'),
  ));
}

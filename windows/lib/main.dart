import 'package:flutter/material.dart';

import 'src/app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final bootstrap = await AppBootstrap.create();
  runApp(
    HongdaStarlinkApp(
      bootstrap: bootstrap,
      resumeConnectOnLaunch: args.contains('--resume-connect'),
    ),
  );
}

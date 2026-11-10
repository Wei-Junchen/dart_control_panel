import 'package:flutter/material.dart';

import 'package:dart_control_panel/app/home_shell.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';

class DartControlPanelApp extends StatelessWidget {
  const DartControlPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dart Guidance Control Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      builder: (context, child) =>
          MobileUiScale(child: child ?? const SizedBox.shrink()),
      home: const HomeShell(),
    );
  }
}

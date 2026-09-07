import 'package:flutter/material.dart';

import 'screens/home_shell.dart';

class DartControlPanelApp extends StatelessWidget {
  const DartControlPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dart Guidance Control Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.light),
      darkTheme:
          ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomeShell(),
    );
  }
}

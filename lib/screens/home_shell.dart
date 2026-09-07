import 'dart:io';

import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/state_poll_controller.dart';
import 'package:dart_control_panel/models/board_address_store.dart';
import 'package:dart_control_panel/screens/files_screen.dart';
import 'package:dart_control_panel/screens/ground_test_screen.dart';
import 'package:dart_control_panel/screens/mode_screen.dart';
import 'package:dart_control_panel/screens/telemetry_screen.dart';
import 'package:dart_control_panel/widgets/connection_dock.dart';

/// 新导航（4 项）：遥测 · 地面测试 · 模式 · 文件。
/// 拥有唯一的板端连接（左下角 dock）：一次 Connect，全部页面共用。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final BoardSession _session = BoardSession();
  StatePollController? _poll;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  static const _destinations = <_Dest>[
    _Dest(label: 'Telemetry', icon: Icons.radar),
    _Dest(label: 'Ground Test', icon: Icons.video_settings_outlined),
    _Dest(label: 'Mode', icon: Icons.track_changes),
    _Dest(label: 'Files', icon: Icons.folder_open_outlined),
  ];

  @override
  void initState() {
    super.initState();
    final envHost = Platform.environment['DART_CTRL_HOST']?.trim();
    final envPort = Platform.environment['DART_CTRL_PORT']?.trim();
    _hostController =
        TextEditingController(text: (envHost?.isNotEmpty ?? false) ? envHost! : '');
    _portController =
        TextEditingController(text: (envPort?.isNotEmpty ?? false) ? envPort! : '9000');
    if (!(envHost?.isNotEmpty ?? false)) {
      final lastUsed = BoardAddressStore.instance.lastUsed;
      if (lastUsed != null) {
        _hostController.text = lastUsed.host;
        _portController.text = '${lastUsed.port}';
      }
    }
    _session.addListener(_onSessionChanged);
    if (envHost?.isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _poll?.stop();
    _session.disconnect();
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 9000;
    if (host.isEmpty) {
      _session.setStatus('enter a board address first', error: true);
      return;
    }
    _session.updateEndpoint(host, port);
    try {
      await _session.connect();
      _poll?.stop();
      final repo = _session.repository!;
      _poll = StatePollController(
        repository: repo,
        connection: _session.connection!,
        onPolled: _session.updateState,
      );
      _poll!.start();
    } catch (e) {
      _session.setStatus('connect failed: $e', error: true);
    }
  }

  Future<void> _disconnect() async {
    _poll?.stop();
    _poll = null;
    await _session.disconnect();
  }

  void _connectTo(String host, int port) {
    _hostController.text = host;
    _portController.text = '$port';
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final page = _pageFor(_index);
        return wide ? _buildWide(page) : _buildNarrow(page);
      },
    );
  }

  Widget _dock() {
    return Align(
      alignment: Alignment.bottomLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ConnectionDock(
          session: _session,
          hostController: _hostController,
          portController: _portController,
          onConnect: _connect,
          onDisconnect: _disconnect,
        ),
      ),
    );
  }

  Widget _buildWide(Widget page) {
    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: (i) => setState(() => _index = i),
                labelType: NavigationRailLabelType.all,
                leading: const SizedBox(
                  height: 48,
                  child: Center(child: Icon(Icons.track_changes)),
                ),
                destinations: [
                  for (final d in _destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.icon),
                      label: Text(d.label),
                    ),
                ],
              ),
              const VerticalDivider(thickness: 1, width: 1),
              Expanded(child: page),
            ],
          ),
          Positioned(left: 88, bottom: 12, child: _dock()),
        ],
      ),
    );
  }

  Widget _buildNarrow(Widget page) {
    return Scaffold(
      body: Stack(
        children: [
          page,
          Positioned(left: 12, right: 12, bottom: 0, child: _dock()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.icon),
              label: d.label,
            ),
        ],
      ),
    );
  }

  Widget _pageFor(int index) {
    return switch (index) {
      0 => TelemetryScreen(
          session: _session,
          onConnectTo: _connectTo,
        ),
      1 => GroundTestScreen(session: _session),
      2 => ModeScreen(session: _session),
      3 => FilesScreen(host: _session.host, key: ValueKey('files-${_session.host}')),
      _ => const SizedBox.shrink(),
    };
  }
}

class _Dest {
  const _Dest({required this.label, required this.icon});

  final String label;
  final IconData icon;
}
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/state_poll_controller.dart';
import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/models/board_address_store.dart';
import 'package:dart_control_panel/screens/files_screen.dart';
import 'package:dart_control_panel/screens/ground_test_screen.dart';
import 'package:dart_control_panel/screens/mode_screen.dart';
import 'package:dart_control_panel/screens/telemetry_screen.dart';
import 'package:dart_control_panel/widgets/connection_dock.dart';

/// 新导航（4 项）：遥测 · 地面测试 · 模式 · 文件。
/// 拥有唯一的板端连接（左下角 dock）：一次 Connect，全部页面共用。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.telemetryController});

  /// Injectable for tests. Production owns one application-lifetime receiver.
  final TelemetryController? telemetryController;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final BoardSession _session = BoardSession();
  late final TelemetryController _telemetry =
      widget.telemetryController ?? TelemetryController();
  late final bool _ownsTelemetry = widget.telemetryController == null;
  StatePollController? _poll;
  late final TextEditingController _hostController;
  static const int _controlPort = 9000;

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
    _hostController = TextEditingController(
      text: (envHost?.isNotEmpty ?? false) ? envHost! : '',
    );
    if (!(envHost?.isNotEmpty ?? false)) {
      final lastUsed = BoardAddressStore.instance.lastUsed;
      if (lastUsed != null) {
        _hostController.text = lastUsed.host;
      }
    }
    _session.addListener(_onSessionChanged);
    _telemetry.start();
    if (envHost?.isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _poll?.stop();
    _session.disconnect();
    if (_ownsTelemetry) _telemetry.dispose();
    _hostController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) {
      _session.setStatus('enter a board address first', error: true);
      return;
    }
    _session.updateEndpoint(host, _controlPort);
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

  void _connectTo(String host, int _) {
    _hostController.text = host;
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
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ConnectionDock(
            session: _session,
            hostController: _hostController,
            onConnect: _connect,
            onDisconnect: _disconnect,
          ),
        ),
      ),
    );
  }

  Widget _buildWide(Widget page) {
    return Scaffold(
      body: Row(
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
          Expanded(
            child: Column(
              children: [
                Expanded(child: page),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                  child: _dock(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrow(Widget page) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: page),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: _dock(),
          ),
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
        controller: _telemetry,
        session: _session,
        onConnectTo: _connectTo,
      ),
      1 => GroundTestScreen(session: _session),
      2 => ModeScreen(session: _session),
      3 =>
        !_session.connected || _session.state == null
            ? const _ConnectionRequired(feature: 'Files')
            : FilesScreen(
                host: _session.host,
                port: _session.state?.fileService.port ?? 9002,
                key: ValueKey(
                  'files-${_session.host}-'
                  '${_session.state?.fileService.port ?? 9002}-'
                  '${_session.state?.fileService.available ?? false}',
                ),
              ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _ConnectionRequired extends StatelessWidget {
  const _ConnectionRequired({required this.feature});

  final String feature;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(feature)),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off, size: 48),
            SizedBox(height: 12),
            Text('Connect to a board first'),
          ],
        ),
      ),
    );
  }
}

class _Dest {
  const _Dest({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

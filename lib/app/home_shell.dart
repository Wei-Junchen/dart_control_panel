import 'package:dart_control_panel/shared/widgets/board_error_banner.dart';
import 'package:dart_control_panel/core/platform/app_paths.dart';
import 'package:dart_control_panel/core/board/session/auto_board_connector.dart';
import 'package:dart_control_panel/core/preferences/connection_settings.dart';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';

import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/board/session/board_config_snapshot.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';
import 'dart:async';
import 'package:dart_control_panel/core/board/session/state_poll_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/core/preferences/board_address_store.dart';
import 'package:dart_control_panel/features/diagnostics/diagnostics_screen.dart';
import 'package:dart_control_panel/features/devices/devices_screen.dart';
import 'package:dart_control_panel/core/preferences/device_registry.dart';
import 'package:dart_control_panel/app/flight_logs/flight_log_controller.dart';
import 'package:dart_control_panel/app/flight_logs/flight_logs_screen.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';
import 'package:dart_control_panel/features/ground_test/ground_test_screen.dart';
import 'package:dart_control_panel/features/mode/mode_screen.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_screen.dart';
import 'package:dart_control_panel/shared/widgets/connection_dock.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';

/// 新导航（4 项）：遥测 · 地面测试 · 模式 · 文件。
/// 拥有唯一的板端连接（左下角 dock）：一次 Connect，全部页面共用。
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    this.telemetryController,
    this.enableAutoDiscovery = true,
    this.connectionSettingsStore,
    this.deviceRegistry,
  });

  /// Injectable for tests. Production owns one application-lifetime receiver.
  final TelemetryController? telemetryController;

  /// Disable live network discovery in isolated widget tests.
  final bool enableAutoDiscovery;
  final ConnectionSettingsStore? connectionSettingsStore;
  final DeviceRegistry? deviceRegistry;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  final FlightLogController _flightLogs = FlightLogController();
  late final BoardSession _session = BoardSession();
  late final DeviceRegistry _deviceRegistry =
      widget.deviceRegistry ?? DeviceRegistry.instance;
  late final TelemetryController _telemetry =
      widget.telemetryController ?? TelemetryController();
  late final bool _ownsTelemetry = widget.telemetryController == null;
  StatePollController? _poll;
  bool _connectionAction = false;
  AppLifecycleListener? _lifecycle;
  late final TextEditingController _hostController;
  late final _connectionSettings =
      widget.connectionSettingsStore ?? ConnectionSettingsStore();
  late final AutoBoardConnector _autoConnector;
  late bool _automatic;
  late bool _bindWifi;
  static const int _controlPort = 9000;

  static const _destinations = <_Dest>[
    _Dest(label: 'Telemetry', icon: Icons.radar),
    _Dest(label: 'Ground Test', icon: Icons.video_settings_outlined),
    _Dest(label: 'Mode', icon: Icons.track_changes),
    _Dest(label: 'Devices', icon: Icons.devices_other),
  ];

  @override
  void initState() {
    super.initState();
    final envHost = Platform.environment['DART_CTRL_HOST']?.trim();
    final settings = _connectionSettings.load();
    _automatic = !(envHost?.isNotEmpty ?? false) && settings.automatic;
    _bindWifi = settings.bindWifi;
    _autoConnector = AutoBoardConnector(
      onFound: (board) => _connect(discoveredHost: board.host),
    )..addListener(_onDiscoveryChanged);
    _hostController = TextEditingController(
      text: (envHost?.isNotEmpty ?? false)
          ? envHost!
          : (Platform.isAndroid ? '10.198.137.1' : ''),
    );
    if (!(envHost?.isNotEmpty ?? false)) {
      final lastUsed = BoardAddressStore.instance.lastUsed;
      if (lastUsed != null) {
        _hostController.text = lastUsed.host;
      }
    }
    _telemetry.enableConnectionRecording();
    _flightLogs.init();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _telemetry.endConnection();
        return AppExitResponse.exit;
      },
    );
    _session.addListener(_onSessionChanged);
    _telemetry.start();
    if (envHost?.isNotEmpty ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    } else if (_automatic && widget.enableAutoDiscovery) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoConnector.start();
      });
    }
  }

  @override
  void dispose() {
    _flightLogs.dispose();
    _autoConnector.removeListener(_onDiscoveryChanged);
    _autoConnector.dispose();
    _lifecycle?.dispose();
    _session.removeListener(_onSessionChanged);
    _poll?.stop();
    _session.disconnect();
    if (_ownsTelemetry) _telemetry.dispose();
    _hostController.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    final state = _session.state;
    _flightLogs.observeGround(
      _session.connected &&
          state?.mode == 'ground' &&
          state?.fileService.available == true,
    );
    if (mounted) setState(() {});
  }

  void _onDiscoveryChanged() {
    if (mounted) setState(() {});
  }

  void _saveConnectionSettings() => _connectionSettings.save(
    ConnectionSettings(automatic: _automatic, bindWifi: _bindWifi),
  );

  void _setAutomatic(bool value) {
    _autoConnector.stop();
    setState(() => _automatic = value);
    _saveConnectionSettings();
    if (value && !_session.connected) _autoConnector.start();
  }

  void _setBindWifi(bool value) {
    setState(() => _bindWifi = value);
    _saveConnectionSettings();
  }

  void _startConnection() {
    if (_connectionAction) return;
    if (_automatic) {
      _autoConnector.start();
    } else {
      _autoConnector.stop();
      _connect();
    }
  }

  Future<BoardConfigSnapshot?> _captureConnectionConfig(
    BoardRepository repo,
    String host,
    String? deviceId,
    String? sn,
    Directory? sessionDirectory,
  ) async {
    try {
      final beforeRev = _session.state?.configRev;
      final config = await repo.getConfig();
      List<int>? resolvedRoi;
      try {
        final state = await repo.getState();
        final roi = state.worker?.vision.detectRoi;
        if (beforeRev != null &&
            beforeRev == state.configRev &&
            roi != null &&
            roi.length == 4 &&
            roi[0] >= 0 &&
            roi[1] >= 0 &&
            roi[2] > 0 &&
            roi[3] > 0) {
          resolvedRoi = List.of(roi);
        }
      } catch (_) {
        /* A worker may not be running; preserve the config anyway. */
      }
      if (!identical(_session.repository, repo)) return null;
      final snapshot = BoardConfigSnapshot(
        config: config,
        capturedAt: DateTime.now(),
        host: host,
        port: _controlPort,
        deviceId: deviceId,
        sn: sn,
        resolvedRoi: resolvedRoi,
      );
      // Independent writes: a storage failure must not disconnect the board.
      try {
        await snapshot.archive();
      } catch (e) {
        debugPrint('配置快照归档失败: $e');
      }
      if (sessionDirectory != null &&
          identical(_session.repository, repo) &&
          _telemetry.recorder?.sessionDirectory?.path ==
              sessionDirectory.path) {
        try {
          await snapshot.write(
            File('${sessionDirectory.path}/board-config.json'),
          );
        } catch (e) {
          debugPrint('遥测配置快照保存失败: $e');
        }
      }
      return identical(_session.repository, repo) ? snapshot : null;
    } catch (e) {
      debugPrint('读取板端配置快照失败: $e');
      return null;
    }
  }

  Future<bool> _connect({String? discoveredHost}) async {
    if (!mounted ||
        _connectionAction ||
        (discoveredHost != null && _session.connected)) {
      return false;
    }
    final host = discoveredHost ?? _hostController.text.trim();
    if (host.isEmpty) {
      _session.setStatus('enter a board address first', error: true);
      return false;
    }
    _connectionAction = true;
    try {
      await _endConnection();
      if (!mounted ||
          (discoveredHost != null &&
              (!_automatic || !_autoConnector.running))) {
        return false;
      }
      _hostController.text = host;
      _session.updateEndpoint(host, _controlPort);
      await AppPaths.prepareWifi(bindWifi: discoveredHost != null || _bindWifi);
      if (!mounted ||
          (discoveredHost != null &&
              (!_automatic || !_autoConnector.running))) {
        return false;
      }
      await _session.connect();
      if (!mounted ||
          (discoveredHost != null &&
              (!_automatic || !_autoConnector.running))) {
        await _endConnection();
        return false;
      }
      final connectedDevice = _session.state?.device;
      _flightLogs.attach(
        HttpBoardFileApi(host, port: _session.state?.fileService.port ?? 9002),
        _session.repository!,
        mutate: (op, args) => _session.mutate(
          op,
          (repo) => op == 'cleanup_recordings'
              ? repo.cleanupRecordings()
              : repo.deleteRecording(args['path'] as String),
        ),
        deviceId: connectedDevice?.deviceId,
        deviceSn: connectedDevice?.sn,
      );
      _onSessionChanged();
      await _telemetry.beginConnection(
        '$host:$_controlPort',
        deviceId: connectedDevice?.deviceId,
      );
      _poll?.stop();
      final repo = _session.repository!;
      final sessionDirectory = _telemetry.recorder?.sessionDirectory;
      final snapshot = _captureConnectionConfig(
        repo,
        host,
        connectedDevice?.deviceId,
        connectedDevice?.sn,
        sessionDirectory,
      );
      _flightLogs.setConnectionSnapshot(snapshot);
      unawaited(snapshot.then<void>((_) {}));
      final source = _telemetry.source;
      if (source is UdpTelemetrySource) {
        source.configureSchemaLoader(
          repo.getTelemetrySchema,
          peer: InternetAddress.tryParse(host)?.address,
        );
      }
      _poll = StatePollController(
        repository: repo,
        connection: _session.connection!,
        onPolled: _session.updateState,
      );
      _poll!.start();
      return true;
    } catch (e) {
      await _endConnection();
      _session.setStatus('connect failed: $e', error: true);
      return false;
    } finally {
      _connectionAction = false;
    }
  }

  Future<void> _disconnect() async {
    _autoConnector.stop();
    if (_connectionAction) return;
    _connectionAction = true;
    try {
      await _endConnection();
    } finally {
      _connectionAction = false;
    }
  }

  Future<void> _endConnection() async {
    _flightLogs.detach();
    _poll?.stop();
    _poll = null;
    final source = _telemetry.source;
    if (source is UdpTelemetrySource) source.configureSchemaLoader(null);
    try {
      await _telemetry.endConnection();
    } finally {
      await _session.disconnect();
    }
  }

  void _connectTo(String host, int _) {
    _setAutomatic(false);
    _hostController.text = host;
    _connect();
  }

  Future<void> _openDeviceLogs(DeviceRecord record) => _openFlightLogs(record);

  Future<void> _openFlightLogs([
    DeviceRecord? record,
    bool unknown = false,
  ]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => FlightLogsScreen(
          controller: _flightLogs,
          filePort: _session.state?.fileService.port ?? 9002,
          deviceIdFilter: record?.deviceId,
          deviceLabel: unknown ? 'unknown' : record?.label,
          unknownOnly: unknown,
          initialTab: record == null ? 1 : 0,
          onReplay: (archive) async {
            Navigator.of(routeContext).pop();
            await _telemetry.openArchive(archive);
            if (mounted) setState(() => _index = 0);
          },
        ),
      ),
    );
  }

  void _openDiagnostics() {
    if (!_session.connected) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            DiagnosticsScreen(session: _session, onConnectTo: _connectTo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >= 900 ||
            (constraints.maxWidth >= 600 &&
                constraints.maxWidth > constraints.maxHeight);
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
            onConnect: _startConnection,
            onDisconnect: _disconnect,
            automatic: _automatic,
            bindWifi: _bindWifi,
            discovering: _autoConnector.running,
            discoveryMessage: _autoConnector.message,
            onAutomaticChanged: _setAutomatic,
            onBindWifiChanged: _setBindWifi,
          ),
        ),
      ),
    );
  }

  Future<void> _showConnection() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: const Text('Board Connect'),
      content: SizedBox(
        width: 480,
        child: ListenableBuilder(
          listenable: _autoConnector,
          builder: (context, _) => StatefulBuilder(
            builder: (context, refresh) => ConnectionDock(
              session: _session,
              hostController: _hostController,
              onConnect: _startConnection,
              onDisconnect: _disconnect,
              automatic: _automatic,
              bindWifi: _bindWifi,
              discovering: _autoConnector.running,
              discoveryMessage: _autoConnector.message,
              onAutomaticChanged: (value) {
                _setAutomatic(value);
                refresh(() {});
              },
              onBindWifiChanged: (value) {
                _setBindWifi(value);
                refresh(() {});
              },
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Widget _buildWide(Widget page) {
    final handset = MobileUiScale.isHandset(context);
    return Scaffold(
      resizeToAvoidBottomInset: handset ? false : null,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Row(
          children: [
            if (handset)
              SizedBox(
                key: const ValueKey('mobile-navigation'),
                width: 56,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Column(
                    children: [
                      const SizedBox(height: 32),
                      for (var i = 0; i < _destinations.length; i++)
                        Tooltip(
                          message: _destinations[i].label,
                          child: Semantics(
                            selected: _index == i,
                            button: true,
                            child: InkWell(
                              onTap: () => setState(() => _index = i),
                              child: Container(
                                height: 56,
                                alignment: Alignment.center,
                                color: _index == i
                                    ? Theme.of(
                                        context,
                                      ).colorScheme.secondaryContainer
                                    : null,
                                child: Icon(_destinations[i].icon, size: 24),
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      ListenableBuilder(
                        listenable: _session,
                        builder: (context, _) => Tooltip(
                          message: 'Board Connect',
                          child: InkWell(
                            key: const ValueKey('mobile-connection-button'),
                            onTap: _showConnection,
                            child: SizedBox(
                              height: 56,
                              child: Center(
                                child: Icon(
                                  _session.connected
                                      ? Icons.link
                                      : Icons.link_off,
                                  size: 24,
                                  color: _session.connected
                                      ? Colors.teal
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(
                        height: MediaQuery.paddingOf(context).bottom + 6,
                      ),
                    ],
                  ),
                ),
              )
            else
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
                  BoardErrorBanner(state: _session.state),
                  Expanded(child: page),
                  if (!handset)
                    Padding(
                      padding: MediaQuery.sizeOf(context).height < 500
                          ? const EdgeInsets.symmetric(horizontal: 12)
                          : const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      child: _dock(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(Widget page) {
    return Scaffold(
      body: Column(
        children: [
          BoardErrorBanner(state: _session.state),
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
        onOpenDiagnostics: _openDiagnostics,
      ),
      1 => GroundTestScreen(session: _session),
      2 => ModeScreen(session: _session),
      3 => DevicesScreen(
        registry: _deviceRegistry,
        session: _session,
        onConnect: _connectTo,
        onOpenLogs: _openDeviceLogs,
        onOpenAllLogs: () => _openFlightLogs(),
        onOpenUnknownLogs: () => _openFlightLogs(null, true),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _Dest {
  const _Dest({required this.label, required this.icon});

  final String label;
  final IconData icon;
}

import 'package:flutter/material.dart';
import 'telemetry_recording_controls.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_controller.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/attitude_view.dart';
import 'package:dart_control_panel/shared/widgets/metric_card.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:dart_control_panel/features/telemetry/seeker_target_view.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_chart.dart';

/// Telemetry visualization screen.
///
/// - Left: 3D missile attitude indicator driven by yaw/pitch/roll.
/// - Center: compact current values and primary realtime chart.
/// - Right: searchable, grouped channel sidebar (desktop).
/// - Names/types come from TCP; samples come from indexed UDP (legacy fallback).
class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({
    super.key,
    this.controller,
    this.session,
    this.onOpenDiagnostics,
  });

  /// Injectable for tests; defaults to the UDP receiver on port 1347.
  final TelemetryController? controller;

  /// Optional shared board session for the slim daemon status strip.
  final BoardSession? session;

  /// Navigation is owned by the app shell, not by this feature.
  final VoidCallback? onOpenDiagnostics;

  @override
  State<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends State<TelemetryScreen> {
  late final TelemetryController _controller =
      widget.controller ?? TelemetryController();
  String _channelQuery = '';
  late final bool _ownsController = widget.controller == null;
  late double _seekerFadeSeconds = _controller.window.toDouble();
  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    final session = widget.session;
    _controller.start();
    if (session != null) {
      session.addListener(_onSessionChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    widget.session?.removeListener(_onSessionChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final handset = MobileUiScale.isHandset(context);
    return Theme(
      data: theme.copyWith(
        cardTheme: CardThemeData(
          elevation: 0,
          color: theme.brightness == Brightness.light
              ? const Color(0xFFFCFEFF)
              : colors.surface,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .65),
            ),
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: theme.brightness == Brightness.light
            ? const Color(0xFFF3F7FA)
            : colors.surfaceContainerLowest,
        appBar: AppBar(
          toolbarHeight: handset ? 28 : 48,
          titleTextStyle: handset
              ? theme.textTheme.titleSmall?.copyWith(color: colors.onSurface)
              : null,
          title: const Row(
            children: [
              Icon(Icons.show_chart, size: 22),
              SizedBox(width: 10),
              Text('Telemetry'),
            ],
          ),
          actions: [
            if (handset)
              IconButton(
                tooltip: '姿态与目标',
                icon: const Icon(Icons.threed_rotation, size: 20),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('姿态与目标'),
                    content: SizedBox(
                      width: 420,
                      child: ListenableBuilder(
                        listenable: _controller,
                        builder: (context, _) => SingleChildScrollView(
                          child: Column(
                            children: [
                              _attitudeCard(context, extent: 160),
                              const SizedBox(height: 8),
                              _seekerCard(context, extent: 160),
                            ],
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
                ),
              ),
            if (_controller.source is UdpTelemetrySource)
              IconButton(
                tooltip: 'UART fields (TCP)',
                icon: const Icon(Icons.schema_outlined),
                onPressed: _showUartSchema,
              ),
            if (MediaQuery.sizeOf(context).width >= 700) ...[
              Text(_sourceStatus),
              const SizedBox(width: 8),
            ],
            if (session == null)
              IconButton(
                tooltip: _controller.running ? 'Pause' : 'Run',
                icon: Icon(
                  _controller.running ? Icons.pause : Icons.play_arrow,
                ),
                onPressed: () {
                  if (_controller.running) {
                    _controller.stop();
                  } else {
                    _controller.start();
                  }
                },
              ),
            if (session != null && widget.onOpenDiagnostics != null)
              PopupMenuButton<String>(
                tooltip: 'Tools',
                icon: const Icon(Icons.build_outlined),
                onSelected: (item) {
                  if (item == 'diagnostics' && session.connected) {
                    widget.onOpenDiagnostics?.call();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'diagnostics',
                    child: Text('Diagnostics (schema/log/export)'),
                  ),
                ],
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              margin: EdgeInsets.fromLTRB(
                handset ? 4 : 12,
                0,
                handset ? 4 : 12,
                4,
              ),
              padding: EdgeInsets.symmetric(vertical: handset ? 0 : 3),
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(
                  color: colors.outlineVariant.withValues(alpha: .65),
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Theme(
                data: handset
                    ? theme.copyWith(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textButtonTheme: const TextButtonThemeData(
                          style: ButtonStyle(
                            minimumSize: WidgetStatePropertyAll(Size(0, 28)),
                            padding: WidgetStatePropertyAll(
                              EdgeInsets.symmetric(horizontal: 6),
                            ),
                          ),
                        ),
                      )
                    : theme,
                child: TelemetryRecordingControls(controller: _controller),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (handset && constraints.maxWidth >= 600) {
                    final content = Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: _chartCard(context)),
                          const SizedBox(width: 6),
                          SizedBox(
                            width: (constraints.maxWidth * .23).clamp(
                              170.0,
                              210.0,
                            ),
                            child: _channelsSidebar(context),
                          ),
                        ],
                      ),
                    );
                    return constraints.maxHeight < 220
                        ? SingleChildScrollView(
                            child: SizedBox(height: 220, child: content),
                          )
                        : content;
                  }
                  final wide = constraints.maxWidth >= 1050;
                  final extent = wide
                      ? (constraints.maxHeight / 2 - 140).clamp(130.0, 210.0)
                      : 210.0;
                  final attitude = _attitudeCard(context, extent: extent);
                  final seeker = _seekerCard(context, extent: extent);
                  if (wide) {
                    final leftWidth = (constraints.maxWidth * .18).clamp(
                      200.0,
                      260.0,
                    );
                    final rightWidth = (constraints.maxWidth * .22).clamp(
                      260.0,
                      320.0,
                    );
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: leftWidth,
                            child: ListView(
                              children: [
                                attitude,
                                const SizedBox(height: 10),
                                seeker,
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, panel) {
                                final height = panel.maxHeight.clamp(
                                  380.0,
                                  double.infinity,
                                );
                                final content = Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _latestValuesCard(context),
                                    const SizedBox(height: 10),
                                    Expanded(child: _chartCard(context)),
                                  ],
                                );
                                return panel.maxHeight < 380
                                    ? SingleChildScrollView(
                                        child: SizedBox(
                                          height: height,
                                          child: content,
                                        ),
                                      )
                                    : content;
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: rightWidth,
                            child: _channelsSidebar(context),
                          ),
                        ],
                      ),
                    );
                  }
                  final compactLandscape =
                      constraints.maxWidth >= 600 &&
                      MediaQuery.sizeOf(context).height < 500;
                  return ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (compactLandscape) ...[
                        SizedBox(height: 280, child: _chartCard(context)),
                        const SizedBox(height: 8),
                      ],
                      if (!compactLandscape) ...[
                        Center(child: attitude),
                        const SizedBox(height: 12),
                        Center(child: seeker),
                        const SizedBox(height: 12),
                      ],
                      _channelsCard(context),
                      const SizedBox(height: 8),
                      _latestValuesCard(context),
                      const SizedBox(height: 8),
                      if (!compactLandscape)
                        SizedBox(height: 280, child: _chartCard(context)),
                      if (compactLandscape) ...[
                        Center(child: attitude),
                        const SizedBox(height: 12),
                        Center(child: seeker),
                      ],
                    ],
                  );
                },
              ),
            ),
            if (session != null) _daemonStrip(context, session),
          ],
        ),
      ),
    );
  }

  /// Slim daemon status strip at the top of the page.
  Widget _daemonStrip(BuildContext context, BoardSession session) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final state = session.state;
        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: MediaQuery.sizeOf(context).height < 500 ? 2 : 6,
          ),
          child: Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                state == null ? 'not connected' : state.state,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: _stateColor(state?.state ?? ''),
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (state != null) ...[
                Text(
                  'mode: ${state.mode}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  '${state.profile} · rot ${state.rotation}°',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'config_rev ${state.configRev}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'fps ${state.worker?.performance.fps.toStringAsFixed(0) ?? '-'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'temp ${state.resources.temperatureC?.toStringAsFixed(1) ?? '-'}°C',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Color _stateColor(String state) => switch (state) {
    'STREAMING' => Colors.green,
    'ERROR' => Colors.red,
    'STANDBY' => Colors.blueGrey,
    '' => Colors.grey,
    _ => Colors.amber,
  };

  Future<void> _showUartSchema() async {
    final source = _controller.source as UdpTelemetrySource;
    await source.refreshSchema();
    if (!mounted) return;
    final schema = source.schema;
    final fields =
        schema?.fields.where((f) => f.sourceName != null).toList() ?? [];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('UART 接收字段 · TCP'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  schema == null
                      ? '尚未取得字段表：${source.lastError ?? "请连接板端 TCP"}'
                      : 'Schema ${schema.id} · UART ${schema.uartReady ? "ready" : "等待串口握手"}',
                ),
                const SizedBox(height: 12),
                for (final field in fields)
                  ListTile(
                    dense: true,
                    leading: Text('#${field.index}'),
                    title: Text(field.sourceName!),
                    trailing: Text(field.type),
                  ),
                if (schema != null && fields.isEmpty)
                  const Text('当前没有已注册的 UART 字段'),
              ],
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
  }

  String get _sourceStatus {
    if (!_controller.running) return 'paused';
    final source = _controller.source;
    if (source is UdpTelemetrySource) {
      final age = source.lastPacketAt == null
          ? 'waiting'
          : '${DateTime.now().difference(source.lastPacketAt!).inMilliseconds} ms ago';
      return '${source.label} · ${source.packets} pkt · $age';
    }
    return 'live — ${source.label}';
  }

  Widget _attitudeCard(BuildContext context, {double extent = 210}) {
    final attitude = _controller.attitude;
    Widget row(String label, double value, String unit, Color color) => Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Text(
          value.isNaN ? '--' : '${value.toStringAsFixed(1)}$unit',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
    return MetricCard(
      title: 'Attitude (UDP UART)',
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: extent, maxHeight: extent),
            child: AttitudeView(
              pitchDeg: attitude.pitch,
              rollDeg: attitude.roll,
              yawDeg: attitude.yaw,
            ),
          ),
        ),
        const SizedBox(height: 8),
        row('Yaw', attitude.yaw, '°', const Color(0xFF81C784)),
        row('Pitch', attitude.pitch, '°', const Color(0xFF4FC3F7)),
        row('Roll', attitude.roll, '°', const Color(0xFFE57373)),
      ],
    );
  }

  String _channelGroup(TelemetryChannel channel) {
    final id = channel.id.toLowerCase();
    if (id.contains('servo') ||
        id.contains('ref') ||
        id.contains('fdb') ||
        id.contains('out') ||
        id.contains('working') ||
        id.contains('dart_state')) {
      return 'Control';
    }
    if (id.contains('gyro') || id.contains('rate')) {
      return 'Rates';
    }
    if (id.contains('target') ||
        id.contains('vision') ||
        id.contains('pixels') ||
        id.contains('found') ||
        id.contains('brightness') ||
        id.contains('area')) {
      return 'Vision';
    }
    if (id.contains('pitch') ||
        id.contains('roll') ||
        id.contains('yaw') ||
        id.contains('fpa') ||
        id.contains('height') ||
        id.contains('angle')) {
      return 'Attitude';
    }
    if (id.contains('speed') ||
        id.contains('body_v') ||
        id.contains('ned_v') ||
        id.contains('acc_') ||
        id.contains('launch')) {
      return 'Motion';
    }
    return 'System';
  }

  Widget _viewPreferences(BuildContext context) => SizedBox(
    width: MobileUiScale.isHandset(context) ? 30 : 48,
    height: MobileUiScale.isHandset(context) ? 30 : 48,
    child: PopupMenuButton<String>(
      key: const ValueKey('telemetry-view-preferences'),
      tooltip: '曲线偏好',
      icon: const Icon(Icons.tune, size: 18),
      padding: EdgeInsets.zero,
      onSelected: (action) {
        String? message;
        switch (action) {
          case 'remember':
            _controller.setRememberChannels(!_controller.rememberChannels);
          case 'save':
            message = _controller.saveDefaultChannels()
                ? '当前多曲线选择已保存为默认'
                : '保存偏好失败：${_controller.viewPreferenceError}';
          case 'load':
            _controller.loadDefaultChannels();
            message = '已加载默认曲线选择';
          case 'reset':
            _controller.restoreInitialChannels();
            message = '已恢复 Pitch / Roll / Yaw';
        }
        if (message != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }
      },
      itemBuilder: (_) => [
        CheckedPopupMenuItem(
          value: 'remember',
          checked: _controller.rememberChannels,
          child: const Text('自动记住曲线选择'),
        ),
        const PopupMenuItem(value: 'save', child: Text('保存当前为默认')),
        const PopupMenuItem(value: 'load', child: Text('加载默认曲线')),
        const PopupMenuItem(value: 'reset', child: Text('恢复初始曲线')),
      ],
    ),
  );

  Widget _channelsSidebar(BuildContext context) {
    final handset = MobileUiScale.isHandset(context);
    final query = _channelQuery.trim().toLowerCase();
    final groups = <String, List<TelemetryChannel>>{
      for (final group in [
        'Attitude',
        'Rates',
        'Control',
        'Vision',
        'Motion',
        'System',
      ])
        group: [],
    };
    for (final channel in _controller.channels) {
      if (query.isEmpty ||
          channel.id.toLowerCase().contains(query) ||
          channel.label.toLowerCase().contains(query)) {
        groups[_channelGroup(channel)]!.add(channel);
      }
    }
    return Card(
      key: const ValueKey('telemetry-channel-sidebar'),
      child: Padding(
        padding: EdgeInsets.all(handset ? 6 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Channels',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: handset ? 12 : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_controller.channels.where((c) => _controller.selected.contains(c.id)).length}/${_controller.channels.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const Spacer(),
                _viewPreferences(context),
              ],
            ),
            SizedBox(height: handset ? 4 : 10),
            TextField(
              key: const ValueKey('telemetry-channel-search'),
              style: handset ? const TextStyle(fontSize: 12) : null,
              decoration: InputDecoration(
                isDense: true,
                constraints: handset
                    ? const BoxConstraints.tightFor(height: 32)
                    : null,
                prefixIconConstraints: handset
                    ? const BoxConstraints.tightFor(width: 28, height: 32)
                    : null,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: 'Search ${_controller.channels.length} channels...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: handset ? 4 : 10,
                ),
              ),
              onChanged: (value) => setState(() => _channelQuery = value),
            ),
            SizedBox(height: handset ? 4 : 8),
            Expanded(
              child: ListView(
                children: [
                  for (final entry in groups.entries)
                    if (entry.value.isNotEmpty)
                      ExpansionTile(
                        key: PageStorageKey('channels-${entry.key}'),
                        initiallyExpanded: true,
                        tilePadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        dense: true,
                        minTileHeight: handset ? 30 : null,
                        childrenPadding: EdgeInsets.zero,
                        title: Text(
                          '${entry.key} (${entry.value.where((c) => _controller.selected.contains(c.id)).length})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        children: [
                          for (final channel in entry.value)
                            _channelRow(context, channel),
                        ],
                      ),
                  if (groups.values.every((list) => list.isEmpty))
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No matching channels'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelRow(BuildContext context, TelemetryChannel channel) {
    final selected = _controller.selected.contains(channel.id);
    return Tooltip(
      message:
          '${channel.id}${channel.type == null ? "" : " · ${channel.type}"}',
      child: InkWell(
        onTap: () => _controller.toggleChannel(channel.id),
        child: SizedBox(
          height: MobileUiScale.isHandset(context) ? 28 : 34,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Checkbox(
                  value: selected,
                  onChanged: (_) => _controller.toggleChannel(channel.id),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: selected ? channel.color : Colors.blueGrey.shade200,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 78),
                child: Text(
                  _formatLatest(channel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected
                        ? channel.color
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _channelsCard(BuildContext context, {double maxFieldsHeight = 180}) {
    final query = _channelQuery.trim().toLowerCase();
    final channels = _controller.channels.where(
      (c) =>
          query.isEmpty ||
          c.id.toLowerCase().contains(query) ||
          c.label.toLowerCase().contains(query),
    );
    return MetricCard(
      title: 'Channels (real-time plot)',
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _viewPreferences(context),
        ),
        TextField(
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search ${_controller.channels.length} channels',
          ),
          onChanged: (value) => setState(() => _channelQuery = value),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxFieldsHeight),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final channel in channels)
                  Tooltip(
                    message:
                        '${channel.id}${channel.type == null ? "" : " · ${channel.type}"}',
                    child: FilterChip(
                      avatar: CircleAvatar(
                        backgroundColor: channel.color,
                        radius: 7,
                      ),
                      label: Text(
                        '${channel.label} '
                        '${_controller.latestValueOf(channel.id).isNaN ? "--" : _controller.latestValueOf(channel.id).toStringAsFixed(1)}${channel.unit}',
                      ),
                      selected: _controller.selected.contains(channel.id),
                      onSelected: (_) => _controller.toggleChannel(channel.id),
                    ),
                  ),
                if (channels.isEmpty) const Text('No matching channels'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _seekerCard(BuildContext context, {double extent = 210}) {
    final frame = _seekerFrameSize;
    final maxFadeSeconds = _controller.window < 1
        ? 1.0
        : _controller.window.toDouble();
    final fadeSeconds = _seekerFadeSeconds
        .clamp(1.0, maxFadeSeconds)
        .toDouble();
    final fadeAdjustable = maxFadeSeconds > 1;
    final validPoints = seekerTargetPoints(
      samples: _controller.samples,
      frameSize: frame,
      now: _controller.now,
      windowSeconds: fadeSeconds,
    );
    final latest = validPoints.isEmpty ? null : validPoints.last;
    final coordinateSpace =
        widget.session?.state?.worker?.view.coordinateSpace ?? 'view';
    return MetricCard(
      title: '2D Seeker target trail',
      children: [
        Center(
          child: SizedBox.square(
            dimension: extent,
            child: SeekerTargetView(
              samples: _controller.samples,
              frameSize: frame,
              windowSeconds: fadeSeconds,
              now: _controller.now,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 44, child: Text('Fade')),
            Expanded(
              child: Slider(
                key: const ValueKey('seeker-fade-slider'),
                value: fadeSeconds,
                min: fadeAdjustable ? 1 : 0,
                max: maxFadeSeconds,
                divisions: fadeAdjustable ? _controller.window - 1 : 1,
                label: '${fadeSeconds.round()} s',
                onChanged: fadeAdjustable
                    ? (value) {
                        setState(() => _seekerFadeSeconds = value);
                      }
                    : null,
              ),
            ),
            SizedBox(
              width: 42,
              child: Text(
                '${fadeSeconds.round()} s',
                key: const ValueKey('seeker-fade-value'),
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        Text(
          '${frame.width.toInt()}×${frame.height.toInt()} $coordinateSpace '
          '· ${fadeSeconds.round()}s trail '
          '· ${latest == null ? 'target --' : 'target ${latest.x.toStringAsFixed(0)}, ${latest.y.toStringAsFixed(0)}'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Size get _seekerFrameSize {
    final state = widget.session?.state;
    final candidates = <List<int>>[
      state?.worker?.view.output ?? const [],
      state?.worker?.camera.output ?? const [],
      state?.expected?.output ?? const [],
    ];
    for (final output in candidates) {
      if (output.length >= 2 && output[0] > 0 && output[1] > 0) {
        return Size(output[0].toDouble(), output[1].toDouble());
      }
    }
    // UDP intentionally carries coordinates, not per-packet dimensions. This
    // fallback is only used until the first daemon state supplies view.output.
    return const Size(640, 360);
  }

  Widget _chartCard(BuildContext context) {
    final handset = MobileUiScale.isHandset(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: EdgeInsets.all(handset ? 4 : 8),
        child: Column(
          children: [
            if (!handset)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.show_chart, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'Telemetry curves',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: '滚轮缩放 Y 轴 · 双击恢复自动范围',
                      child: Icon(
                        Icons.zoom_in,
                        size: 18,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: TelemetryChart(controller: _controller)),
            Theme(
              data: handset
                  ? Theme.of(context).copyWith(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textButtonTheme: const TextButtonThemeData(
                        style: ButtonStyle(
                          minimumSize: WidgetStatePropertyAll(Size(0, 28)),
                          padding: WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 6),
                          ),
                          textStyle: WidgetStatePropertyAll(
                            TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                      iconButtonTheme: const IconButtonThemeData(
                        style: ButtonStyle(
                          minimumSize: WidgetStatePropertyAll(Size(28, 28)),
                          padding: WidgetStatePropertyAll(EdgeInsets.zero),
                          iconSize: WidgetStatePropertyAll(20),
                        ),
                      ),
                    )
                  : Theme.of(context),
              child: TelemetryRecordingControls(
                controller: _controller,
                timeline: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _latestValuesCard(BuildContext context) {
    final selected = _controller.channels
        .where((channel) => _controller.selected.contains(channel.id))
        .toList();
    for (final channel in _controller.channels) {
      if (channel.id == 'capture_fps' &&
          !_controller.selected.contains(channel.id)) {
        selected.add(channel);
      }
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current values',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: selected.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final channel = selected[index];
                  return Container(
                    width: 125,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: channel.color.withValues(alpha: 0.06),
                      border: Border.all(
                        color: channel.color.withValues(alpha: 0.15),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          _formatLatest(channel),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: channel.color,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLatest(TelemetryChannel channel) {
    final value = _controller.latestValueOf(channel.id);
    if (!value.isFinite) return '--';
    final digits = value.abs() >= 1000 ? 0 : (value.abs() >= 100 ? 1 : 2);
    final suffix = channel.unit.isEmpty ? '' : ' ${channel.unit}';
    return '${value.toStringAsFixed(digits)}$suffix';
  }
}

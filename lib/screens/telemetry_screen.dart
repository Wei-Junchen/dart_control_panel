import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/screens/diagnostics_screen.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/telemetry/udp_telemetry_source.dart';
import 'package:dart_control_panel/widgets/attitude_view.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';
import 'package:dart_control_panel/widgets/seeker_target_view.dart';
import 'package:dart_control_panel/widgets/telemetry_chart.dart';

/// Telemetry visualization screen.
///
/// - Left: 3D missile attitude indicator driven by yaw/pitch/roll.
/// - Right: channel checkboxes (勾选) + live multi-series realtime chart.
/// - Data comes directly from the board's VOFA+ FireWater UDP broadcast.
class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({
    super.key,
    this.controller,
    this.session,
    this.onConnectTo,
  });

  /// Injectable for tests; defaults to the UDP receiver on port 1347.
  final TelemetryController? controller;

  /// Optional shared board session for the slim daemon status strip +
  /// the diagnostics tool.
  final BoardSession? session;
  final void Function(String host, int port)? onConnectTo;

  @override
  State<TelemetryScreen> createState() => _TelemetryScreenState();
}

class _TelemetryScreenState extends State<TelemetryScreen> {
  late final TelemetryController _controller =
      widget.controller ?? TelemetryController();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Telemetry'),
        actions: [
          if (MediaQuery.sizeOf(context).width >= 700) ...[
            Text(_sourceStatus),
            const SizedBox(width: 8),
          ],
          if (session == null)
            IconButton(
              tooltip: _controller.running ? 'Pause' : 'Run',
              icon: Icon(_controller.running ? Icons.pause : Icons.play_arrow),
              onPressed: () {
                if (_controller.running) {
                  _controller.stop();
                } else {
                  _controller.start();
                }
              },
            ),
          if (session != null)
            PopupMenuButton<String>(
              tooltip: 'Tools',
              icon: const Icon(Icons.build_outlined),
              onSelected: (item) {
                if (item == 'diagnostics' && session.connected) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DiagnosticsScreen(
                        session: session,
                        onConnectTo: widget.onConnectTo,
                      ),
                    ),
                  );
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
          if (session != null) _daemonStrip(context, session),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 900;
                final attitude = _attitudeCard(context);
                final seeker = _seekerCard(context);
                if (wide) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 360,
                          child: ListView(
                            children: [
                              attitude,
                              const SizedBox(height: 12),
                              seeker,
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _channelsCard(context),
                              const SizedBox(height: 8),
                              _latestValuesCard(context),
                              const SizedBox(height: 8),
                              Expanded(child: _chartCard(context)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    Center(child: attitude),
                    const SizedBox(height: 12),
                    Center(child: seeker),
                    const SizedBox(height: 12),
                    _channelsCard(context),
                    const SizedBox(height: 8),
                    _latestValuesCard(context),
                    const SizedBox(height: 8),
                    SizedBox(height: 280, child: _chartCard(context)),
                  ],
                );
              },
            ),
          ),
        ],
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
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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

  Widget _attitudeCard(BuildContext context) {
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
            constraints: const BoxConstraints(maxWidth: 320, maxHeight: 320),
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

  Widget _channelsCard(BuildContext context) {
    return MetricCard(
      title: 'Channels (real-time plot)',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final channel in TelemetryChannel.all)
              FilterChip(
                avatar: CircleAvatar(backgroundColor: channel.color, radius: 7),
                label: Text(
                  '${channel.label} '
                  '${_controller.latestValueOf(channel.id).isNaN ? '--' : _controller.latestValueOf(channel.id).toStringAsFixed(1)}${channel.unit}',
                ),
                selected: _controller.selected.contains(channel.id),
                onSelected: (_) => _controller.toggleChannel(channel.id),
              ),
          ],
        ),
      ],
    );
  }

  Widget _seekerCard(BuildContext context) {
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
      now: DateTime.now(),
      windowSeconds: fadeSeconds,
    );
    final latest = validPoints.isEmpty ? null : validPoints.last;
    final coordinateSpace =
        widget.session?.state?.worker?.view.coordinateSpace ?? 'view';
    return MetricCard(
      title: '2D Seeker target trail',
      children: [
        Center(
          child: SeekerTargetView(
            samples: _controller.samples,
            frameSize: frame,
            windowSeconds: fadeSeconds,
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
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: TelemetryChart(controller: _controller),
      ),
    );
  }

  Widget _latestValuesCard(BuildContext context) {
    final selected = TelemetryChannel.all
        .where((channel) => _controller.selected.contains(channel.id))
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current values',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 62,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: selected.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final channel = selected[index];
                  return Container(
                    width: 132,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: channel.color.withValues(alpha: 0.10),
                      border: Border.all(
                        color: channel.color.withValues(alpha: 0.45),
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

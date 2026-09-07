import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/telemetry_controller.dart';
import 'package:dart_control_panel/screens/diagnostics_screen.dart';
import 'package:dart_control_panel/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/widgets/attitude_view.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';
import 'package:dart_control_panel/widgets/telemetry_chart.dart';

/// Telemetry visualization screen.
///
/// - Left: 3D missile attitude indicator driven by yaw/pitch/roll.
/// - Right: channel checkboxes (勾选) + live multi-series realtime chart.
/// - Data source is [DummyTelemetrySource] until the board exposes a real
///   telemetry interface (swap it in [TelemetryController] only).
class TelemetryScreen extends StatefulWidget {
  const TelemetryScreen({
    super.key,
    this.controller,
    this.session,
    this.onConnectTo,
  });

  /// Injectable for tests; defaults to a dummy-source controller.
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

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.stop();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    // keep the dummy envelope in sync with the board-reported mode
    if (session?.state != null) {
      _controller.setModeProfile(session!.state!.mode);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Telemetry'),
        actions: [
          Text(_controller.running ? 'live — ${_controller.source.label}' : 'paused'),
          const SizedBox(width: 8),
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
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DiagnosticsScreen(
                      session: session,
                      onConnectTo: widget.onConnectTo,
                    ),
                  ));
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'diagnostics', child: Text('Diagnostics (schema/log/export)')),
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
                if (wide) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 360, child: attitude),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _channelsCard(context),
                              const SizedBox(height: 12),
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
                    _channelsCard(context),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 280,
                      child: _chartCard(context),
                    ),
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
                Text('mode: ${state.mode}',
                    style: Theme.of(context).textTheme.bodySmall),
                Text('${state.profile} · rot ${state.rotation}°',
                    style: Theme.of(context).textTheme.bodySmall),
                Text('config_rev ${state.configRev}',
                    style: Theme.of(context).textTheme.bodySmall),
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

  Widget _attitudeCard(BuildContext context) {
    final attitude = _controller.attitude;
    Widget row(String label, double value, String unit, Color color) => Row(
          children: [
            SizedBox(
              width: 48,
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Text(
              value.isNaN ? '--' : '${value.toStringAsFixed(1)}$unit',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        );
    return MetricCard(
      title: 'Attitude (dummy)',
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
                avatar: CircleAvatar(
                  backgroundColor: channel.color,
                  radius: 7,
                ),
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

  Widget _chartCard(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: TelemetryChart(controller: _controller),
      ),
    );
  }
}
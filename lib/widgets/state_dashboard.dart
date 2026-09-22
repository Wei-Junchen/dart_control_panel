import 'package:flutter/material.dart';

import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';

/// P2 presentational dashboard: renders every section of [DaemonState] with
/// the same information parity as the old Tk GUI.
///
/// Pure presentation — takes an immutable [DaemonState] and lays it out
/// responsively (single column on narrow windows, wrapping grid on wide
/// windows). No socket/polling logic lives here, which keeps it unit
/// testable.
class StateDashboard extends StatelessWidget {
  const StateDashboard({super.key, required this.state});

  final DaemonState state;

  @override
  Widget build(BuildContext context) {
    final worker = state.worker;
    final cards = <Widget>[
      if (state.isTransitional) _TransitionBanner(state: state),
      DaemonCard(state: state),
      if (worker != null) ..._workerCards(state, worker),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 820;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: wide
              ? Wrap(spacing: 12, runSpacing: 12, children: cards)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cards,
                ),
        );
      },
    );
  }

  List<Widget> _workerCards(DaemonState state, WorkerState worker) => [
    PerformanceCard(worker: worker),
    TargetCard(worker: worker),
    IspCard(camera: worker.camera),
    VisionCard(worker: worker),
    ResourcesCard(resources: state.resources, features: state.features),
    ViewControlCard(worker: worker),
    UartCard(worker: worker),
    StreamCard(worker: worker),
  ];
}

/// Banner shown while the daemon is in a transitional state
/// (STARTING / STANDBY_PENDING / WAKING / STOPPING) — the UI must not imply a
/// settled state and should disable conflicting actions.
class _TransitionBanner extends StatelessWidget {
  const _TransitionBanner({required this.state});

  final DaemonState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.autorenew, color: theme.colorScheme.onTertiaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Transitioning: ${state.state}${state.pendingProfile != null ? ' → ${state.pendingProfile}' : ''}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const SizedBox(width: 96, child: LinearProgressIndicator()),
          ],
        ),
      ),
    );
  }
}

class DaemonCard extends StatelessWidget {
  const DaemonCard({super.key, required this.state});

  final DaemonState state;

  @override
  Widget build(BuildContext context) {
    final transitional = state.isTransitional;
    return MetricCard(
      title: 'Daemon',
      trailing: StateBadge(state: state.state),
      children: [
        StatRow(label: 'mode', value: state.mode),
        StatRow(
          label: 'image settings',
          value: state.imageSettingsLocked ? 'locked' : 'editable',
        ),
        StatRow(label: 'profile', value: state.profile),
        StatRow(label: 'pending', value: state.pendingProfile ?? '-'),
        StatRow(label: 'rotation', value: '${state.rotation}°'),
        StatRow(label: 'config_rev', value: '${state.configRev}'),
        if (state.configWarning.isNotEmpty)
          StatRow(
            label: 'config warning',
            value: state.configWarning,
            highlight: true,
          ),
        StatRow(
          label: 'last known good',
          value: state.lastKnownGood.isEmpty ? '-' : state.lastKnownGood,
        ),
        StatRow(label: 'worker pid', value: '${state.workerPid}'),
        StatRow(
          label: 'daemon uptime',
          value: '${(state.daemonUptimeS ?? 0).toStringAsFixed(0)} s',
        ),
        StatRow(label: 'restarts', value: '${state.restarts}'),
        StatRow(
          label: 'file service',
          value:
              ':${state.fileService.port} '
              '${state.fileService.available ? 'ready' : 'locked'}',
          highlight: state.fileService.enabled && !state.fileService.available,
        ),
        StatRow(
          label: 'last error',
          value: state.lastError.isEmpty ? '-' : state.lastError,
          highlight: state.lastError.isNotEmpty,
        ),
        if (transitional)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: LinearProgressIndicator(backgroundColor: Colors.transparent),
          ),
      ],
    );
  }
}

class StateBadge extends StatelessWidget {
  const StateBadge({super.key, required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    return Badge(
      label: Text(state),
      backgroundColor: switch (state) {
        'STREAMING' => Colors.green,
        'STOPPED' => Colors.grey,
        'STANDBY' => Colors.blueGrey,
        'ERROR' => Colors.red,
        _ => Colors.amber, // STARTING / STANDBY_PENDING / WAKING / STOPPING
      },
    );
  }
}

class PerformanceCard extends StatelessWidget {
  const PerformanceCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final p = worker.performance;
    return MetricCard(
      title: 'Performance',
      children: [
        StatRow(
          label: 'fps',
          value: '${p.fps.toStringAsFixed(1)} / ${p.requestedFps}',
          highlight: p.requestedFps > 0 && p.fps < p.requestedFps * 0.5,
        ),
        StatRow(
          label: 'detection fps',
          value: p.detectionFps.toStringAsFixed(1),
        ),
        StatRow(
          label: 'process',
          value: '${p.processMs.toStringAsFixed(2)} ms',
        ),
        StatRow(
          label: 'process max',
          value: '${p.processMaxMs.toStringAsFixed(2)} ms',
        ),
        StatRow(label: 'frames', value: '${worker.frameCount}'),
        StatRow(
          label: 'errors/timeouts',
          value: '${p.errors}/${p.timeouts}',
          highlight: p.errors > 0 || p.timeouts > 0,
        ),
      ],
    );
  }
}

class TargetCard extends StatelessWidget {
  const TargetCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final t = worker.target;
    return MetricCard(
      title: 'Target',
      trailing: Badge(
        label: Text(t.found ? 'FOUND' : 'LOST'),
        backgroundColor: t.found ? Colors.green : Colors.red,
      ),
      children: [
        StatRow(label: 'position', value: t.found ? '(${t.x}, ${t.y})' : '-'),
        StatRow(label: 'pixels', value: '${t.pixels}'),
        StatRow(label: 'area', value: '${t.area}'),
        StatRow(label: 'rect', value: t.rect.join(',')),
        StatRow(label: 'brightness', value: t.brightness.toStringAsFixed(1)),
        StatRow(
          label: 'pitch/yaw',
          value:
              '${t.pitchControl.toStringAsFixed(3)} / ${t.yawControl.toStringAsFixed(3)}',
        ),
      ],
    );
  }
}

/// Requested (camera.*) vs actual (camera.isp.*) side by side. Differences
/// are highlighted — e.g. GC4653 analog gain may quantize, so only the ISP
/// readback proves the effect.
class IspCard extends StatelessWidget {
  const IspCard({super.key, required this.camera});

  final Camera camera;

  @override
  Widget build(BuildContext context) {
    final isp = camera.isp;
    final expMismatch = isp.exposureUs != camera.exposureUs;
    final gainMismatch =
        isp.again != camera.again ||
        isp.dgain != camera.dgain ||
        isp.ispDgain != camera.ispDgain;
    return MetricCard(
      title: 'ISP — requested vs actual',
      children: [
        Row(
          children: const [
            Expanded(child: _PairHeader('Requested')),
            SizedBox(width: 12),
            Expanded(child: _PairHeader('Actual (isp)')),
          ],
        ),
        const SizedBox(height: 4),
        _PairRow(
          label: 'exposure us',
          left: '${camera.exposureUs}',
          right: '${isp.exposureUs}',
          mismatch: expMismatch,
        ),
        _PairRow(
          label: 'again',
          left: '${camera.again}',
          right: '${isp.again}',
          mismatch: gainMismatch,
        ),
        _PairRow(
          label: 'dgain',
          left: '${camera.dgain}',
          right: '${isp.dgain}',
          mismatch: gainMismatch,
        ),
        _PairRow(
          label: 'isp_dgain',
          left: '${camera.ispDgain}',
          right: '${isp.ispDgain}',
          mismatch: gainMismatch,
        ),
        const Divider(height: 16),
        StatRow(label: 'awb_auto', value: '${camera.awbAuto}'),
        StatRow(label: 'adaptive tone', value: '${camera.ispAdaptiveTone}'),
        StatRow(label: 'iso', value: '${isp.iso}'),
        StatRow(label: 'luma', value: '${isp.averageLuma}'),
        StatRow(label: 'wb gain', value: isp.wbGain.join('/')),
        StatRow(label: 'color temp K', value: '${isp.colorTemperature}'),
        StatRow(
          label: 'output',
          value: '${camera.output.join('x')} (${camera.format})',
        ),
      ],
    );
  }
}

class _PairHeader extends StatelessWidget {
  const _PairHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
    );
  }
}

class _PairRow extends StatelessWidget {
  const _PairRow({
    required this.label,
    required this.left,
    required this.right,
    required this.mismatch,
  });

  final String label;
  final String left;
  final String right;
  final bool mismatch;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = mismatch
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(
              left,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: mismatch ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class VisionCard extends StatelessWidget {
  const VisionCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final v = worker.vision;
    return MetricCard(
      title: 'Vision',
      children: [
        const StatRow(label: 'detector', value: 'NV21 green'),
        StatRow(label: 'roi', value: v.detectRoi.join(',')),
        StatRow(label: 'search radius', value: '${v.searchRadius}'),
        StatRow(
          label: 'thresholds',
          value: 'area ${v.areaThreshold} / px ${v.pixelsThreshold}',
        ),
        StatRow(
          label: 'stride',
          value: 'x ${v.xStride} / y ${v.yStride} / n ${v.detectEveryN}',
        ),
        StatRow(label: 'detection frames', value: '${v.detectionFrames}'),
        StatRow(
          label: 'jobs dropped',
          value: '${v.jobsDropped}',
          highlight: v.jobsDropped > 0,
        ),
      ],
    );
  }
}

class ResourcesCard extends StatelessWidget {
  const ResourcesCard({
    super.key,
    required this.resources,
    required this.features,
  });

  final Resources resources;
  final Features features;

  @override
  Widget build(BuildContext context) {
    return MetricCard(
      title: 'Hardware / Features',
      children: [
        StatRow(
          label: 'temperature',
          value: resources.temperatureC == null
              ? '-'
              : '${resources.temperatureC!.toStringAsFixed(1)} °C',
          highlight: (resources.temperatureC ?? 0) > 80,
        ),
        StatRow(label: 'vb pool', value: '${resources.vbPoolCount}'),
        StatRow(
          label: 'mipi',
          value:
              '${resources.mipiLoaded ? 'loaded' : 'not loaded'} (${resources.mipiUsers})',
        ),
        StatRow(
          label: 'power',
          value: resources.powerW?.toStringAsFixed(1) ?? '-',
        ),
        StatRow(
          label: 'reboot needed',
          value: resources.needsReboot ? 'yes' : 'no',
          highlight: resources.needsReboot,
        ),
        StatRow(
          label: 'overlay/rtsp/uart',
          value: '${features.overlay}/${features.rtsp}/${features.uartEnabled}',
        ),
      ],
    );
  }
}

class ViewControlCard extends StatelessWidget {
  const ViewControlCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final view = worker.view;
    final control = worker.control;
    final overlay = worker.overlay;
    return MetricCard(
      title: 'View / Control',
      children: [
        StatRow(label: 'view profile', value: view.profile),
        StatRow(
          label: 'crop',
          value: '${view.cropEnabled ? 'on' : 'off'} ${view.crop.join(',')}',
        ),
        StatRow(
          label: 'output',
          value:
              '${view.output.join('x')} rot ${view.rotation}° offx ${view.visibleOffsetX}',
        ),
        StatRow(
          label: 'scale',
          value: view.scale.map((e) => e.toStringAsFixed(2)).join(','),
        ),
        StatRow(label: 'space', value: view.coordinateSpace),
        StatRow(
          label: 'overlay sync',
          value:
              '${overlay.frameSync ? 'on' : 'off'} '
              'D ${overlay.detectionFrameId} '
              'ok/miss ${overlay.matchedFrames}/${overlay.missedFrames}',
          highlight: overlay.missedFrames > 0,
        ),
        StatRow(
          label: 'sync wait',
          value:
              '${overlay.lastWaitUs} us / max ${overlay.maxWaitUs} us '
              '(deadline ${overlay.syncTimeoutMs} ms)',
          highlight: overlay.lastWaitUs >= overlay.syncTimeoutMs * 1000,
        ),
        StatRow(
          label: 'mode',
          value:
              '${control.mode} fx ${control.fx.toStringAsFixed(1)} fy ${control.fy.toStringAsFixed(1)}',
        ),
        StatRow(
          label: 'roll',
          value: '${control.rollUnit} sign ${control.rollSign}',
        ),
        StatRow(label: 'distance', value: control.distance.toStringAsFixed(2)),
      ],
    );
  }
}

class UartCard extends StatelessWidget {
  const UartCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final u = worker.uart;
    return MetricCard(
      title: 'UART',
      trailing: Badge(
        label: Text(u.open ? 'OPEN' : 'CLOSED'),
        backgroundColor: u.open ? Colors.green : Colors.grey,
      ),
      children: [
        StatRow(label: 'rx bytes', value: '${u.rxBytes}'),
        StatRow(label: 'rx packets', value: '${u.rxPackets}'),
        StatRow(label: 'tx packets', value: '${u.txPackets}'),
        StatRow(
          label: 'crc errors',
          value: '${u.crcErrors}',
          highlight: u.crcErrors > 0,
        ),
        StatRow(
          label: 'decode errors',
          value: '${u.decodeErrors}',
          highlight: u.decodeErrors > 0,
        ),
        StatRow(
          label: 'align drops',
          value: '${u.alignDrops}',
          highlight: u.alignDrops > 0,
        ),
        StatRow(label: 'tx gap us', value: '${u.txMinGapUs}..${u.txMaxGapUs}'),
        StatRow(
          label: 'telemetry',
          value: u.telemetryValid ? 'valid' : 'invalid',
          highlight: u.telemetryValid == false,
        ),
        StatRow(
          label: 'p/r/y',
          value:
              '${u.pitch.toStringAsFixed(1)}/${u.roll.toStringAsFixed(1)}/${u.yaw.toStringAsFixed(1)}',
        ),
        StatRow(label: 'air speed', value: u.airSpeed.toStringAsFixed(1)),
        for (final value in u.values.entries)
          StatRow(
            label: 'rx.${value.key}',
            value: value.value.toStringAsFixed(4),
          ),
      ],
    );
  }
}

class StreamCard extends StatelessWidget {
  const StreamCard({super.key, required this.worker});

  final WorkerState worker;

  @override
  Widget build(BuildContext context) {
    final s = worker.stream;
    final udp = worker.udpTelemetry;
    return MetricCard(
      title: 'RTSP encoder',
      children: [
        StatRow(
          label: 'rtsp',
          value: '${s.rtspEnabled ? 'on' : 'off'} :${s.rtspPort}',
        ),
        StatRow(label: 'rtsp clients', value: '${s.rtspClients}'),
        StatRow(
          label: 'source/input',
          value: '${s.sourceFrames}/${s.inputFrames}',
        ),
        StatRow(
          label: 'encoded MB',
          value: (s.encodedBytes / 1048576).toStringAsFixed(1),
        ),
        StatRow(label: 'encoded frames', value: '${s.encodedFrames}'),
        const Divider(height: 16),
        StatRow(
          label: 'udp telemetry',
          value: udp.running ? '${udp.host}:${udp.port} @ ${udp.hz} Hz' : 'off',
        ),
        StatRow(
          label: 'udp sent/errors',
          value: '${udp.sentPackets}/${udp.sendErrors}',
          highlight: udp.sendErrors > 0,
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/shared/widgets/connection_bar.dart';
import 'package:dart_control_panel/shared/widgets/metric_card.dart';
import 'package:dart_control_panel/shared/widgets/state_dashboard.dart';

/// The board exposes exactly two policy modes.  Mode switching is atomic on
/// the daemon; individual RTSP/recording feature toggles intentionally do not
/// exist in the current protocol.
class ModeScreen extends StatefulWidget {
  const ModeScreen({super.key, required this.session});

  final BoardSession session;

  @override
  State<ModeScreen> createState() => _ModeScreenState();
}

class _ModeScreenState extends State<ModeScreen> {
  Future<void> _switchMode(String mode) async {
    if (mode == widget.session.state?.mode) return;
    if (mode == 'flight') {
      final ok = await _confirm(
        '切换到空中飞行模式',
        'RTSP 会立即停止，画面设置锁定；相机完成初始化后进入待发射 standby。',
        '切换到 Flight',
      );
      if (!ok) return;
    }
    try {
      await widget.session.mutate(
        'set_operating_mode $mode',
        (repo) => repo.setOperatingMode(mode),
      );
    } catch (_) {
      // BoardSession already exposes the daemon error.
    }
  }

  Future<void> _restart() async {
    try {
      await widget.session.mutate(
        'restart_worker',
        (repo) => repo.restartWorker(),
      );
    } catch (_) {}
  }

  Future<void> _setFlightActive(bool active) async {
    if (active &&
        !await _confirm(
          '开始飞行记录',
          '相机将立即 wake，并开始识别、H.264 录像、UART 和 UDP 遥测。',
          '开始',
        )) {
      return;
    }
    try {
      await widget.session.mutate(
        'set_flight_active $active',
        (repo) => repo.setFlightActive(active),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) {
        final session = widget.session;
        final state = session.state;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Mode'),
            actions: [
              if (session.connection != null)
                ConnectionStatusChip(connection: session.connection!),
              const SizedBox(width: 12),
            ],
          ),
          body: state == null
              ? const Center(child: Text('请先连接开发板'))
              : _body(context, state),
        );
      },
    );
  }

  Widget _body(BuildContext context, DaemonState state) {
    final session = widget.session;
    final busy = session.busy || state.isTransitional || state.modeTransition;
    final flight = state.mode == 'flight';
    final udp = state.worker?.udpTelemetry;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        DaemonCard(state: state),
        const SizedBox(height: 12),
        MetricCard(
          title: '运行模式',
          trailing: Badge(
            label: Text(flight ? 'FLIGHT' : 'GROUND'),
            backgroundColor: flight ? Colors.deepOrange : Colors.teal,
          ),
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'ground',
                  label: Text('Ground 地面'),
                  icon: Icon(Icons.tune),
                ),
                ButtonSegment(
                  value: 'flight',
                  label: Text('Flight 空中'),
                  icon: Icon(Icons.flight_takeoff),
                ),
              ],
              selected: {flight ? 'flight' : 'ground'},
              onSelectionChanged: busy ? null : (v) => _switchMode(v.first),
            ),
            const SizedBox(height: 12),
            Text(
              flight
                  ? '空中：RTSP 关闭，画面参数锁定；未激活时相机保持 standby。'
                  : '地面：RTSP 实时预览开启，可修改视频模式、绿色阈值、ROI 与 ISP 参数。',
            ),
            const SizedBox(height: 8),
            StatRow(label: 'RTSP', value: state.features.rtsp ? 'on' : 'off'),
            StatRow(
              label: 'image settings',
              value: state.imageSettingsLocked ? 'locked' : 'editable',
            ),
            StatRow(
              label: 'recording',
              value: state.features.recording ? 'active' : 'stopped',
            ),
          ],
        ),
        if (flight) ...[
          const SizedBox(height: 12),
          MetricCard(
            title: '飞行触发',
            trailing: Badge(
              label: Text(state.flight.state),
              backgroundColor: state.flight.active
                  ? Colors.red
                  : Colors.blueGrey,
            ),
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('flight_active'),
                subtitle: Text(
                  state.flight.active
                      ? '识别、录像、UART、UDP 正在运行'
                      : '相机已初始化并处于 standby',
                ),
                value: state.flight.active,
                onChanged: busy ? null : _setFlightActive,
              ),
              if (state.flight.triggerSource.isNotEmpty)
                StatRow(label: 'trigger', value: state.flight.triggerSource),
              if (state.flight.telemetryHost.isNotEmpty)
                StatRow(label: 'UDP target', value: state.flight.telemetryHost),
              if (state.flight.recordPath.isNotEmpty)
                StatRow(label: 'video', value: state.flight.recordPath),
              if (state.flight.telemetryPath.isNotEmpty)
                StatRow(label: 'telemetry', value: state.flight.telemetryPath),
              if (!state.flight.active &&
                  state.flight.lastRecordPath.isNotEmpty)
                StatRow(
                  label: 'last video',
                  value: state.flight.lastRecordPath,
                ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        MetricCard(
          title: 'UDP 遥测',
          children: [
            StatRow(
              label: 'publisher',
              value: udp?.active == true
                  ? 'sending'
                  : (udp?.running == true ? 'armed / silent' : 'stopped'),
            ),
            StatRow(
              label: 'destination',
              value: udp == null
                  ? '-'
                  : '${udp.host}:${udp.port} @ ${udp.hz} Hz',
            ),
            StatRow(
              label: 'packets / errors',
              value: udp == null
                  ? '- / -'
                  : '${udp.sentPackets} / ${udp.sendErrors}',
            ),
            StatRow(
              label: 'last send age',
              value: udp == null || udp.lastSendAgeMs < 0
                  ? '-'
                  : '${udp.lastSendAgeMs} ms',
            ),
          ],
        ),
        const SizedBox(height: 12),
        MetricCard(
          title: '系统',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : _restart,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Restart worker'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _confirmReboot,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Reboot board'),
                ),
              ],
            ),
            if (state.resources.needsReboot)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '板端报告需要重启',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmReboot() async {
    if (!await _confirm('重启开发板', '将中断识别和控制链，确定继续？', '继续')) return;
    if (!await _confirm('再次确认', '现在立即重启开发板？', '立即重启')) return;
    try {
      await widget.session.mutate(
        'reboot_board',
        (repo) => repo.rebootBoard(confirm: true),
      );
    } catch (_) {}
  }

  Future<bool> _confirm(String title, String message, String action) async {
    return (await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(action),
              ),
            ],
          ),
        )) ??
        false;
  }
}

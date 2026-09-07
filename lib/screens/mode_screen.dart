import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/profile.dart';
import 'package:dart_control_panel/widgets/connection_bar.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';
import 'package:dart_control_panel/widgets/state_dashboard.dart';

/// P4/新导航 — 模式页：Ground ↔ Flight 切换（set_mode，见 update.md），
/// 并收纳原 Camera + Features 的板端控制（生命周期/readout/rotation/
/// presets/custom features/录像/重启）。
class ModeScreen extends StatefulWidget {
  const ModeScreen({super.key, required this.session});

  final BoardSession session;

  @override
  State<ModeScreen> createState() => _ModeScreenState();
}

class _ModeScreenState extends State<ModeScreen> {
  Map<String, Profile> _profiles = const {};
  String? _selectedProfile;
  int _rotation = 0;
  final TextEditingController _recordEveryN = TextEditingController(text: '4');
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _recordEveryN.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
    _maybeLoad();
  }

  void _maybeLoad() {
    final session = widget.session;
    if (_loaded || session.state == null) return;
    _loaded = true;
    final repo = session.repository;
    if (repo == null) return;
    repo.getProfiles().then((profiles) {
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        final current = session.state;
        _selectedProfile = (current?.profile.isNotEmpty ?? false)
            ? current!.profile
            : profiles.keys.firstOrNull;
        _rotation = current?.rotation ?? 0;
      });
    }).catchError((Object e) {
      session.setStatus('get_profiles failed: $e', error: true);
    });
    final worker = session.state!.worker;
    if (worker != null) {
      _recordEveryN.text = '${worker.stream.recordEveryN}';
    }
  }

  Future<void> _mutate(
      String label, Future<void> Function(BoardSession) op) async {
    final session = widget.session;
    if (!session.connected) return;
    try {
      await session.mutate(label, (repo) async => op(session));
    } catch (_) {
      // error already surfaced via session status
    }
    if (mounted) {
      setState(() {
        _rotation = widget.session.state?.rotation ?? _rotation;
        final s = widget.session.state;
        if (s != null && s.profile.isNotEmpty) _selectedProfile = s.profile;
      });
    }
  }

  int? get _recordEveryNValue => int.tryParse(_recordEveryN.text.trim());

  // --- mode switch ---------------------------------------------------------

  Future<void> _switchMode(String mode) async {
    final session = widget.session;
    try {
      await session.mutate('set_mode $mode',
          (repo) => repo.setMode(mode));
    } on Exception catch (e) {
      final text = '$e';
      final unknown = text.contains('unknown op') || text.contains('not implemented');
      session.setStatus(
        unknown
            ? 'The board does not implement set_mode yet — see update.md for the proposed interface'
            : 'mode switch rejected: $text',
        error: true,
      );
    }
  }

  Future<void> _confirmSwitchMode(String mode) async {
    if (mode == 'flight' &&
        !(await _confirm(
          '切换到 Flight 模式',
          'Flight 模式建议板端关闭 RTSP、开启内录并持续记录遥测。\n'
              '确认切换？',
          '切换',
        ))) {
      return;
    }
    await _switchMode(mode);
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
              ? _notConnected(context)
              : _buildBody(context, session, state),
        );
      },
    );
  }

  Widget _notConnected(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.track_changes, size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            'Connect once (bottom-left) to switch modes and control the board',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
      BuildContext context, BoardSession session, DaemonState state) {
    final busy = session.busy;
    final transitional = state.isTransitional || state.modeTransition;
    final canMutate = !busy && !transitional;
    final currentMode = state.mode == 'flight' ? 'flight' : 'ground';

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        DaemonCard(state: state),
        const SizedBox(height: 12),
        _modeCard(context, session, state, canMutate, currentMode),
        const SizedBox(height: 12),
        if (state.resources.needsReboot)
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber),
                  const SizedBox(width: 12),
                  const Expanded(
                      child: Text('Board requests a reboot to apply changes.')),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: busy ? null : _confirmReboot,
                    child: const Text('Reboot'),
                  ),
                ],
              ),
            ),
          ),
        _section(
          context,
          'Board control',
          initiallyExpanded: true,
          children: [
            _lifecycleCard(context, session, state, canMutate),
            const SizedBox(height: 12),
            _pictureCard(context, session, state, canMutate),
          ],
        ),
        _section(
          context,
          'Features & recording',
          initiallyExpanded: false,
          children: [
            _featuresCard(context, session, state, canMutate),
          ],
        ),
        _section(context, 'System', initiallyExpanded: false, children: [
          MetricCard(
            title: 'Board',
            children: [
              StatRow(
                  label: 'reboot needed',
                  value: '${state.resources.needsReboot}'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : _confirmReboot,
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Reboot board (double confirm)'),
              ),
            ],
          ),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _section(BuildContext context, String title,
      {required List<Widget> children, bool initiallyExpanded = false}) {
    if (children.length == 1) {
      return children.first;
    }
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text(title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        initiallyExpanded: initiallyExpanded,
        childrenPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 12),
        children: children,
      ),
    );
  }

  Widget _modeCard(BuildContext context, BoardSession session,
      DaemonState state, bool canMutate, String currentMode) {
    final pending = state.modePending;
    return MetricCard(
      title: 'Mode',
      trailing: Badge(
        label: Text(
          pending != null
              ? 'switching → $pending'
              : currentMode.toUpperCase(),
        ),
        backgroundColor: currentMode == 'flight'
            ? Colors.deepOrange
            : Colors.teal,
      ),
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'ground',
              label: Text('Ground'),
              icon: Icon(Icons.science_outlined),
            ),
            ButtonSegment(
              value: 'flight',
              label: Text('Flight'),
              icon: Icon(Icons.flight_takeoff),
            ),
          ],
          selected: {currentMode},
          onSelectionChanged: canMutate
              ? (selection) => _confirmSwitchMode(selection.first)
              : null,
        ),
        const SizedBox(height: 8),
        Text(
          currentMode == 'flight'
              ? 'Flight: 内录 + 遥测记录，板端建议关闭 RTSP（影像页会提示不可用）。'
              : 'Ground: 实时回传影像用于识别调参（RTSP on）。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (state.modePending != null)
          const SizedBox(
              width: double.infinity,
              child: LinearProgressIndicator(minHeight: 2)),
        if (session.statusMessage?.contains('set_mode') == true)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              session.statusMessage!,
              style: TextStyle(
                  color: session.statusError
                      ? Theme.of(context).colorScheme.error
                      : null),
            ),
          ),
      ],
    );
  }

  Widget _lifecycleCard(BuildContext context, BoardSession session,
      DaemonState state, bool canMutate) {
    final stateName = state.state;
    return MetricCard(
      title: 'Worker lifecycle',
      children: [
        _profilePicker(canMutate: canMutate),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: canMutate &&
                      (stateName == 'STOPPED' ||
                          stateName == 'ERROR' ||
                          stateName == 'STANDBY')
                  ? () => _mutate('start_worker', (s) async =>
                      s.repository!.startWorker(profile: _selectedProfile))
                  : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
            FilledButton.icon(
              onPressed: canMutate && stateName == 'STREAMING'
                  ? () => _mutate('stop_worker',
                      (s) async => s.repository!.stopWorker())
                  : null,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            OutlinedButton.icon(
              onPressed: canMutate && stateName == 'STREAMING'
                  ? () => _mutate('restart_worker',
                      (s) async => s.repository!.restartWorker())
                  : null,
              icon: const Icon(Icons.refresh),
              label: const Text('Restart'),
            ),
            OutlinedButton.icon(
              onPressed: canMutate && stateName == 'STREAMING'
                  ? () => _mutate('camera_standby',
                      (s) async => s.repository!.cameraStandby())
                  : null,
              icon: const Icon(Icons.power),
              label: const Text('Standby'),
            ),
            OutlinedButton.icon(
              onPressed: canMutate &&
                      (stateName == 'STANDBY' ||
                          stateName == 'STANDBY_PENDING')
                  ? () => _mutate('camera_wake',
                      (s) async => s.repository!.cameraWake())
                  : null,
              icon: const Icon(Icons.wb_sunny),
              label: const Text('Wake'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pictureCard(BuildContext context, BoardSession session,
      DaemonState state, bool canMutate) {
    return MetricCard(
      title: 'Readout profile & rotation',
      children: [
        _profilePicker(canMutate: canMutate, forReadout: true),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: canMutate &&
                  _selectedProfile != null &&
                  _selectedProfile != state.profile
              ? () => _mutate('apply_readout_profile', (s) async =>
                  s.repository!.applyReadoutProfile(_selectedProfile!))
              : null,
          child: const Text('Apply readout profile (rolls back on failure)'),
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('0°')),
            ButtonSegment(value: 90, label: Text('90°')),
            ButtonSegment(value: 180, label: Text('180°')),
            ButtonSegment(value: 270, label: Text('270°')),
          ],
          selected: {_rotation},
          onSelectionChanged: !canMutate
              ? null
              : (selection) => setState(() => _rotation = selection.first),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: canMutate && _rotation != state.rotation
              ? () => _mutate('set_rotation',
                  (s) async => s.repository!.setRotation(_rotation))
              : null,
          child: const Text('Apply rotation (restarts while running)'),
        ),
      ],
    );
  }

  Widget _featuresCard(BuildContext context, BoardSession session,
      DaemonState state, bool canMutate) {
    final features = state.features;
    final worker = state.worker;
    return MetricCard(
      title: 'Features / recording',
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in ['debug', 'training', 'competition', 'idle'])
              ChoiceChip(
                label: Text(preset),
                selected: features.preset == preset,
                onSelected: canMutate
                    ? (_) => _mutate('apply preset $preset', (s) async =>
                        s.repository!.applyFeaturePreset(preset))
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
        _switchRow(context, canMutate, 'RTSP', features.rtsp,
            (v) => _mutate('set_features',
                (s) async => s.repository!.setFeatures(rtsp: v))),
        _switchRow(context, canMutate, 'Recording', features.recording, (v) =>
            _mutate('set_features', (s) async =>
                s.repository!.setFeatures(recording: v))),
        _switchRow(context, canMutate, 'Overlay', features.overlay,
            (v) => _mutate('set_features', (s) async =>
                s.repository!.setFeatures(overlay: v))),
        _switchRow(context, canMutate, 'UART', features.uartEnabled,
            (v) => _mutate('set_uart', (s) async =>
                s.repository!.setUart(v))),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 130, child: Text('record_every_n')),
            SizedBox(
              width: 90,
              child: TextField(
                controller: _recordEveryN,
                enabled: canMutate,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: canMutate &&
                      (worker?.stream.recording ?? false) == false
                  ? () {
                      final n = _recordEveryNValue;
                      if (n == null || n < 1 || n > 120) {
                        session.setStatus('record_every_n must be 1..120',
                            error: true);
                        return;
                      }
                      _mutate('start_recording', (s) async =>
                          s.repository!.startRecording(recordEveryN: n));
                    }
                  : null,
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('Start recording'),
            ),
            OutlinedButton.icon(
              onPressed: canMutate && (worker?.stream.recording ?? false)
                  ? () => _mutate('stop_recording',
                      (s) async => s.repository!.stopRecording())
                  : null,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            OutlinedButton.icon(
              onPressed: canMutate && (worker?.stream.recording ?? false)
                  ? () => _mutate('rotate_recording', (s) async =>
                      s.repository!.rotateRecording())
                  : null,
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Rotate file'),
            ),
          ],
        ),
        if (worker != null) ...[
          const Divider(height: 16),
          StatRow(
              label: 'current file',
              value: worker.stream.recordPath.isEmpty
                  ? '-'
                  : worker.stream.recordPath),
          StatRow(
              label: 'record fps / errors',
              value:
                  '${worker.stream.recordFps} / ${worker.stream.recordErrors}'),
        ],
      ],
    );
  }

  Widget _switchRow(BuildContext context, bool canMutate, String label,
      bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Switch(value: value, onChanged: canMutate ? onChanged : null),
          Expanded(
            child: Text(
              value ? 'on (restarts worker)' : 'off (restarts worker)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _profilePicker(
      {required bool canMutate, bool forReadout = false}) {
    final session = widget.session;
    final state = session.state!;
    final current =
        forReadout ? state.profile : (_selectedProfile ?? state.profile);
    return DropdownButtonFormField<String>(
      key: ValueKey(forReadout ? 'readout_profile' : 'start_profile'),
      initialValue: _profiles.containsKey(current) ? current : null,
      decoration: InputDecoration(
        labelText: forReadout ? 'Readout profile' : 'Start profile',
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final entry in _profiles.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              '${entry.key} '
              '(${entry.value.expected?.sensor.join('x') ?? '?'} → '
              '${entry.value.expected?.output.join('x') ?? '?'} '
              '@${entry.value.expected?.fps.toStringAsFixed(0) ?? '?'})',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: canMutate ? (v) => setState(() => _selectedProfile = v) : null,
    );
  }

  Future<void> _confirmReboot() async {
    if (!await _confirm('Reboot board',
        'This reconnects the camera and interrupts streaming. Continue?',
        'Continue')) {
      return;
    }
    if (!await _confirm('Really reboot?',
        'Final step — reboot the board now?', 'Reboot now')) {
      return;
    }
    try {
      final schedule = await widget.session.mutate(
        'reboot_board',
        (repo) => repo.rebootBoard(confirm: true),
      );
      if (mounted) {
        widget.session
            .setStatus('Reboot scheduled: ${schedule['delay_s'] ?? '?'} s');
      }
    } catch (_) {}
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}
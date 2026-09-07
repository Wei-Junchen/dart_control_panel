import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/video_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/profile.dart';
import 'package:dart_control_panel/models/runtime_draft.dart';
import 'package:dart_control_panel/widgets/connection_bar.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';
import 'package:dart_control_panel/widgets/tuning_form.dart';
import 'package:dart_control_panel/widgets/video_panel.dart';

/// 地面测试页：左侧实时 RTSP 画面 + 画面配置（readout profile /
/// rotation / overlay），右侧识别与 ISP 调参表单 —— 影像服务于调参。
/// 数据与连接全部来自共享 [session]。
class GroundTestScreen extends StatefulWidget {
  const GroundTestScreen({
    super.key,
    required this.session,
    this.videoController,
  });

  final BoardSession session;

  /// Injectable for tests; defaults to a real media_kit-backed controller.
  final VideoController? videoController;

  @override
  State<GroundTestScreen> createState() => _GroundTestScreenState();
}

class _GroundTestScreenState extends State<GroundTestScreen> {
  late final BoardSession _session = widget.session;
  late final VideoController _video = widget.videoController ?? VideoController();

  final GlobalKey<TuningFormState> _formKey = GlobalKey<TuningFormState>();
  final RuntimeDraft _draft = RuntimeDraft();
  bool _tuningBusy = false;
  bool _loaded = false;
  bool _tuningLoaded = false;

  Map<String, Profile> _profiles = const {};
  String? _selectedProfile;
  int _rotation = 0;
  bool _overlay = false;
  bool _overlayRoi = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _video.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
    final session = _session;
    if (session.state == null) return;
    if (!_loaded) {
      _loaded = true;
      _loadProfiles(session);
    }
    if (!_tuningLoaded && session.repository != null) {
      _tuningLoaded = true;
      _loadTuning(session);
    }
    if (!_session.connected && _video.isActive) {
      _video.stop();
    }
  }

  Future<void> _loadProfiles(BoardSession session) async {
    final repo = session.repository;
    if (repo == null) return;
    try {
      final profiles = await repo.getProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        final current = session.state;
        _selectedProfile = (current?.profile.isNotEmpty ?? false)
            ? current!.profile
            : profiles.keys.firstOrNull;
        _rotation = current?.rotation ?? 0;
        _overlay = current?.features.overlay ?? false;
        _overlayRoi = current?.worker?.overlay.roi ?? false;
      });
    } catch (e) {
      session.setStatus('get_profiles failed: $e', error: true);
    }
  }

  Future<void> _loadTuning(BoardSession session) async {
    final repo = session.repository;
    if (repo == null) return;
    try {
      final state = await repo.getState();
      _draft.loadFrom(state);
      _formKey.currentState?.syncFromDraft();
    } catch (e) {
      session.setStatus('tuning load failed: $e', error: true);
    }
  }

  Future<void> _applyTuning() async {
    final session = _session;
    if (!session.connected) return;
    final errors = _draft.validate();
    if (errors.isNotEmpty) {
      session.setStatus('Cannot apply: ${errors.values.join('; ')}', error: true);
      return;
    }
    setState(() => _tuningBusy = true);
    try {
      final args = _draft.toArgs();
      final result = await session.mutate('apply_runtime', (repo) async {
        final r = await repo.applyRuntime(args);
        return r;
      });
      _draft.loadFrom(result.state);
      _formKey.currentState?.syncFromDraft();
      session.setStatus('Applied: ${result.message.isEmpty ? '${args.length} field(s)' : result.message}');
    } catch (_) {
    } finally {
      if (mounted) setState(() => _tuningBusy = false);
    }
  }

  void _revertTuning() {
    _draft.revert();
    _formKey.currentState?.syncFromDraft();
    _session.setStatus('Reverted local edits');
  }

  Future<void> _mutate(
      String label, Future<void> Function(BoardSession) op) async {
    final session = _session;
    if (!session.connected) return;
    try {
      await session.mutate(label, (repo) async => op(session));
    } catch (_) {}
  }

  Future<void> _toggleOverlay(bool value) async {
    setState(() => _overlay = value);
    await _mutate('overlay', (s) async =>
        s.repository!.applyRuntime({'overlay': value}));
  }

  Future<void> _toggleOverlayRoi(bool value) async {
    setState(() => _overlayRoi = value);
    await _mutate('overlay_roi', (s) async =>
        s.repository!.applyRuntime({'overlay_roi': value}));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final state = _session.state;
        final host = _session.host;
        final url = 'rtsp://$host:8554/live';
        final rtspOk = state != null &&
            state.features.rtsp &&
            (state.worker?.stream.rtspEnabled ?? false);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Ground Test'),
            actions: [
              if (_session.connection != null)
                ConnectionStatusChip(connection: _session.connection!),
              const SizedBox(width: 12),
            ],
          ),
          body: state == null
              ? _notConnected(context)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 1000;
                    final picture = _pictureColumn(context, state, rtspOk, url);
                    final tuning = _tuningColumn(context);
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                  width: 460,
                                  child: picture),
                              const VerticalDivider(width: 12),
                              Expanded(child: tuning),
                            ],
                          )
                        : ListView(
                            children: [
                              SizedBox(height: 260, child: picture),
                              tuning,
                            ],
                          );
                  },
                ),
        );
      },
    );
  }

  Widget _notConnected(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_settings_outlined,
              size: 48, color: Colors.grey),
          const SizedBox(height: 8),
          Text(
            'Connect once (bottom-left) — 影像 + 调参都在这一页',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _pictureColumn(
      BuildContext context, DaemonState state, bool rtspOk, String url) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: rtspOk
              ? VideoPanel(controller: _video, rtspAvailable: true, url: url)
              : const RtspUnavailable(),
        ),
        const SizedBox(height: 12),
        MetricCard(
          title: '画面配置',
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('readout_profile'),
              initialValue:
                  _profiles.containsKey(state.profile) ? state.profile : null,
              decoration: const InputDecoration(
                labelText: 'Readout profile',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final entry in _profiles.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(entry.key, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: _session.busy
                  ? null
                  : (v) => setState(() => _selectedProfile = v),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _session.busy ||
                          _selectedProfile == null ||
                          _selectedProfile == state.profile
                      ? null
                      : () => _mutate('apply_readout_profile', (s) async =>
                          s.repository!.applyReadoutProfile(_selectedProfile!)),
                  child: const Text('Apply profile'),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('0°')),
                    ButtonSegment(value: 90, label: Text('90°')),
                    ButtonSegment(value: 180, label: Text('180°')),
                    ButtonSegment(value: 270, label: Text('270°')),
                  ],
                  selected: {_rotation},
                  onSelectionChanged: _session.busy
                      ? null
                      : (selection) =>
                          setState(() => _rotation = selection.first),
                ),
                FilledButton.tonal(
                  onPressed: _session.busy || _rotation == state.rotation
                      ? null
                      : () => _mutate('set_rotation', (s) async =>
                          s.repository!.setRotation(_rotation)),
                  child: const Text('Apply rotation'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const SizedBox(width: 130, child: Text('overlay')),
                Switch(
                  value: _overlay,
                  onChanged: _session.busy ? null : _toggleOverlay,
                ),
              ],
            ),
            Row(
              children: [
                const SizedBox(width: 130, child: Text('overlay roi')),
                Switch(
                  value: _overlayRoi,
                  onChanged: _session.busy ? null : _toggleOverlayRoi,
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _tuningColumn(BuildContext context) {
    return TuningForm(
      key: _formKey,
      draft: _draft,
      busy: _tuningBusy,
      onApply: _applyTuning,
      onRevert: _revertTuning,
      onReload: () => _loadTuning(_session),
    );
  }
}
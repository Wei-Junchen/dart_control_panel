import 'package:flutter/material.dart';

import 'package:dart_control_panel/controllers/board_session.dart';
import 'package:dart_control_panel/controllers/video_controller.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/profile.dart';
import 'package:dart_control_panel/models/runtime_draft.dart';
import 'package:dart_control_panel/widgets/connection_bar.dart';
import 'package:dart_control_panel/widgets/json_config_editor.dart';
import 'package:dart_control_panel/widgets/metric_card.dart';
import 'package:dart_control_panel/widgets/tuning_form.dart';
import 'package:dart_control_panel/widgets/video_panel.dart';

/// 地面测试页：左侧实时 RTSP 画面 + 画面配置（readout profile /
/// rotation），右侧识别、ISP 与 overlay 调参表单 —— 影像服务于调参。
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
  late final VideoController _video =
      widget.videoController ?? VideoController(liveStream: true);

  final GlobalKey<TuningFormState> _formKey = GlobalKey<TuningFormState>();
  final RuntimeDraft _draft = RuntimeDraft();
  bool _tuningBusy = false;
  bool _loaded = false;
  bool _tuningLoaded = false;
  Object? _loadedRepository;
  Map<String, dynamic>? _boardConfig;
  _ConfigurationView _configurationView = _ConfigurationView.json;

  Map<String, Profile> _profiles = const {};
  String? _selectedProfile;
  int _rotation = 0;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onSessionChanged();
    });
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
    if (!identical(_loadedRepository, session.repository)) {
      _loadedRepository = session.repository;
      _loaded = false;
      _tuningLoaded = false;
      _profiles = const {};
      _selectedProfile = null;
      _boardConfig = null;
    }
    if (session.state == null) return;
    if (!_loaded) {
      _loaded = true;
      _loadProfiles(session);
    }
    if (!_tuningLoaded && session.repository != null) {
      _tuningLoaded = true;
      _loadTuning(session);
    }
    if ((!_session.connected || !session.state!.features.rtsp) &&
        _video.isActive) {
      _video.stop();
    }
  }

  Future<void> _loadProfiles(BoardSession session) async {
    final repo = session.repository;
    if (repo == null) return;
    try {
      final results = await Future.wait([repo.getProfiles(), repo.getConfig()]);
      final profiles = results[0] as Map<String, Profile>;
      final config = Map<String, dynamic>.from(results[1] as Map);
      final launcher = config['launcher'] is Map
          ? Map<String, dynamic>.from(config['launcher'] as Map)
          : const <String, dynamic>{};
      final view = config['view'] is Map
          ? Map<String, dynamic>.from(config['view'] as Map)
          : const <String, dynamic>{};
      final configured = profiles.entries
          .where(
            (entry) =>
                entry.value.readout == launcher['readout'] &&
                entry.value.view == view['profile'],
          )
          .map((entry) => entry.key)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _boardConfig = config;
        final current = session.state;
        _selectedProfile = profiles.containsKey(current?.profile)
            ? current!.profile
            : configured ?? profiles.keys.firstOrNull;
        _rotation = current?.rotation ?? 0;
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
    if (session.state?.imageSettingsLocked ?? false) {
      session.setStatus('Flight 模式已锁定画面设置', error: true);
      return;
    }
    final errors = _draft.validate();
    if (errors.isNotEmpty) {
      session.setStatus(
        'Cannot apply: ${errors.values.join('; ')}',
        error: true,
      );
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
      session.setStatus(
        'Applied: ${result.message.isEmpty ? '${args.length} field(s)' : result.message}',
      );
    } catch (_) {
    } finally {
      if (mounted) setState(() => _tuningBusy = false);
    }
  }

  Future<Map<String, dynamic>> _reloadJsonConfig() async {
    final repo = _session.repository;
    if (repo == null) throw StateError('board is not connected');
    final config = await repo.getConfig();
    if (mounted) setState(() => _boardConfig = config);
    return config;
  }

  Future<Map<String, dynamic>> _uploadJsonConfig(
    Map<String, dynamic> config,
  ) async {
    final session = _session;
    if (session.state?.imageSettingsLocked ?? false) {
      throw StateError('Flight mode locks image configuration');
    }
    if (session.repository == null) throw StateError('board is not connected');

    await session.mutate(
      'set_config',
      (repo) => repo.setConfig(Map<String, dynamic>.from(config)),
    );
    final stored = await session.repository!.getConfig();
    final state = session.state;
    if (state != null) {
      _draft.loadFrom(state);
      _formKey.currentState?.syncFromDraft();
    }
    if (mounted) {
      setState(() {
        _boardConfig = stored;
        _selectedProfile = state?.profile ?? _selectedProfile;
        _rotation = state?.rotation ?? _rotation;
      });
    }
    session.setStatus('Configuration uploaded and verified by daemon');
    return stored;
  }

  void _revertTuning() {
    _draft.revert();
    _formKey.currentState?.syncFromDraft();
    _session.setStatus('Reverted local edits');
  }

  Future<void> _mutate(
    String label,
    Future<void> Function(BoardSession) op,
  ) async {
    final session = _session;
    if (!session.connected) return;
    if (session.state?.imageSettingsLocked ?? false) {
      session.setStatus('Flight 模式已锁定画面设置', error: true);
      return;
    }
    try {
      await session.mutate(label, (repo) async => op(session));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final state = _session.state;
        final host = _session.host;
        final url = 'rtsp://$host:8554/live';
        final rtspOk =
            state != null &&
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
                    final tuning = _configurationWorkspace(context, state);
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 5, child: picture),
                              const VerticalDivider(width: 12),
                              Expanded(flex: 7, child: tuning),
                            ],
                          )
                        : ListView(
                            children: [
                              // The preview column also contains picture
                              // controls. A fixed 260 px box clipped/overflowed
                              // those controls on compact windows.
                              SizedBox(
                                height: constraints.maxHeight
                                    .clamp(520.0, 700.0)
                                    .toDouble(),
                                child: picture,
                              ),
                              SizedBox(
                                height: constraints.maxHeight
                                    .clamp(620.0, 860.0)
                                    .toDouble(),
                                child: tuning,
                              ),
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
          const Icon(
            Icons.video_settings_outlined,
            size: 48,
            color: Colors.grey,
          ),
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
    BuildContext context,
    DaemonState state,
    bool rtspOk,
    String url,
  ) {
    final locked = state.imageSettingsLocked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: rtspOk
              ? VideoPanel(
                  controller: _video,
                  rtspAvailable: true,
                  url: url,
                  liveStream: true,
                )
              : const RtspUnavailable(),
        ),
        const SizedBox(height: 12),
        if (locked)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Text('Flight 模式：RTSP 已关闭，画面设置已锁定。请在 Mode 页切回 Ground。'),
            ),
          ),
        MetricCard(
          title: '画面配置',
          children: [
            DropdownButtonFormField<String>(
              key: const ValueKey('readout_profile'),
              initialValue: _profiles.containsKey(_selectedProfile)
                  ? _selectedProfile
                  : null,
              decoration: const InputDecoration(
                labelText: 'Readout profile',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final entry in _profiles.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      '${entry.key}  (${entry.value.readout} → ${entry.value.view})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _session.busy || locked
                  ? null
                  : (v) => setState(() => _selectedProfile = v),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed:
                      _session.busy ||
                          locked ||
                          _selectedProfile == null ||
                          _selectedProfile == state.profile
                      ? null
                      : () => _mutate(
                          'apply_readout_profile',
                          (s) async => s.repository!.applyReadoutProfile(
                            _selectedProfile!,
                          ),
                        ),
                  child: const Text('Apply profile'),
                ),
                SegmentedButton<int>(
                  segments: [
                    for (final degrees in const [0, 90, 180, 270])
                      ButtonSegment(
                        value: degrees,
                        label: Text('$degrees°'),
                        enabled:
                            _profiles[_selectedProfile]?.supportedRotations
                                .contains(degrees) ??
                            true,
                      ),
                  ],
                  selected: {_rotation},
                  onSelectionChanged: _session.busy || locked
                      ? null
                      : (selection) =>
                            setState(() => _rotation = selection.first),
                ),
                FilledButton.tonal(
                  onPressed:
                      _session.busy || locked || _rotation == state.rotation
                      ? null
                      : () => _mutate(
                          'set_rotation',
                          (s) async => s.repository!.setRotation(_rotation),
                        ),
                  child: const Text('Apply rotation'),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _configurationWorkspace(BuildContext context, DaemonState state) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colors.primaryContainer.withValues(alpha: 0.78),
                  colors.secondaryContainer.withValues(alpha: 0.50),
                ],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(Icons.tune_rounded, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Configuration Studio',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _configurationView == _ConfigurationView.json
                            ? 'Edit the complete validated board configuration'
                            : 'Quick controls for live detector and ISP tuning',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                SegmentedButton<_ConfigurationView>(
                  key: const ValueKey('configuration-view-selector'),
                  segments: const [
                    ButtonSegment(
                      value: _ConfigurationView.json,
                      icon: Icon(Icons.data_object, size: 18),
                      label: Text('JSON'),
                    ),
                    ButtonSegment(
                      value: _ConfigurationView.controls,
                      icon: Icon(Icons.tune, size: 18),
                      label: Text('Controls'),
                    ),
                  ],
                  selected: {_configurationView},
                  onSelectionChanged: (selection) {
                    setState(() => _configurationView = selection.first);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _configurationView.index,
              children: [
                JsonConfigEditor(
                  initialConfig: _boardConfig,
                  connected: _session.repository != null,
                  uploadLocked: state.imageSettingsLocked || _session.busy,
                  onReload: _reloadJsonConfig,
                  onUpload: _uploadJsonConfig,
                ),
                TuningForm(
                  key: _formKey,
                  draft: _draft,
                  busy: _tuningBusy,
                  locked: state.imageSettingsLocked,
                  onApply: _applyTuning,
                  onRevert: _revertTuning,
                  onReload: () => _loadTuning(_session),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _ConfigurationView { json, controls }

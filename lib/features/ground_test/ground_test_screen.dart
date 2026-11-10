import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/board/session/board_session.dart';
import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/models/profile.dart';
import 'package:dart_control_panel/features/ground_test/config_document_draft.dart';
import 'package:dart_control_panel/shared/widgets/connection_bar.dart';
import 'package:dart_control_panel/features/ground_test/json_config_editor.dart';
import 'package:dart_control_panel/shared/widgets/metric_card.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:dart_control_panel/features/ground_test/config_controls.dart';
import 'package:dart_control_panel/core/video/video_panel.dart';

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

  final _jsonKey = GlobalKey<JsonConfigEditorState>();
  final _configDraft = ConfigDocumentDraft();
  int _configGeneration = 0;
  bool _tuningBusy = false;
  bool _loaded = false;
  bool _tuningLoaded = false;
  Object? _loadedRepository;
  Map<String, dynamic>? _boardConfig;
  _ConfigurationView _configurationView = _ConfigurationView.json;
  _MobileGroundView _mobileView = _MobileGroundView.preview;

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
    _configDraft.dispose();
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
      _configGeneration++;
      _configDraft.clear();
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
    final generation = _configGeneration;
    try {
      final results = await Future.wait([repo.getProfiles(), repo.getConfig()]);
      final profiles = results[0] as Map<String, Profile>;
      final config = Map<String, dynamic>.from(results[1] as Map);
      final launcher = config['launcher'] is Map
          ? Map<String, dynamic>.from(config['launcher'] as Map)
          : const <String, dynamic>{};
      final sensor = config['sensor'] is Map
          ? Map<String, dynamic>.from(config['sensor'] as Map)
          : const <String, dynamic>{};
      final readout = sensor['readout'] ?? launcher['readout'];
      final view = config['view'] is Map
          ? Map<String, dynamic>.from(config['view'] as Map)
          : const <String, dynamic>{};
      final configured = profiles.entries
          .where(
            (entry) =>
                entry.value.readout == readout &&
                entry.value.view == view['profile'],
          )
          .map((entry) => entry.key)
          .firstOrNull;
      if (!mounted ||
          generation != _configGeneration ||
          !identical(repo, session.repository)) {
        return;
      }
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
    try {
      await _reloadJsonConfig(confirm: false);
    } catch (e) {
      if (mounted) {
        session.setStatus('Configuration load failed: $e', error: true);
      }
    }
  }

  void _setConfigBusy(bool value) {
    if (!mounted) return;
    setState(() {
      _tuningBusy = value;
      _configDraft.busy = value;
    });
  }

  Future<void> _applyConfigRuntime() async {
    final repo = _session.repository;
    final args = _configDraft.runtimeArgs;
    final generation = _configGeneration;
    if (repo == null ||
        args == null ||
        args.isEmpty ||
        _tuningBusy ||
        _session.busy ||
        (_session.state?.imageSettingsLocked ?? true) ||
        _configDraft.validate().isNotEmpty) {
      return;
    }
    _setConfigBusy(true);
    try {
      await _session.mutate('apply_runtime', (_) => repo.applyRuntime(args));
      final stored = await repo.getConfig();
      if (!mounted ||
          generation != _configGeneration ||
          !identical(repo, _session.repository)) {
        return;
      }
      _configDraft.load(stored);
      setState(() => _boardConfig = stored);
      _session.setStatus('已实时应用 ${args.length} 个字段，无需重启 worker');
    } catch (_) {
      /* Keep the user's draft on rejection. Session refreshes state. */
    } finally {
      _setConfigBusy(false);
    }
  }

  Future<Map<String, dynamic>> _reloadJsonConfig({bool confirm = true}) async {
    final repo = _session.repository;
    if (repo == null) throw StateError('board is not connected');
    if (confirm && _configDraft.dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('放弃未上传的配置修改？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('重新读取'),
            ),
          ],
        ),
      );
      if (discard != true) throw StateError('已取消，保留本地草稿');
    }
    final generation = _configGeneration;
    final config = await repo.getConfig();
    Map<String, dynamic>? schema;
    try {
      final contract = await repo.getSchema();
      if (contract['config_schema'] is Map) {
        schema = Map<String, dynamic>.from(contract['config_schema'] as Map);
      }
    } catch (_) {
      /* Old boards retain the JSON-only editing path. */
    }
    if (!mounted ||
        generation != _configGeneration ||
        !identical(repo, _session.repository)) {
      throw StateError('连接已变化，忽略过期配置');
    }
    _configDraft.setSchema(schema);
    _configDraft.load(config, preserveEdits: !confirm);
    setState(() => _boardConfig = config);
    return config;
  }

  Future<Map<String, dynamic>> _uploadJsonConfig(
    Map<String, dynamic> config,
  ) async {
    final session = _session;
    if (session.state?.imageSettingsLocked ?? false) {
      throw StateError('Flight mode locks image configuration');
    }
    final repo = session.repository;
    final generation = _configGeneration;
    if (repo == null) throw StateError('board is not connected');

    await session.mutate(
      'set_config',
      (repo) => repo.setConfig(Map<String, dynamic>.from(config)),
    );
    if (!mounted ||
        generation != _configGeneration ||
        !identical(repo, session.repository)) {
      throw StateError('连接已变化，忽略旧连接的上传结果');
    }
    final stored = await repo.getConfig();
    if (!mounted ||
        generation != _configGeneration ||
        !identical(repo, session.repository)) {
      throw StateError('连接已变化，忽略旧连接的上传结果');
    }
    final state = session.state;
    _configDraft.load(stored);
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
    if (_configDraft.dirty) {
      session.setStatus('存在未上传的配置草稿，请先上传或撤销，再使用画面快捷操作。', error: true);
      return;
    }
    _setConfigBusy(true);
    try {
      await session.mutate(label, (repo) async => op(session));
      await _reloadJsonConfig(confirm: false);
    } catch (_) {
    } finally {
      _setConfigBusy(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final state = _session.state;
        final handset = MobileUiScale.isHandset(context);
        final keyboardVisible =
            handset && MediaQuery.viewInsetsOf(context).bottom > 0;
        final host = _session.host;
        final url = 'rtsp://$host:8554/live';
        final rtspOk =
            state != null &&
            state.features.rtsp &&
            (state.worker?.stream.rtspEnabled ?? false);
        return Scaffold(
          appBar: keyboardVisible
              ? null
              : AppBar(
                  title: handset && state != null
                      ? Row(
                          children: [
                            const Text('Ground Test'),
                            const SizedBox(width: 12),
                            Expanded(child: _mobileViewSelector()),
                          ],
                        )
                      : const Text('Ground Test'),
                  actions: [
                    if (_session.connection != null && !handset)
                      ConnectionStatusChip(connection: _session.connection!),
                    const SizedBox(width: 12),
                  ],
                ),
          body: state == null
              ? _notConnected(context)
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (MobileUiScale.isHandset(context)) {
                      return _mobileWorkspace(
                        context,
                        state,
                        rtspOk,
                        url,
                        keyboardVisible,
                      );
                    }
                    final wide = constraints.maxWidth >= 1000;
                    final picture = _pictureColumn(context, state, rtspOk, url);
                    final tuning = _configurationWorkspace(context, state);
                    return wide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(flex: 7, child: picture),
                              const VerticalDivider(width: 12),
                              Expanded(flex: 5, child: tuning),
                            ],
                          )
                        : ListView(
                            children: [
                              // The preview column also contains picture
                              // controls. A fixed 260 px box clipped/overflowed
                              // those controls on compact windows.
                              SizedBox(
                                height: (constraints.maxHeight * 0.78)
                                    .clamp(480.0, 900.0)
                                    .toDouble(),
                                child: picture,
                              ),
                              SizedBox(
                                height: (constraints.maxHeight * 0.62)
                                    .clamp(460.0, 760.0)
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '请先连接开发板，即可查看画面并调整参数。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileWorkspace(
    BuildContext context,
    DaemonState state,
    bool rtspOk,
    String url,
    bool keyboardVisible,
  ) {
    return IndexedStack(
      index: _mobileView.index,
      children: [
        _videoPreview(rtspOk, url),
        ListView(
          padding: const EdgeInsets.all(8),
          children: _pictureSettings(context, state),
        ),
        _configurationWorkspace(
          context,
          state,
          keyboardVisible: keyboardVisible,
        ),
      ],
    );
  }

  Widget _mobileViewSelector() {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<_MobileGroundView>(
        key: const ValueKey('mobile-ground-view-selector'),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        segments: const [
          ButtonSegment(
            value: _MobileGroundView.preview,
            icon: Icon(Icons.videocam_outlined),
            label: Text('预览'),
          ),
          ButtonSegment(
            value: _MobileGroundView.picture,
            icon: Icon(Icons.tune),
            label: Text('画面设置'),
          ),
          ButtonSegment(
            value: _MobileGroundView.config,
            icon: Icon(Icons.data_object),
            label: Text('配置'),
          ),
        ],
        selected: {_mobileView},
        onSelectionChanged: (selection) {
          FocusScope.of(context).unfocus();
          setState(() => _mobileView = selection.first);
        },
      ),
    );
  }

  Widget _videoPreview(bool rtspOk, String url) => rtspOk
      ? VideoPanel(
          controller: _video,
          rtspAvailable: true,
          url: url,
          liveStream: true,
          onFullscreen: () => showVideoPlaybackDialog(
            context,
            controller: _video,
            url: url,
            title: '实时画面',
            liveStream: true,
          ),
        )
      : const RtspUnavailable();

  Widget _pictureColumn(
    BuildContext context,
    DaemonState state,
    bool rtspOk,
    String url,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _videoPreview(rtspOk, url)),
        const SizedBox(height: 12),
        ..._pictureSettings(context, state),
      ],
    );
  }

  List<Widget> _pictureSettings(BuildContext context, DaemonState state) {
    final locked = state.imageSettingsLocked;
    return [
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
    ];
  }

  Widget _configurationWorkspace(
    BuildContext context,
    DaemonState state, {
    bool keyboardVisible = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final handset = MobileUiScale.isHandset(context);
    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!keyboardVisible)
            Container(
              margin: EdgeInsets.fromLTRB(
                12,
                handset ? 4 : 12,
                12,
                handset ? 4 : 10,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: handset ? 8 : 16,
                vertical: handset ? 0 : 13,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    colors.primaryContainer.withValues(alpha: 0.78),
                    colors.secondaryContainer.withValues(alpha: 0.50),
                  ],
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: colors.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Row(
                children: [
                  if (!handset)
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(Icons.tune_rounded, color: colors.primary),
                    ),
                  if (!handset) const SizedBox(width: 12),
                  if (!handset)
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
                                : '根据板端 schema 生成，与 JSON 共用草稿',
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
                      FocusScope.of(context).unfocus();
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
                  key: _jsonKey,
                  sharedDraft: _configDraft,
                  keyboardCompact: keyboardVisible,
                  onBusyChanged: _setConfigBusy,
                  initialConfig: _boardConfig,
                  connected: _session.repository != null,
                  uploadLocked:
                      state.imageSettingsLocked || _session.busy || _tuningBusy,
                  onReload: _reloadJsonConfig,
                  onUpload: _uploadJsonConfig,
                ),
                ConfigControls(
                  key: ValueKey(_configGeneration),
                  draft: _configDraft,
                  onLiveApply: _applyConfigRuntime,
                  locked: state.imageSettingsLocked || _session.busy,
                  onApply: () => _jsonKey.currentState?.uploadCurrent(),
                  onReload: () async {
                    _setConfigBusy(true);
                    try {
                      await _reloadJsonConfig();
                    } catch (e) {
                      if (mounted) {
                        _session.setStatus('Reload failed: $e', error: true);
                      }
                    } finally {
                      _setConfigBusy(false);
                    }
                  },
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

enum _MobileGroundView { preview, picture, config }

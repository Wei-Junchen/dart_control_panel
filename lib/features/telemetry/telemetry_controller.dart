import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'telemetry_archive.dart';
import 'telemetry_envelope.dart';
import 'package:dart_control_panel/core/preferences/telemetry_view_settings.dart';
export 'telemetry_envelope.dart' show TelemetryPoint;

import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';

/// Live telemetry hub: owns a [TelemetrySource] (dummy until the board has a
/// UDP stream), a time-capped sample ring buffer, and the set of charted
/// channels. Pure Dart + ChangeNotifier.
class TelemetryController extends ChangeNotifier {
  TelemetryController({
    TelemetrySource? source,
    this.window = 20,
    TelemetryRecorder? recorder,
    TelemetryViewSettingsStore? viewSettingsStore,
  }) : viewSettingsStore =
           viewSettingsStore ??
           (source == null
               ? TelemetryViewSettingsStore()
               : TelemetryViewSettingsStore.memory()),
       _source = source ?? UdpTelemetrySource(),
       recorder = recorder ?? (source == null ? TelemetryRecorder() : null) {
    final preferences = this.viewSettingsStore.load();
    rememberChannels = preferences.remember;
    _selected
      ..clear()
      ..addAll(preferences.channels);
    if (_source is UdpTelemetrySource) {
      _source.onSchemaChanged = _onSchemaChanged;
    }
    _refreshChannels();
  }

  final TelemetryViewSettingsStore viewSettingsStore;
  late bool rememberChannels;
  Timer? _viewSaveTimer;
  String? get viewPreferenceError => viewSettingsStore.error;

  bool saveDefaultChannels() {
    _viewSaveTimer?.cancel();
    _viewSaveTimer = null;
    final ok = viewSettingsStore.save(
      TelemetryViewSettings(
        channels: _selected.toList()..sort(),
        remember: rememberChannels,
      ),
    );
    return ok;
  }

  void setRememberChannels(bool value) {
    _viewSaveTimer?.cancel();
    _viewSaveTimer = null;
    rememberChannels = value;
    final previous = viewSettingsStore.load();
    viewSettingsStore.save(
      TelemetryViewSettings(
        channels: value ? (_selected.toList()..sort()) : previous.channels,
        remember: value,
      ),
    );
    _notify();
  }

  void loadDefaultChannels() {
    _viewSaveTimer?.cancel();
    _viewSaveTimer = null;
    _selected
      ..clear()
      ..addAll(viewSettingsStore.load().channels);
    _channelsChanged();
  }

  void restoreInitialChannels() {
    _selected
      ..clear()
      ..addAll(defaultSelected);
    _channelsChanged(save: true);
  }

  void _channelsChanged({bool save = false}) {
    if (save && rememberChannels) {
      _viewSaveTimer?.cancel();
      if (viewSettingsStore.file == null) {
        saveDefaultChannels();
      } else {
        _viewSaveTimer = Timer(
          const Duration(milliseconds: 350),
          saveDefaultChannels,
        );
      }
    }
    if (replaying && archive != null) {
      unawaited(seekTimeline(cursorUs, focusUs: chartFocusUs));
    }
    _notify();
  }

  /// Checked channels are plotted.
  static const defaultSelected = {'pitch', 'roll', 'yaw'};

  final TelemetrySource _source;
  final TelemetryRecorder? recorder;
  bool _connectionManaged = false, _connectionActive = false;
  bool _displayFrozen = false, _reviewConnection = false;
  final _connectionClock = Stopwatch();
  int _viewRequest = 0;
  int? _frozenDurationUs;
  TelemetryArchive? _connectionArchive;
  Future<TelemetryArchive>? _historyLoading;
  bool _frozenHistoryReady = false;
  List<TelemetrySample> _seekCache = [];
  int _cacheFromUs = 0, _cacheToUs = -1;

  bool get connected => _connectionActive;
  Directory? pendingRecording;
  int? chartFocusUs;
  int? clipStartUs, clipEndUs;
  int get selectionStartUs => clipStartUs ?? 0;
  int get selectionEndUs => clipEndUs ?? timelineDurationUs;
  bool get selecting => clipStartUs != null;
  int? _liveChartRightUs;
  double? _liveChartWindow;
  List<TelemetrySample>? _liveChartSamples;
  void captureLiveChartFrame() {
    if (_connectionManaged && !replaying) {
      _liveChartRightUs = timelineDurationUs;
      // Grow the initial window from time zero, rather than centering Pause
      // on negative time (which would violate start <= cursor <= end).
      _liveChartWindow = (_liveChartRightUs! / 1e6).clamp(
        .001,
        window.toDouble(),
      );
      _liveChartSamples = List.of(_samples);
    }
  }

  int get chartRightUs => replaying
      ? (chartFocusUs ?? cursorUs) + (chartWindow * 500000).round()
      : (_liveChartRightUs ?? timelineDurationUs);

  Future<void> prepareSave() async {
    final directory = pendingRecording;
    if (directory == null) return;
    final value = await TelemetryArchive.open(directory);
    if (archive?.directory.path != directory.path) {
      await openArchive(value);
      await seek(value.durationUs);
    }
    clipStartUs ??= 0;
    clipEndUs ??= value.durationUs;
    await seek(cursorUs.clamp(selectionStartUs, selectionEndUs));
  }

  Future<void> decideRecording({
    required bool save,
    bool trim = false,
    Directory? destination,
    String? name,
    List<String>? tags,
  }) async {
    final directory = pendingRecording;
    if (directory == null || !save) return;
    if (recorder?.error != null) {
      throw StateError('recording write failed; original retained');
    }
    Directory? stagingClip;
    final root = destination ?? recorder?.directory ?? directory.parent;
    final original = await TelemetryArchive.open(directory);
    var value = original;
    try {
      if (trim) {
        stagingClip = await original.exportRange(
          root,
          selectionStartUs,
          selectionEndUs,
        );
        value = await TelemetryArchive.open(stagingClip);
      }
      final saved = await value.saveNamed(
        root,
        name ?? recorder?.settings.name ?? '日志',
        tags ?? recorder?.settings.tags ?? const [],
      );
      await openArchive(await TelemetryArchive.open(saved));
    } finally {
      if (stagingClip != null && await stagingClip.exists()) {
        await stagingClip.delete(recursive: true);
      }
    }
    // Delete the staging session only after a successful verified save.
    await directory.delete(recursive: true);
    if (recorder?.sessionDirectory?.path == directory.path) {
      recorder!.forgetSession(directory);
    }
    pendingRecording = null;
    _notify();
  }

  Future<void> moveSelection(bool start, int us) async {
    pauseDisplay();
    clipStartUs ??= 0;
    clipEndUs ??= timelineDurationUs;
    if (start) {
      clipStartUs = us.clamp(0, cursorUs);
    } else {
      clipEndUs = us.clamp(cursorUs, timelineDurationUs);
    }
    playbackFromUs = clipStartUs!;
    playbackToUs = clipEndUs!;
    await seekTimeline(cursorUs, focusUs: start ? clipStartUs : clipEndUs);
  }

  void enableConnectionRecording() {
    _connectionManaged = true;
  }

  Future<void> beginConnection(String endpoint) async {
    if (_connectionActive) await endConnection();
    _viewRequest++;
    _connectionManaged = true;
    _connectionArchive = null;
    _historyLoading = null;
    _connectionClock
      ..reset()
      ..start();
    returnToLive();
    _samples.clear();
    await recorder?.beginSession(endpoint);
    _connectionActive = true;
    pendingRecording = null;
    start();
    cursorUs = 0;
    _refreshChannels();
    _notify();
  }

  Future<void> endConnection() async {
    if (!_connectionActive) return;
    final hadRecording = recorder?.sessionActive == true;
    final wasFollowing = followingLatest;
    final previousCursor = timelineCursorUs;
    _connectionActive = false;
    _viewRequest++;
    if (!replaying) pauseDisplay();
    await stop();
    await recorder?.endSession();
    _connectionClock.stop();
    if (hadRecording) {
      pendingRecording = recorder?.sessionDirectory;
      if (pendingRecording != null && recorder?.error == null) {
        // Finalize only the cache. Keep the complete session available for
        // immediate offline playback; saving to the library is explicit.
        final value = await TelemetryArchive.open(pendingRecording!);
        await openArchive(value);
        await seek(wasFollowing ? value.durationUs : previousCursor);
      }
    }
    _notify();
  }

  int get timelineDurationUs {
    if (archive != null && !_reviewConnection) return archive!.durationUs;
    if (_frozenDurationUs != null) return _frozenDurationUs!;
    if (_connectionManaged) {
      return recorder?.sessionDurationUs ??
          _connectionClock.elapsedMicroseconds;
    }
    return archive?.durationUs ?? 0;
  }

  bool get followingLatest => !replaying;
  bool get offlineReplay => archive != null && !_reviewConnection;
  int get timelineCursorUs => followingLatest ? timelineDurationUs : cursorUs;

  void pauseDisplay() {
    pausePlayback();
    if (!replaying) {
      // Freeze the last rendered transform, not a newly centered latest sample.
      final right = _liveChartRightUs ?? timelineDurationUs;
      _chartWindow ??= _liveChartWindow;
      final center = right - (chartWindow * 500000).round();
      _frozenDurationUs = right;
      chartFocusUs = center;
      cursorUs = center.clamp(selectionStartUs, selectionEndUs);
      _replaySamples = List.of(_liveChartSamples ?? _samples);
      _cursorSample = null;
      for (final sample in _replaySamples!.reversed) {
        if (sample.time.microsecondsSinceEpoch <= cursorUs) {
          _cursorSample = sample;
          break;
        }
      }
      _displayFrozen = true;
      chartViewRevision++;
      _frozenHistoryReady = false;
      _seekCache = List.of(_replaySamples!);
      _cacheToUs = right;
      _cacheFromUs = (right - chartWindow * 1000000).round().clamp(0, right);
    }
    _notify();
  }

  Future<TelemetryArchive?> historyForExport() async {
    if (offlineReplay) return archive;
    final sink = recorder;
    final directory = sink?.sessionDirectory;
    if (sink == null || directory == null) return null;
    final cached = _connectionArchive;
    // A paused timeline is a snapshot. Do not flush/fsync the live writer and
    // re-index the growing file on every pointer movement.
    if (_displayFrozen && _frozenHistoryReady && cached != null) return cached;
    _historyLoading ??= (() async {
      await sink.flush();
      if (sink.sessionDirectory != directory) {
        throw StateError('connection changed during history read');
      }
      final value = cached ?? await TelemetryArchive.open(directory);
      await value.refresh();
      return value;
    })();
    final task = _historyLoading!;
    try {
      final value = await task;
      if (sink.sessionDirectory != directory) return null;
      _connectionArchive = value;
      if (_displayFrozen) _frozenHistoryReady = true;
      return value;
    } finally {
      if (identical(_historyLoading, task)) _historyLoading = null;
    }
  }

  Future<void> seekTimeline(int us, {int? focusUs}) async {
    if (archive != null && !_reviewConnection) {
      pausePlayback();
      await seek(us, focusUs: focusUs);
      return;
    }
    pauseDisplay();
    final request = ++_viewRequest;
    final sink = recorder;
    final directory = sink?.sessionDirectory;
    if (sink == null || directory == null) return;
    try {
      final value = await historyForExport();
      if (value == null ||
          _disposed ||
          request != _viewRequest ||
          sink.sessionDirectory != directory) {
        return;
      }
      _connectionArchive = value;
      archive = value;
      _reviewConnection = true;
      playbackFromUs = 0;
      playbackToUs = timelineDurationUs.clamp(0, value.durationUs);
      await seek(us.clamp(0, timelineDurationUs), focusUs: focusUs);
    } catch (e) {
      _historyLoading = null;
      if (!_disposed && request == _viewRequest) {
        playbackError = e;
        _notify();
      }
    }
  }

  TelemetryArchive? archive;
  List<TelemetrySample>? _replaySamples;
  TelemetrySample? _cursorSample;
  int cursorUs = 0;
  int playbackFromUs = 0, playbackToUs = 0;
  double playbackSpeed = 1;
  Timer? _playTimer;
  final _playClock = Stopwatch();
  int _playOriginUs = 0, _seekGeneration = 0;
  bool _seeking = false, _playStarting = false;
  int _playRequest = 0;
  Object? playbackError;
  bool get replaying => archive != null || _displayFrozen;
  bool get playing => _playTimer != null;
  DateTime get now => replaying
      ? DateTime.fromMicrosecondsSinceEpoch(cursorUs, isUtc: true)
      : _connectionManaged
      ? DateTime.fromMicrosecondsSinceEpoch(timelineDurationUs, isUtc: true)
      : DateTime.now();

  Future<void> openArchive(TelemetryArchive value) async {
    _chartNavigationEpoch++;
    _overview = null;
    pausePlayback();
    _viewRequest++;
    _frozenDurationUs = null;
    clipStartUs = clipEndUs = null;
    archive = value;
    _reviewConnection = false;
    _displayFrozen = true;
    _seekCache = [];
    _cacheToUs = -1;
    playbackFromUs = 0;
    playbackToUs = value.durationUs;
    _replaySamples = [];
    _cursorSample = null;
    archiveOpenRevision++;
    // A newly opened log starts with the complete flight in view. Keep the
    // playback cursor at the beginning; viewport focus is independent of it.
    _chartWindow = (value.durationUs / 1e6).clamp(.001, 3600).toDouble();
    await seek(0, focusUs: value.durationUs ~/ 2);
  }

  Future<void> seek(int us, {int? focusUs}) async {
    final value = archive;
    if (value == null || _disposed) return;
    final generation = ++_seekGeneration;
    final limit = _reviewConnection
        ? timelineDurationUs.clamp(0, value.durationUs)
        : value.durationUs;
    final target = us.clamp(
      selectionStartUs,
      selectionEndUs.clamp(selectionStartUs, limit),
    );
    final focus = (focusUs ?? target).clamp(0, limit);
    final from = (focus - chartWindow * 500000).round().clamp(0, limit);
    final to = (focus + chartWindow * 500000).round().clamp(0, limit);
    final samples = <TelemetrySample>[];
    try {
      final estimated =
          value.rows *
          (to - from) /
          (value.durationUs > 0 ? value.durationUs : 1);
      if (estimated > maxDisplaySamples) {
        await _loadOverview(value, from, to, target, generation);
        if (generation != _seekGeneration || _disposed || archive != value) {
          return;
        }
        cursorUs = target;
        chartFocusUs = focus;
        playbackError = null;
        _refreshChannels();
        chartViewRevision++;
        _notify();
        return;
      }
      _overview = null;
      if (from >= _cacheFromUs && to <= _cacheToUs) {
        samples.addAll(
          _seekCache.where((s) {
            final us = s.time.microsecondsSinceEpoch;
            return us >= from && us <= to;
          }),
        );
      } else {
        // Bounded read-ahead lets adjacent slider movements render from RAM.
        final cacheFrom = (from - chartWindow * 1000000).round().clamp(0, from);
        final cacheTo = (to + chartWindow * 1000000).round().clamp(0, limit);
        final loaded = <TelemetrySample>[];
        await for (final row in value.range(cacheFrom, cacheTo)) {
          if (generation != _seekGeneration || _disposed) return;
          loaded.add(row.sample);
          if (loaded.length % 1024 == 0) {
            await Future<void>.delayed(Duration.zero);
          }
        }
        if (generation != _seekGeneration || _disposed || archive != value) {
          return;
        }
        // Keep memory bounded even for unexpectedly high-rate sources.
        if (loaded.length <= maxDisplaySamples * 3) {
          _seekCache = loaded;
          _cacheFromUs = cacheFrom;
          _cacheToUs = cacheTo;
        }
        samples.addAll(
          loaded.where((s) {
            final us = s.time.microsecondsSinceEpoch;
            return us >= from && us <= to;
          }),
        );
      }
      if (generation != _seekGeneration || _disposed || archive != value) {
        return;
      }
      TelemetrySample? cursorSample;
      if (target >= from && target <= to) {
        for (final sample in samples.reversed) {
          if (sample.time.microsecondsSinceEpoch <= target) {
            cursorSample = sample;
            break;
          }
        }
      }
      cursorSample ??= (await value.atOrBefore(target))?.sample;
      if (generation != _seekGeneration || _disposed || archive != value) {
        return;
      }
      _cursorSample = cursorSample;
      cursorUs = target;
      chartFocusUs = focus;
      _replaySamples = samples;
      chartViewRevision++;
      playbackError = null;
      _refreshChannels();
      _notify();
    } catch (e) {
      if (generation != _seekGeneration || _disposed) return;
      playbackError = e;
      pausePlayback();
      _notify();
    }
  }

  Future<void> _loadOverview(
    TelemetryArchive value,
    int from,
    int to,
    int target,
    int generation,
  ) async {
    final resolution = (to - from) / _chartPixels;
    if (_overview == null ||
        _overviewArchive != value ||
        _overviewFields != _selectedSignature ||
        from < _overviewFrom ||
        to > _overviewTo ||
        _overviewBucketUs > resolution * 1.01) {
      final span = to - from;
      final start = (from - span).clamp(0, from);
      final end = (to + span).clamp(to, value.durationUs);
      final columns = resolution <= 0
          ? 1
          : ((end - start) / resolution).ceil().clamp(1, 8192);
      final envelopes = {
        for (final id in _selected)
          id: TelemetryEnvelope(start / 1e6, end / 1e6, columns),
      };
      final preview = <TelemetrySample>[];
      var count = 0;
      int lastBucket = -1;
      await for (final row in value.range(start, end)) {
        if (generation != _seekGeneration || _disposed || archive != value) {
          return;
        }
        final sample = row.sample;
        final t = row.elapsedUs / 1e6;
        for (final entry in envelopes.entries) {
          final v = sample.valueOf(entry.key);
          if (v.isFinite) entry.value.add(TelemetryPoint(t, v));
        }
        final bucket = ((row.elapsedUs - start) / ((end - start + 1) / columns))
            .floor();
        if (bucket != lastBucket) {
          preview.add(sample);
          lastBucket = bucket;
        }
        if (++count % 1024 == 0) await Future<void>.delayed(Duration.zero);
      }
      if (generation != _seekGeneration || _disposed) return;
      _overview = {
        for (final entry in envelopes.entries) entry.key: entry.value.points,
      };
      _overviewArchive = value;
      _overviewFields = _selectedSignature;
      _overviewFrom = start;
      _overviewTo = end;
      _overviewBucketUs = (end - start) / columns;
      _replaySamples = preview;
    }
    // Sparse-index lookup: at most one index block, even inside long gaps.
    final exact = await value.atOrBefore(target);
    if (generation != _seekGeneration || _disposed) return;
    _cursorSample = exact?.sample;
  }

  void pausePlayback() {
    _playRequest++;
    _seekGeneration++;
    _playTimer?.cancel();
    _playTimer = null;
    _playClock.stop();
    _notify();
  }

  void setPlaybackRange(int fromUs, int toUs) {
    final value = archive;
    if (value == null ||
        fromUs < 0 ||
        toUs < fromUs ||
        toUs > value.durationUs) {
      return;
    }
    pausePlayback();
    playbackFromUs = fromUs;
    playbackToUs = toUs;
    _notify();
  }

  Future<void> play() async {
    final value = archive;
    if (value == null ||
        playing ||
        _playStarting ||
        _disposed ||
        playbackToUs <= playbackFromUs) {
      return;
    }
    final request = ++_playRequest;
    _playStarting = true;
    try {
      if (cursorUs < playbackFromUs || cursorUs >= playbackToUs) {
        await seek(playbackFromUs);
        if (archive != value ||
            _disposed ||
            playbackError != null ||
            request != _playRequest) {
          return;
        }
      }
      _playOriginUs = cursorUs;
      _playClock
        ..reset()
        ..start();
      _playTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
        if (_seeking || archive == null) return;
        _seeking = true;
        try {
          final next =
              _playOriginUs +
              (_playClock.elapsedMicroseconds * playbackSpeed).round();
          await seek(next.clamp(playbackFromUs, playbackToUs));
          if (archive != null && cursorUs >= playbackToUs) pausePlayback();
        } finally {
          _seeking = false;
        }
      });
      _notify();
    } finally {
      _playStarting = false;
    }
  }

  Future<void> step() async {
    pausePlayback();
    final value = archive;
    if (value == null || cursorUs >= playbackToUs) return;
    await for (final row in value.range(cursorUs + 1, playbackToUs)) {
      await seek(row.elapsedUs);
      break;
    }
  }

  void resumeDisplay() {
    if (!_connectionActive && archive != null) {
      pausePlayback();
      unawaited(seekTimeline(timelineDurationUs));
      return;
    }
    returnToLive();
  }

  void returnToLive() {
    _chartNavigationEpoch++;
    _chartWindow = null;
    _liveChartRightUs = null;
    _liveChartWindow = null;
    _liveChartSamples = null;
    _overview = null;
    pausePlayback();
    _seekGeneration++;
    _viewRequest++;
    archive = null;
    chartFocusUs = null;
    clipStartUs = clipEndUs = null;
    _frozenDurationUs = null;
    _displayFrozen = false;
    _reviewConnection = false;
    _replaySamples = null;
    _cursorSample = null;
    _seekCache = [];
    _cacheToUs = -1;
    _frozenHistoryReady = false;
    playbackError = null;
    _refreshChannels();
    _notify();
  }

  int _chartNavigationEpoch = 0;
  int get chartNavigationEpoch => _chartNavigationEpoch;
  int _chartPixels = 1024;
  void setChartPixelWidth(double width) {
    _chartPixels = width.round().clamp(64, 2048);
  }

  Map<String, List<TelemetryPoint>>? _overview;
  TelemetryArchive? _overviewArchive;
  String _overviewFields = '';
  int _overviewFrom = 0, _overviewTo = -1;
  double _overviewBucketUs = double.infinity;
  String get _selectedSignature => (_selected.toList()..sort()).join('|');

  double? _chartWindow;
  double get chartWindow =>
      _chartWindow ?? _liveChartWindow ?? window.toDouble();

  Future<void> inspectChart({int? centerUs, double? windowSeconds}) async {
    pauseDisplay(); // Freeze only display; receiver/recorder keep running.
    if (windowSeconds != null) {
      _chartWindow = windowSeconds.clamp(.001, 3600).toDouble();
    }
    final center = (centerUs ?? chartFocusUs ?? cursorUs).clamp(
      0,
      timelineDurationUs,
    );
    await seekTimeline(center, focusUs: center);
  }

  final int window; // seconds of history kept/plotted
  int get maxDisplaySamples => window * 1000;
  final List<TelemetrySample> _samples = [];
  final Set<String> _selected = {...defaultSelected};
  List<TelemetryChannel> _channels = List.unmodifiable(TelemetryChannel.all);
  String _channelSignature = '';
  List<TelemetryChannel> get channels => _channels;

  void _onSchemaChanged() {
    if (_disposed) return;
    _refreshChannels();
    _notify();
  }

  void _refreshChannels() {
    final descriptors = <String, String?>{
      for (final channel in TelemetryChannel.all) channel.id: null,
    };
    final source = _source;
    final schema = source is UdpTelemetrySource ? source.schema : null;
    if (archive != null) {
      final fields = (archive!.metadata['schema'] as Map?)?['fields'];
      if (fields is List) {
        for (final f in fields.whereType<Map>()) {
          descriptors[f['name'] as String] = f['type'] as String?;
        }
      }
      for (final key in archive!.columns.skip(2)) {
        descriptors.putIfAbsent(key, () => null);
      }
    } else if (schema != null) {
      for (final field in schema.fields) {
        descriptors[field.name] = field.type;
      }
      descriptors['seq'] = 'uint32';
      descriptors['stream_id'] = 'uint32';
    } else {
      final keys = latest?.values.keys.toList() ?? <String>[];
      keys.sort();
      for (final key in keys) {
        descriptors.putIfAbsent(key, () => null);
      }
    }
    final signature = descriptors.entries
        .map((e) => '${e.key}:${e.value}')
        .join('|');
    if (signature == _channelSignature) return;
    _channelSignature = signature;
    _channels = List.unmodifiable(
      descriptors.entries.map(
        (e) => TelemetryChannel.discovered(e.key, type: e.value),
      ),
    );
  }

  bool _running = false;
  bool _disposed = false;

  int archiveOpenRevision = 0;
  int chartDataRevision = 0;
  int chartViewRevision = 0;

  void _notify() {
    chartDataRevision++;
    if (!_disposed) notifyListeners();
  }

  TelemetrySource get source => _source;
  bool get running => _running;
  Set<String> get selected => Set.unmodifiable(_selected);

  List<TelemetrySample> get samples =>
      List.unmodifiable(_replaySamples ?? _samples);

  /// Latest sample (drives the 3D attitude view); null before the first tick.
  TelemetrySample? get latest {
    final values = _replaySamples ?? _samples;
    if (replaying) return _cursorSample;
    if (values.isEmpty) return null;
    return values.last;
  }

  /// pitch/roll/yaw in degrees from the latest sample (NaN when missing).
  ({double pitch, double roll, double yaw}) get attitude {
    final s = latest;
    return (
      pitch: s?.valueOf('pitch') ?? double.nan,
      roll: s?.valueOf('roll') ?? double.nan,
      yaw: s?.valueOf('yaw') ?? double.nan,
    );
  }

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _source.start(_onSample);
    _notify();
  }

  Future<void> stop() async {
    if (!_running || _disposed) return;
    _running = false;
    await _source.stop();
    _notify();
  }

  /// Forget samples from the previous connection/board.
  void clear() {
    if (_disposed || _samples.isEmpty) return;
    _samples.clear();
    _refreshChannels();
    _notify();
  }

  void toggleChannel(String channel) {
    if (_disposed) return;
    if (!_selected.remove(channel)) _selected.add(channel);
    _channelsChanged(save: true);
  }

  void _onSample(TelemetrySample sample) {
    if (_connectionManaged && !_connectionActive) return;
    final elapsed = recorder?.add(sample);
    final displaySample = _connectionManaged
        ? TelemetrySample(
            time: DateTime.fromMicrosecondsSinceEpoch(
              elapsed ?? _connectionClock.elapsedMicroseconds,
              isUtc: true,
            ),
            values: sample.values,
            schema: sample.schema,
            sourceAddress: sample.sourceAddress,
            receivedAt: sample.time,
            receiverStats: sample.receiverStats,
          )
        : sample;
    _samples.add(displaySample);
    _refreshChannels();
    final cutoff = (_connectionManaged ? displaySample.time : DateTime.now())
        .subtract(Duration(seconds: window));
    // trim: keep at most one second beyond the window
    while (_samples.isNotEmpty &&
        (_samples.first.time.isBefore(cutoff) ||
            _samples.length > maxDisplaySamples)) {
      _samples.removeAt(0);
    }
    _notify();
  }

  /// Series for [channel] over the visible window, oldest first.
  List<TelemetryPoint> seriesFor(String channel, {int? maxPoints}) {
    final overview = _overview?[channel];
    if (overview != null && _overviewArchive == archive) {
      final right = chartRightUs / 1e6;
      final visible = overview
          .where((p) => p.seconds >= right - chartWindow && p.seconds <= right)
          .map((p) => TelemetryPoint(right - p.seconds, p.value))
          .toList();
      return _reduceSeries(visible, maxPoints);
    }
    final timestamp =
        replaying || (_connectionManaged && _liveChartRightUs != null)
        ? DateTime.fromMicrosecondsSinceEpoch(chartRightUs, isUtc: true)
        : now;
    final result = <TelemetryPoint>[];
    for (final s in _replaySamples ?? _liveChartSamples ?? _samples) {
      final seconds = timestamp.difference(s.time).inMilliseconds / 1000.0;
      if (seconds < 0 || seconds > chartWindow) continue;
      final value = s.valueOf(channel);
      if (value.isNaN || value.isInfinite) continue;
      result.add(TelemetryPoint(seconds, value));
    }
    return _reduceSeries(result, maxPoints);
  }

  List<TelemetryPoint> _reduceSeries(
    List<TelemetryPoint> points,
    int? maxPoints,
  ) {
    if (maxPoints == null || points.length <= maxPoints) return points;
    final envelope = TelemetryEnvelope(
      0,
      chartWindow.toDouble(),
      (maxPoints ~/ 4).clamp(1, 4096),
    );
    for (final p in points) {
      envelope.add(p);
    }
    return envelope.points;
  }

  /// Latest value of [channel] for the checkbox legend (NaN when absent).
  double latestValueOf(String channel) =>
      latest?.valueOf(channel) ?? double.nan;

  @override
  void dispose() {
    if (_viewSaveTimer?.isActive == true) saveDefaultChannels();
    _viewSaveTimer?.cancel();
    _disposed = true;
    _playTimer?.cancel();
    _seekGeneration++;
    _viewRequest++;
    final sink = recorder;
    if (sink != null) unawaited(sink.close().whenComplete(sink.dispose));
    if (_source is UdpTelemetrySource) {
      _source.onSchemaChanged = null;
    }
    _source.stop();
    super.dispose();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dart_control_panel/core/platform/android_log_share.dart';
import 'package:dart_control_panel/shared/widgets/log_directory_picker.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:flutter/material.dart';
import 'telemetry_archive.dart';
import 'telemetry_controller.dart';
import 'telemetry_save_dialog.dart';
import 'telemetry_log_settings_dialog.dart';
import 'telemetry_selection_timeline.dart';

/// Summary above the dashboard, or compact transport controls below its chart.
class TelemetryRecordingControls extends StatefulWidget {
  const TelemetryRecordingControls({
    super.key,
    required this.controller,
    this.timeline = false,
    this.saveEditor = false,
  });
  final TelemetryController controller;
  final bool timeline;
  final bool saveEditor;
  @override
  State<TelemetryRecordingControls> createState() =>
      _TelemetryRecordingControlsState();
}

class _TelemetryRecordingControlsState
    extends State<TelemetryRecordingControls> {
  bool _busy = false;
  double? _dragSeconds;
  Timer? _scrubTimer;
  Future<void>? _scrubTask;
  int? _pendingScrubUs;
  bool _dragging = false;
  int _scrubGeneration = 0;
  String? _message;
  TelemetryController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    c.recorder?.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopScrub();
    c.removeListener(_changed);
    c.recorder?.removeListener(_changed);
    super.dispose();
  }

  void _stopScrub() {
    _scrubGeneration++;
    _scrubTimer?.cancel();
    _scrubTimer = null;
    _pendingScrubUs = null;
    _dragging = false;
  }

  void _queueScrub(double seconds) {
    _pendingScrubUs = (seconds * 1000000).round();
    if (_scrubTimer == null) {
      _scrubTimer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => _pumpScrub(),
      );
      _pumpScrub(); // Render the first movement immediately.
    }
  }

  void _pumpScrub() {
    if (_scrubTask != null || _pendingScrubUs == null) return;
    final target = _pendingScrubUs!.clamp(c.selectionStartUs, c.selectionEndUs);
    final generation = _scrubGeneration;
    _pendingScrubUs = null;
    _scrubTask =
        (() async {
          try {
            await c.seekTimeline(target);
          } catch (e) {
            if (mounted && generation == _scrubGeneration) {
              setState(() => _message = '$e');
            }
          }
        })().whenComplete(() {
          _scrubTask = null;
          if (!mounted || generation != _scrubGeneration) return;
          if (!_dragging && _pendingScrubUs == null) {
            _scrubTimer?.cancel();
            _scrubTimer = null;
            setState(() => _dragSeconds = null);
          }
        });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(Directory directory) => _run(() async {
    setState(() => _message = '正在压缩本次日志…');
    await AndroidLogShare.share(directory);
    if (mounted) setState(() => _message = '已打开分享面板，是否发送由目标应用决定');
  });

  Future<void> _open(Directory directory) async {
    final archive = await TelemetryArchive.open(directory);
    if (mounted) await c.openArchive(archive);
  }

  Future<void> _list() async {
    await c.recorder?.flush();
    final root = c.recorder?.directory ?? TelemetryRecorder.defaultDirectory();
    await root.create(recursive: true);
    final dirs = <Directory>[];
    await for (final entry in root.list()) {
      if (entry is Directory &&
          !entry.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .last
              .startsWith('connection_') &&
          await File('${entry.path}/metadata.json').exists()) {
        dirs.add(entry);
      }
    }
    dirs.sort((a, b) => b.path.compareTo(a.path));
    if (!mounted) return;
    final selected = await showDialog<Directory>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地连接记录'),
        content: SizedBox(
          width: 560,
          height: 360,
          child: dirs.isEmpty
              ? const Center(child: Text('尚无记录；Connect 成功后开始新记录'))
              : ListView.builder(
                  itemCount: dirs.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(
                      dirs[i].uri.pathSegments.where((s) => s.isNotEmpty).last,
                    ),
                    subtitle: FutureBuilder<String>(
                      future: (() async {
                        final doc =
                            jsonDecode(
                                  await File(
                                    '${dirs[i].path}/metadata.json',
                                  ).readAsString(),
                                )
                                as Map;
                        final tags = (doc['tags'] as List?)?.join(' · ') ?? '';
                        return tags.isEmpty
                            ? dirs[i].path
                            : '$tags\n${dirs[i].path}';
                      })(),
                      builder: (context, snapshot) =>
                          Text(snapshot.data ?? dirs[i].path),
                    ),
                    leading: const Icon(Icons.history),
                    trailing: Platform.isAndroid
                        ? IconButton(
                            tooltip: '压缩并分享单次日志',
                            onPressed: _busy ? null : () => _share(dirs[i]),
                            icon: const Icon(Icons.share_outlined),
                          )
                        : null,
                    onTap: () => Navigator.pop(context, dirs[i]),
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
    if (selected != null && mounted) await _open(selected);
  }

  Future<void> _interval() async {
    final archive = await c.historyForExport();
    if (archive == null || archive.rows == 0) {
      throw StateError('当前连接尚无有效遥测样本');
    }
    if (!mounted) return;
    final duration =
        (c.offlineReplay
            ? archive.durationUs
            : c.timelineDurationUs.clamp(0, archive.durationUs)) /
        1000000;
    var range = RangeValues(0, duration);
    final chosen = await showDialog<({RangeValues range, bool export})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('区间回放 / 截取保存'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${range.start.toStringAsFixed(3)} ～ ${range.end.toStringAsFixed(3)} 秒',
                ),
                RangeSlider(
                  values: range,
                  max: duration > 0 ? duration : 1,
                  onChanged: duration == 0
                      ? null
                      : (value) => update(() => range = value),
                ),
                const Text('保留区间内全部样本和原序号，不影响正在接收的数据。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (range: range, export: false)),
              child: const Text('回放选区'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, (range: range, export: true)),
              child: const Text('截取保存'),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    final from = (chosen.range.start * 1000000).round();
    final to = (chosen.range.end * 1000000).round();
    if (!chosen.export) {
      await c.openArchive(archive);
      c.setPlaybackRange(from, to);
      await c.seek(from);
      return;
    }
    final path = await chooseLogDirectory(context, confirmButtonText: '保存截取记录');
    if (path == null) return;
    final result = await archive.exportRange(Directory(path), from, to);
    if (mounted) setState(() => _message = '已保存：${result.path}');
  }

  static String timeLabel(double seconds) {
    final ms = (seconds * 1000).round();
    final minutes = ms ~/ 60000;
    return '${minutes.toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final recorder = c.recorder;
    final duration = c.timelineDurationUs / 1000000;
    final max = duration > 0 ? duration : 1.0;
    final current = (_dragSeconds ?? c.timelineCursorUs / 1000000).clamp(
      c.selectionStartUs / 1000000.0,
      (c.selectionEndUs / 1000000.0).clamp(0.0, max),
    );
    if (!widget.timeline) {
      return Padding(
        padding: MobileUiScale.isHandset(context)
            ? const EdgeInsets.symmetric(horizontal: 4)
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RecordingSummaryRow(
              children: [
                Text(
                  c.followingLatest
                      ? (recorder?.sessionActive == true
                            ? '实时遥测'
                            : '等待 Connect')
                      : (recorder?.sessionActive == true
                            ? '历史查看 · 接收与记录继续'
                            : '历史查看'),
                ),
                if (recorder != null)
                  Tooltip(
                    message:
                        recorder.sessionDirectory?.path ??
                        recorder.directory.path,
                    child: Text(
                      '${recorder.sessionActive
                          ? '连接记录中'
                          : recorder.sessionSaved
                          ? '会话缓存已就绪'
                          : recorder.sessionDirectory == null
                          ? '未开始记录'
                          : '缓存收尾中'} ${recorder.written} 行 · 本地丢弃 ${recorder.dropped}',
                    ),
                  ),
                if (c.pendingRecording != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => showTelemetrySaveDialog(context, c)),
                    child: const Text('保存接收日志'),
                  ),
                if (Platform.isAndroid && c.offlineReplay && !c.connected)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _share(c.archive!.directory),
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('压缩分享'),
                  ),
                if (recorder != null)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => showTelemetryLogSettings(context, recorder),
                          ),
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: const Text('日志设置'),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : () => _run(_list),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('记录列表'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final path = await chooseLogDirectory(
                            context,
                            confirmButtonText: '打开记录',
                          );
                          if (path != null && mounted) {
                            await _open(Directory(path));
                          }
                        }),
                  child: const Text('打开记录目录'),
                ),
              ],
            ),
            if (recorder?.error != null)
              Text(
                '保存失败：${recorder!.error}',
                style: const TextStyle(color: Colors.red),
              ),
            if (_message != null) Text(_message!),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: widget.saveEditor || c.selecting
                  ? TelemetrySelectionTimeline(
                      key: const ValueKey('telemetry-selection-timeline'),
                      duration: duration,
                      start: c.selectionStartUs / 1000000.0,
                      current: current,
                      end: c.selectionEndUs / 1000000.0,
                      onStart: (v) =>
                          c.moveSelection(true, (v * 1000000).round()),
                      onEnd: (v) =>
                          c.moveSelection(false, (v * 1000000).round()),
                      onCurrentStart: () {
                        _dragging = true;
                        c.pauseDisplay();
                      },
                      onCurrent: (v) {
                        setState(() => _dragSeconds = v);
                        _queueScrub(v);
                      },
                      onCurrentEnd: (v) {
                        _dragging = false;
                        _queueScrub(_dragSeconds ?? v);
                      },
                    )
                  : SizedBox(
                      height: MobileUiScale.isHandset(context) ? 28 : 48,
                      child: Slider(
                        key: const ValueKey('telemetry-history-slider'),
                        value: current,
                        max: max,
                        onChangeStart: duration == 0
                            ? null
                            : (_) {
                                _dragging = true;
                                c.pauseDisplay();
                              },
                        // Disk reads never disable the slider. Latest target wins,
                        // with one seek in flight and no unbounded request queue.
                        onChanged: duration == 0
                            ? null
                            : (value) {
                                setState(
                                  () => _dragSeconds = value.clamp(
                                    c.selectionStartUs / 1000000.0,
                                    c.selectionEndUs / 1000000.0,
                                  ),
                                );
                                _queueScrub(value);
                              },
                        onChangeEnd: duration == 0
                            ? null
                            : (value) {
                                _dragging = false;
                                _queueScrub(value);
                              },
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${timeLabel(current)} / ${timeLabel(duration)}',
                key: const ValueKey('telemetry-history-time'),
              ),
            ),
          ],
        ),
        if (widget.saveEditor || c.selecting)
          Text(
            '起点 ${timeLabel(c.selectionStartUs / 1000000.0)} · 播放 ${timeLabel(current)} · 终点 ${timeLabel(c.selectionEndUs / 1000000.0)}',
          ),
        if (!widget.saveEditor)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            children: [
              TextButton.icon(
                key: const ValueKey('telemetry-pause'),
                onPressed: c.pauseDisplay,
                icon: const Icon(Icons.pause),
                label: const Text('暂停'),
              ),
              TextButton.icon(
                key: const ValueKey('telemetry-resume'),
                onPressed: () {
                  _stopScrub();
                  _dragSeconds = null;
                  c.resumeDisplay();
                },
                icon: const Icon(Icons.fast_forward),
                label: const Text('恢复'),
              ),
              if (c.offlineReplay) ...[
                IconButton(
                  tooltip: '播放选区',
                  onPressed: _busy ? null : c.play,
                  icon: const Icon(Icons.play_arrow),
                ),
                IconButton(
                  tooltip: '下一样本',
                  onPressed: _busy ? null : c.step,
                  icon: const Icon(Icons.skip_next),
                ),
                DropdownButton<double>(
                  value: c.playbackSpeed,
                  items: [
                    for (final speed in [0.25, 1.0, 2.0, 4.0])
                      DropdownMenuItem(value: speed, child: Text('$speed×')),
                  ],
                  onChanged: (value) {
                    c.pausePlayback();
                    setState(() => c.playbackSpeed = value!);
                  },
                ),
              ],
              IconButton(
                tooltip: '区间回放 / 截取保存',
                onPressed: _busy || duration == 0
                    ? null
                    : () => _run(_interval),
                icon: const Icon(Icons.content_cut),
              ),
              if (_busy || _scrubTask != null)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        if (_message != null) Text(_message!),
        if (c.playbackError != null)
          Text(
            '历史读取失败：${c.playbackError}',
            style: const TextStyle(color: Colors.red),
          ),
      ],
    );
  }
}

class _RecordingSummaryRow extends StatelessWidget {
  const _RecordingSummaryRow({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if ((size.height < 500 || MobileUiScale.isHandset(context)) &&
        size.width > size.height) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(spacing: 12, children: children),
      );
    }
    return Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

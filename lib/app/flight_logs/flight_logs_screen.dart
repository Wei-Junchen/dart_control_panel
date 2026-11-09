import 'dart:io';

import 'package:dart_control_panel/shared/widgets/log_directory_picker.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:flutter/material.dart';
import 'package:dart_control_panel/features/files/files_screen.dart';
import 'package:dart_control_panel/features/files/board_file_api.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_archive.dart';
import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/core/video/video_panel.dart';
import 'package:dart_control_panel/features/flight_analysis/luma_analysis_screen.dart';
import 'flight_log_controller.dart';

class FlightLogsScreen extends StatefulWidget {
  const FlightLogsScreen({
    super.key,
    required this.controller,
    required this.onReplay,
    this.filePort = 9002,
    this.deviceIdFilter,
    this.deviceLabel,
    this.initialTab = 0,
    this.unknownOnly = false,
  });
  final FlightLogController controller;
  final Future<void> Function(TelemetryArchive) onReplay;
  final int filePort;
  final String? deviceIdFilter;
  final String? deviceLabel;
  final int initialTab;
  final bool unknownOnly;
  @override
  State<FlightLogsScreen> createState() => _FlightLogsScreenState();
}

class _FlightLogsScreenState extends State<FlightLogsScreen> {
  FlightLogController get c => widget.controller;
  String? get deviceIdFilter => widget.deviceIdFilter;
  String? get deviceLabel => widget.deviceLabel;
  bool get compact => MediaQuery.sizeOf(context).height < 500;
  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
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
              child: const Text('删除'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> copy(RemoteEntry entry) async {
    try {
      await c.copyRemote(entry, c.localRoot);
    } catch (e) {
      showError(e);
    }
  }

  Future<void> useDefaultRoot() async {
    try {
      await c.setLocalRoot(FlightLogController.defaultLocalRoot());
    } catch (e) {
      showError(e);
    }
  }

  Future<void> chooseLocal() async {
    final path = await chooseLogDirectory(
      context,
      initialDirectory: c.localRoot.existsSync() ? c.localRoot.path : null,
    );
    if (path == null) return;
    try {
      await c.setLocalRoot(Directory(path));
    } catch (e) {
      showError(e);
    }
  }

  void showError(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> replay(LocalFlightLog log) async {
    try {
      final archive = await TelemetryArchive.open(log.directory);
      if (mounted) await widget.onReplay(archive);
    } catch (e) {
      showError(e);
    }
  }

  Future<double?> askFps(LocalFlightLog log) async {
    final field = TextEditingController(
      text: ((log.metadata['estimated_video_fps'] as num?)?.toDouble() ?? 80)
          .toStringAsFixed(3),
    );
    final fps = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('H.264 无损封装 MP4'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('原始 H.264 不含可靠容器时间戳。请确认实际录像帧率；此值决定播放速度，不会重新编码。'),
            TextField(
              controller: field,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: '实际录像 FPS（1..1000）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final f = double.tryParse(field.text);
              if (f != null && f.isFinite && f >= 1 && f <= 1000) {
                Navigator.pop(context, f);
              }
            },
            child: const Text('封装'),
          ),
        ],
      ),
    );
    // Dialog route may still be animating; controller disposal is delayed.
    Future<void>.delayed(const Duration(seconds: 1), field.dispose);
    return fps;
  }

  Future<void> remux(LocalFlightLog log) async {
    final fps = await askFps(log);
    if (fps == null) return;
    await c.remuxLocal(log, fps);
    if (c.error != null) showError(c.error!);
  }

  Future<void> play(LocalFlightLog log) => _playVideo(log, raw: false);

  Future<void> _playVideo(LocalFlightLog log, {required bool raw}) async {
    var file = raw ? log.rawMp4 : log.overlayMp4;
    final source = raw ? log.rawH264 : log.overlayH264;
    if (file == null && source != null) {
      final fps = await askFps(log);
      if (fps == null) return;
      await c.remuxLocal(log, fps);
      if (c.error != null) {
        showError(c.error!);
        return;
      }
      file = raw ? log.rawMp4 : log.overlayMp4;
    }
    if (file == null) {
      showError(raw ? '没有原始录像' : '没有叠加录像');
      return;
    }
    await _openVideo(log, file);
  }

  Future<void> _openVideo(LocalFlightLog log, File file) async {
    final player = VideoController();
    try {
      await player.open(file.uri.toString());
      if (!mounted) return;
      await showVideoPlaybackDialog(
        context,
        controller: player,
        url: file.uri.toString(),
        title: log.name,
      );
    } catch (e) {
      showError(e);
    } finally {
      await player.stop();
      player.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: MobileUiScale.isHandset(context)
              ? 40
              : compact
              ? 40
              : kToolbarHeight,
          title: Text(deviceLabel == null ? '飞行日志' : '飞行日志 · $deviceLabel'),
          bottom: TabBar(
            tabs: [
              Tab(
                height: MobileUiScale.isHandset(context)
                    ? 26
                    : compact
                    ? 34
                    : 46,
                text: '板端记录',
              ),
              Tab(
                height: MobileUiScale.isHandset(context)
                    ? 26
                    : compact
                    ? 34
                    : 46,
                text: '本地副本 / 回放',
              ),
              Tab(
                height: MobileUiScale.isHandset(context)
                    ? 26
                    : compact
                    ? 34
                    : 46,
                text: '原始文件',
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '刷新日志',
              onPressed: c.busy
                  ? null
                  : () async {
                      await c.refreshLocal();
                      if (c.ground) await c.refreshRemote(cleanup: true);
                    },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            if (c.busy) const LinearProgressIndicator(),
            if (c.status != null || c.error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                color: c.error == null
                    ? null
                    : Theme.of(context).colorScheme.errorContainer,
                child: SelectableText(
                  [?c.status, ?c.error].join('\n'),
                  maxLines: compact ? 2 : null,
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  remote(),
                  local(),
                  c.connected
                      ? FilesScreen(host: c.remoteHost!, port: widget.filePort)
                      : const Center(child: Text('连接板子后可浏览原始文件')),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget remote() {
    if (!c.connected || !c.ground) {
      return const Center(
        child: Text(
          '连接板子并进入地面模式后，自动扫描记录和清理空目录。\n离线时仍可在“本地副本 / 回放”查看已复制的日志。',
          textAlign: TextAlign.center,
        ),
      );
    }
    if ((widget.unknownOnly && (c.deviceId?.trim().isNotEmpty ?? false)) ||
        (deviceIdFilter != null && c.deviceId != deviceIdFilter)) {
      return Center(
        child: Text(
          '当前连接的不是该设备，无法浏览其板端记录。\n请回到设备页连接对应板子。',
          textAlign: TextAlign.center,
        ),
      );
    }
    if (c.remote.isEmpty) return const Center(child: Text('暂无板端飞行记录'));
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '复制后在本机无损封装 MP4，保留原始 H.264 / CSV。缺少帧率时可手动封装。删除板端记录不会删除本地副本。',
          ),
        ),
        for (final entry in c.remote)
          ListTile(
            leading: const Icon(Icons.flight_takeoff),
            title: Text(entry.name),
            subtitle: Text(entry.path),
            trailing: Wrap(
              children: [
                TextButton.icon(
                  onPressed: c.busy ? null : () => copy(entry),
                  icon: const Icon(Icons.download),
                  label: const Text('复制到本地'),
                ),
                IconButton(
                  tooltip: '删除板端整条记录',
                  onPressed: c.busy
                      ? null
                      : () async {
                          if (await confirm(
                            '删除板端 ${entry.name}？',
                            '将永久删除该目录中的录像与 CSV。已有本地副本不受影响。',
                          )) {
                            await c.deleteRemote(entry);
                          }
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget local() {
    final logs = widget.unknownOnly
        ? c.local.where((log) => log.deviceId == null).toList()
        : deviceIdFilter == null
        ? c.local
        : c.local.where((log) => log.deviceId == deviceIdFilter).toList();
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: compact ? 4 : 12,
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  '本地目录：${c.localRoot.path}'
                  '${c.legacyRoot.path != c.localRoot.path && c.legacyRoot.existsSync() ? '\n旧版目录：${c.legacyRoot.path}' : ''}',
                  maxLines: compact ? 2 : null,
                ),
              ),
              TextButton.icon(
                style: compact
                    ? TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
                onPressed: c.busy ? null : useDefaultRoot,
                icon: const Icon(Icons.restore),
                label: const Text('默认目录'),
              ),
              TextButton.icon(
                style: compact
                    ? TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      )
                    : null,
                onPressed: c.busy ? null : chooseLocal,
                icon: const Icon(Icons.folder_open),
                label: const Text('选择目录'),
              ),
            ],
          ),
        ),
        Expanded(
          child: logs.isEmpty
              ? Center(
                  child: Text(
                    deviceIdFilter == null
                        ? '尚无本地飞行记录，请从板端复制或选择已有的本地日志目录'
                        : '该设备尚无本地飞行记录',
                  ),
                )
              : ListView(
                  children: [
                    for (final log in logs)
                      ListTile(
                        leading: Icon(
                          log.metadata['complete'] == true
                              ? Icons.flight
                              : Icons.warning_amber,
                        ),
                        title: Text(
                          '${log.name} · ${log.metadata['source_host'] ?? ''}',
                        ),
                        subtitle: Text(
                          '设备：${log.sn ?? log.deviceId ?? '未关联（旧记录）'}\n复制时间：${log.metadata['copied_at'] ?? '未知'}（非飞行发生时间）\n${log.directory.path}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        isThreeLine: true,
                        trailing: Wrap(
                          children: [
                            if (log.replayable)
                              TextButton.icon(
                                onPressed: c.busy ? null : () => replay(log),
                                icon: const Icon(Icons.show_chart),
                                label: const Text('遥测回放'),
                              ),
                            if (log.hasOverlay)
                              TextButton.icon(
                                onPressed: c.busy
                                    ? null
                                    : () => _playVideo(log, raw: false),
                                icon: const Icon(
                                  Icons.play_circle_outline,
                                  size: 18,
                                ),
                                label: const Text('叠加录像'),
                              ),
                            if (log.hasRaw)
                              TextButton.icon(
                                onPressed: c.busy
                                    ? null
                                    : () => _playVideo(log, raw: true),
                                icon: const Icon(
                                  Icons.videocam_outlined,
                                  size: 18,
                                ),
                                label: const Text('原始录像'),
                              ),
                            if ((Platform.isLinux || Platform.isAndroid) &&
                                (log.rawH264 != null ||
                                    log.overlayH264 != null))
                              TextButton.icon(
                                key: const ValueKey('analyze-h264'),
                                onPressed: c.busy
                                    ? null
                                    : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) => LumaAnalysisScreen(
                                            video:
                                                log.rawH264 ?? log.overlayH264!,
                                            snapshot: log.snapshot,
                                          ),
                                        ),
                                      ),
                                icon: const Icon(
                                  Icons.analytics_outlined,
                                  size: 18,
                                ),
                                label: const Text('离线分析'),
                              ),
                            if (log.needsRemux)
                              TextButton(
                                onPressed: c.busy ? null : () => remux(log),
                                child: const Text('封装 MP4'),
                              ),
                            if (Platform.isAndroid)
                              IconButton(
                                tooltip: '压缩并分享单次日志',
                                onPressed: c.busy
                                    ? null
                                    : () async {
                                        await c.shareLocal(log);
                                        if (c.error != null) {
                                          showError(c.error!);
                                        }
                                      },
                                icon: const Icon(Icons.share_outlined),
                              ),
                            IconButton(
                              tooltip: '删除本地副本',
                              onPressed: c.busy
                                  ? null
                                  : () async {
                                      if (await confirm(
                                        '删除本地 ${log.name}？',
                                        '仅删除这份本地副本，板端原文件不受影响。',
                                      )) {
                                        await c.deleteLocal(log);
                                      }
                                    },
                              icon: const Icon(Icons.delete_outline),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

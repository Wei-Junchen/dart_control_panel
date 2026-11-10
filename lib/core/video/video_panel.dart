import 'dart:async';

import 'package:flutter/material.dart';

import 'package:dart_control_panel/core/video/video_controller.dart';
import 'package:dart_control_panel/core/video/video_backend.dart';

/// P5 video panel: the player surface plus video-transport status and
/// controls. Kept presentational so widget tests can drive it with a fake
/// [VideoController].
///
/// - video status (connecting/buffering/playing/paused/error) is shown apart
///   from the control-plane status of the parent screen;
/// - reconnect rebuilds only the player (never the board worker);
/// - when the board reports RTSP unavailable ([rtspAvailable] == false) the
///   preview button is replaced by an explanation.
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    required this.controller,
    required this.rtspAvailable,
    required this.url,
    this.liveStream = false,
    this.onFullscreen,
    this.footer,
    this.showStatusStrip = true,
  });

  final VideoController controller;
  final bool rtspAvailable;
  final String url;
  final bool liveStream;
  final VoidCallback? onFullscreen;
  final Widget? footer;
  final bool showStatusStrip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        return Stack(
          fit: StackFit.expand,
          children: [
            _surface(context, status),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ?footer,
                  if (showStatusStrip) _statusStrip(context, status),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _surface(BuildContext context, VideoStatus status) {
    if (status == VideoStatus.idle) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_off_outlined,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text('Preview stopped'),
            ],
          ),
        ),
      );
    }
    return ColoredBox(color: Colors.black, child: controller.build(context));
  }

  Widget _statusStrip(BuildContext context, VideoStatus status) {
    final theme = Theme.of(context);
    final (color, label) = switch (status) {
      VideoStatus.idle => (theme.colorScheme.outline, 'stopped'),
      VideoStatus.connecting => (Colors.amber, 'connecting'),
      VideoStatus.buffering => (
        Colors.amber,
        liveStream ? 'waiting for live frame' : 'buffering',
      ),
      VideoStatus.playing => (
        Colors.green,
        liveStream ? 'live · no buffer' : 'playing',
      ),
      VideoStatus.paused => (Colors.blueGrey, 'paused'),
      VideoStatus.error => (theme.colorScheme.error, 'stream error'),
    };

    return Material(
      color: Color.lerp(Colors.black, color, 0.35)!.withValues(alpha: 0.72),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: IconTheme(
          data: const IconThemeData(color: Colors.white),
          child: Row(
            children: [
              Icon(
                status == VideoStatus.error
                    ? Icons.error_outline
                    : status.isActive
                    ? Icons.videocam
                    : Icons.videocam_outlined,
                size: 18,
                color: color,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.lastError ?? url,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: Colors.white70,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onFullscreen != null && status.isActive)
                IconButton(
                  tooltip: '全屏播放',
                  visualDensity: VisualDensity.compact,
                  onPressed: onFullscreen,
                  icon: const Icon(Icons.fullscreen, color: Colors.white),
                ),
              _action(context, status),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(BuildContext context, VideoStatus status) {
    final busy =
        status == VideoStatus.connecting || status == VideoStatus.buffering;
    return switch (status) {
      VideoStatus.idle => FilledButton.icon(
        onPressed: rtspAvailable && !busy ? () => controller.open(url) : null,
        icon: const Icon(Icons.play_arrow, size: 18),
        label: const Text('Start preview'),
      ),
      VideoStatus.error => FilledButton.icon(
        onPressed: () => controller.reconnect(),
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Reconnect player'),
      ),
      _ => Wrap(
        spacing: 4,
        children: [
          if (liveStream)
            IconButton(
              tooltip: '丢弃旧帧并回到实时画面',
              onPressed: busy ? null : () => controller.reconnect(),
              icon: const Icon(Icons.skip_next),
            )
          else
            IconButton(
              tooltip: status == VideoStatus.paused ? 'Resume' : 'Pause',
              onPressed: busy
                  ? null
                  : () => status == VideoStatus.paused
                        ? controller.resume()
                        : controller.pause(),
              icon: Icon(
                status == VideoStatus.paused ? Icons.play_arrow : Icons.pause,
              ),
            ),
          IconButton(
            tooltip: 'Stop preview',
            onPressed: () => controller.stop(),
            icon: const Icon(Icons.stop),
          ),
        ],
      ),
    };
  }
}

class VideoPlaybackDialog extends StatelessWidget {
  const VideoPlaybackDialog({
    super.key,
    required this.controller,
    required this.url,
    required this.title,
    this.liveStream = false,
  });

  final VideoController controller;
  final String url;
  final String title;
  final bool liveStream;

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: VideoPanel(
          controller: controller,
          rtspAvailable: true,
          url: url,
          liveStream: liveStream,
          showStatusStrip: liveStream,
          footer: _footer(context),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.72), Colors.transparent],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 4),
        child: Row(
          children: [
            if (!liveStream)
              ListenableBuilder(
                listenable: controller,
                builder: (context, _) {
                  final status = controller.status;
                  if (status == VideoStatus.error ||
                      status == VideoStatus.idle) {
                    return IconButton(
                      tooltip: '重新播放',
                      onPressed: () => status == VideoStatus.error
                          ? controller.reconnect()
                          : controller.open(url),
                      icon: const Icon(Icons.replay, color: Colors.white),
                    );
                  }
                  final paused = status == VideoStatus.paused;
                  final busy =
                      status == VideoStatus.connecting ||
                      status == VideoStatus.buffering;
                  return IconButton(
                    tooltip: paused ? 'Resume' : 'Pause',
                    onPressed: busy
                        ? null
                        : () =>
                              paused ? controller.resume() : controller.pause(),
                    icon: Icon(
                      paused ? Icons.play_arrow : Icons.pause,
                      color: Colors.white,
                    ),
                  );
                },
              ),
            Expanded(
              child: liveStream
                  ? Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      ).textTheme.titleSmall?.copyWith(color: Colors.white),
                    )
                  : ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) =>
                          controller.status == VideoStatus.error
                          ? const Text(
                              '播放失败',
                              style: TextStyle(color: Colors.white),
                            )
                          : _PlaybackSeekBar(controller: controller),
                    ),
            ),
            IconButton(
              tooltip: '关闭播放',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showVideoPlaybackDialog(
  BuildContext context, {
  required VideoController controller,
  required String url,
  required String title,
  bool liveStream = false,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (context) => VideoPlaybackDialog(
      controller: controller,
      url: url,
      title: title,
      liveStream: liveStream,
    ),
  );
}

class _PlaybackSeekBar extends StatefulWidget {
  const _PlaybackSeekBar({required this.controller});

  final VideoController controller;

  @override
  State<_PlaybackSeekBar> createState() => _PlaybackSeekBarState();
}

class _PlaybackSeekBarState extends State<_PlaybackSeekBar> {
  double? _dragMs;

  void _seek(double value) {
    unawaited(widget.controller.seek(Duration(milliseconds: value.round())));
  }

  static String _format(Duration value) {
    final total = value.inSeconds;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.seekable) return const SizedBox.shrink();
        final durationMs = widget.controller.duration!.inMilliseconds
            .toDouble();
        final positionMs =
            widget.controller.position?.inMilliseconds.toDouble() ?? 0;
        final value = (_dragMs ?? positionMs).clamp(0.0, durationMs);
        final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.white70,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Row(
          children: [
            Text(
              _format(Duration(milliseconds: value.round())),
              style: labelStyle,
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  thumbColor: Colors.white,
                  overlayColor: Colors.white24,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                ),
                child: Slider(
                  allowedInteraction: SliderInteraction.slideThumb,
                  value: value,
                  max: durationMs,
                  onChangeStart: (v) {
                    setState(() => _dragMs = v);
                    _seek(v);
                  },
                  onChanged: (v) {
                    setState(() => _dragMs = v);
                    _seek(v);
                  },
                  onChangeEnd: (v) {
                    _seek(v);
                    setState(() => _dragMs = null);
                  },
                ),
              ),
            ),
            Text(_format(widget.controller.duration!), style: labelStyle),
          ],
        );
      },
    );
  }
}

/// Info strip shown instead of the player when RTSP is not enabled on the
/// board (features.rtsp / worker.stream.rtsp_enabled both false).
class RtspUnavailable extends StatelessWidget {
  const RtspUnavailable({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tv_off, size: 56, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              const Text('RTSP is not enabled on this board'),
              const SizedBox(height: 4),
              Text(
                'RTSP 仅在 Ground 模式可用；请到 Mode 页切换。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;
// ignore: implementation_imports - see class docs: mpv options need NativePlayer
import 'package:media_kit/src/player/native/player/real.dart' as mk_native;
import 'package:media_kit_video/media_kit_video.dart' as mk_video;

import 'video_backend.dart';

/// media_kit (libmpv) backend for Linux / Windows / macOS.
///
/// Live RTSP backend. Its live options intentionally mirror the proven ffplay
/// invocation instead of applying mpv's more destructive `low-latency`
/// profile: reliable RTSP/TCP, no demux cache, FFmpeg `nobuffer/low_delay`,
/// and normal late-frame dropping. UDP remains available through
/// `DART_RTSP_TRANSPORT=udp` for special networks.
class MediaKitBackend implements VideoBackend {
  static const defaultRtspTransport = 'tcp';
  static const defaultBufferSize = 1024 * 1024;
  static const defaultOpenOptions = <String, String>{
    'cache': 'no',
    'cache-on-disk': 'no',
    'cache-pause': 'no',
    'demuxer-readahead-secs': '0',
    'demuxer-max-bytes': '$defaultBufferSize',
    'demuxer-max-back-bytes': '0',
    // Exact FFmpeg-side intent of:
    // ffplay -rtsp_transport tcp -fflags nobuffer -flags low_delay -framedrop
    'demuxer-lavf-o': 'fflags=+nobuffer',
    'vd-lavc-o': 'flags=+low_delay',
    'framedrop': 'yes',
    'audio': 'no',
  };

  MediaKitBackend({
    this.liveStream = false,
    String? rtspTransport,
    this.openOptions = defaultOpenOptions,
  }) : rtspTransport = _rtspTransportFromEnv(rtspTransport) {
    mk.MediaKit.ensureInitialized();
    _player = mk.Player(
      configuration: mk.PlayerConfiguration(
        bufferSize: liveStream ? defaultBufferSize : 32 * 1024 * 1024,
        muted: liveStream,
      ),
    );
    _controller = mk_video.VideoController(_player);
    _subscriptions = [
      _player.stream.buffering.listen((buffering) {
        if (buffering) {
          _emit(VideoBackendEventKind.buffering);
        } else if (_player.state.playing) {
          // media_kit emits START_FILE as playing=true followed immediately
          // by buffering=true. The later core-idle=false event is the actual
          // first-frame-ready signal; map it back to playing instead of
          // leaving the Ground UI stuck on "waiting for live frame".
          _emit(VideoBackendEventKind.playing);
        }
      }),
      _player.stream.playing.listen(
        (v) => _emit(
          v ? VideoBackendEventKind.playing : VideoBackendEventKind.paused,
        ),
      ),
      _player.stream.error.listen(
        (msg) => _emit(VideoBackendEventKind.error, message: msg),
      ),
      _player.stream.completed.listen(
        (_) => _emit(VideoBackendEventKind.stopped),
      ),
    ];
  }

  static String _rtspTransportFromEnv(String? override) {
    final env = Platform.environment['DART_RTSP_TRANSPORT']
        ?.trim()
        .toLowerCase();
    if (env is String && (env == 'udp' || env == 'tcp')) return env;
    final candidate = override?.trim().toLowerCase();
    if (candidate is String && (candidate == 'udp' || candidate == 'tcp')) {
      return candidate;
    }
    return defaultRtspTransport;
  }

  final bool liveStream;
  String rtspTransport;
  Map<String, String> openOptions;
  late final mk.Player _player;
  late final mk_video.VideoController _controller;
  late final List<StreamSubscription<Object?>> _subscriptions;
  final _events = StreamController<VideoBackendEvent>.broadcast();
  bool _disposed = false;

  void _emit(VideoBackendEventKind kind, {String? message}) {
    if (_disposed) return;
    _events.add(VideoBackendEvent(kind, message: message));
  }

  bool get _hasNativePlayer => _player.platform is mk_native.NativePlayer;

  Future<void> _setProperty(String key, String value) async {
    if (_hasNativePlayer) {
      await (_player.platform as mk_native.NativePlayer).setProperty(
        key,
        value,
        waitForInitialization: true,
      );
    }
  }

  @override
  Future<void> open(String url) async {
    if (liveStream) {
      await _setProperty('rtsp-transport', rtspTransport);
      for (final entry in openOptions.entries) {
        try {
          await _setProperty(entry.key, entry.value);
        } catch (_) {
          // property may not exist on every libmpv build — non-fatal
        }
      }
    }
    await _player.open(mk.Media(url));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.play();

  @override
  Future<void> close() async {
    await _player.pause();
    await _player.stop();
  }

  @override
  Widget build(BuildContext context) => mk_video.Video(
    controller: _controller,
    controls: mk_video.NoVideoControls,
    filterQuality: FilterQuality.high,
  );

  @override
  Stream<VideoBackendEvent> get events => _events.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    await _player.dispose();
    await _events.close();
  }
}

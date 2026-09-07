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
/// Low-latency settings per AGENTS.md §6.2: RTSP-over-TCP first, `cache=no`
/// so the preview never buffers far ahead of the encoder and never
/// backpressures the board's recording path. [rtspTransport] / [openOptions]
/// stay configurable so they can be tuned on real hardware without touching
/// the UI.
class MediaKitBackend implements VideoBackend {
  MediaKitBackend({
    String? rtspTransport,
    this.openOptions = const <String, String>{
      'cache': 'no',
      'demuxer-readahead-secs': '0.1',
      // mirror the proven ffplay command:
      //   ffplay -rtsp_transport tcp -fflags nobuffer -flags low_delay -framedrop
      'demuxer-lavf-o': 'fflags=nobuffer',
      'vd-lavc-o': 'flags=low_delay',
      'framedrop': 'yes',
    },
  }) : rtspTransport = _rtspTransportFromEnv(rtspTransport) {
    mk.MediaKit.ensureInitialized();
    _player = mk.Player();
    _controller = mk_video.VideoController(_player);
    _subscriptions = [
      _player.stream.buffering.listen((v) => _emit(v
          ? VideoBackendEventKind.buffering
          : VideoBackendEventKind.paused)),
      _player.stream.playing.listen((v) => _emit(v
          ? VideoBackendEventKind.playing
          : VideoBackendEventKind.paused)),
      _player.stream.error.listen(
          (msg) => _emit(VideoBackendEventKind.error, message: msg)),
      _player.stream.completed
          .listen((_) => _emit(VideoBackendEventKind.stopped)),
    ];
  }

static String _rtspTransportFromEnv(String? override) {
    final env = Platform.environment['DART_RTSP_TRANSPORT']?.trim().toLowerCase();
    if (env is String && (env == 'udp' || env == 'tcp')) return env;
    final candidate = override?.trim().toLowerCase();
    if (candidate is String && (candidate == 'udp' || candidate == 'tcp')) {
      return candidate;
    }
    return 'tcp';
  }

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
      await (_player.platform as mk_native.NativePlayer)
          .setProperty(key, value, waitForInitialization: true);
    }
  }

  @override
  Future<void> open(String url) async {
    await _setProperty('rtsp-transport', rtspTransport);
    for (final entry in openOptions.entries) {
      try {
        await _setProperty(entry.key, entry.value);
      } catch (_) {
        // property may not exist on every libmpv build — non-fatal
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
  Widget build(BuildContext context) =>
      mk_video.Video(controller: _controller, controls: mk_video.NoVideoControls);

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
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:dart_control_panel/video/video_backend.dart';

/// Scriptable [VideoBackend] for tests — no decoder involved. Emit events
/// with [emit] / [emitError]; hooks record calls.
class FakeVideoBackend implements VideoBackend {
  final _events = StreamController<VideoBackendEvent>.broadcast();
  int openCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int closeCalls = 0;
  int disposeCalls = 0;
  String? lastUrl;
  Object? openError;
  Widget? surface;

  @override
  Stream<VideoBackendEvent> get events => _events.stream;

  @override
  Future<void> open(String url) async {
    openCalls++;
    lastUrl = url;
    if (openError != null) throw openError!;
  }

  @override
  Future<void> pause() async => pauseCalls++;

  @override
  Future<void> resume() async => resumeCalls++;

  @override
  Future<void> close() async => closeCalls++;

  @override
  Widget build(BuildContext context) =>
      surface ?? const ColoredBox(color: Color(0xFF112233));

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _events.close();
  }

  void emit(VideoBackendEventKind kind, {String? message}) =>
      _events.add(VideoBackendEvent(kind, message: message));

  void emitPlaying() => emit(VideoBackendEventKind.playing);
  void emitBuffering() => emit(VideoBackendEventKind.buffering);
  void emitPaused() => emit(VideoBackendEventKind.paused);
  void emitStopped() => emit(VideoBackendEventKind.stopped);
  void emitError(String message) =>
      emit(VideoBackendEventKind.error, message: message);
}

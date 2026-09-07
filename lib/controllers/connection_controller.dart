import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/protocol/protocol_exception.dart';

enum BoardConnectionStatus { disconnected, connecting, connected, reconnecting }

/// Tracks control-plane reachability for the one-request-per-connection
/// client.
///
/// Because every request opens its own socket, "reconnect" reduces to
/// "start probing again", and the *poll interval* carries the exponential
/// backoff: with every consecutive transport failure the interval doubles
/// (500 ms -> 1 s -> 2 s -> ... capped at [maxInterval]) so a dead link is not
/// hammered; the first success resets everything to [baseInterval].
///
/// Pure Dart + ChangeNotifier; no sockets are held here.
class ConnectionController extends ChangeNotifier {
  ConnectionController({
    this.baseInterval = const Duration(milliseconds: 500),
    this.minInterval = const Duration(milliseconds: 500),
    this.maxInterval = const Duration(seconds: 16),
    this.inactiveOverride = const Duration(seconds: 2),
    this.backoffFactor = 2,
    BoardConnectionStatus initialStatus = BoardConnectionStatus.disconnected,
  }) : status = initialStatus;

  final Duration baseInterval;
  final Duration minInterval;
  final Duration maxInterval;

  /// Applied when the app window is not active (poll slows to 1-2 s).
  final Duration inactiveOverride;
  final int backoffFactor;

  BoardConnectionStatus status;
  int consecutiveFailures = 0;
  int successfulResponses = 0;
  String? lastError;

  bool get isConnected => status == BoardConnectionStatus.connected;
  bool get isTransitional =>
      status == BoardConnectionStatus.connecting ||
      status == BoardConnectionStatus.reconnecting;

  /// Called right before a poll request is sent.
  void onPollStart() {
    if (status == BoardConnectionStatus.disconnected) {
      status = BoardConnectionStatus.connecting;
      notifyListeners();
    }
  }

  /// Called when a poll returns valid state (or the probe succeeds).
  void onPollSuccess() {
    final changed = status != BoardConnectionStatus.connected ||
        consecutiveFailures != 0;
    status = BoardConnectionStatus.connected;
    consecutiveFailures = 0;
    successfulResponses++;
    if (lastError != null) lastError = null;
    if (changed) notifyListeners();
  }

  /// Called when a poll fails for any reason. Only transport-level failures
  /// count towards the backoff.
  void onPollFailure(ProtocolException error) {
    final transport = error is ProtocolTransportClosed ||
        error is ProtocolTimeout ||
        error is ProtocolCodecException;
    if (transport) {
      consecutiveFailures++;
    }
    lastError = error.message;
    if (status != BoardConnectionStatus.disconnected &&
        status != BoardConnectionStatus.reconnecting) {
      status = BoardConnectionStatus.reconnecting;
    }
    notifyListeners();
  }

  /// Mark the transport as unreachable without a poll round (e.g. manual
  /// probe). Resets the backoff so the next poll starts from [baseInterval].
  void forceDisconnect() {
    status = BoardConnectionStatus.disconnected;
    consecutiveFailures = 0;
    lastError = null;
    notifyListeners();
  }

  void forceConnect() {
    status = BoardConnectionStatus.connecting;
    notifyListeners();
  }

  /// The interval to use for the next poll, applying exponential backoff for
  /// consecutive [consecutiveFailures]. When [windowActive] is false, the
  /// poll must not go faster than [inactiveOverride].
  Duration nextPollInterval({bool windowActive = true}) {
    final base = consecutiveFailures == 0
        ? baseInterval
        : baseInterval * pow(backoffFactor, consecutiveFailures).toInt();
    var interval = base;
    if (interval < minInterval) interval = minInterval;
    if (interval > maxInterval) interval = maxInterval;
    if (!windowActive && interval < inactiveOverride) {
      interval = inactiveOverride;
    }
    return interval;
  }
}

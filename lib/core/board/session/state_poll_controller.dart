import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/api/protocol_exception.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';

import 'package:dart_control_panel/core/board/session/connection_controller.dart';

/// Periodic `get_state` poller.
///
/// Guarantees:
/// - at most one poll in flight at any time (a slow response is never
///   followed by a queued duplicate — no concurrent poll pileup);
/// - the interval comes from [ConnectionController.nextPollInterval]
///   (500 ms when healthy, exponential backoff while transport fails,
///   1-2 s when the window is inactive);
/// - failures never stop the loop; state simply stays stale and the next
///   tick retries.
class StatePollController extends ChangeNotifier {
  StatePollController({
    required this._repository,
    required this._connection,
    this.initialDelay = Duration.zero,
    this.onPolled,
  });

  final BoardRepository _repository;
  final ConnectionController _connection;
  final Duration initialDelay;

  /// Called with each successfully polled state (e.g. to feed a shared
  /// BoardSession so every page sees live values).
  final void Function(DaemonState state)? onPolled;

  DaemonState? _state;
  Timer? _timer;
  bool _inflight = false;
  bool _windowActive = true;
  int _pollCount = 0;
  int _skippedCount = 0;
  String? _lastError;
  bool _started = false;

  DaemonState? get state => _state;

  /// Latest error (kept between ticks until a success clears it).
  String? get lastError => _lastError;

  int get pollCount => _pollCount;
  int get skippedCount => _skippedCount;
  bool get inflight => _inflight;

  /// True between start() and stop(); state may be stale while false.
  bool get isStarted => _started;

  ConnectionController get connection => _connection;

  void start() {
    _started = true;
    _timer?.cancel();
    _timer = Timer(initialDelay, () => _scheduleTick(Duration.zero));
  }

  /// Called from the app lifecycle observer: inactive/hidden windows poll
  /// at 1-2 s instead of 500 ms.
  void setWindowActive(bool active) {
    _windowActive = active;
    if (!_started) return;
    _timer?.cancel();
    _scheduleTick(Duration.zero);
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  void _scheduleTick(Duration delay) {
    _timer?.cancel();
    if (!_started) return;
    final interval = _connection.nextPollInterval(windowActive: _windowActive);
    _timer = Timer(delay > Duration.zero ? delay : interval, _tick);
  }

  Future<void> _tick() async {
    if (!_started) return;
    if (_inflight) {
      _skippedCount++;
      _scheduleTick(const Duration(milliseconds: 100));
      return;
    }
    _inflight = true;
    _connection.onPollStart();
    try {
      final state = await _repository.getState();
      _state = state;
      _lastError = null;
      _pollCount++;
      onPolled?.call(state);
      _connection.onPollSuccess();
    } on OperationFailedException catch (e) {
      // Daemon answered but rejected the op: report, keep detailed error,
      // still a "reachable" board.
      _lastError = 'operation failed: ${e.message}';
      _pollCount++;
      _connection.onPollFailure(e);
    } on ProtocolException catch (e) {
      _lastError = e.message;
      _pollCount++;
      _connection.onPollFailure(e);
    } catch (e, st) {
      _lastError = '$e';
      _pollCount++;
      _connection.onPollFailure(
        ProtocolException('unexpected poll error: $e', cause: st),
      );
    } finally {
      _inflight = false;
      notifyListeners();
      _scheduleTick(Duration.zero);
    }
  }
}

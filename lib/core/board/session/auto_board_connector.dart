import 'dart:async';
import 'package:flutter/foundation.dart';
import 'board_discovery.dart';

/// Discovery stops on success or explicit disconnect. Generation invalidation
/// prevents an in-flight probe from connecting after switching to manual mode.
class AutoBoardConnector extends ChangeNotifier {
  AutoBoardConnector({
    required this.onFound,
    Future<BoardCandidate?> Function()? discover,
    this.interval = const Duration(seconds: 3),
  }) : _discover = discover ?? BoardDiscovery().findBoard;

  final Future<bool> Function(BoardCandidate) onFound;
  final Future<BoardCandidate?> Function() _discover;
  final Duration interval;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool running = false;
  String message = '连接板端 AP 后自动查找本机网段的 .1';

  void start() {
    if (_disposed || running) return;
    running = true;
    final generation = ++_generation;
    unawaited(_tick(generation));
  }

  void stop() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    running = false;
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && running && generation == _generation;

  Future<void> _tick(int generation) async {
    message = '正在查找板端 .1:9000…';
    notifyListeners();
    try {
      final board = await _discover();
      if (!_current(generation)) return;
      if (board != null) {
        message = '${board.localAddress} → ${board.host}:9000';
        notifyListeners();
        final connected = await onFound(board);
        if (!_current(generation)) return;
        if (connected) {
          stop();
          return;
        }
      }
      message = '未连接：请连接板端 AP，将每 3 秒重试';
    } catch (e) {
      if (!_current(generation)) return;
      message = '网络暂不可用，将重试：$e';
    }
    if (!_current(generation)) return;
    notifyListeners();
    _timer = Timer(interval, () => _tick(generation));
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

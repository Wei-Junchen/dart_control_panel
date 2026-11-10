import 'package:flutter/foundation.dart';

/// Serializes mutations: only one operation runs at a time; everything else
/// queues on a single chain. Per AGENTS.md the UI mutation queue must stay
/// serialized even when the poll loop uses its own sockets.
///
/// A failed operation does not break the chain. [isBusy] reflects pending +
/// running work and is what screens use to disable conflicting buttons.
class MutationQueue extends ChangeNotifier {
  Future<void> _chain = Future<void>.value();
  int _pending = 0;
  int _generation = 0;

  bool get isBusy => _pending > 0;
  int get pending => _pending;

  Future<T> enqueue<T>(Future<T> Function() op) {
    final generation = _generation;
    _pending++;
    notifyListeners();
    final result = _chain.then((_) {
      if (generation != _generation) {
        throw StateError('Mutation cancelled by queue reset');
      }
      return op();
    });
    _chain = result.then<void>(
      (_) => _settled(),
      onError: (Object _, StackTrace _) => _settled(),
    );
    return result;
  }

  void _settled() {
    _pending--;
    notifyListeners();
  }

  /// Invalidates queued work (e.g. after disconnect). In-flight work continues,
  /// and new work waits for it so mutations remain strictly serialized.
  /// Invalidated futures complete with a [StateError] when they reach the head.
  void reset() {
    _generation++;
  }
}

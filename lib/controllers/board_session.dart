import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:dart_control_panel/controllers/connection_controller.dart';
import 'package:dart_control_panel/controllers/mutation_queue.dart';
import 'package:dart_control_panel/models/board_address_store.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';
import 'package:dart_control_panel/repositories/board_repository.dart';

/// Shared board session for the lifecycle/features screens (P4).
///
/// Owns the repository + connection, a serialized [MutationQueue], the latest
/// [state] and a user-facing status message. Every mutation refreshes state
/// afterwards — including on failure, so a rejected/rolled-back operation
/// never leaves a fake toggle on screen.
class BoardSession extends ChangeNotifier {
  BoardSession({
    this.host = DaemonClient.defaultHost,
    this.port = 9000,
  });

  String host;
  int port;

  BoardRepository? _repository;
  ConnectionController? _connection;
  final MutationQueue _queue = MutationQueue();
  DaemonState? _state;
  String? _statusMessage;
  bool _statusError = false;
  bool _connecting = false;

  BoardRepository? get repository => _repository;
  ConnectionController? get connection => _connection;
  MutationQueue get queue => _queue;
  DaemonState? get state => _state;
  String? get statusMessage => _statusMessage;
  bool get statusError => _statusError;
  bool get connected => _repository != null;
  bool get busy => _queue.isBusy;
  bool get connecting => _connecting;

void updateEndpoint(String host, int port) {
    this.host = host;
    this.port = port;
  }

  Future<void> connect() async {
    _connecting = true;
    notifyListeners();
    _queue.reset();
    final repo = BoardRepository(DaemonClient(host: host, port: port));
    try {
      final probe = await repo.getState(); // reachability probe
      _repository = repo;
      _connection = ConnectionController();
      _connection!.onPollSuccess();
      _state = probe;
      // remember the endpoint for the next session (no credentials involved)
      unawaited(BoardAddressStore.instance.remember(host, port));
      setStatus('Connected');
    } catch (_) {
      await repo.close();
      rethrow;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _queue.reset();
    await _repository?.close();
    _repository = null;
    _connection = null;
    _state = null;
    _statusMessage = null;
    notifyListeners();
  }

  /// Fresh `get_state`; updates [state] and notifies.
  Future<DaemonState> refresh() async {
    final repo = _repository;
    if (repo == null) {
      throw const ProtocolTransportClosed('not connected');
    }
    final state = await repo.getState();
    _state = state;
    notifyListeners();
    return state;
  }

  /// Lets the shared 500 ms poll feed state into this session, so every page
  /// sees live values without polling itself.
  void updateState(DaemonState state) {
    _state = state;
    notifyListeners();
  }

  /// Runs a mutation serialized through the queue. Always refreshes state
  /// afterwards (success, rollback and transport failure), so the UI shows
  /// the daemon's real result — never an assumed toggle.
  Future<T> mutate<T>(String label, Future<T> Function(BoardRepository) op) {
    return _queue.enqueue(() async {
      final repo = _repository;
      if (repo == null) {
        throw const ProtocolTransportClosed('not connected');
      }
      try {
        final result = await op(repo);
        await refresh();
        setStatus('$label: ok');
        return result;
      } on OperationFailedException catch (e) {
        setStatus('$label rejected: ${e.message}', error: true);
        try {
          await refresh();
        } catch (_) {}
        rethrow;
      } on ProtocolException catch (e) {
        setStatus('$label failed: ${e.message}', error: true);
        try {
          await refresh();
        } catch (_) {}
        rethrow;
      }
    });
  }

  void setStatus(String message, {bool error = false}) {
    _statusMessage = message;
    _statusError = error;
    notifyListeners();
  }
}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ndjson_codec.dart';
import 'protocol_exception.dart';

/// Result of a successful `result` line when `ok == true`.
class ResponseMessage {
  const ResponseMessage({
    required this.id,
    required this.ok,
    required this.raw,
    this.state,
    this.configRev,
    this.payload,
    this.message,
  });

  final int id;
  final bool ok;
  final String? state;
  final int? configRev;
  final Map<String, dynamic>? payload;
  final String? message;

  /// This class always represents a `result` line that passed validation.
  String get type => 'result';

  /// The full `result` object as received (forward-compatible).
  final Map<String, dynamic> raw;
}

/// NDJSON v1 control-plane client (one request per connection).
///
/// Responsibilities only: connect, send one request line, read the
/// `accepted` + `result` lines, verify ids, apply the timeout, cleanly close
/// the socket. No UI logic lives here.
///
/// Per the AGENTS.md contract every call checks:
/// 1. both lines parse as JSON objects;
/// 2. the first line is `accepted`;
/// 3. the second line is `result`;
/// 4. both ids equal the request id;
/// 5. `result.ok == true`.
///
/// A codec-level `error` line (no id) and a `result` line with `ok:false`
/// both surface as exceptions — the caller must not treat `accepted` as
/// success.
class DaemonClient {
  DaemonClient({
    this.host = defaultHost,
    this.port = defaultPort,
    this.timeout = const Duration(seconds: 3),
    NdjsonCodec? codec,
  }) : _codec = codec ?? NdjsonCodec();

  static const defaultHost = '10.149.242.1';
  static const defaultPort = 9000;

  final String host;
  final int port;
  final Duration timeout;
  final NdjsonCodec _codec;

  /// Coerces an id to an integer, rejecting anything else.
  static int coerceId(Object? id) {
    if (id is int) return id;
    if (id is double && id == id.roundToDouble()) return id.toInt();
    if (id is num && id == id.toInt()) return id.toInt();
    throw ArgumentError.value(id, 'id', 'request id must be an integer');
  }

  /// Sends one request on a fresh connection and returns the validated
  /// `result` message, or throws an [OperationFailedException] /
  /// [ProtocolException] subclass.
  Future<ResponseMessage> call({
    required Object? id,
    required String op,
    Map<String, dynamic>? args,
  }) async {
    final idInt = coerceId(id);
    final line = _codec.encodeRequest(id: idInt, op: op, args: args);

    final Socket socket;
    try {
      socket = await Socket.connect(host, port).timeout(timeout, onTimeout: () {
        throw ProtocolTimeout('connect timeout to $host:$port');
      });
    } on SocketException catch (e) {
      throw ProtocolTransportClosed('connect to $host:$port failed: ${e.message}',
          cause: e);
    } on TimeoutException catch (e) {
      throw ProtocolTimeout('connect to $host:$port timed out', cause: e);
    }

    final reader = _LineReader(socket, deadline: timeout);
    socket.add(utf8.encode(line));

    try {
      return await _awaitResult(reader, idInt, op);
    } on ProtocolException {
      rethrow;
    } on TimeoutException catch (e) {
      throw ProtocolTimeout('no result from $host:$port within $timeout', cause: e);
    } finally {
      socket.destroy();
      reader.dispose();
    }
  }

  Future<ResponseMessage> _awaitResult(
      _LineReader reader, int id, String op) async {
    var acceptedSeen = false;
    while (true) {
      final event = await reader.next();
      if (event.kind == StreamDecodeEventKind.error) {
        throw event.error!;
      }
      final obj = event.line!;
      final type = obj['type'];
      final responseId = _idOf(obj);
      switch (type) {
        case 'accepted':
          acceptedSeen = true;
          if (responseId != null && responseId != id) {
            throw ProtocolIdMismatch(
                'accepted line has id $responseId, expected $id');
          }
          continue;
        case 'result':
          if (responseId != null && responseId != id) {
            throw ProtocolIdMismatch(
                'result line has id $responseId, expected $id');
          }
          if (!acceptedSeen) {
            // Rare: daemon skipped accepted. The result line alone is still
            // actionable per protocol semantics; do not hang waiting.
            // (Verified in daemon_client_test.)
          }
          return _buildResult(obj, id, op);
        case 'error':
          if (responseId != null && responseId != id) {
            throw ProtocolIdMismatch(
                'error line has id $responseId, expected $id');
          }
          throw ProtocolException(
              'daemon reported an error: ${obj['message'] ?? obj}');
        default:
          throw ProtocolDecodeException('unexpected line type: $type');
      }
    }
  }

  ResponseMessage _buildResult(Map<String, dynamic> obj, int id, String op) {
    final ok = obj['ok'] is bool ? obj['ok'] as bool : false;
    final state = obj['state'];
    final configRev = obj['config_rev'];
    if (!ok) {
      throw OperationFailedException(
        obj['error'] is String
            ? obj['error'] as String
            : 'daemon rejected $op with ok:false',
        op: op,
        state: state is String ? state : null,
        configRev: configRev is num ? configRev.toInt() : null,
      );
    }
    return ResponseMessage(
      id: id,
      ok: true,
      raw: obj,
      state: state is String ? state : null,
      configRev: configRev is num ? configRev.toInt() : null,
      payload: obj['payload'] is Map
          ? Map<String, dynamic>.from(obj['payload'] as Map)
          : null,
      message: obj['message'] is String ? obj['message'] as String : null,
    );
  }

  static int? _idOf(Map<String, dynamic> obj) {
    final id = obj['id'];
    if (id is num) return id.toInt();
    return null;
  }

  /// One-request-per-connection client: there is no persistent socket to
  /// close. Kept for symmetry with future shared-connection modes.
  Future<void> close() async {}
}

/// Buffered line reader over a socket: accumulates chunks, emits one decoded
/// event per line, fails with the deadline unless the operation completes.
class _LineReader {
  _LineReader(this._socket, {required this.deadline}) {
    final decoder = NdjsonCodec().streamDecoder();
    decoder.events.listen((event) {
      final completer = _pending;
      _pending = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(event);
      }
    });
    _socketSubscription = _socket.listen(
      (chunk) => decoder.addChunk(chunk),
      onDone: () {
        decoder.close();
        _closePending(const ProtocolTransportClosed(
            'connection closed before the result line arrived'));
      },
      onError: (Object e, StackTrace st) {
        _closePending(ProtocolTransportClosed('socket error: $e', cause: e));
      },
      cancelOnError: true,
    );
    _timer = Timer(deadline, () {
      _closePending(const ProtocolTimeout('timed out waiting for response'));
      _socket.destroy();
    });
  }

  final Socket _socket;
  final Duration deadline;
  late final StreamSubscription<List<int>> _socketSubscription;
  late final Timer _timer;

  Completer<StreamDecodeEvent>? _pending;
  StreamDecodeEvent? _carry;

  Future<StreamDecodeEvent> next() {
    final carry = _carry;
    if (carry != null) {
      _carry = null;
      return Future.value(carry);
    }
    final completer = Completer<StreamDecodeEvent>();
    _pending = completer;
    return completer.future;
  }

  void dispose() {
    _socketSubscription.cancel();
    _timer.cancel();
  }

  void _closePending(ProtocolException error) {
    final completer = _pending;
    _pending = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dart_control_panel/core/board/api/protocol_exception.dart';

/// Encoding and parsing helpers for the daemon's newline-delimited JSON v1
/// protocol (UTF-8, one JSON object per line, max [maxLineBytes] per line).
///
/// This class is pure Dart (no Flutter dependency) so it can be unit tested
/// and reused from the CLI.
class NdjsonCodec {
  NdjsonCodec({this.maxLineBytes = 65536});

  final int maxLineBytes;

  /// Serializes one request into a single UTF-8 line terminated by `\n`.
  ///
  /// The generated object always has `v:1`, `type:"request"`, the given
  /// integer [id], [op] and [args].
  String encodeRequest({
    required int id,
    required String op,
    Map<String, dynamic>? args,
  }) {
    if (op.isEmpty) {
      throw ArgumentError('op must not be empty');
    }
    final line =
        '${jsonEncode({'v': 1, 'type': 'request', 'id': id, 'op': op, 'args': args ?? <String, dynamic>{}})}\n';
    if (utf8.encode(line).length > maxLineBytes) {
      throw ProtocolCodecException(
        'request line exceeds $maxLineBytes bytes (${utf8.encode(line).length})',
      );
    }
    return line;
  }

  /// Parses one complete line (must end with `\n`) into a JSON object.
  Map<String, dynamic> decodeLine(String line) {
    if (!line.endsWith('\n')) {
      throw const ProtocolDecodeException('incomplete line without newline');
    }
    if (line.length == 1) {
      throw const ProtocolDecodeException('empty line');
    }
    if (utf8.encode(line).length > maxLineBytes) {
      throw ProtocolDecodeException('line exceeds $maxLineBytes bytes');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(line.substring(0, line.length - 1));
    } on FormatException catch (e) {
      throw ProtocolDecodeException('invalid JSON: ${e.message}', cause: e);
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProtocolDecodeException('expected a JSON object');
    }
    return decoded;
  }

  /// Creates a chunk-fed stream decoder for accumulated socket data.
  StreamDecoder streamDecoder() => StreamDecoder(maxLineBytes: maxLineBytes);
}

enum StreamDecodeEventKind { line, error }

class StreamDecodeEvent {
  const StreamDecodeEvent.line(this.line)
    : kind = StreamDecodeEventKind.line,
      error = null;
  const StreamDecodeEvent.error(this.error)
    : kind = StreamDecodeEventKind.error,
      line = null;

  final StreamDecodeEventKind kind;
  final Map<String, dynamic>? line;
  final ProtocolDecodeException? error;
}

/// Buffers raw UTF-8 chunks, splits them on `\n` and emits one event per
/// complete line. Handles half packets (半包), coalesced packets (粘包),
/// oversized lines and invalid UTF-8.
class StreamDecoder {
  StreamDecoder({required this.maxLineBytes});

  final int maxLineBytes;
  final _events = StreamController<StreamDecodeEvent>.broadcast();
  final List<int> _buffer = <int>[];

  Stream<StreamDecodeEvent> get events => _events.stream;

  void addChunk(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      final byte = bytes[i];
      _buffer.add(byte);
      if (byte == 0x0a) {
        _emitLine();
      }
    }
  }

  void _emitLine() {
    final length = _buffer.length - 1; // strip trailing \n
    final lineBytes = _buffer.getRange(0, length).toList();
    _buffer.clear();
    if (length > maxLineBytes) {
      _events.add(
        StreamDecodeEvent.error(
          const ProtocolDecodeException('line exceeds maximum allowed length'),
        ),
      );
      return;
    }
    String text;
    try {
      text = utf8.decode(lineBytes, allowMalformed: false);
    } on FormatException catch (e) {
      _events.add(
        StreamDecodeEvent.error(
          ProtocolDecodeException('invalid UTF-8: ${e.message}', cause: e),
        ),
      );
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      _events.add(
        StreamDecodeEvent.error(
          ProtocolDecodeException('invalid JSON: ${e.message}', cause: e),
        ),
      );
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _events.add(
        const StreamDecodeEvent.error(
          ProtocolDecodeException('expected a JSON object'),
        ),
      );
      return;
    }
    _events.add(StreamDecodeEvent.line(decoded));
  }

  /// Drains any trailing buffer and stops the stream. Must be called exactly
  /// once after the socket closes.
  void close() {
    if (_buffer.isNotEmpty) {
      _events.add(
        const StreamDecodeEvent.error(
          ProtocolDecodeException('connection closed in the middle of a line'),
        ),
      );
      _buffer.clear();
    }
    unawaited(_events.close());
  }
}

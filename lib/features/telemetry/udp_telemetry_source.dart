import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_control_panel/features/telemetry/telemetry_sample.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_wire.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_source.dart';

/// Receives indexed DVT1 UDP with TCP metadata (legacy FireWater fallback).
///
/// Wire form: `key:value,key:value,...\n`, one datagram per sample. Unknown
/// keys are retained, so adding board metrics does not break this client.
class UdpTelemetrySource implements TelemetrySource {
  UdpTelemetrySource({this.port = 1347});

  final int port;
  TelemetrySchema? schema;
  void Function()? onSchemaChanged;
  int schemaMisses = 0;
  Future<Map<String, dynamic>> Function()? _schemaLoader;
  String? _peer;
  int _schemaGeneration = 0;
  bool _schemaLoading = false;
  DateTime? _lastSchemaAttempt;
  int? _binarySchema;
  int? _streamId;
  final List<int> _retiredStreams = [];

  /// Owned by HomeShell, not an individual page. No UDP stop on navigation.
  void configureSchemaLoader(
    Future<Map<String, dynamic>> Function()? loader, {
    String? peer,
  }) {
    _schemaGeneration++;
    _schemaLoader = loader;
    _peer = peer;
    schema = null;
    onSchemaChanged?.call();
    _schemaLoading = false;
    _lastSchemaAttempt = null;
    lastSequence = null;
    _binarySchema = null;
    _streamId = null;
    _retiredStreams.clear();
    if (loader != null) unawaited(refreshSchema());
  }

  Future<void> refreshSchema() async {
    final loader = _schemaLoader;
    final now = DateTime.now();
    if (loader == null ||
        _schemaLoading ||
        (_lastSchemaAttempt != null &&
            now.difference(_lastSchemaAttempt!) < const Duration(seconds: 1))) {
      return;
    }
    final generation = _schemaGeneration;
    _schemaLoading = true;
    _lastSchemaAttempt = now;
    try {
      final received = TelemetrySchema.fromJson(await loader());
      if (generation == _schemaGeneration) {
        schema = received;
        onSchemaChanged?.call();
      }
    } catch (error) {
      if (generation == _schemaGeneration) lastError = error;
    } finally {
      if (generation == _schemaGeneration) _schemaLoading = false;
    }
  }

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;
  bool _starting = false;
  int _generation = 0;
  void Function(TelemetrySample)? _onSample;

  int packets = 0;
  int parseErrors = 0;
  int droppedPackets = 0;
  int? lastSequence;
  DateTime? lastPacketAt;
  Object? lastError;

  @override
  String get label => 'UDP 0.0.0.0:$port';

  @override
  void start(void Function(TelemetrySample sample) onSample) {
    _onSample = onSample;
    if (_socket != null || _starting) return;
    // An intentional pause is not network packet loss. Start a new sequence baseline.
    lastSequence = null;
    _starting = true;
    final generation = ++_generation;
    _bind()
        .then((socket) {
          if (generation != _generation || _onSample == null) {
            socket.close();
            return;
          }
          _starting = false;
          _socket = socket;
          _subscription = socket.listen((event) {
            if (event != RawSocketEvent.read) return;
            Datagram? datagram;
            while ((datagram = socket.receive()) != null) {
              _consume(datagram!);
            }
          }, onError: (Object error) => lastError = error);
        })
        .catchError((Object error) {
          _starting = false;
          lastError = error;
        });
  }

  Future<RawDatagramSocket> _bind() async {
    try {
      return await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: true,
      );
    } catch (_) {
      // `reusePort` is unavailable on some Flutter desktop targets.
      return RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
    }
  }

  void _consume(Datagram datagram) {
    try {
      if (_peer != null && datagram.address.address != _peer) return;
      final binary = TelemetryWire.isBinary(datagram.data);
      final values = binary
          ? TelemetryWire.decode(datagram.data, schema)
          : parseFireWater(
              utf8.decode(datagram.data, allowMalformed: false).trim(),
            );
      if (binary) {
        final stream = values['stream_id']!.toInt();
        if (_retiredStreams.contains(stream)) return;
        if (_streamId != null && _streamId != stream) {
          _retiredStreams.add(_streamId!);
          if (_retiredStreams.length > 4) _retiredStreams.removeAt(0);
        }
        // A worker restart gets a new ephemeral stream id, not a board identity.
        if (_binarySchema != schema!.id || _streamId != stream) {
          lastSequence = null;
        }
        _binarySchema = schema!.id;
        _streamId = values['stream_id']?.toInt();
        final sequence = values['seq']!.toInt();
        if (lastSequence != null) {
          final delta = (sequence - lastSequence!) & 0xffffffff;
          if (delta == 0 || delta >= 0x80000000) return;
          droppedPackets += delta - 1;
        }
        lastSequence = sequence;
      }
      if (values.isEmpty) throw const FormatException('empty telemetry packet');

      packets++;
      lastPacketAt = DateTime.now();
      lastError = null;

      final sequence = values['seq']?.toInt();
      if (!binary &&
          sequence != null &&
          lastSequence != null &&
          sequence > lastSequence! + 1) {
        droppedPackets += sequence - lastSequence! - 1;
      }
      if (sequence != null) lastSequence = sequence;

      // UI aliases. Preserve every original field for plots/diagnostics.
      values['pitch'] = values['uart_valid'] == 1
          ? values['uart_pitch'] ?? double.nan
          : double.nan;
      values['roll'] = values['uart_valid'] == 1
          ? values['uart_roll'] ?? double.nan
          : double.nan;
      values['yaw'] = values['uart_valid'] == 1
          ? values['uart_yaw'] ?? double.nan
          : double.nan;
      values['fps'] = values['fps'] ?? values['capture_fps'] ?? double.nan;
      _onSample?.call(
        TelemetrySample(
          time: lastPacketAt!,
          values: Map.unmodifiable(values),
          sourceAddress: datagram.address.address,
          schema: binary ? _archiveSchema() : null,
          receiverStats: {
            'packets': packets,
            'dropped_packets': droppedPackets,
            'parse_errors': parseErrors,
            'schema_misses': schemaMisses,
          },
        ),
      );
    } on MissingTelemetrySchema catch (error) {
      schemaMisses++;
      lastError = error;
      unawaited(refreshSchema()); // Drop, never queue stale packets.
    } catch (error) {
      parseErrors++;
      lastError = error;
    }
  }

  TelemetrySchema? _archiveSchemaSource;
  Map<String, dynamic>? _archiveSchemaSnapshot;

  Map<String, dynamic>? _archiveSchema() {
    final value = schema;
    if (value == null) return null;
    if (value != _archiveSchemaSource) {
      _archiveSchemaSource = value;
      _archiveSchemaSnapshot = {
        'format': 'DVT1',
        'byte_order': 'little',
        'checksum': 'crc32_ieee',
        'schema_id': value.id,
        'uart_ready': value.uartReady,
        'fields': [
          for (final f in value.fields)
            {
              'index': f.index,
              'name': f.name,
              'type': f.type,
              'source_name': f.sourceName,
            },
        ],
      };
    }
    return _archiveSchemaSnapshot;
  }

  static Map<String, double> parseFireWater(String line) {
    final result = <String, double>{};
    for (final raw in line.split(',')) {
      final token = raw.trim();
      final separator = token.indexOf(':');
      if (separator <= 0 || separator == token.length - 1) continue;
      final key = token.substring(0, separator).trim();
      final value = double.tryParse(token.substring(separator + 1).trim());
      if (key.isNotEmpty && value != null) result[key] = value;
    }
    return result;
  }

  @override
  Future<void> stop() async {
    _generation++;
    _onSample = null;
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _starting = false;
  }
}

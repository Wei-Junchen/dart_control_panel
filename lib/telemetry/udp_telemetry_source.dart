import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'telemetry_sample.dart';
import 'telemetry_source.dart';

/// Receives the board's VOFA+ FireWater UDP stream.
///
/// Wire form: `key:value,key:value,...\n`, one datagram per sample. Unknown
/// keys are retained, so adding board metrics does not break this client.
class UdpTelemetrySource implements TelemetrySource {
  UdpTelemetrySource({this.port = 1347});

  final int port;
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
      final decoded = utf8.decode(datagram.data, allowMalformed: false).trim();
      final values = parseFireWater(decoded);
      if (values.isEmpty) throw const FormatException('empty telemetry packet');

      packets++;
      lastPacketAt = DateTime.now();

      final sequence = values['seq']?.toInt();
      if (sequence != null &&
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
      values['fps'] = values['capture_fps'] ?? double.nan;
      _onSample?.call(TelemetrySample(time: lastPacketAt!, values: values));
    } catch (error) {
      parseErrors++;
      lastError = error;
    }
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

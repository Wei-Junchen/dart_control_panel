import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_wire.dart';
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';

void main() {
  test(
    'unified C++ fps survives UDP aliases; legacy capture_fps still works',
    () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final source = UdpTelemetrySource(port: port);
      final sender = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() async {
        sender.close();
        await source.stop();
      });
      final samples = <Map<String, double>>[];
      source.start((sample) => samples.add(sample.values));
      for (final name in ['dvt1-fps.json', 'dvt1.json']) {
        final fixture = jsonDecode(
          await File('test/features/telemetry/fixtures/$name').readAsString(),
        );
        source.configureSchemaLoader(
          () async => Map<String, dynamic>.from(fixture['schema']),
        );
        final hex = fixture['hex'] as String;
        final bytes = Uint8List.fromList([
          for (var i = 0; i < hex.length; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
        final decoded = TelemetryWire.decode(
          bytes,
          TelemetrySchema.fromJson(
            Map<String, dynamic>.from(fixture['schema']),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 70));
        final before = samples.length;
        sender.send(bytes, InternetAddress.loopbackIPv4, port);
        for (var i = 0; i < 50 && samples.length == before; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(samples.length, before + 1);
        expect(samples.last['fps'], decoded['fps'] ?? decoded['capture_fps']);
        if (name == 'dvt1-fps.json') {
          expect(samples.last['fps'], 80);
          expect(samples.last.containsKey('capture_fps'), false);
          expect(samples.last.containsKey('detect_fps'), false);
        }
      }
    },
  );
}

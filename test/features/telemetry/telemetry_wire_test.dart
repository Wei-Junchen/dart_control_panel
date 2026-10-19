import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';
import 'package:dart_control_panel/core/board/api/daemon_client.dart';
import 'package:dart_control_panel/features/telemetry/telemetry_wire.dart';
import 'package:dart_control_panel/features/telemetry/udp_telemetry_source.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/features/telemetry/fixtures/dvt1.json',
            ).readAsStringSync(),
          )
          as Map;
  final schemaJson = Map<String, dynamic>.from(fixture['schema'] as Map);
  final schema = TelemetrySchema.fromJson(schemaJson);
  final hex = fixture['hex'] as String;
  final bytes = Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
  void checksum(Uint8List p) => ByteData.sublistView(p).setUint32(
    p.length - 4,
    TelemetryWire.crc32(p, p.length - 4),
    Endian.little,
  );
  test('matches C++ packet, all eight types and unsigned boundaries', () {
    expect(
      TelemetryWire.crc32(Uint8List.fromList(utf8.encode('123456789'))),
      0xcbf43926,
    );
    final v = TelemetryWire.decode(bytes, schema);
    expect(v['seq'], 4294967295);
    expect(v['stream_id'], 123);
    expect(v['frame'], 42);
    expect(v['mono_ms'], 1234);
    expect(v['uart_rx_u8'], 255);
    expect(v['uart_rx_i8'], -128);
    expect(v['uart_rx_u16'], 65535);
    expect(v['uart_rx_i16'], -32768);
    expect(v['uart_rx_u32'], 4294967295);
    expect(v['uart_rx_i32'], -2147483648);
    expect(schema.fields[26].sourceName, 'u8');
    expect(v['uart_rx_f32'], 1.25);
    expect(v['uart_rx_f64'], -12.5);
  });
  test('CRC is validated before requesting absent/changed schema', () {
    expect(
      () => TelemetryWire.decode(bytes, null),
      throwsA(isA<MissingTelemetrySchema>()),
    );
    final p = Uint8List.fromList(bytes)..[25] ^= 1;
    expect(() => TelemetryWire.decode(p, null), throwsFormatException);
    p.setAll(0, bytes);
    p[4] ^= 1;
    checksum(p);
    expect(
      () => TelemetryWire.decode(p, schema),
      throwsA(isA<MissingTelemetrySchema>()),
    );
  });
  test(
    'rejects truncation, duplicates, unknown indices, extra bytes and bad registry',
    () {
      expect(
        () => TelemetryWire.decode(
          Uint8List.sublistView(bytes, 0, bytes.length - 1),
          schema,
        ),
        throwsFormatException,
      );
      for (final index in [0, 255]) {
        final p = Uint8List.fromList(bytes);
        p[27] = index;
        checksum(p);
        expect(() => TelemetryWire.decode(p, schema), throwsFormatException);
      }
      final p = Uint8List.fromList([
        ...bytes.sublist(0, bytes.length - 4),
        0,
        0,
        0,
        0,
        0,
      ]);
      checksum(p);
      expect(() => TelemetryWire.decode(p, schema), throwsFormatException);
      expect(
        () => TelemetrySchema.fromJson({...schemaJson, 'schema_id': 0}),
        throwsFormatException,
      );
      expect(
        () => TelemetrySchema.fromJson({
          ...schemaJson,
          'fields': List.filled(91, schemaJson['fields'][0]),
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'real UDP fetches TCP schema once, drops unknown packets, then preserves aliases',
    () async {
      final probe = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final port = probe.port;
      probe.close();
      final source = UdpTelemetrySource(port: port);
      final samples = <Map<String, double>>[];
      var calls = 0;
      final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = tcp.listen((socket) {
        var buffer = '';
        socket.listen((data) async {
          buffer += utf8.decode(data);
          if (!buffer.contains('\n')) return;
          final request = jsonDecode(buffer.split('\n').first) as Map;
          calls++;
          expect(request['op'], 'get_telemetry_schema');
          socket.write(
            '${jsonEncode({'v': 1, 'type': 'accepted', 'id': request['id'], 'mono_us': 1})}\n',
          );
          socket.write(
            '${jsonEncode({'v': 1, 'type': 'result', 'id': request['id'], 'ok': true, 'state': 'STREAMING', 'config_rev': 1, 'payload': schemaJson})}\n',
          );
          await socket.flush();
          await socket.close();
        });
      });
      final repo = BoardRepository(
        DaemonClient(host: '127.0.0.1', port: tcp.port),
      );
      addTearDown(() async {
        await subscription.cancel();
        await tcp.close();
        await repo.close();
      });
      source.configureSchemaLoader(repo.getTelemetrySchema);
      source.start((s) => samples.add(s.values));
      final tx = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        tx.close();
        await source.stop();
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      tx.send(bytes, InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(samples.single['pitch'], 1.25);
      expect(calls, 1);
      // Same sequence is ignored; wrap-around is accepted, gaps counted.
      tx.send(bytes, InternetAddress.loopbackIPv4, port);
      final next = Uint8List.fromList(bytes);
      ByteData.sublistView(next).setUint32(8, 1, Endian.little);
      checksum(next);
      tx.send(next, InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(samples.length, 2);
      expect(source.droppedPackets, 1);
      // A worker restart has a new stream id; its sequence starts again at zero.
      ByteData.sublistView(next).setUint32(8, 0, Endian.little);
      ByteData.sublistView(next).setUint32(12, 124, Endian.little);
      checksum(next);
      tx.send(next, InternetAddress.loopbackIPv4, port);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(samples.length, 3);
      next[4] ^= 1;
      checksum(next);
      for (var i = 0; i < 10; i++) {
        tx.send(next, InternetAddress.loopbackIPv4, port);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(source.schemaMisses, 10);
      expect(calls, 1);
      expect(samples.length, 3);
    },
  );
}

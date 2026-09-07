import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/protocol/daemon_client.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';

/// Minimal NDJSON daemon simulator on a local ServerSocket.
///
/// [handler] maps the request line to the raw response lines the fake daemon
/// should write (one JSON object per line). Returning null leaves the request
/// unanswered (simulates a hung daemon / network loss on the control socket).
class MockDaemon {
  MockDaemon._(this._server);

  final ServerSocket _server;
  final List<Socket> _connections = [];
  Future<void> Function(String requestLine)? onRequest;

  static Future<MockDaemon> start(
    Future<List<String>?> Function(String requestLine) handler,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final daemon = MockDaemon._(server);
    server.listen((socket) {
      daemon._connections.add(socket);
      socket.listen(
        (data) async {
          final text = utf8.decode(data, allowMalformed: true);
          for (final line in LineSplitter.split(text)) {
            if (line.trim().isEmpty) continue;
            final replyLines = await handler(line);
            if (replyLines == null) continue;
            for (final reply in replyLines) {
              socket.write(reply);
              socket.write('\n');
            }
          }
        },
        onError: (_) {},
      );
    });
    return daemon;
  }

  int get port => _server.port;
  int get connectionCount => _connections.length;

  Future<void> stop() async {
    for (final c in _connections) {
      try {
        await c.close();
      } catch (_) {}
    }
    await _server.close();
  }

  /// Sends raw bytes to the most recent connection (for chunked delivery).
  void writeRawToLatest(List<int> bytes) {
    _connections.last.add(bytes);
  }
}

void main() {
  group('DaemonClient', () {
    test('sends a valid UTF-8 NDJSON request line', () async {
      String? seen;
      final daemon = await MockDaemon.start((requestLine) async {
        seen = requestLine;
        return [
          '{"v":1,"type":"accepted","id":7,"mono_us":1000}',
          '{"v":1,"type":"result","id":7,"ok":true,"state":"STOPPED","config_rev":1,"payload":{}}',
        ];
      });
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      await client.call(id: 7, op: 'get_profiles');
      await client.close();
      await daemon.stop();

      final json = jsonDecode(seen!) as Map<String, dynamic>;
      expect(json, {
        'v': 1,
        'type': 'request',
        'id': 7,
        'op': 'get_profiles',
        'args': <String, dynamic>{},
      });
    });

    test('succeeds when accepted + result are valid and ids match', () async {
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"accepted","id":42,"mono_us":123456789}',
            '{"v":1,"type":"result","id":42,"ok":true,"state":"STREAMING","config_rev":184,"payload":{"answer":42}}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      final msg = await client.call(id: 42, op: 'get_state');
      await client.close();
      await daemon.stop();

      expect(msg.type, 'result');
      expect(msg.id, 42);
      expect(msg.ok, isTrue);
      expect(msg.state, 'STREAMING');
      expect(msg.configRev, 184);
      expect(msg.payload!['answer'], 42);
      expect(daemon.connectionCount, 1);
    });

    test('survives fragmented and coalesced TCP writes', () async {
      Socket? conn;
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        conn = socket;
        final lines = [
          '{"v":1,"type":"accepted","id":42,"mono_us":1}',
          '{"v":1,"type":"result","id":42,"ok":true,"state":"STREAMING","config_rev":9,"payload":{"p":1}}',
        ];
        final full = utf8.encode('${lines.join('\n')}\n');
        // Fragmented writes: byte-at-a-time, then one big burst per remaining.
        Timer(Duration.zero, () => conn!.add(full.sublist(0, 2)));
        Timer(const Duration(milliseconds: 10), () {
          for (var i = 2; i < full.length; i++) {
            conn!.add([full[i]]);
          }
        });
      });

      final client = DaemonClient(host: '127.0.0.1', port: server.port);
      final msg = await client.call(id: 42, op: 'get_state');
      await client.close();
      await server.close();
      expect(msg.ok, isTrue);
      expect(msg.payload!['p'], 1);
    });

    test('throws OperationFailed when result.ok == false', () async {
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"accepted","id":42,"mono_us":1}',
            '{"v":1,"type":"result","id":42,"ok":false,"state":"STREAMING","config_rev":184,"error":"gain verification failed: requested=1024/1024/1024 actual=..."}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      try {
        await client.call(id: 42, op: 'apply_runtime');
        fail('expected OperationFailedException');
      } on OperationFailedException catch (e) {
        expect(e.message, contains('gain verification failed'));
        expect(e.state, 'STREAMING');
        expect(e.configRev, 184);
      } finally {
        await client.close();
        await daemon.stop();
      }
    });

    test('throws on id mismatch between accepted/result and request', () async {
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"accepted","id":42,"mono_us":1}',
            '{"v":1,"type":"result","id":999,"ok":true,"state":"STREAMING","config_rev":1,"payload":{}}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      await expectLater(
        client.call(id: 42, op: 'get_state'),
        throwsA(isA<ProtocolIdMismatch>()),
      );
      await client.close();
      await daemon.stop();
    });

    test('throws ProtocolException on a bare error line without id', () async {
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"error","message":"invalid request"}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      await expectLater(
        client.call(id: 42, op: 'get_state'),
        throwsA(isA<ProtocolException>()),
      );
      await client.close();
      await daemon.stop();
    });

    test('accepts result directly when accepted line is missing', () async {
      // Some failure modes only deliver one line; per spec two lines are
      // returned, but the client must not hang forever waiting for both.
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"result","id":42,"ok":true,"state":"STREAMING","config_rev":1,"payload":{"a":1}}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      final msg = await client.call(id: 42, op: 'get_state');
      expect(msg.ok, isTrue);
      await client.close();
      await daemon.stop();
    });

    test('throws Timeout when the server never answers', () async {
      final daemon = await MockDaemon.start((requestLine) async => null);
      final client = DaemonClient(
        host: '127.0.0.1',
        port: daemon.port,
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        client.call(id: 42, op: 'get_state'),
        throwsA(isA<ProtocolTimeout>()),
      );
      await client.close();
      await daemon.stop();
    });

    test('throws TransportClosed when EOF arrives before result', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        socket.write('{"v":1,"type":"accepted","id":42,"mono_us":1}\n');
        Future<void>.delayed(const Duration(milliseconds: 20), () async {
          try {
            await socket.flush();
            await socket.close();
          } catch (_) {}
        });
      });
      final client = DaemonClient(
        host: '127.0.0.1',
        port: server.port,
        timeout: const Duration(seconds: 5),
      );
      await expectLater(
        client.call(id: 42, op: 'get_state'),
        throwsA(isA<ProtocolTransportClosed>()),
      );
      await client.close();
      await server.close();
    });

    test('throws TransportClosed when the connection is refused', () async {
      // Bind and immediately close to get a refused/unreachable port.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final client = DaemonClient(
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(seconds: 2),
      );
      await expectLater(
        client.call(id: 1, op: 'get_state'),
        throwsA(isA<ProtocolTransportClosed>()),
      );
      await client.close();
    });

    test('rejects a request id that is not an integer', () async {
      final client = DaemonClient(host: '127.0.0.1', port: 1);
      expect(
        () => client.call(id: 42.5, op: 'get_state'),
        throwsArgumentError,
      );
      await client.close();
    });

    test('one-request-per-connection: second call opens a new socket',
        () async {
      final daemon = await MockDaemon.start((requestLine) async => [
            '{"v":1,"type":"accepted","id":9,"mono_us":1}',
            '{"v":1,"type":"result","id":9,"ok":true,"state":"STOPPED","config_rev":1,"payload":{}}',
          ]);
      final client = DaemonClient(host: '127.0.0.1', port: daemon.port);
      await client.call(id: 9, op: 'heartbeat');
      await client.call(id: 9, op: 'heartbeat');
      await client.close();
      await daemon.stop();
      expect(daemon.connectionCount, 2);
    });
  });
}

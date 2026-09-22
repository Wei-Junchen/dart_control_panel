import 'dart:convert';
import 'dart:io';

/// Serves two-line NDJSON fixture exchanges as raw bytes, split into awkward
/// chunks. Recorded requests expose op, args and id for assertions.
class FixtureDaemon {
  FixtureDaemon(this._server);

  final ServerSocket _server;
  final List<Socket> _connections = [];
  final List<(String, Map<String, dynamic>, int)> requests = [];

  static Future<FixtureDaemon> start(
    Future<String> Function(String op) body,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final daemon = FixtureDaemon(server);
    server.listen((socket) {
      daemon._connections.add(socket);
      socket.listen((data) async {
        final requestLine = utf8.decode(data).trim();
        final request = jsonDecode(requestLine) as Map<String, dynamic>;
        final op = request['op'] as String;
        final requestId = (request['id'] as num).toInt();
        daemon.requests.add((
          op,
          Map<String, dynamic>.from(request['args'] as Map? ?? const {}),
          requestId,
        ));
        final bodyText = await body(op);
        if (bodyText.isEmpty) return;
        // The client allocates its own ids; fixtures use a placeholder id.
        final reply = bodyText.replaceAll('"id":42', '"id":$requestId');
        final bytes = utf8.encode(reply);
        // Chop into uneven fragments to exercise the stream decoder.
        var offset = 0;
        var step = 1;
        while (offset < bytes.length) {
          final end = offset + step;
          socket.add(bytes.sublist(offset, end.clamp(0, bytes.length)));
          offset = end > bytes.length ? bytes.length : end;
          step = (step + 2) % 17 + 1;
        }
      });
    });
    return daemon;
  }

  int get port => _server.port;
  int get connectionCount => _connections.length;

  /// All ops seen, in order.
  List<String> get ops => [for (final r in requests) r.$1];

  Future<void> stop() async {
    for (final c in _connections) {
      try {
        await c.close();
      } catch (_) {}
    }
    await _server.close();
  }
}

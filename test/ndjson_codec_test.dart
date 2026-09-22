import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/protocol/ndjson_codec.dart';
import 'package:dart_control_panel/protocol/protocol_exception.dart';

void main() {
  group('NdjsonCodec.encodeRequest', () {
    test('produces exactly one UTF-8 JSON line', () {
      final codec = NdjsonCodec();
      final line = codec.encodeRequest(id: 42, op: 'get_state', args: {});
      expect(line.endsWith('\n'), isTrue);
      final json = jsonDecode(line) as Map<String, dynamic>;
      expect(json, {
        'v': 1,
        'type': 'request',
        'id': 42,
        'op': 'get_state',
        'args': <String, dynamic>{},
      });
      expect(utf8.encode(line), hasLength(line.length));
    });

    test('encodes args verbatim', () {
      final line = NdjsonCodec().encodeRequest(
        id: 43,
        op: 'apply_runtime',
        args: {'again': 2048, 'overlay': true},
      );
      final json = jsonDecode(line) as Map<String, dynamic>;
      expect((json['args'] as Map)['again'], 2048);
      expect((json['args'] as Map)['overlay'], true);
    });

    test('rejects lines longer than 8192 bytes', () {
      final codec = NdjsonCodec(maxLineBytes: 8192);
      final big = List.filled(9000, 'x').join();
      expect(
        () => codec.encodeRequest(id: 1, op: 'op', args: {'big': big}),
        throwsA(isA<ProtocolCodecException>()),
      );
    });
  });

  group('NdjsonCodec.decodeLine', () {
    test('parses a complete UTF-8 JSON line', () {
      final line = '{"v":1,"type":"accepted","id":42,"mono_us":123}\n';
      final obj = NdjsonCodec().decodeLine(line);
      expect(obj['type'], 'accepted');
      expect(obj['id'], 42);
    });

    test('rejects trailing data without newline', () {
      expect(
        () => NdjsonCodec().decodeLine('{"a":1}'),
        throwsA(isA<ProtocolDecodeException>()),
      );
    });

    test('rejects invalid JSON', () {
      expect(
        () => NdjsonCodec().decodeLine('{not json}\n'),
        throwsA(isA<ProtocolDecodeException>()),
      );
    });

    test('rejects non-object JSON', () {
      expect(
        () => NdjsonCodec().decodeLine('[1,2,3]\n'),
        throwsA(isA<ProtocolDecodeException>()),
      );
    });

    test('rejects empty lines', () {
      expect(
        () => NdjsonCodec().decodeLine('\n'),
        throwsA(isA<ProtocolDecodeException>()),
      );
    });
  });

  group('StreamDecoder', () {
    test('handles one complete line', () async {
      final dec = NdjsonCodec().streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      dec.addChunk(utf8.encode('{"v":1,"type":"accepted","id":1}\n'));
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.line!['type'], 'accepted');
    });

    test('handles split packets (半包)', () async {
      final dec = NdjsonCodec().streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      final bytes = utf8.encode(
        '{"v":1,"type":"accepted","id":42,"mono_us":1}\n',
      );
      for (final b in bytes) {
        dec.addChunk([b]);
      }
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.line!['id'], 42);
    });

    test('handles multiple lines in one packet (粘包)', () async {
      final dec = NdjsonCodec().streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      dec.addChunk(
        utf8.encode(
          '{"v":1,"type":"accepted","id":42}\n{"v":1,"type":"result","id":42,"ok":true}\n',
        ),
      );
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events[1].line!['ok'], isTrue);
    });

    test('survives garbage and reports error events', () async {
      final dec = NdjsonCodec().streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      dec.addChunk(
        utf8.encode('{bad json}\n{"v":1,"type":"result","id":2,"ok":true}\n'),
      );
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events[0].kind, StreamDecodeEventKind.error);
      expect(events[1].line!['id'], 2);
    });

    test('rejects a line exceeding maxLineBytes', () async {
      final dec = NdjsonCodec(maxLineBytes: 64).streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      dec.addChunk(utf8.encode('{"pad":"${'x' * 100}"}\n'));
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events.single.kind, StreamDecodeEventKind.error);
    });

    test('reports invalid UTF-8 as error without crashing', () async {
      final dec = NdjsonCodec().streamDecoder();
      final events = <StreamDecodeEvent>[];
      dec.events.listen(events.add);
      dec.addChunk([0xff, 0xfe, 0x00, 0x0a]);
      dec.close();
      await Future<void>.delayed(Duration.zero);
      expect(events.single.kind, StreamDecodeEventKind.error);
    });
  });
}

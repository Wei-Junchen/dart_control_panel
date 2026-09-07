import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/models/board_address_store.dart';
import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/diagnostics_summary.dart';

DaemonState _fixtureState() {
  final raw = File('test/fixtures/payloads/state_envelope_full.json')
      .readAsStringSync();
  return DaemonState.fromEnvelope(jsonDecode(raw) as Map<String, dynamic>);
}

void main() {
  group('BoardAddressStore', () {
    late File file;
    late BoardAddressStore store;

    setUp(() {
      final dir = Directory.systemTemp.createTempSync('dart_ctrl_test_');
      file = File('${dir.path}/addresses.json');
      store = BoardAddressStore(file: file);
    });

    tearDown(() {
      if (file.existsSync()) file.deleteSync();
      file.parent.deleteSync(recursive: true);
    });

    test('empty store yields no last used', () {
      expect(store.load(), isEmpty);
      expect(store.lastUsed, isNull);
    });

    test('remember upserts and moves the address to the front', () async {
      await store.remember('10.149.242.1', 9000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.remember('192.168.1.50', 9001);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.remember('10.149.242.1', 9000); // upsert

      final loaded = store.load();
      expect(loaded, hasLength(2));
      expect(store.lastUsed!.host, '10.149.242.1');
      expect(store.lastUsed!.port, 9000);
      // persisted as JSON, no credentials concept anywhere
      final decoded = jsonDecode(file.readAsStringSync()) as List;
      expect(decoded, hasLength(2));
      expect(decoded.first['host'], '10.149.242.1');
    });

    test('caps the list at max entries', () async {
      for (var i = 0; i < 12; i++) {
        await store.remember('10.0.0.$i', 9000);
      }
      expect(store.load().length, BoardAddressStore.maxEntries);
      expect(store.lastUsed!.host, '10.0.0.11');
    });

    test('remove deletes a single entry', () async {
      await store.remember('a', 9000);
      await store.remember('b', 9000);
      await store.remove('a', 9000);
      final loaded = store.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.host, 'b');
    });

    test('tolerates a corrupt storage file', () async {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('{not json');
      expect(store.load(), isEmpty);
      expect(store.lastUsed, isNull);
      await store.remember('ok', 9000); // still writable afterwards
      expect(store.load(), hasLength(1));
    });
  });

  group('buildDiagnosticsSummary', () {
    test('covers all major sections from the full fixture', () {
      final summary = buildDiagnosticsSummary(
        _fixtureState(),
        board: '10.149.242.1:9000',
        appVersion: '0.1.0',
      );
      expect(summary, contains('=== Dart Guidance control panel diagnostics ==='));
      expect(summary, contains('board=10.149.242.1:9000'));
      expect(summary, contains('app_version=0.1.0'));
      expect(summary, contains('STREAMING'));
      expect(summary, contains('full_wide_640x360'));
      expect(summary, contains('config_rev=184'));
      expect(summary, contains('fps=79.8'));
      expect(summary, contains('found=true'));
      expect(summary, contains('requested exposure_us=1000'));
      expect(summary, contains('actual 999'));
      expect(summary, contains('rtsp=true:8554'));
      expect(summary, contains('temperature_c=51.2'));
      expect(summary, contains('crc_errors=0'));
    });

    test('works with a minimal/empty state (no worker)', () {
      final summary = buildDiagnosticsSummary(DaemonState.fromEnvelope({
        'v': 1,
        'payload': {'state': 'STOPPED'},
      }));
      expect(summary, contains('daemon: STOPPED'));
      // no worker section, no crash
      expect(summary, isNot(contains('worker: frames=')));
    });
  });
}
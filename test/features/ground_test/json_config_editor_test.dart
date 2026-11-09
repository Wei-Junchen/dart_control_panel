import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/features/ground_test/json_config_editor.dart';
import 'package:dart_control_panel/shared/widgets/mobile_ui_scale.dart';
import 'package:dart_control_panel/features/ground_test/config_document_draft.dart';

void main() {
  group('parseBoardConfigJson', () {
    test('accepts only a JSON object at the top level', () {
      expect(parseBoardConfigJson('{"schema_version":1}').valid, isTrue);
      expect(parseBoardConfigJson('[1,2,3]').valid, isFalse);
      expect(parseBoardConfigJson('').error, 'JSON is empty');
    });

    test('syntax errors include a source location', () {
      final result = parseBoardConfigJson('{\n  "x":,\n}');
      expect(result.valid, isFalse);
      expect(result.error, contains('2:'));
    });

    test('validates configurable UART receive field layout', () {
      const valid = '''
{"uart":{"rx_layout":{
  "packet_size":8,"header":170,"checksum":"none","checksum_offset":0,
  "byte_order":"big","fields":[
    {"name":"battery_mv","type":"uint16","offset":1},
    {"name":"temperature","type":"int16","offset":3}
  ]
}}}''';
      expect(parseBoardConfigJson(valid).valid, isTrue);

      final overlap = valid.replaceFirst('"offset":3', '"offset":2');
      final result = parseBoardConfigJson(overlap);
      expect(result.valid, isFalse);
      expect(result.error, contains('overlaps'));
    });
  });

  testWidgets('edits, validates, confirms and uploads complete JSON', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    Map<String, dynamic>? uploaded;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JsonConfigEditor(
            initialConfig: const {
              'schema_version': 1,
              'launcher': {'operating_mode': 'ground'},
            },
            onReload: () async => const {'schema_version': 1},
            onUpload: (config) async {
              uploaded = config;
              return config;
            },
          ),
        ),
      ),
    );

    final source = find.byKey(const ValueKey('json-config-source'));
    expect(find.text('default.json'), findsOneWidget);
    expect(find.text('BOARD COPY'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('upload-json-config')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      source,
      '{"schema_version":2,"view":{"rotation":90}}',
    );
    await tester.pump();
    expect(find.text('LOCAL CHANGES'), findsOneWidget);
    expect(find.text('Valid JSON object'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('upload-json-config')));
    await tester.pumpAndSettle();
    expect(find.text('Upload complete configuration?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-json-upload')));
    await tester.pumpAndSettle();

    expect(uploaded?['schema_version'], 2);
    expect((uploaded?['view'] as Map)['rotation'], 90);
    expect(
      find.text('Daemon accepted and reloaded the configuration'),
      findsOneWidget,
    );
    expect(find.text('BOARD COPY'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('handset columns edit and upload one continuous document', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 363);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final draft = ConfigDocumentDraft()
      ..load({'first': 1, 'second': 2, 'third': 3});
    addTearDown(draft.dispose);
    Map<String, dynamic>? uploaded;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        builder: (context, child) => MobileUiScale(child: child!),
        home: Scaffold(
          body: JsonConfigEditor(
            sharedDraft: draft,
            initialConfig: null,
            onReload: () async => {},
            onUpload: (config) async {
              uploaded = config;
              return config;
            },
          ),
        ),
      ),
    );
    final left = find.byKey(const ValueKey('json-config-source'));
    final right = find.byKey(const ValueKey('json-config-source-right'));
    expect(right, findsOneWidget);
    final originalLeft = tester.widget<TextField>(left).controller!.text;
    final originalRight = tester.widget<TextField>(right).controller!.text;
    expect(originalLeft + originalRight, draft.text);
    await tester.enterText(left, originalLeft.replaceFirst('1', '10'));
    await tester.enterText(right, originalRight.replaceFirst('3', '30'));
    await tester.pump();
    expect(draft.document, {'first': 10, 'second': 2, 'third': 30});
    expect(
      tester.widget<TextField>(left).controller!.text,
      originalLeft.replaceFirst('1', '10'),
    );
    await tester.tap(find.byKey(const ValueKey('upload-json-config')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-json-upload')));
    await tester.pumpAndSettle();
    expect(uploaded, {'first': 10, 'second': 2, 'third': 30});
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid JSON explains error and disables upload', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JsonConfigEditor(
            initialConfig: const {'schema_version': 1},
            onReload: () async => const {'schema_version': 1},
            onUpload: (config) async => config,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('json-config-source')),
      '{"broken":}',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('upload-json-config')),
          )
          .onPressed,
      isNull,
    );
    final status = tester.widget<Text>(
      find.byKey(const ValueKey('json-config-status')),
    );
    expect(status.data, contains('1:'));
  });
}

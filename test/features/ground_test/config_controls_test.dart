import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/ground_test/config_controls.dart';
import 'package:dart_control_panel/features/ground_test/json_config_editor.dart';
import 'config_document_draft_test.dart' as fixtures;

void main() {
  testWidgets(
    'unknown new board fields are rendered with no client field list',
    (tester) async {
      final d = fixtures.draft();
      d.schema!['properties']['future'] = {
        'type': 'object',
        'title': '新模块',
        'properties': {
          'limit': {
            'type': 'integer',
            'default': 3,
            'minimum': 1,
            'maximum': 5,
          },
        },
        'additionalProperties': false,
      };
      d.edit('future.limit', 3);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigControls(draft: d, onApply: () {}, onReload: () {}),
          ),
        ),
      );
      final finder = find.byKey(const ValueKey('config-future.limit'));
      await tester.ensureVisible(finder);
      expect(finder, findsOneWidget);
      await tester.enterText(finder, '6');
      await tester.pump();
      expect(d.validate(), contains('future.limit'));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apply-config-controls')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(finder, '4');
      await tester.pump();
      expect(d.at('future.limit'), 4);
      expect(d.validate(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Controls and JSON use the same draft, including partial edits', (
    tester,
  ) async {
    final d = fixtures.draft();
    var controls = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                TextButton(
                  onPressed: () {
                    FocusScope.of(context).unfocus();
                    setState(() => controls = !controls);
                  },
                  child: const Text('switch'),
                ),
                Expanded(
                  child: IndexedStack(
                    index: controls ? 1 : 0,
                    children: [
                      JsonConfigEditor(
                        sharedDraft: d,
                        initialConfig: null,
                        onReload: () async => d.document!,
                        onUpload: (v) async => v,
                      ),
                      ConfigControls(draft: d, onApply: () {}, onReload: () {}),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final cx = find.byKey(const ValueKey('config-control.cx'));
    await tester.ensureVisible(cx);
    await tester.enterText(cx, '123.5');
    await tester.pump();
    await tester.tap(find.text('switch'));
    await tester.pump();
    final json = find.byKey(const ValueKey('json-config-source'));
    expect(
      jsonDecode(
        tester.widget<TextField>(json).controller!.text,
      )['control']['cx'],
      123.5,
    );
    await tester.enterText(json, '{ broken');
    await tester.pump();
    await tester.tap(find.text('switch'));
    await tester.pump();
    expect(find.textContaining('JSON 尚未合法'), findsOneWidget);
    expect(d.text, '{ broken');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'flight lock and missing schema never expose stale static controls',
    (tester) async {
      final d = fixtures.draft();
      d.edit('control.cx', 100);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConfigControls(
              draft: d,
              locked: true,
              onApply: () {},
              onReload: () {},
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('apply-config-controls')),
            )
            .onPressed,
        isNull,
      );
      d.setSchema(null);
      await tester.pump();
      expect(find.textContaining('板端未提供受支持的 config_schema'), findsOneWidget);
      expect(find.text('roll sign'), findsNothing);
      expect(find.text('NV21 green score（唯一识别器）'), findsNothing);
    },
  );
}

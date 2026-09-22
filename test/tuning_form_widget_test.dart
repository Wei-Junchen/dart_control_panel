import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/runtime_draft.dart';
import 'package:dart_control_panel/widgets/tuning_form.dart';

DaemonState _fixtureState() {
  final raw = File(
    'test/fixtures/payloads/state_envelope_full.json',
  ).readAsStringSync();
  return DaemonState.fromEnvelope(jsonDecode(raw) as Map<String, dynamic>);
}

void main() {
  late RuntimeDraft draft;
  late TuningFormState formState;
  var applyCalls = 0;
  var revertCalls = 0;
  var reloadCalls = 0;

  Future<void> pump(WidgetTester tester) async {
    draft = RuntimeDraft.fromState(_fixtureState());
    applyCalls = 0;
    revertCalls = 0;
    reloadCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TuningForm(
            key: GlobalKey<TuningFormState>(),
            draft: draft,
            onApply: () => applyCalls++,
            onRevert: () => revertCalls++,
            onReload: () => reloadCalls++,
          ),
        ),
      ),
    );
  }

  Finder field(String key) => find.byKey(ValueKey('field.$key'));

  testWidgets('renders baseline values from the board', (tester) async {
    await pump(tester);
    expect(find.text('Detector'), findsOneWidget);
    expect(find.text('ISP'), findsOneWidget);
    expect(find.text('Control'), findsOneWidget);
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('0 changed'), findsNothing);

    final exposure = tester.widget<TextField>(field('exposure_us'));
    expect(exposure.controller!.text, '1000');
    final again = tester.widget<TextField>(field('again'));
    expect(again.controller!.text, '1024');
    final syncTimeout = tester.widget<TextField>(
      field('overlay_sync_timeout_ms'),
    );
    expect(syncTimeout.controller!.text, '6');
    expect(find.textContaining('NV21 green'), findsOneWidget);
  });

  testWidgets('typing marks the field dirty and counts changes', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field('exposure_us'), '1500');
    await tester.pump();
    expect(draft.isDirty(RuntimeDraft.exposureUs), isTrue);
    expect(draft.valueOf(RuntimeDraft.exposureUs), 1500);
    expect(find.text('1 changed'), findsOneWidget);
  });

  testWidgets('invalid integer text does not touch the draft', (tester) async {
    await pump(tester);
    await tester.enterText(field('search_radius'), '');
    await tester.pump();
    expect(draft.hasChanges, isFalse);
    expect(find.text('must be an integer'), findsOneWidget);
  });

  testWidgets('out-of-range values block Apply', (tester) async {
    await pump(tester);
    await tester.enterText(field('search_radius'), '0');
    await tester.pump();
    expect(draft.validate()[RuntimeDraft.searchRadius], isNotNull);
    final apply = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Apply'),
    );
    expect(apply.onPressed, isNull);
  });

  testWidgets('Apply fires with only changed fields', (tester) async {
    await pump(tester);
    await tester.enterText(field('exposure_us'), '1500');
    await tester.pump();
    expect(draft.toArgs(), {RuntimeDraft.exposureUs: 1500});
    final apply = find.widgetWithText(FilledButton, 'Apply');
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    expect(applyCalls, 1);
  });

  testWidgets('Revert and Reload buttons fire', (tester) async {
    await pump(tester);
    await tester.enterText(field('again'), '2048');
    await tester.pump();
    final revert = find.widgetWithText(OutlinedButton, 'Revert local edits');
    await tester.ensureVisible(revert);
    await tester.tap(revert);
    expect(revertCalls, 1);
    final reload = find.widgetWithText(TextButton, 'Reload from board');
    await tester.ensureVisible(reload);
    await tester.tap(reload);
    expect(reloadCalls, 1);
  });

  testWidgets('ROI mode chips switch between region and full frame', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'full'));
    await tester.pump();
    expect(draft.roiMode, 'full');
    expect(draft.valueOf(RuntimeDraft.detectRoi), 'full');
    // ROI rectangle fields are removed in full-frame mode.
    expect(find.byKey(const ValueKey('field.roi[0]')), findsNothing);
    // switching back to region restores them with the previous rect
    await tester.tap(find.widgetWithText(ChoiceChip, 'region'));
    await tester.pump();
    expect(draft.roiMode, 'region');
    expect(find.byKey(const ValueKey('field.roi[0]')), findsOneWidget);
  });

  testWidgets('syncFromDraft restores board values after external load', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(field('exposure_us'), '7777');
    await tester.pump();
    expect(draft.isDirty(RuntimeDraft.exposureUs), isTrue);

    // Simulate a fresh load from the board (reload / apply-success).
    draft.loadFrom(_fixtureState());
    formState = tester.state(find.byType(TuningForm));
    formState.syncFromDraft();
    await tester.pump();

    expect(draft.hasChanges, isFalse);
    final exposure = tester.widget<TextField>(field('exposure_us'));
    expect(exposure.controller!.text, '1000');
  });
}

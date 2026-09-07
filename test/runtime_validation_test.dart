import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:dart_control_panel/models/daemon_state.dart';
import 'package:dart_control_panel/models/runtime_draft.dart';

DaemonState _fixtureState() {
  final raw = File('test/fixtures/payloads/state_envelope_full.json')
      .readAsStringSync();
  return DaemonState.fromEnvelope(jsonDecode(raw) as Map<String, dynamic>);
}

DaemonState _stateWith({int? exposureUs}) {
  final base = _fixtureState();
  final envelope = Map<String, dynamic>.from(base.envelope);
  final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
  final worker = Map<String, dynamic>.from(payload['worker'] as Map);
  final camera = Map<String, dynamic>.from(worker['camera'] as Map);
  if (exposureUs != null) camera['exposure_us'] = exposureUs;
  worker['camera'] = camera;
  payload['worker'] = worker;
  envelope['payload'] = payload;
  return DaemonState.fromEnvelope(envelope);
}

void main() {
  group('RuntimeDraft baseline', () {
    test('loadFrom builds a clean baseline from board state', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      expect(draft.hasChanges, isFalse);
      expect(draft.valueOf(RuntimeDraft.exposureUs), 1000);
      expect(draft.valueOf(RuntimeDraft.again), 1024);
      expect(draft.valueOf(RuntimeDraft.coarseStride), 4);
      expect(draft.valueOf(RuntimeDraft.detectRoi), '40,40,280,160');
      expect(draft.roiList, [40, 40, 280, 160]);
      expect(draft.roiMode, 'region');
      expect(draft.labList, [20, 60, -128, -20, 0, 60]);
      expect(draft.valueOf(RuntimeDraft.controlMode), 'angle_rad');
    });
  });

  group('dirty tracking', () {
    test('editing a field marks it dirty and serializes only it', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.exposureUs, 1500);
      expect(draft.hasChanges, isTrue);
      expect(draft.isDirty(RuntimeDraft.exposureUs), isTrue);
      expect(draft.toArgs(), {RuntimeDraft.exposureUs: 1500});
    });

    test('typing the baseline value back clears the dirty flag', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.exposureUs, 1500);
      expect(draft.hasChanges, isTrue);
      draft.edit(RuntimeDraft.exposureUs, 1000); // baseline again
      expect(draft.hasChanges, isFalse);
      expect(draft.toArgs(), isEmpty);
    });

    test('revert discards all pending edits', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.again, 2048);
      draft.edit(RuntimeDraft.overlay, false);
      expect(draft.changedFields, hasLength(2));
      draft.revert();
      expect(draft.hasChanges, isFalse);
      expect(draft.valueOf(RuntimeDraft.again), 1024);
      expect(draft.valueOf(RuntimeDraft.overlay), isTrue);
    });

    test('loadFrom clears previous edits and replaces the baseline', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.again, 4096);
      draft.loadFrom(_stateWith(exposureUs: 0));
      expect(draft.hasChanges, isFalse);
      expect(draft.valueOf(RuntimeDraft.again), 1024);
      expect(draft.valueOf(RuntimeDraft.exposureUs), 0);
    });
  });

  group('CSV composites', () {
    test('setLabComponent rebuilds the CSV from effective values', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.setLabComponent(0, 25);
      expect(draft.labList, [25, 60, -128, -20, 0, 60]);
      expect(draft.valueOf(RuntimeDraft.lab), '25,60,-128,-20,0,60');
      // no spaces, as required by the protocol
      expect(draft.valueOf(RuntimeDraft.lab), isNot(contains(' ')));
    });

    test('ROI mode and rectangle are mutually exclusive', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.setRoiMode('off');
      expect(draft.roiMode, 'off');
      expect(draft.valueOf(RuntimeDraft.detectRoi), 'off');
      draft.setRoiMode('LEGACY');
      expect(draft.roiMode, 'legacy');
      draft.setRoiRect(10, 10, 100, 50);
      expect(draft.roiMode, 'region');
      expect(draft.roiList, [10, 10, 100, 50]);
      expect(draft.valueOf(RuntimeDraft.detectRoi), '10,10,100,50');
    });
  });

  group('validation', () {
    test('empty/garbage integer fields are rejected (historical Tk bug)', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.coarseStride, ','); // old ""/"," bug
      expect(draft.validate()[RuntimeDraft.coarseStride], contains('integer'));
      draft.edit(RuntimeDraft.coarseStride, 0);
      expect(draft.validate()[RuntimeDraft.coarseStride], isNotNull);
      draft.edit(RuntimeDraft.coarseStride, 17);
      expect(draft.validate()[RuntimeDraft.coarseStride], isNotNull);
      draft.edit(RuntimeDraft.coarseStride, 4);
      expect(draft.validate(), isEmpty);
    });

    test('lab components respect ranges and min<=max', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.setLabComponent(1, 10); // l_max 10 < l_min 20
      expect(draft.validate()[RuntimeDraft.lab], contains('l_min'));
      draft.setLabComponent(1, 90); // valid
      expect(draft.validate(), isEmpty);
      draft.setLabComponent(2, 200); // a_min out of [-128,127]
      expect(draft.validate()[RuntimeDraft.lab], contains('a_min'));
    });

    test('edge_x must satisfy 2*edge_x < output width', () {
      final draft = RuntimeDraft.fromState(_fixtureState()); // output 640x360
      draft.edit(RuntimeDraft.edgeX, 320);
      expect(draft.validate()[RuntimeDraft.edgeX], contains('640'));
      draft.edit(RuntimeDraft.edgeX, 319);
      expect(draft.validate(), isEmpty);
      draft.edit(RuntimeDraft.edgeX, -1);
      expect(draft.validate()[RuntimeDraft.edgeX], isNotNull);
    });

    test('search radius and thresholds bounded by output', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.searchRadius, 0);
      expect(draft.validate()[RuntimeDraft.searchRadius], isNotNull);
      draft.edit(RuntimeDraft.searchRadius, 641);
      expect(draft.validate()[RuntimeDraft.searchRadius], isNotNull);
      draft.edit(RuntimeDraft.areaThreshold, 640 * 360 + 1);
      expect(draft.validate()[RuntimeDraft.areaThreshold], isNotNull);
      draft.edit(RuntimeDraft.searchRadius, 640);
      draft.edit(RuntimeDraft.areaThreshold, 640 * 360);
      expect(draft.validate(), isEmpty);
    });

    test('ROI must stay inside the output frame', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.setRoiRect(500, 300, 200, 100); // 700x400 > 640x360
      expect(draft.validate()[RuntimeDraft.detectRoi], contains('exceeds'));
      draft.setRoiRect(40, 30, 600, 320);
      expect(draft.validate(), isEmpty);
    });

    test('manual gain requires exposure_us > 0', () {
      final draft = RuntimeDraft.fromState(_stateWith(exposureUs: 0));
      draft.edit(RuntimeDraft.again, 2048);
      final errors = draft.validate();
      expect(errors[RuntimeDraft.again], contains('exposure_us'));
      draft.edit(RuntimeDraft.exposureUs, 2000);
      expect(draft.validate(), isEmpty);
    });

    test('gain ranges: 0 = unchanged, else 1024..262144', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.dgain, 1023);
      expect(draft.validate()[RuntimeDraft.dgain], isNotNull);
      draft.edit(RuntimeDraft.dgain, 262145);
      expect(draft.validate()[RuntimeDraft.dgain], isNotNull);
      draft.edit(RuntimeDraft.dgain, 2048);
      expect(draft.validate(), isEmpty);
    });

    test('enum fields validate their vocabulary', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.controlMode, 'foo');
      expect(draft.validate()[RuntimeDraft.controlMode], isNotNull);
      draft.edit(RuntimeDraft.controlMode, 'pixel');
      draft.edit(RuntimeDraft.rollUnit, 'foo');
      expect(draft.validate()[RuntimeDraft.rollUnit], isNotNull);
      draft.edit(RuntimeDraft.rollUnit, 'deg');
      draft.edit(RuntimeDraft.detectorMode, 'foo');
      expect(draft.validate()[RuntimeDraft.detectorMode], isNotNull);
      draft.edit(RuntimeDraft.detectorMode, 'fast'); // backend alias
      expect(draft.validate(), isEmpty);
    });

    test('float fields: fx/fy must be > 0', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.fx, 0);
      expect(draft.validate()[RuntimeDraft.fx], isNotNull);
      draft.edit(RuntimeDraft.fx, 0.1);
      expect(draft.validate(), isEmpty);
    });

    test('unvalidated dirty fields do not block unrelated edits', () {
      final draft = RuntimeDraft.fromState(_fixtureState());
      draft.edit(RuntimeDraft.overlay, false);
      draft.edit(RuntimeDraft.again, 2048); // exposure 1000 > 0, valid
      expect(draft.validate(), isEmpty);
      expect(draft.toArgs(),
          {RuntimeDraft.overlay: false, RuntimeDraft.again: 2048});
    });
  });
}
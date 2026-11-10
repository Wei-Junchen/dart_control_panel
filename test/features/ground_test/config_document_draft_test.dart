import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_control_panel/features/ground_test/config_document_draft.dart';

Map<String, dynamic> fixture() =>
    jsonDecode(
          File(
            Platform.environment['DART_CONFIG_SCHEMA_FIXTURE'] ??
                'test/fixtures/payloads/config_schema_v1.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
ConfigDocumentDraft draft() {
  final f = fixture();
  return ConfigDocumentDraft()
    ..setSchema(Map<String, dynamic>.from(f['schema'] as Map))
    ..load(Map<String, dynamic>.from(f['config'] as Map));
}

void main() {
  test(
    'real board schema accepts its config and describes only public UART keys',
    () {
      final d = draft();
      expect(d.validate(), isEmpty);
      expect(d.dirty, isFalse);
      expect(
        (d.schema!['properties']['uart']['properties'] as Map).keys,
        unorderedEquals(['enabled', 'baud']),
      );
    },
  );
  test(
    'both editing paths share one document and preserve unrelated fields',
    () {
      final d = draft();
      final uart = jsonEncode(d.document!['uart']);
      d.edit('control.cx', 123.5);
      expect(jsonDecode(d.text)['control']['cx'], 123.5);
      expect(jsonEncode(d.document!['uart']), uart);
      expect(d.dirty, isTrue);
      final json = jsonDecode(d.text);
      json['control']['cy'] = 321.0;
      d.editJson(jsonEncode(json));
      expect(d.at('control.cy'), 321);
      expect(d.at('control.cx'), 123.5);
      d.revert();
      expect(d.at('control.cx'), -1);
      expect(d.dirty, isFalse);
    },
  );
  test(
    'actual server numeric, enum, array, optional and oneOf constraints apply',
    () {
      final d = draft();
      for (final entry in {
        'control.cx': -.5,
        'control.fx': 0,
        'detector.luma_threshold': 256,
        'detector.ellipse_max_axis_ratio': 2.1,
        'detector.ellipse_min_iou': 0,
        'isp.again': 1,
        'isp.wb_gain': [1024, 1024],
        'view.rotation': 45,
      }.entries) {
        d.revert();
        d.edit(entry.key, entry.value);
        expect(d.validate(), isNotEmpty, reason: entry.key);
      }
      d.revert();
      d.edit('isp.again', 0);
      d.edit('control.cx', -1);
      d.edit('detector.roi', null);
      expect(d.validate(), isEmpty);
      final json = jsonDecode(d.text);
      json['control'].remove('cx');
      json['control'].remove('cy');
      json['detector'].remove('mode');
      d.editJson(jsonEncode(json));
      expect(d.validate(), isEmpty);
    },
  );
  test(
    'mode-specific fields follow schema conditions without deleting values',
    () {
      final d = draft();
      final fields = d.schema!['properties']['detector']['properties'] as Map;
      expect(
        d.visible(Map<String, dynamic>.from(fields['green_y_min'] as Map)),
        isTrue,
      );
      expect(
        d.visible(Map<String, dynamic>.from(fields['luma_threshold'] as Map)),
        isFalse,
      );
      d.edit('detector.luma_threshold', 99);
      d.edit('detector.mode', 'luma_ellipse');
      expect(
        d.visible(Map<String, dynamic>.from(fields['green_y_min'] as Map)),
        isFalse,
      );
      expect(
        d.visible(Map<String, dynamic>.from(fields['luma_threshold'] as Map)),
        isTrue,
      );
      expect(d.at('detector.green_y_min'), 20);
      expect(d.at('detector.luma_threshold'), 99);
    },
  );
  test(
    'invalid JSON and incomplete numeric edits survive unrelated updates',
    () {
      final d = draft();
      d.invalid('control.cx', 'incomplete');
      expect(d.validate(), isNotEmpty);
      d.edit('control.cy', 100);
      expect(d.validate(), contains('control.cx'));
      d.editJson('{ unfinished');
      expect(d.document, isNull);
      expect(d.text, '{ unfinished');
      d.load(
        Map<String, dynamic>.from(fixture()['config'] as Map),
        preserveEdits: true,
      );
      expect(d.text, '{ unfinished');
      expect(d.dirty, isTrue);
      d.revert();
      expect(d.validate(), isEmpty);
    },
  );
  test(
    'runtime arguments come from metadata; structural edits need full upload',
    () {
      final d = draft();
      expect(d.runtimeArgs, isEmpty);
      d.edit('control.cx', 123.5);
      expect(d.runtimeArgs, {'cx': 123.5});
      d.edit('record.gop', 31);
      expect(d.runtimeArgs, isNull);
      d.revert();
      d.edit('detector.roi', [1, 1, 10, 10]);
      expect(d.runtimeArgs, isNull);
      d.revert();
      d.edit('detector.luma_threshold', 99);
      expect(d.runtimeArgs, {'luma_threshold': 99});
    },
  );
  test('malformed object schema falls back to JSON rather than crashing', () {
    final d = draft();
    d.setSchema({
      'x-contract-version': 1,
      'type': 'object',
      'properties': {
        'broken': {'type': 'object'},
      },
    });
    expect(d.schema, isNull);
  });
  test('missing or future schema disables generated controls', () {
    final d = draft();
    d.setSchema(null);
    expect(d.schema, isNull);
    d.setSchema({'type': 'object', 'properties': {}, 'x-contract-version': 99});
    expect(d.schema, isNull);
  });
}

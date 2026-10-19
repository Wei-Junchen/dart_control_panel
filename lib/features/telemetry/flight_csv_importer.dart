import 'dart:convert';
import 'dart:io';

import 'telemetry_archive.dart';

/// Adapts board monotonic CSV to the existing indexed replay archive. The raw
/// CSV is retained; no board wall-clock date is inferred from its filename.
class FlightCsvImporter {
  static List<String> cells(String line) {
    final out = <String>[];
    var value = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          value.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == ',' && !quoted) {
        out.add(value.toString());
        value = StringBuffer();
      } else {
        value.write(c);
      }
    }
    if (quoted) throw const FormatException('CSV 引号未闭合');
    out.add(value.toString());
    return out;
  }

  static Future<TelemetryArchive> importFile(
    File raw,
    Directory directory, {
    String? source,
    Map<String, dynamic> extra = const {},
  }) async {
    await directory.create(recursive: true);
    final partial = File('${directory.path}/samples.csv.part');
    final sink = partial.openWrite();
    List<String>? header;
    var names = <String>[];
    final aliases = <String, String>{};
    int? firstUs,
        previousUs,
        firstFrame,
        lastFrame,
        firstVisionUs,
        lastVisionUs;
    var rows = 0;
    try {
      await for (final line
          in raw
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        if (line.trim().isEmpty) continue;
        final row = cells(line);
        if (header == null) {
          header = row.map((v) => v.replaceFirst('\uFEFF', '')).toList();
          if (header.toSet().length != header.length ||
              !header.contains('mono_us')) {
            throw const FormatException('CSV 缺少 mono_us 或列名重复');
          }
          names = header.where((v) => v != 'uart_schema').toList();
          if (names.any(
            (n) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(n),
          )) {
            throw const FormatException('CSV 列名无效');
          }
          for (final field in ['pitch', 'roll', 'yaw', 'air_speed']) {
            if (!names.contains(field)) {
              for (final candidate in ['uart_$field', 'uart_rx_$field']) {
                if (names.contains(candidate)) {
                  aliases[field] = candidate;
                  break;
                }
              }
            }
          }
          if (!names.contains('fps') && names.contains('capture_fps')) {
            aliases['fps'] = 'capture_fps';
          }
          names = [...names, ...aliases.keys];
          if (names.length > 128) {
            throw const FormatException('CSV 列数超过回放上限128');
          }
          sink.writeln(
            ['client_elapsed_us', 'client_received_at', ...names].join(','),
          );
          continue;
        }
        if (row.length != header.length) {
          throw FormatException('CSV 第${rows + 2}行列数不匹配');
        }
        final values = <String, String>{
          for (var i = 0; i < header.length; i++) header[i]: row[i],
        };
        final us = int.tryParse(values['mono_us']!);
        if (us == null || us < 0 || (previousUs != null && us < previousUs)) {
          throw const FormatException('CSV mono_us 无效或发生倒退');
        }
        firstUs ??= us;
        previousUs = us;
        for (final name in names) {
          final text = values[aliases[name] ?? name] ?? '';
          if (text.isNotEmpty) {
            final n = double.tryParse(text);
            if (n == null || n.isInfinite) {
              throw FormatException('CSV 非数值列：$name');
            }
          }
        }
        final frame = int.tryParse(values['frame'] ?? '');
        final vision = int.tryParse(
          values['vision_mono_us'] ?? values['mono_us']!,
        );
        if (frame != null && frame > 0 && vision != null && vision > 0) {
          firstFrame ??= frame;
          firstVisionUs ??= vision;
          lastFrame = frame;
          lastVisionUs = vision;
        }
        final elapsed = us - firstUs;
        // Epoch-relative, explicitly NOT a measured flight wall-clock timestamp.
        final stamp = DateTime.fromMicrosecondsSinceEpoch(
          elapsed,
          isUtc: true,
        ).toIso8601String();
        sink.writeln(
          [
            elapsed,
            stamp,
            for (final name in names) values[aliases[name] ?? name] ?? '',
          ].join(','),
        );
        rows++;
      }
      if (rows == 0) throw const FormatException('CSV 没有有效样本');
      await sink.flush();
      await sink.close();
      await partial.rename('${directory.path}/samples.csv');
      double? fps;
      if (firstFrame != null &&
          lastFrame! > firstFrame &&
          lastVisionUs! > firstVisionUs!) {
        final estimate =
            (lastFrame - firstFrame) * 1000000 / (lastVisionUs - firstVisionUs);
        if (estimate >= 1 && estimate <= 1000) fps = estimate;
      }
      final metadata = <String, dynamic>{
        ...extra,
        'format': 'dart_telemetry_csv_v1',
        'columns': names,
        'source': source ?? raw.path,
        'complete': true,
        'rows': rows,
        'duration_us': previousUs! - firstUs!,
        'imported_at': DateTime.now().toUtc().toIso8601String(),
        'flight_wall_clock_known': false,
        'timestamp_source': 'board_monotonic',
        'board_first_mono_us': firstUs,
        'board_last_mono_us': previousUs,
        'estimated_video_fps': ?fps,
      };
      final tmp = File('${directory.path}/metadata.json.tmp');
      await tmp.writeAsString(jsonEncode(metadata), flush: true);
      await tmp.rename('${directory.path}/metadata.json');
      return TelemetryArchive.open(directory);
    } catch (_) {
      await sink.close();
      rethrow;
    }
  }
}

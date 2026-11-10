import 'dart:convert';
import 'dart:typed_data';

/// TCP-negotiated names/types; UDP never carries names or a device identity.
class TelemetryField {
  const TelemetryField(this.index, this.name, this.type, {this.sourceName});
  final int index;
  final String name;
  final String type;
  final String? sourceName;
  int get size => TelemetryWire.sizes[type]!;
}

class TelemetrySchema {
  TelemetrySchema._(this.id, this.fields, this.uartReady);
  final int id;
  final List<TelemetryField> fields;
  final bool uartReady;

  factory TelemetrySchema.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'DVT1' ||
        json['byte_order'] != 'little' ||
        json['checksum'] != 'crc32_ieee') {
      throw const FormatException('unsupported telemetry schema');
    }
    final raw = json['fields'];
    final id = json['schema_id'];
    if (id is! int ||
        id < 0 ||
        id > 0xffffffff ||
        raw is! List ||
        raw.isEmpty ||
        raw.length > 90) {
      throw const FormatException('invalid telemetry registry');
    }
    final names = <String>{};
    final fields = <TelemetryField>[];
    final identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$');
    for (var i = 0; i < raw.length; i++) {
      final f = raw[i];
      if (f is! Map ||
          f['index'] != i ||
          f['name'] is! String ||
          !identifier.hasMatch(f['name'] as String) ||
          !names.add(f['name'] as String) ||
          ['seq', 'stream_id'].contains(f['name']) ||
          !TelemetryWire.sizes.containsKey(f['type'])) {
        throw const FormatException('invalid telemetry field');
      }
      final sourceName = f['source'] == 'uart' ? f['source_name'] : null;
      if (f['source'] == 'uart' &&
          (sourceName is! String ||
              !RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,31}$').hasMatch(sourceName))) {
        throw const FormatException('invalid UART source name');
      }
      fields.add(
        TelemetryField(
          i,
          f['name'] as String,
          f['type'] as String,
          sourceName: sourceName as String?,
        ),
      );
    }
    if (fields.where((f) => f.sourceName != null).length > 64) {
      throw const FormatException('UART field limit exceeded');
    }
    if (TelemetryWire.schemaId(fields) != id) {
      throw const FormatException('schema fingerprint mismatch');
    }
    return TelemetrySchema._(
      id,
      List.unmodifiable(fields),
      json['uart'] is Map && json['uart']['schema_ready'] == true,
    );
  }
}

class MissingTelemetrySchema implements Exception {
  const MissingTelemetrySchema(this.id);
  final int id;
  @override
  String toString() => 'waiting for TCP telemetry schema $id';
}

class TelemetryWire {
  static const sizes = <String, int>{
    'uint8': 1,
    'int8': 1,
    'uint16': 2,
    'int16': 2,
    'uint32': 4,
    'int32': 4,
    'float32': 4,
    'float64': 8,
  };

  static bool isBinary(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 68 &&
      bytes[1] == 86 &&
      bytes[2] == 84 &&
      bytes[3] == 49;

  static int crc32(Uint8List bytes, [int? length]) {
    var crc = 0xffffffff;
    for (var i = 0; i < (length ?? bytes.length); i++) {
      crc ^= bytes[i];
      for (var b = 0; b < 8; b++) {
        crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0);
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }

  static int schemaId(List<TelemetryField> fields) {
    var hash = 2166136261;
    for (final f in fields) {
      for (final part in [f.name, f.type]) {
        for (final c in [...utf8.encode(part), 0]) {
          hash = ((hash ^ c) * 16777619) & 0xffffffff;
        }
      }
    }
    return hash;
  }

  static Map<String, double> decode(Uint8List bytes, TelemetrySchema? schema) {
    if (!isBinary(bytes) || bytes.length < 22 || bytes.length > 1024) {
      throw const FormatException('invalid DVT1 size/magic');
    }
    final data = ByteData.sublistView(bytes);
    if (crc32(bytes, bytes.length - 4) !=
        data.getUint32(bytes.length - 4, Endian.little)) {
      throw const FormatException('telemetry CRC32 mismatch');
    }
    final count = data.getUint16(16, Endian.little);
    if (count == 0 || count > 90) {
      throw const FormatException('invalid field count');
    }
    final id = data.getUint32(4, Endian.little);
    if (schema == null || schema.id != id) throw MissingTelemetrySchema(id);
    if (count != schema.fields.length) {
      throw const FormatException('schema count mismatch');
    }
    var offset = 18;
    final seen = <int>{};
    final values = <String, double>{
      'seq': data.getUint32(8, Endian.little).toDouble(),
      'stream_id': data.getUint32(12, Endian.little).toDouble(),
    };
    for (var i = 0; i < count; i++) {
      if (offset >= bytes.length - 4) {
        throw const FormatException('truncated field');
      }
      final index = bytes[offset++];
      if (index >= count || !seen.add(index)) {
        throw const FormatException('invalid/duplicate index');
      }
      final f = schema.fields[index];
      if (offset + f.size > bytes.length - 4) {
        throw const FormatException('truncated value');
      }
      final num value = switch (f.type) {
        'uint8' => data.getUint8(offset),
        'int8' => data.getInt8(offset),
        'uint16' => data.getUint16(offset, Endian.little),
        'int16' => data.getInt16(offset, Endian.little),
        'uint32' => data.getUint32(offset, Endian.little),
        'int32' => data.getInt32(offset, Endian.little),
        'float32' => data.getFloat32(offset, Endian.little),
        'float64' => data.getFloat64(offset, Endian.little),
        _ => throw const FormatException('unknown field type'),
      };
      if (!value.isFinite) throw const FormatException('non-finite telemetry');
      values[f.name] = value.toDouble();
      offset += f.size;
    }
    if (offset != bytes.length - 4) {
      throw const FormatException('trailing bytes');
    }
    return values;
  }
}

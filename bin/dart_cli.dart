import 'dart:convert';
import 'dart:io';

import 'package:dart_control_panel/core/board/models/daemon_state.dart';
import 'package:dart_control_panel/core/board/api/daemon_client.dart';
import 'package:dart_control_panel/core/board/api/protocol_exception.dart';
import 'package:dart_control_panel/core/board/api/board_repository.dart';

/// P0 acceptance: a pure-Dart CLI that can talk to the daemon without any
/// Flutter UI.
///
/// Usage:
///   dart run bin/dart_cli.dart [opts] `<op>` [`args-json`]
///
/// ops: get_state | get_profiles | get_schema | get_logs | heartbeat
///
/// opts:
///   --host HOST      board IP            (default 10.149.242.1)
///   --port PORT      daemon port         (default 9000)
///   --timeout MS     per-request timeout (default 3000)
///
/// Examples:
///   dart run bin/dart_cli.dart --host 10.149.242.1 get_state
///   dart run bin/dart_cli.dart get_logs '{"lines":50}'
Future<void> main(List<String> arguments) async {
  var host = DaemonClient.defaultHost;
  var port = DaemonClient.defaultPort;
  var timeoutMs = 3000;
  final positional = <String>[];

  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    switch (arg) {
      case '--host':
        host = arguments[++i];
      case '--port':
        port = int.parse(arguments[++i]);
      case '--timeout':
        timeoutMs = int.parse(arguments[++i]);
      default:
        positional.add(arg);
    }
  }

  if (positional.isEmpty) {
    stderr.writeln(
      'usage: dart run bin/dart_cli.dart [--host H] [--port P] <op> [args-json]',
    );
    exitCode = 2;
    return;
  }

  final op = positional[0];
  Map<String, dynamic> args = {};
  if (positional.length > 1) {
    try {
      final decoded = jsonDecode(positional[1]);
      if (decoded is Map) args = Map<String, dynamic>.from(decoded);
    } on FormatException catch (e) {
      stderr.writeln('invalid args json: ${e.message}');
      exitCode = 2;
      return;
    }
  }

  final repository = BoardRepository(
    DaemonClient(
      host: host,
      port: port,
      timeout: Duration(milliseconds: timeoutMs),
    ),
  );

  try {
    switch (op) {
      case 'get_state':
        final state = await repository.getState();
        _printStateSummary(state);
        stdout.writeln(jsonEncode(state.envelope));
      case 'get_profiles':
        final profiles = await repository.getProfiles();
        stdout.writeln(
          jsonEncode(
            profiles.map(
              (name, p) => MapEntry(name, {
                'readout': p.readout,
                'view': p.view,
                'status': p.status,
                'expected': p.expected == null
                    ? null
                    : {
                        'sensor': p.expected!.sensor,
                        'output': p.expected!.output,
                        'fps': p.expected!.fps,
                      },
              }),
            ),
          ),
        );
      case 'get_schema':
        stdout.writeln(jsonEncode(await repository.getSchema()));
      case 'get_logs':
        final lines = args['lines'] is num
            ? (args['lines'] as num).toInt()
            : 120;
        for (final line in await repository.getLogs(lines: lines)) {
          stdout.writeln(line);
        }
      case 'heartbeat':
        stdout.writeln(jsonEncode(await repository.heartbeat()));
      default:
        stderr.writeln('unknown op: $op');
        stderr.writeln(
          'supported: get_state | get_profiles | get_schema | get_logs | heartbeat',
        );
        exitCode = 2;
    }
  } on OperationFailedException catch (e) {
    stderr.writeln('daemon error: ${e.message} (state=${e.state})');
    exitCode = 1;
  } on ProtocolException catch (e) {
    stderr.writeln('protocol error: $e');
    exitCode = 1;
  } finally {
    await repository.close();
  }
}

void _printStateSummary(DaemonState state) {
  final w = state.worker;
  final sb = StringBuffer()
    ..writeln('state=          ${state.state}')
    ..writeln('profile=        ${state.profile}')
    ..writeln(
      'mode=           ${state.mode} locked=${state.imageSettingsLocked}',
    )
    ..writeln('rotation=       ${state.rotation} config_rev=${state.configRev}')
    ..writeln(
      'features=       '
      'rtsp=${state.features.rtsp} '
      'overlay=${state.features.overlay}',
    )
    ..writeln('temperature=    ${state.resources.temperatureC}');
  if (w != null) {
    sb
      ..writeln(
        'fps=            '
        '${w.performance.fps.toStringAsFixed(1)} '
        'det=${w.performance.detectionFps.toStringAsFixed(1)} '
        '(requested ${w.performance.requestedFps})',
      )
      ..writeln(
        'target=         '
        '${w.target.found ? 'found' : 'lost'} '
        '(${w.target.x},${w.target.y}) px=${w.target.pixels} '
        'area=${w.target.area}',
      )
      ..writeln(
        'exposure_us=    ${w.camera.exposureUs} '
        'actual=${w.camera.isp.exposureUs}',
      )
      ..writeln(
        'gain=           ${w.camera.again}/${w.camera.dgain}/'
        '${w.camera.ispDgain} actual=${w.camera.isp.again}/'
        '${w.camera.isp.dgain}/${w.camera.isp.ispDgain}',
      )
      ..writeln(
        'stream=         rtsp=${w.stream.rtspEnabled}:'
        '${w.stream.rtspPort} clients=${w.stream.rtspClients} '
        'encoded=${w.stream.encodedFrames}',
      )
      ..writeln(
        'udp=            ${w.udpTelemetry.running} '
        '${w.udpTelemetry.host}:${w.udpTelemetry.port} '
        '${w.udpTelemetry.hz}Hz sent=${w.udpTelemetry.sentPackets}',
      );
  }
  stdout.write(sb);
}

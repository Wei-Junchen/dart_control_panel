import 'package:dart_control_panel/core/board/models/json_view.dart';

/// One entry of the `get_profiles` payload. The profile list MUST be loaded
/// dynamically from the board; never hardcode the set in the client.
class Profile {
  Profile({
    required this.readout,
    required this.view,
    required this.status,
    this.expected,
    this.supportedRotations = const [0, 90, 180, 270],
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    final v = JsonView(json);
    return Profile(
      readout: v.str('readout'),
      view: v.str('view'),
      status: v.str('status'),
      expected: v.nested('expected') == null
          ? null
          : Expected.fromJson(
              Map<String, dynamic>.from(json['expected'] as Map),
            ),
      supportedRotations: v.intList('supported_rotations').isEmpty
          ? const [0, 90, 180, 270]
          : v.intList('supported_rotations'),
    );
  }

  final String readout;
  final String view;

  /// Optional per spec; empty string when the board does not provide it.
  final String status;
  final Expected? expected;
  final List<int> supportedRotations;
}

class Expected {
  Expected({required this.sensor, required this.output, required this.fps});

  factory Expected.fromJson(Map<String, dynamic> json) {
    final v = JsonView(json);
    return Expected(
      sensor: v.intList('sensor'),
      output: v.intList('output'),
      fps: v.dbl('fps'),
    );
  }

  final List<int> sensor;
  final List<int> output;
  final double fps;
}

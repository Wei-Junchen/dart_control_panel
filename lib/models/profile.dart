import 'json_view.dart';

/// One entry of the `get_profiles` payload. The profile list MUST be loaded
/// dynamically from the board; never hardcode the set in the client.
class Profile {
  Profile({
    required this.readout,
    required this.view,
    required this.features,
    required this.status,
    this.expected,
  });

  factory Profile.fromJson(Map<String, dynamic> json) {
    final v = JsonView(json);
    return Profile(
      readout: v.str('readout'),
      view: v.str('view'),
      features: v.str('features'),
      status: v.str('status'),
      expected: v.nested('expected') == null
          ? null
          : Expected.fromJson(Map<String, dynamic>.from(json['expected'] as Map)),
    );
  }

  final String readout;
  final String view;
  final String features;

  /// Optional per spec; empty string when the board does not provide it.
  final String status;
  final Expected? expected;
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

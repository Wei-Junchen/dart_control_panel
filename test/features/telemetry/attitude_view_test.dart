import 'package:dart_control_panel/features/telemetry/attitude_scene.dart';
import 'package:dart_control_panel/features/telemetry/attitude_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const north = AttitudeVector(1, 0, 0);
  const east = AttitudeVector(0, 1, 0);
  const down = AttitudeVector(0, 0, 1);
  const origin = AttitudeVector(0, 0, 0);

  void expectVector(AttitudeVector actual, AttitudeVector expected) {
    expect(actual.x, closeTo(expected.x, 1e-10));
    expect(actual.y, closeTo(expected.y, 1e-10));
    expect(actual.z, closeTo(expected.z, 1e-10));
  }

  test('zero attitude aligns body FRD with world NED', () {
    final rotation = NedAttitudeRotation(0, 0, 0);
    for (final vector in [north, east, down]) {
      expectVector(rotation.apply(vector), vector);
    }
  });

  test('roll about X, pitch about Y, yaw about down-positive Z', () {
    expectVector(NedAttitudeRotation(0, 90, 0).apply(east), down);
    expectVector(NedAttitudeRotation(0, 90, 0).apply(north), north);
    expectVector(NedAttitudeRotation(90, 0, 0).apply(north), down * -1);
    expectVector(NedAttitudeRotation(0, 0, 90).apply(north), east);
    expectVector(NedAttitudeRotation(90, 90, 90).apply(east), east);
    expectVector(NedAttitudeRotation(90, 90, 90).apply(down), north);
  });

  test('compound attitude preserves a right-handed orthonormal triad', () {
    final rotation = NedAttitudeRotation(27, -51, 83);
    final x = rotation.apply(north);
    final y = rotation.apply(east);
    final z = rotation.apply(down);
    for (final axis in [x, y, z]) {
      expect(axis.length, closeTo(1, 1e-10));
    }
    expect(x.dot(y), closeTo(0, 1e-10));
    expect(y.dot(z), closeTo(0, 1e-10));
    expectVector(x.cross(y), z);
  });

  test('camera is fixed at k*(-1,0,0), looking at origin, NED up=-Z', () {
    const camera = NedAttitudeCamera(k: 10);
    const size = Size(320, 320);
    expectVector(camera.position, const AttitudeVector(-10, 0, 0));
    expectVector(camera.forward, (origin - camera.position).normalized());
    expectVector(camera.right, east);
    expect(camera.up.dot(down), lessThan(0));
    expect(camera.forward.dot(camera.up), closeTo(0, 1e-10));
    expect(camera.project(origin, size), const Offset(160, 160));
    expect(camera.project(east, size).dx, greaterThan(160));
    expect(camera.project(north, size), const Offset(160, 160));
    expect(camera.project(down, size).dy, greaterThan(160));
    expect(camera.depth(north), greaterThan(camera.depth(origin)));
  });

  testWidgets('renderer handles finite and missing telemetry safely', (
    tester,
  ) async {
    for (final angles in [
      (0.0, 0.0, 0.0),
      (35.0, -45.0, 90.0),
      (double.nan, double.infinity, double.negativeInfinity),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox.square(
              dimension: 320,
              child: AttitudeView(
                pitchDeg: angles.$1,
                rollDeg: angles.$2,
                yawDeg: angles.$3,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
  });
}

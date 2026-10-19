import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'attitude_scene.dart';

class _Face {
  _Face(this.color, this.points);
  final Color color;
  final List<AttitudeVector> points;
}

/// Missile geometry in the **body frame**, centered on the origin:
/// nose along +X (forward), +Y right, +Z down (FRD). Rotating around the origin
/// therefore spins the missile around its own center point.
class _MissileGeometry {
  List<_Face> build() {
    const segments = 12;
    const bodyR = 0.24;
    const noseTip = AttitudeVector(1.12, 0, 0);
    const coneBaseX = 0.45;
    const tailX = -1.12;

    final faces = <_Face>[];
    final coneRing = _ring(coneBaseX, bodyR, segments);
    final tailRing = _ring(tailX, 0.17, segments);

    // nose cone
    for (var i = 0; i < segments; i++) {
      final a = coneRing[i];
      final b = coneRing[(i + 1) % segments];
      faces.add(_Face(const Color(0xFFBF6154), [noseTip, a, b]));
    }
    // body cylinder
    for (var i = 0; i < segments; i++) {
      final a = coneRing[i];
      final b = coneRing[(i + 1) % segments];
      final c = tailRing[(i + 1) % segments];
      final d = tailRing[i];
      faces.add(_Face(const Color(0xFF9AA0A6), [a, b, c, d]));
    }
    // tail cap
    const tailCenter = AttitudeVector(tailX, 0, 0);
    for (var i = 0; i < segments; i++) {
      final a = tailRing[i];
      final b = tailRing[(i + 1) % segments];
      faces.add(_Face(const Color(0xFF6D7175), [tailCenter, a, b]));
    }
    // fins (4, at 45° diagonals so they read as an X from behind)
    const finColor = Color(0xFFD64550);
    for (final a in const [45.0, 135.0, 225.0, 315.0]) {
      final rad = a * math.pi / 180.0;
      final dir = AttitudeVector(0, math.cos(rad), math.sin(rad));
      final inner = dir * 0.17;
      final outer = dir * 0.62;
      faces.add(
        _Face(finColor, [
          inner + const AttitudeVector(-0.55, 0, 0),
          inner + const AttitudeVector(tailX, 0, 0),
          outer + const AttitudeVector(tailX, 0, 0),
          outer + const AttitudeVector(-0.55, 0, 0),
        ]),
      );
    }
    return faces;
  }

  static List<AttitudeVector> _ring(double x, double r, int n) => [
    for (var i = 0; i < n; i++)
      AttitudeVector(
        x,
        r * math.cos(2 * math.pi * i / n),
        r * math.sin(2 * math.pi * i / n),
      ),
  ];
}

/// NED attitude indicator with a fixed camera directly behind along +X:
/// - the missile spins around its own center (body-frame rotation);
/// - two orthogonal triads, both anchored at the missile center:
///   a fixed, never-rotating ground/inertial frame (neutral X/Y/Z) and the
///   rigid-body frame (colored x/y/z) that rotates with the model — when the
///   two frames diverge, yaw/pitch/roll are directly readable.
class AttitudeView extends StatelessWidget {
  const AttitudeView({
    super.key,
    required this.pitchDeg,
    required this.rollDeg,
    required this.yawDeg,
  });

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _AttitudePainter(
          pitchDeg: pitchDeg,
          rollDeg: rollDeg,
          yawDeg: yawDeg,
        ),
      ),
    );
  }
}

class _AttitudePainter extends CustomPainter {
  _AttitudePainter({
    required this.pitchDeg,
    required this.rollDeg,
    required this.yawDeg,
  });

  final double pitchDeg;
  final double rollDeg;
  final double yawDeg;

  static const _axisLen = 0.9;

  // ground/inertial frame: fixed in space, one neutral color for the triad
  static const _worldAxes = [
    (AttitudeVector(1, 0, 0), Color(0xFFB0BEC5), 'X · N'),
    (AttitudeVector(0, 1, 0), Color(0xFFB0BEC5), 'Y · E'),
    (AttitudeVector(0, 0, 1), Color(0xFFB0BEC5), 'Z · D'),
  ];
  // rigid-body frame: rotates with the missile, colored per axis
  static const _bodyAxes = [
    (AttitudeVector(1, 0, 0), Color(0xFFE57373), 'x'),
    (AttitudeVector(0, 1, 0), Color(0xFF81C784), 'y'),
    (AttitudeVector(0, 0, 1), Color(0xFF64B5F6), 'z'),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    double safeDeg(double v) => v.isFinite ? v : 0.0;
    final rotation = NedAttitudeRotation(
      safeDeg(pitchDeg),
      safeDeg(rollDeg),
      safeDeg(yawDeg),
    );
    final camera = NedAttitudeCamera();

    // ground/inertial frame: fixed at the missile center, never rotates
    _paintAxisFrame(
      canvas,
      size,
      camera,
      rotation,
      _worldAxes,
      worldFrame: true,
    );
    _paintMissile(canvas, size, camera, rotation);
    // rigid-body frame: driven by the attitude; drawn last so it stays
    // readable even when it overlaps with the world frame (level attitude)
    _paintAxisFrame(
      canvas,
      size,
      camera,
      rotation,
      _bodyAxes,
      worldFrame: false,
    );
  }

  void _paintMissile(
    Canvas canvas,
    Size size,
    NedAttitudeCamera camera,
    NedAttitudeRotation rotation,
  ) {
    final projected = <({double depth, Path path, Color color})>[];
    for (final face in _MissileGeometry().build()) {
      final world = [for (final p in face.points) rotation.apply(p)];
      final offsets = [for (final p in world) camera.project(p, size)];
      final depth =
          world.map(camera.depth).reduce((a, b) => a + b) / world.length;
      final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
      for (final o in offsets.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      path.close();
      projected.add((depth: depth, path: path, color: face.color));
    }
    // Far faces first: larger positive camera-forward distance.
    projected.sort((a, b) => b.depth.compareTo(a.depth));
    for (final f in projected) {
      canvas.drawPath(f.path, Paint()..color = f.color);
      canvas.drawPath(
        f.path,
        Paint()
          ..color = const Color(0x33000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    }
    // center marker (rotation pivot)
    final c = camera.project(const AttitudeVector(0, 0, 0), size);
    canvas.drawCircle(c, 2.5, Paint()..color = const Color(0xFFEEEEEE));
  }

  /// Draws one orthogonal triad, both anchored at the missile center:
  /// the fixed world frame (unrotated) or the rigid-body frame (rotated by
  /// the current attitude).
  void _paintAxisFrame(
    Canvas canvas,
    Size size,
    NedAttitudeCamera camera,
    NedAttitudeRotation rotation,
    List<(AttitudeVector, Color, String)> axes, {
    required bool worldFrame,
  }) {
    const at = AttitudeVector(0, 0, 0);
    final origin = camera.project(at, size);
    for (final (dir, color, label) in axes) {
      final rotated = worldFrame ? dir : rotation.apply(dir);
      final end = camera.project(at + rotated * _axisLen, size);
      canvas.drawLine(
        origin,
        end,
        Paint()
          ..color = color
          ..strokeWidth = worldFrame ? 2.0 : 1.6,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: color,
            fontSize: worldFrame ? 12 : 10,
            fontWeight: FontWeight.bold,
            fontStyle: worldFrame ? FontStyle.normal : FontStyle.italic,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        end + (worldFrame ? const Offset(3, -13) : const Offset(3, 3)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AttitudePainter old) =>
      old.pitchDeg != pitchDeg ||
      old.rollDeg != rollDeg ||
      old.yawDeg != yawDeg;
}

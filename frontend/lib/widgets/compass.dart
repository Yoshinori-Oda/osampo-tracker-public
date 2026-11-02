import 'dart:math';
import 'package:flutter/material.dart';

class RealCompassWidget extends StatelessWidget {
  final double heading;
  final bool isHeadingMode;
  final double size;

  const RealCompassWidget({
    super.key,
    required this.heading,
    required this.isHeadingMode,
    this.size = 32.0
  });

  @override
  Widget build(BuildContext context) {
    final needleAngle = isHeadingMode ? -(heading * pi / 180) : 0.0;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CompassPainter(needleAngle: needleAngle)
      )
    );
  }
}

class _CompassPainter extends CustomPainter {
  final double needleAngle;

  _CompassPainter({required this.needleAngle});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // circle and outline
    final bgPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.grey.shade300
      ..style = PaintingStyle.fill
      ..strokeWidth = 2.0;
    
    canvas.drawCircle(center, radius, bgPaint);
    canvas.drawCircle(center, radius - 1, borderPaint);

    // needles (top for default)
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(needleAngle);

    final needleLength = radius * 0.65;
    final needleWidth = radius * 0.25;

    // N-side
    final northPath = Path()
      ..moveTo(0, -needleLength)
      ..lineTo(needleWidth, 0)
      ..lineTo(-needleWidth, 0)
      ..close();
      final northPaint = Paint()..color = Colors.redAccent;
      canvas.drawPath(northPath, northPaint);

    // S-side
    final southPath = Path()
      ..moveTo(0, needleLength)
      ..lineTo(needleWidth, 0)
      ..lineTo(-needleWidth, 0)
      ..close();
    final southPaint = Paint()..color = Colors.blueGrey.shade300;
    canvas.drawPath(southPath, southPaint);

    // center pin
    canvas.drawCircle(Offset.zero, 2.5, Paint()..color = Colors.white);
    canvas.drawCircle(Offset.zero, 1.5, Paint()..color = Colors.black87);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CompassPainter oldDelegate) {
    return oldDelegate.needleAngle != needleAngle;
  }
}
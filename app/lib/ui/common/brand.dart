/// The LocalCanvas mark and wordmark.
///
/// A simple geometric canvas/flow symbol drawn with Flutter's own painting
/// primitives — no external asset, no icon font, nothing to load at runtime.
/// The same widget draws the intro (with [CanvasMark.progress] animated) and
/// every static appearance afterwards, so the brand never has two versions.
library;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// The mark: a canvas, and a flow crossing it.
///
/// [progress] runs 0 → 1 and is what "line formation" means here: the frame
/// draws itself, then the flow, then the node lands.
class CanvasMark extends StatelessWidget {
  const CanvasMark({
    super.key,
    this.size = 72,
    this.progress = 1,
    this.color,
    this.nodeColor,
  });

  final double size;
  final double progress;

  /// Defaults to the primary text colour: the mark is monochrome, and the one
  /// accent belongs to action and state, not to decoration.
  final Color? color;

  /// The single accented point on the flow — the mark's one spot of colour.
  final Color? nodeColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _MarkPainter(
          progress: progress.clamp(0.0, 1.0),
          stroke: color ?? palette.textPrimary,
          node: nodeColor ?? palette.accent,
        ),
        isComplex: false,
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter({
    required this.progress,
    required this.stroke,
    required this.node,
  });

  final double progress;
  final Color stroke;
  final Color node;

  // The three movements of the formation, as fractions of [progress].
  static const double _frameEnd = 0.62;
  static const double _flowStart = 0.34;
  static const double _flowEnd = 0.88;
  static const double _nodeStart = 0.72;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide;
    final inset = unit * 0.10;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      unit - inset * 2,
      unit - inset * 2,
    );
    final radius = Radius.circular(unit * 0.24);
    final strokeWidth = unit * 0.075;

    final framePath = Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
    _drawPortion(
      canvas,
      framePath,
      _phase(0, _frameEnd),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = stroke,
    );

    // The flow: in low on the left, a single bend, out high on the right.
    final flowStart = Offset(rect.left + rect.width * 0.20, rect.bottom - rect.height * 0.24);
    final flowBend = Offset(rect.left + rect.width * 0.46, rect.top + rect.height * 0.74);
    final flowEnd = Offset(rect.right - rect.width * 0.22, rect.top + rect.height * 0.28);
    final flowPath = Path()
      ..moveTo(flowStart.dx, flowStart.dy)
      ..quadraticBezierTo(flowBend.dx, flowBend.dy, flowEnd.dx, flowEnd.dy);
    _drawPortion(
      canvas,
      flowPath,
      _phase(_flowStart, _flowEnd),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 0.85
        ..strokeCap = StrokeCap.round
        ..color = stroke.withValues(alpha: 0.55),
    );

    final nodeT = Curves.easeOutBack.transform(_phase(_nodeStart, 1));
    if (nodeT > 0) {
      canvas.drawCircle(
        flowEnd,
        (unit * 0.085) * nodeT.clamp(0.0, 1.2),
        Paint()..color = node,
      );
    }
  }

  /// How far through one movement [progress] has come, 0 → 1.
  double _phase(double from, double to) =>
      ((progress - from) / (to - from)).clamp(0.0, 1.0);

  void _drawPortion(Canvas canvas, Path path, double t, Paint paint) {
    if (t <= 0) return;
    if (t >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * t), paint);
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.progress != progress || old.stroke != stroke || old.node != node;
}

/// The wordmark. Hierarchy by weight, not by colour.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.fontSize = 30, this.color});

  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.1,
      letterSpacing: -fontSize * 0.02,
      color: color ?? context.palette.textPrimary,
    );
    return Text.rich(
      TextSpan(
        children: <TextSpan>[
          TextSpan(text: 'Local', style: base.copyWith(fontWeight: FontWeight.w300)),
          TextSpan(text: 'Canvas', style: base.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
      semanticsLabel: 'LocalCanvas',
      textAlign: TextAlign.center,
    );
  }
}

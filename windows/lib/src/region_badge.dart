import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'node_region.dart';

class RegionBadge extends StatelessWidget {
  const RegionBadge({
    super.key,
    required this.region,
    this.width = 30,
    this.height = 22,
  });

  final NodeRegion region;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: region.name,
      child: CustomPaint(
        size: Size(width, height),
        painter: _RegionBadgePainter(region.code),
      ),
    );
  }
}

class _RegionBadgePainter extends CustomPainter {
  const _RegionBadgePainter(this.code);

  final String code;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final radius = Radius.circular(size.shortestSide * .2);
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, radius));
    canvas.drawRect(rect, Paint()..color = _background(code));

    switch (code) {
      case 'JP':
        canvas.drawCircle(
          rect.center,
          size.shortestSide * .22,
          Paint()..color = const Color(0xFFEF3340),
        );
        break;
      case 'HK':
        _drawFlower(canvas, rect.center, size.shortestSide * .27);
        break;
      case 'SG':
        canvas.drawRect(
          Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2),
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          Offset(size.width * .27, size.height * .27),
          size.height * .17,
          Paint()..color = Colors.white,
        );
        canvas.drawCircle(
          Offset(size.width * .31, size.height * .27),
          size.height * .13,
          Paint()..color = const Color(0xFFEF3340),
        );
        break;
      case 'US':
        _drawStripes(canvas, size, const Color(0xFFB22234), Colors.white, 7);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width * .44, size.height * .54),
          Paint()..color = const Color(0xFF3C3B6E),
        );
        _drawStars(
          canvas,
          Rect.fromLTWH(0, 0, size.width * .44, size.height * .54),
          3,
          4,
          Colors.white,
        );
        break;
      case 'TW':
        canvas.drawRect(
          Rect.fromLTWH(0, 0, size.width * .48, size.height * .55),
          Paint()..color = const Color(0xFF000095),
        );
        _drawSun(
          canvas,
          Offset(size.width * .24, size.height * .275),
          size.height * .13,
          Colors.white,
        );
        break;
      case 'KR':
        canvas.drawCircle(
          rect.center,
          size.shortestSide * .2,
          Paint()..color = const Color(0xFFCD2E3A),
        );
        canvas.drawArc(
          Rect.fromCircle(center: rect.center, radius: size.shortestSide * .2),
          0,
          3.14159,
          true,
          Paint()..color = const Color(0xFF0047A0),
        );
        break;
      case 'CN':
        _drawStar(
          canvas,
          Offset(size.width * .25, size.height * .3),
          size.height * .16,
          const Color(0xFFFFDE00),
        );
        break;
      case 'DE':
        _drawHorizontalBands(canvas, size, const <Color>[
          Color(0xFF171717),
          Color(0xFFDD0000),
          Color(0xFFFFCE00),
        ]);
        break;
      case 'FR':
        _drawVerticalBands(canvas, size, const <Color>[
          Color(0xFF0055A4),
          Colors.white,
          Color(0xFFEF4135),
        ]);
        break;
      case 'NL':
        _drawHorizontalBands(canvas, size, const <Color>[
          Color(0xFFAE1C28),
          Colors.white,
          Color(0xFF21468B),
        ]);
        break;
      case 'RU':
        _drawHorizontalBands(canvas, size, const <Color>[
          Colors.white,
          Color(0xFF0039A6),
          Color(0xFFD52B1E),
        ]);
        break;
      case 'GB':
        _drawCross(canvas, size, const Color(0xFFCF142B), Colors.white);
        break;
      case 'CA':
        canvas.drawRect(
          Rect.fromLTWH(size.width * .25, 0, size.width * .5, size.height),
          Paint()..color = Colors.white,
        );
        _drawStar(
          canvas,
          rect.center,
          size.height * .16,
          const Color(0xFFD80621),
        );
        break;
      case 'AU':
        _drawStars(
          canvas,
          Rect.fromLTWH(size.width * .42, 0, size.width * .58, size.height),
          2,
          2,
          Colors.white,
        );
        break;
      case 'IN':
        _drawHorizontalBands(canvas, size, const <Color>[
          Color(0xFFFF9933),
          Colors.white,
          Color(0xFF138808),
        ]);
        canvas.drawCircle(
          rect.center,
          size.height * .1,
          Paint()..color = const Color(0xFF000080),
        );
        break;
      case 'TH':
        _drawHorizontalBands(canvas, size, const <Color>[
          Color(0xFFA51931),
          Colors.white,
          Color(0xFF2D2A4A),
          Colors.white,
          Color(0xFFA51931),
        ]);
        break;
      case 'ID':
        canvas.drawRect(
          Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2),
          Paint()..color = Colors.white,
        );
        break;
      case 'PH':
        canvas.drawRect(
          Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2),
          Paint()..color = const Color(0xFFCE1126),
        );
        final path = Path()
          ..moveTo(0, 0)
          ..lineTo(size.width * .4, size.height / 2)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(path, Paint()..color = Colors.white);
        break;
      case 'ZZ':
        _drawGlobe(canvas, rect.center, size.shortestSide * .3);
        break;
      default:
        _drawCode(canvas, size, code);
        break;
    }

    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(.5), radius),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x220F172A),
    );
  }

  Color _background(String value) => switch (value) {
    'HK' || 'CN' || 'TW' || 'SG' || 'ID' || 'CA' => const Color(0xFFDE2910),
    'US' || 'FR' || 'GB' || 'AU' || 'TH' || 'MY' => const Color(0xFF174EA6),
    'JP' || 'KR' || 'RU' || 'IN' || 'PH' => Colors.white,
    'DE' => const Color(0xFF171717),
    'NL' => const Color(0xFFAE1C28),
    'VN' => const Color(0xFFDA251D),
    'BR' => const Color(0xFF009C3B),
    'TR' => const Color(0xFFE30A17),
    _ => const Color(0xFFEAF0F8),
  };

  void _drawCode(Canvas canvas, Size size, String value) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          color: value == 'ZZ' ? const Color(0xFF60708A) : Colors.white,
          fontSize: size.height * .42,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
  }

  void _drawHorizontalBands(Canvas canvas, Size size, List<Color> colors) {
    final band = size.height / colors.length;
    for (var i = 0; i < colors.length; i++) {
      canvas.drawRect(
        Rect.fromLTWH(0, i * band, size.width, band + .5),
        Paint()..color = colors[i],
      );
    }
  }

  void _drawVerticalBands(Canvas canvas, Size size, List<Color> colors) {
    final band = size.width / colors.length;
    for (var i = 0; i < colors.length; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * band, 0, band + .5, size.height),
        Paint()..color = colors[i],
      );
    }
  }

  void _drawStripes(Canvas canvas, Size size, Color a, Color b, int count) {
    _drawHorizontalBands(
      canvas,
      size,
      List<Color>.generate(count, (i) => i.isEven ? a : b),
    );
  }

  void _drawCross(Canvas canvas, Size size, Color cross, Color border) {
    final wide = Paint()
      ..color = border
      ..strokeWidth = size.height * .28;
    final narrow = Paint()
      ..color = cross
      ..strokeWidth = size.height * .16;
    canvas.drawLine(const Offset(0, 0), Offset(size.width, size.height), wide);
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), wide);
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      wide,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      wide,
    );
    canvas.drawLine(
      const Offset(0, 0),
      Offset(size.width, size.height),
      narrow,
    );
    canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), narrow);
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      narrow,
    );
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      narrow,
    );
  }

  void _drawStars(
    Canvas canvas,
    Rect rect,
    int rows,
    int columns,
    Color color,
  ) {
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        _drawStar(
          canvas,
          Offset(
            rect.left + (column + .5) * rect.width / columns,
            rect.top + (row + .5) * rect.height / rows,
          ),
          rect.height / rows * .17,
          color,
        );
      }
    }
  }

  void _drawStar(Canvas canvas, Offset center, double radius, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -1.5708 + i * 0.628319;
      final r = i.isEven ? radius : radius * .42;
      final point = Offset(
        center.dx + r * math.cos(angle),
        center.dy + r * math.sin(angle),
      );
      if (i == 0)
        path.moveTo(point.dx, point.dy);
      else
        path.lineTo(point.dx, point.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawSun(Canvas canvas, Offset center, double radius, Color color) {
    canvas.drawCircle(center, radius * .58, Paint()..color = color);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i < 12; i++) {
      final angle = i * 0.523599;
      canvas.drawLine(
        Offset(
          center.dx + radius * .7 * math.cos(angle),
          center.dy + radius * .7 * math.sin(angle),
        ),
        Offset(
          center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle),
        ),
        paint,
      );
    }
  }

  void _drawFlower(Canvas canvas, Offset center, double radius) {
    final paint = Paint()..color = Colors.white;
    for (var i = 0; i < 5; i++) {
      final angle = i * 1.256637 - 1.5708;
      final petal = Offset(
        center.dx + radius * .45 * math.cos(angle),
        center.dy + radius * .45 * math.sin(angle),
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: petal,
          width: radius * .75,
          height: radius * .34,
        ),
        paint,
      );
    }
    canvas.drawCircle(
      center,
      radius * .12,
      Paint()..color = const Color(0xFFDE2910),
    );
  }

  void _drawGlobe(Canvas canvas, Offset center, double radius) {
    final paint = Paint()
      ..color = const Color(0xFF60708A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(center, radius, paint);
    canvas.drawOval(
      Rect.fromCenter(center: center, width: radius, height: radius * 2),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _RegionBadgePainter oldDelegate) =>
      oldDelegate.code != code;
}

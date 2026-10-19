import 'dart:math';

import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/models.dart';
import 'theme.dart';

const _axis = TextStyle(fontSize: 10, color: C.muted);

void _text(Canvas c, String s, Offset at, {TextStyle style = _axis, bool center = false, bool right = false}) {
  final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
  var o = at;
  if (center) o = o.translate(-tp.width / 2, 0);
  if (right) o = o.translate(-tp.width, 0);
  tp.paint(c, o);
}

/// Etykiety godzin na osi czasu nocy.
void _timeAxis(Canvas c, Rect r, DateTime start, DateTime end) {
  final span = end.difference(start).inMinutes;
  if (span <= 0) return;
  final step = span > 300 ? 120 : (span > 120 ? 60 : 30);
  var t = DateTime(start.year, start.month, start.day, start.hour);
  while (t.isBefore(start)) {
    t = t.add(Duration(minutes: step));
  }
  final grid = Paint()
    ..color = C.muted.withValues(alpha: 0.15)
    ..strokeWidth = 1;
  while (t.isBefore(end)) {
    final x = r.left + r.width * t.difference(start).inMinutes / span;
    c.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
    _text(c, hhmm(t), Offset(x, r.bottom + 4), center: true);
    t = t.add(Duration(minutes: step));
  }
}

/// Hipnogram: fazy snu w czasie.
class Hypnogram extends StatelessWidget {
  final List<MinuteSample> minutes;
  final double height;
  const Hypnogram({super.key, required this.minutes, this.height = 150});

  @override
  Widget build(BuildContext context) {
    if (minutes.length < 2) {
      return SizedBox(height: 60, child: Center(child: Text('Za mało danych', style: _axis)));
    }
    return SizedBox(height: height, child: CustomPaint(painter: _HypnoPainter(minutes), size: Size.infinite));
  }
}

class _HypnoPainter extends CustomPainter {
  final List<MinuteSample> ms;
  _HypnoPainter(this.ms);

  @override
  void paint(Canvas c, Size size) {
    const left = 58.0;
    final r = Rect.fromLTWH(left, 0, size.width - left, size.height - 18);
    final rowH = r.height / 4;
    for (final s in Stage.values) {
      _text(c, s.label, Offset(0, r.top + rowH * s.index + rowH / 2 - 6),
          style: TextStyle(fontSize: 10, color: C.stage(s)));
    }
    _timeAxis(c, r, ms.first.ts.subtract(const Duration(minutes: 1)), ms.last.ts);
    final n = ms.length;
    final w = r.width / n;
    for (var i = 0; i < n; i++) {
      final s = ms[i].stage;
      final paint = Paint()..color = C.stage(s);
      final top = r.top + rowH * s.index + 3;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(r.left + i * w, top, w + 0.6, r.bottom - top), const Radius.circular(2)),
        paint..color = C.stage(s).withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HypnoPainter old) => old.ms != ms;
}

/// Oś czasu zdarzeń dźwiękowych (kropki) z głośnością w tle.
class EventTimeline extends StatelessWidget {
  final DateTime start;
  final DateTime end;
  final List<SoundEvent> events;
  final List<MinuteSample> minutes;
  const EventTimeline({super.key, required this.start, required this.end, required this.events, required this.minutes});

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 130, child: CustomPaint(painter: _EventPainter(start, end, events, minutes), size: Size.infinite));
}

class _EventPainter extends CustomPainter {
  final DateTime start, end;
  final List<SoundEvent> evs;
  final List<MinuteSample> ms;
  _EventPainter(this.start, this.end, this.evs, this.ms);

  @override
  void paint(Canvas c, Size size) {
    const left = 58.0;
    final r = Rect.fromLTWH(left, 0, size.width - left, size.height - 18);
    final span = max(1, end.difference(start).inSeconds);
    final types = SoundType.values;
    final rowH = r.height / types.length;
    _timeAxis(c, r, start, end);
    for (final t in types) {
      _text(c, '${t.emoji} ${t.label}', Offset(0, r.top + rowH * t.index + rowH / 2 - 6),
          style: TextStyle(fontSize: 10, color: C.sound(t)));
    }
    // Chrapanie jako pasy minutowe
    final snorePaint = Paint()..color = C.sound(SoundType.snore).withValues(alpha: 0.5);
    for (final m in ms.where((m) => m.snore)) {
      final x = r.left + r.width * m.ts.subtract(const Duration(minutes: 1)).difference(start).inSeconds / span;
      final w = r.width * 60 / span;
      final y = r.top + rowH * SoundType.snore.index + rowH * 0.25;
      c.drawRect(Rect.fromLTWH(x, y, max(1.5, w), rowH * 0.5), snorePaint);
    }
    for (final e in evs) {
      if (e.type == SoundType.snore) continue;
      final x = r.left + r.width * e.ts.difference(start).inSeconds / span;
      final y = r.top + rowH * e.type.index + rowH / 2;
      final p = Paint()..color = e.counts ? C.sound(e.type) : C.muted.withValues(alpha: 0.4);
      c.drawCircle(Offset(x, y), 3.5 + 3 * e.confidence.clamp(0.0, 1.0), p);
    }
  }

  @override
  bool shouldRepaint(covariant _EventPainter old) => true;
}

/// Prosty wykres liniowy (np. luksy w nocy, długość snu w kolejnych nocach).
class LineSeriesChart extends StatelessWidget {
  final List<double?> values;
  final List<String> labels;
  final Color color;
  final String unit;
  final double height;
  final bool logScale;
  final double? goal;
  const LineSeriesChart({
    super.key,
    required this.values,
    this.labels = const [],
    this.color = C.moon,
    this.unit = '',
    this.height = 140,
    this.logScale = false,
    this.goal,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height,
      child: CustomPaint(painter: _LinePainter(values, labels, color, unit, logScale, goal), size: Size.infinite));
}

class _LinePainter extends CustomPainter {
  final List<double?> v;
  final List<String> labels;
  final Color color;
  final String unit;
  final bool logScale;
  final double? goal;
  _LinePainter(this.v, this.labels, this.color, this.unit, this.logScale, this.goal);

  /// Skala logarytmiczna przydaje się dla luksów (0,1 … 500 lx).
  double _t(double x) => logScale ? (x <= 0 ? 0 : log(x + 1) / ln10) : x;

  @override
  void paint(Canvas c, Size size) {
    final pts = v.whereType<double>().toList();
    if (pts.isEmpty) {
      _text(c, 'Brak danych', Offset(size.width / 2, size.height / 2 - 6), center: true);
      return;
    }
    const left = 36.0;
    final r = Rect.fromLTWH(left, 6, size.width - left - 4, size.height - 24);
    var hi = pts.map(_t).reduce(max);
    if (goal != null) hi = max(hi, _t(goal!));
    if (hi <= 0) hi = 1;
    hi *= 1.1;
    final grid = Paint()
      ..color = C.muted.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    for (var k = 0; k <= 2; k++) {
      final y = r.bottom - r.height * k / 2;
      c.drawLine(Offset(r.left, y), Offset(r.right, y), grid);
      final raw = hi * k / 2;
      final val = logScale ? (pow(10, raw) - 1).toDouble() : raw;
      _text(c, val >= 10 ? val.round().toString() : val.toStringAsFixed(1), Offset(r.left - 4, y - 6), right: true);
    }
    if (goal != null) {
      final y = r.bottom - r.height * _t(goal!) / hi;
      c.drawLine(Offset(r.left, y), Offset(r.right, y),
          Paint()
            ..color = C.moon.withValues(alpha: 0.5)
            ..strokeWidth = 1);
    }
    final n = v.length;
    final path = Path();
    var started = false;
    for (var i = 0; i < n; i++) {
      final val = v[i];
      if (val == null) {
        started = false;
        continue;
      }
      final x = n == 1 ? r.center.dx : r.left + r.width * i / (n - 1);
      final y = r.bottom - r.height * _t(val) / hi;
      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
      c.drawCircle(Offset(x, y), n > 60 ? 1.2 : 2.5, Paint()..color = color);
    }
    c.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
    if (labels.isNotEmpty) {
      final every = max(1, (labels.length / 6).ceil());
      for (var i = 0; i < labels.length; i += every) {
        final x = labels.length == 1 ? r.center.dx : r.left + r.width * i / (labels.length - 1);
        _text(c, labels[i], Offset(x, r.bottom + 4), center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

/// Wykres słupkowy (np. bąki na noc, rozkład godzinowy).
class BarSeriesChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;
  final int? highlight;
  const BarSeriesChart(
      {super.key, required this.values, this.labels = const [], this.color = C.gas, this.height = 140, this.highlight});

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height, child: CustomPaint(painter: _BarPainter(values, labels, color, highlight), size: Size.infinite));
}

class _BarPainter extends CustomPainter {
  final List<double> v;
  final List<String> labels;
  final Color color;
  final int? hl;
  _BarPainter(this.v, this.labels, this.color, this.hl);

  @override
  void paint(Canvas c, Size size) {
    if (v.isEmpty) {
      _text(c, 'Brak danych', Offset(size.width / 2, size.height / 2 - 6), center: true);
      return;
    }
    const left = 30.0;
    final r = Rect.fromLTWH(left, 14, size.width - left, size.height - 32);
    var hi = v.reduce(max);
    if (hi <= 0) hi = 1;
    final n = v.length;
    final slot = r.width / n;
    final bw = max(2.0, slot * 0.68);
    _text(c, hi >= 10 ? hi.round().toString() : hi.toStringAsFixed(1), Offset(r.left - 4, r.top - 6), right: true);
    _text(c, '0', Offset(r.left - 4, r.bottom - 6), right: true);
    for (var i = 0; i < n; i++) {
      final h = r.height * v[i] / hi;
      final x = r.left + slot * i + (slot - bw) / 2;
      final paint = Paint()..color = (hl == null || hl == i) ? color : color.withValues(alpha: 0.45);
      c.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTWH(x, r.bottom - h, bw, max(h, 0.5)),
              topLeft: const Radius.circular(4), topRight: const Radius.circular(4)),
          paint);
      if (n <= 14 && v[i] > 0) {
        _text(c, v[i] >= 10 || v[i] == v[i].roundToDouble() ? v[i].round().toString() : v[i].toStringAsFixed(1),
            Offset(x + bw / 2, r.bottom - h - 13), center: true, style: const TextStyle(fontSize: 10, color: C.text));
      }
    }
    if (labels.isNotEmpty) {
      final every = max(1, (labels.length / 8).ceil());
      for (var i = 0; i < labels.length && i < n; i += every) {
        _text(c, labels[i], Offset(r.left + slot * i + slot / 2, r.bottom + 4), center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => true;
}

/// Pierścień z oceną snu.
class ScoreRing extends StatelessWidget {
  final int score;
  final double size;
  const ScoreRing({super.key, required this.score, this.size = 96});

  @override
  Widget build(BuildContext context) {
    final color = score >= 80 ? C.gas : (score >= 60 ? C.moon : C.danger);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(score / 100, color),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$score', style: TextStyle(fontSize: size * 0.32, fontWeight: FontWeight.w700, color: color)),
            Text('ocena', style: TextStyle(fontSize: size * 0.11, color: C.muted)),
          ]),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double f;
  final Color color;
  _RingPainter(this.f, this.color);

  @override
  void paint(Canvas c, Size s) {
    final r = Rect.fromLTWH(6, 6, s.width - 12, s.height - 12);
    final bg = Paint()
      ..color = C.surface2
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9;
    c.drawArc(r, 0, 2 * pi, false, bg);
    c.drawArc(
        r,
        -pi / 2,
        2 * pi * f.clamp(0.0, 1.0),
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 9);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.f != f;
}

/// Pasek proporcji faz snu.
class StageBar extends StatelessWidget {
  final Night n;
  const StageBar({super.key, required this.n});

  @override
  Widget build(BuildContext context) {
    final parts = [
      (Stage.deep, n.deepMin),
      (Stage.light, n.lightMin),
      (Stage.rem, n.remMin),
      (Stage.wake, n.awakeMin),
    ];
    final total = parts.fold<int>(0, (a, b) => a + b.$2);
    if (total == 0) return const SizedBox();
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          height: 12,
          child: Row(children: [
            for (final p in parts)
              if (p.$2 > 0) Expanded(flex: p.$2, child: Container(color: C.stage(p.$1))),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 14, runSpacing: 4, children: [
        for (final p in parts)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: C.stage(p.$1), shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text('${p.$1.label} ${durHM(p.$2)}', style: const TextStyle(fontSize: 12, color: C.muted)),
          ]),
      ]),
    ]);
  }
}

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/models.dart';
import '../engine/sleep_analysis.dart';
import 'theme.dart';

const _axis = TextStyle(fontSize: 10, color: C.muted);

void _text(Canvas c, String s, Offset at, {TextStyle style = _axis, bool center = false, bool right = false}) {
  final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr)..layout();
  var o = at;
  if (center) o = o.translate(-tp.width / 2, 0);
  if (right) o = o.translate(-tp.width, 0);
  tp.paint(c, o);
}

void _dashed(Canvas c, Offset a, Offset b, Paint p, {double dash = 4, double gap = 4}) {
  final len = (b - a).distance;
  final dir = (b - a) / len;
  var d = 0.0;
  while (d < len) {
    final e = min(d + dash, len);
    c.drawLine(a + dir * d, a + dir * e, p);
    d += dash + gap;
  }
}

/// Gładka krzywa przez punkty (Catmull-Rom → Bézier).
Path _smoothPath(List<Offset> pts) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = i > 0 ? pts[i - 1] : pts[i];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
    final c1 = p1 + (p2 - p0) / 6;
    final c2 = p2 - (p3 - p1) / 6;
    path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// Uśrednia serię do maks. [target] punktów (płynniejsza krzywa, szybsze rysowanie).
List<double> _downsample(List<double> v, int target) {
  if (v.length <= target) return v;
  final step = v.length / target;
  return List.generate(target, (i) {
    final a = (i * step).floor();
    final b = min(v.length, ((i + 1) * step).ceil());
    var s = 0.0;
    for (var k = a; k < b; k++) {
      s += v[k];
    }
    return s / max(1, b - a);
  });
}

// =========================================================================
// FALA SNU (jak w Sleep Cycle)
// =========================================================================

/// Główny wykres nocy: płynna fala głębokości snu z gradientem, pod nią
/// pasy zdarzeń dźwiękowych. Przeciągnij palcem, żeby zobaczyć godzinę i fazę.
class SleepWaveGraph extends StatefulWidget {
  final List<MinuteSample> minutes;
  final List<SoundEvent> events;
  final DateTime start;
  final DateTime end;
  final bool showFarts;
  const SleepWaveGraph(
      {super.key,
      required this.minutes,
      required this.events,
      required this.start,
      required this.end,
      this.showFarts = true});

  @override
  State<SleepWaveGraph> createState() => _SleepWaveGraphState();
}

class _SleepWaveGraphState extends State<SleepWaveGraph> {
  double? cursor; // 0..1
  late List<double> depth;

  @override
  void initState() {
    super.initState();
    depth = SleepAnalysis.depthCurve(widget.minutes);
  }

  @override
  void didUpdateWidget(covariant SleepWaveGraph old) {
    super.didUpdateWidget(old);
    if (old.minutes != widget.minutes) depth = SleepAnalysis.depthCurve(widget.minutes);
  }

  void _set(Offset local, double width) {
    const left = _WavePainter.left;
    setState(() => cursor = ((local.dx - left) / (width - left - 4)).clamp(0.0, 1.0).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    if (widget.minutes.length < 3) {
      return const SizedBox(height: 80, child: Center(child: Text('Za mało danych na wykres', style: _axis)));
    }
    String? label;
    if (cursor != null) {
      final i = (cursor! * (widget.minutes.length - 1)).round();
      final m = widget.minutes[i];
      label = '${hhmm(m.ts)} · ${m.stage.label}${m.snore ? ' · chrapanie' : ''}'
          '${m.farts > 0 ? ' · 💨${m.farts}' : ''}${m.apneas > 0 ? ' · 🫁${m.apneas}' : ''}'
          '${m.breathRate != null ? ' · ${m.breathRate!.round()} odd./min' : ''}';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 18,
        child: label == null
            ? const Text('Przeciągnij palcem po wykresie', style: TextStyle(fontSize: 11, color: C.muted))
            : Text(label, style: const TextStyle(fontSize: 12, color: C.text, fontWeight: FontWeight.w600)),
      ),
      const SizedBox(height: 6),
      LayoutBuilder(
        builder: (c, box) => GestureDetector(
          onHorizontalDragStart: (d) => _set(d.localPosition, box.maxWidth),
          onHorizontalDragUpdate: (d) => _set(d.localPosition, box.maxWidth),
          onHorizontalDragEnd: (_) => setState(() => cursor = null),
          onTapDown: (d) => _set(d.localPosition, box.maxWidth),
          onTapUp: (_) => setState(() => cursor = null),
          child: SizedBox(
            height: 240,
            width: box.maxWidth,
            child: CustomPaint(
              painter: _WavePainter(depth, widget.minutes, widget.events, widget.start, widget.end, cursor,
                  widget.showFarts),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _WavePainter extends CustomPainter {
  static const left = 52.0;
  final List<double> depth;
  final List<MinuteSample> ms;
  final List<SoundEvent> evs;
  final DateTime start, end;
  final double? cursor;
  final bool showFarts;
  _WavePainter(this.depth, this.ms, this.evs, this.start, this.end, this.cursor, this.showFarts);

  @override
  void paint(Canvas c, Size size) {
    const waveH = 150.0;
    const laneH = 13.0;
    final r = Rect.fromLTWH(left, 6, size.width - left - 4, waveH);
    final lanesTop = r.bottom + 14;

    // Poziomy: Czuwanie / Sen / Głęboki
    final guide = Paint()
      ..color = C.muted.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    final levels = [(0.0, 'Czuwanie'), (0.5, 'Sen'), (1.0, 'Głęboki')];
    for (final (v, name) in levels) {
      final y = r.top + r.height * v;
      _dashed(c, Offset(r.left, y), Offset(r.right, y), guide);
      _text(c, name, Offset(0, y - 6));
    }

    // Fala
    final d = _downsample(depth, 160);
    final pts = [
      for (var i = 0; i < d.length; i++)
        Offset(r.left + r.width * i / max(1, d.length - 1), r.top + r.height * d[i])
    ];
    final line = _smoothPath(pts);
    final area = Path.from(line)
      ..lineTo(r.right, r.top)
      ..lineTo(r.left, r.top)
      ..close();
    // Wypełnienie między krzywą a „czuwaniem” — im głębiej, tym więcej koloru.
    c.drawPath(
      area,
      Paint()
        ..shader = ui.Gradient.linear(
          r.topCenter,
          r.bottomCenter,
          [const Color(0xFF5EC8F2).withValues(alpha: 0.05), const Color(0xFF4F6BFF).withValues(alpha: 0.35),
            const Color(0xFF7B4DFF).withValues(alpha: 0.55)],
          [0.0, 0.55, 1.0],
        ),
    );
    c.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, const [Color(0xFF9FE7FF), Color(0xFF8C7BFF)]),
    );

    // Pasy zdarzeń
    final span = max(1, end.difference(start).inSeconds);
    double xAt(DateTime t) => r.left + r.width * (t.difference(start).inSeconds / span).clamp(0.0, 1.0).toDouble();
    final lanes = [
      (SoundType.snore, '😴'),
      if (showFarts) (SoundType.fart, '💨'),
      (SoundType.apnea, '🫁'),
      (SoundType.talk, '💬'),
    ];
    for (var li = 0; li < lanes.length; li++) {
      final (type, icon) = lanes[li];
      final y = lanesTop + li * (laneH + 4);
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(r.left, y, r.width, laneH), const Radius.circular(6)),
          Paint()..color = C.surface2.withValues(alpha: 0.7));
      _text(c, icon, Offset(left - 22, y - 1), style: const TextStyle(fontSize: 11));
      final col = C.sound(type);
      if (type == SoundType.snore) {
        final w = max(1.5, r.width * 60 / span);
        for (final m in ms.where((m) => m.snore)) {
          final x = xAt(m.ts.subtract(const Duration(minutes: 1)));
          c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y + 2, w, laneH - 4), const Radius.circular(3)),
              Paint()..color = col.withValues(alpha: 0.75));
        }
      } else {
        for (final e in evs.where((e) =>
            e.type == type ||
            (type == SoundType.talk && e.type == SoundType.cough) ||
            (type == SoundType.apnea && e.type == SoundType.hypopnea))) {
          final x = xAt(e.ts);
          final p = Paint()..color = e.counts ? C.sound(e.type) : C.muted.withValues(alpha: 0.35);
          if (type == SoundType.apnea) {
            c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x - 1.5, y + 1, 3, laneH - 2), const Radius.circular(2)), p);
          } else {
            c.drawCircle(Offset(x, y + laneH / 2), 3.6, p);
          }
        }
      }
    }

    // Oś czasu: start i koniec pogrubione, pełne godziny pomiędzy
    final axisY = lanesTop + lanes.length * (laneH + 4) + 2;
    const bold = TextStyle(fontSize: 11, color: C.text, fontWeight: FontWeight.w700);
    _text(c, hhmm(start), Offset(r.left, axisY), style: bold);
    _text(c, hhmm(end), Offset(r.right, axisY), style: bold, right: true);
    final mins = end.difference(start).inMinutes;
    final step = mins > 360 ? 120 : 60;
    var t = DateTime(start.year, start.month, start.day, start.hour).add(Duration(minutes: step));
    while (t.isBefore(end)) {
      final x = xAt(t);
      if (x - r.left > 34 && r.right - x > 34) _text(c, '${t.hour}', Offset(x, axisY), center: true);
      t = t.add(Duration(minutes: step));
    }

    // Kursor
    if (cursor != null) {
      final x = r.left + r.width * cursor!;
      c.drawLine(Offset(x, r.top), Offset(x, axisY - 2),
          Paint()
            ..color = C.text.withValues(alpha: 0.6)
            ..strokeWidth = 1);
      final i = (cursor! * (d.length - 1)).round();
      c.drawCircle(Offset(x, r.top + r.height * d[i]), 5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.cursor != cursor || old.depth != depth;
}

/// Klasyczny hipnogram (schodki faz) — widok alternatywny.
class Hypnogram extends StatelessWidget {
  final List<MinuteSample> minutes;
  final double height;
  const Hypnogram({super.key, required this.minutes, this.height = 150});

  @override
  Widget build(BuildContext context) {
    if (minutes.length < 2) {
      return const SizedBox(height: 60, child: Center(child: Text('Za mało danych', style: _axis)));
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
    final n = ms.length;
    final w = r.width / n;
    var i = 0;
    while (i < n) {
      var j = i;
      while (j < n && ms[j].stage == ms[i].stage) {
        j++;
      }
      final s = ms[i].stage;
      final y = r.top + rowH * s.index + rowH * 0.18;
      c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(r.left + i * w, y, (j - i) * w, rowH * 0.64), const Radius.circular(5)),
        Paint()..color = C.stage(s),
      );
      i = j;
    }
    _text(c, hhmm(ms.first.ts.subtract(const Duration(minutes: 1))), Offset(r.left, r.bottom + 4));
    _text(c, hhmm(ms.last.ts), Offset(r.right, r.bottom + 4), right: true);
  }

  @override
  bool shouldRepaint(covariant _HypnoPainter old) => old.ms != ms;
}

// =========================================================================
// WYKRESY TRENDÓW
// =========================================================================

/// Gładki wykres liniowy z gradientowym wypełnieniem i linią średniej.
class LineSeriesChart extends StatelessWidget {
  final List<double?> values;
  final List<String> labels;
  final Color color;
  final String unit;
  final double height;
  final bool logScale;
  final double? goal;
  final bool showAverage;
  final String Function(double)? fmt;
  final bool zeroBased;
  const LineSeriesChart({
    super.key,
    required this.values,
    this.labels = const [],
    this.color = C.moon,
    this.unit = '',
    this.height = 150,
    this.logScale = false,
    this.goal,
    this.showAverage = true,
    this.fmt,
    this.zeroBased = true,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height,
      child: CustomPaint(
          painter: _LinePainter(values, labels, color, unit, logScale, goal, showAverage, fmt, zeroBased),
          size: Size.infinite));
}

class _LinePainter extends CustomPainter {
  final List<double?> v;
  final List<String> labels;
  final Color color;
  final String unit;
  final bool logScale;
  final double? goal;
  final bool showAvg;
  final String Function(double)? customFmt;
  final bool zeroBased;
  _LinePainter(this.v, this.labels, this.color, this.unit, this.logScale, this.goal, this.showAvg, this.customFmt,
      this.zeroBased);

  /// Skala logarytmiczna przydaje się dla luksów (0,1 … 500 lx).
  double _t(double x) => logScale ? (x <= 0 ? 0 : log(x + 1) / ln10) : x;
  double _inv(double y) => logScale ? (pow(10, y) - 1).toDouble() : y;

  String _fmt(double x) => customFmt != null ? customFmt!(x) : (x >= 10 ? x.round().toString() : x.toStringAsFixed(1));

  @override
  void paint(Canvas c, Size size) {
    final pts = v.whereType<double>().toList();
    if (pts.isEmpty) {
      _text(c, 'Brak danych', Offset(size.width / 2, size.height / 2 - 6), center: true);
      return;
    }
    final left = customFmt != null ? 44.0 : 32.0;
    final r = Rect.fromLTWH(left, 10, size.width - left - 6, size.height - 30);
    var hi = pts.map(_t).reduce(max);
    var lo = pts.map(_t).reduce(min);
    if (goal != null) {
      hi = max(hi, _t(goal!));
      lo = min(lo, _t(goal!));
    }
    if (logScale) {
      lo = 0;
    } else if (zeroBased) {
      lo = min(0, lo);
    } else {
      final pad = max((hi - lo) * 0.15, 1.0);
      lo -= pad;
      hi += pad * 0.2;
    }
    if (hi - lo <= 0) hi = lo + 1;
    hi += (hi - lo) * 0.12;
    double yOf(double val) => r.bottom - r.height * (_t(val) - lo) / (hi - lo);

    final grid = Paint()
      ..color = C.muted.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var k = 0; k <= 2; k++) {
      final y = r.bottom - r.height * k / 2;
      c.drawLine(Offset(r.left, y), Offset(r.right, y), grid);
      _text(c, _fmt(_inv(lo + (hi - lo) * k / 2)), Offset(r.left - 5, y - 6), right: true);
    }

    final n = v.length;
    double xOf(int i) => n == 1 ? r.center.dx : r.left + r.width * i / (n - 1);

    // Segmenty bez przerw (null przerywa linię)
    final segments = <List<Offset>>[];
    var cur = <Offset>[];
    for (var i = 0; i < n; i++) {
      final val = v[i];
      if (val == null) {
        if (cur.isNotEmpty) segments.add(cur);
        cur = [];
        continue;
      }
      cur.add(Offset(xOf(i), yOf(val)));
    }
    if (cur.isNotEmpty) segments.add(cur);

    for (final seg in segments) {
      final path = _smoothPath(seg);
      if (seg.length > 1) {
        final area = Path.from(path)
          ..lineTo(seg.last.dx, r.bottom)
          ..lineTo(seg.first.dx, r.bottom)
          ..close();
        c.drawPath(
            area,
            Paint()
              ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter,
                  [color.withValues(alpha: 0.38), color.withValues(alpha: 0.0)]));
      }
      c.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round);
      if (n <= 31) {
        for (final p in seg) {
          c.drawCircle(p, 3.2, Paint()..color = C.bg);
          c.drawCircle(
              p,
              3.2,
              Paint()
                ..color = color
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.8);
        }
      }
    }

    if (goal != null) {
      final y = yOf(goal!);
      _dashed(c, Offset(r.left, y), Offset(r.right, y),
          Paint()
            ..color = C.moon.withValues(alpha: 0.7)
            ..strokeWidth = 1.2);
      _text(c, 'cel', Offset(r.right - 2, y - 14), right: true, style: const TextStyle(fontSize: 10, color: C.moon));
    } else if (showAvg && pts.length > 1) {
      final avg = pts.reduce((a, b) => a + b) / pts.length;
      final y = yOf(avg);
      _dashed(c, Offset(r.left, y), Offset(r.right, y),
          Paint()
            ..color = C.text.withValues(alpha: 0.35)
            ..strokeWidth = 1);
      _text(c, 'śr. ${_fmt(avg)}${customFmt != null ? '' : unit}', Offset(r.right - 2, y - 14),
          right: true, style: const TextStyle(fontSize: 10, color: C.text));
    }

    if (labels.isNotEmpty) {
      final every = max(1, (labels.length / 6).ceil());
      for (var i = 0; i < labels.length; i += every) {
        _text(c, labels[i], Offset(xOf(i), r.bottom + 6), center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => true;
}

/// Zaokrąglone słupki z gradientem i przerywaną linią średniej.
class BarSeriesChart extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final Color color;
  final double height;
  final int? highlight;
  final bool showAverage;
  final String Function(double)? fmt;
  const BarSeriesChart({
    super.key,
    required this.values,
    this.labels = const [],
    this.color = C.gas,
    this.height = 150,
    this.highlight,
    this.showAverage = true,
    this.fmt,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height,
      child: CustomPaint(painter: _BarPainter(values, labels, color, highlight, showAverage, fmt), size: Size.infinite));
}

class _BarPainter extends CustomPainter {
  final List<double> v;
  final List<String> labels;
  final Color color;
  final int? hl;
  final bool showAvg;
  final String Function(double)? customFmt;
  _BarPainter(this.v, this.labels, this.color, this.hl, this.showAvg, this.customFmt);

  String _fmt(double x) => customFmt != null
      ? customFmt!(x)
      : (x >= 10 || x == x.roundToDouble() ? x.round().toString() : x.toStringAsFixed(1));

  @override
  void paint(Canvas c, Size size) {
    if (v.isEmpty) {
      _text(c, 'Brak danych', Offset(size.width / 2, size.height / 2 - 6), center: true);
      return;
    }
    const left = 6.0;
    final r = Rect.fromLTWH(left, 18, size.width - left * 2, size.height - 38);
    var hi = v.reduce(max);
    if (hi <= 0) hi = 1;
    final n = v.length;
    final slot = r.width / n;
    final bw = min(26.0, max(3.0, slot * 0.62));
    final radius = Radius.circular(bw / 2);

    // tło „torów” słupków
    for (var i = 0; i < n; i++) {
      final x = r.left + slot * i + (slot - bw) / 2;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, r.top, bw, r.height), radius),
          Paint()..color = C.surface2.withValues(alpha: 0.55));
    }
    for (var i = 0; i < n; i++) {
      final h = max(v[i] > 0 ? bw : 0.0, r.height * v[i] / hi);
      final x = r.left + slot * i + (slot - bw) / 2;
      final rect = Rect.fromLTWH(x, r.bottom - h, bw, h);
      final dim = hl != null && hl != i;
      c.drawRRect(
          RRect.fromRectAndRadius(rect, radius),
          Paint()
            ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, [
              color.withValues(alpha: dim ? 0.45 : 1.0),
              Color.lerp(color, const Color(0xFF4F6BFF), 0.55)!.withValues(alpha: dim ? 0.35 : 0.85),
            ]));
      if (n <= 14 && v[i] > 0) {
        _text(c, _fmt(v[i]), Offset(x + bw / 2, r.bottom - h - 14),
            center: true, style: const TextStyle(fontSize: 10, color: C.text, fontWeight: FontWeight.w600));
      }
    }
    if (showAvg && n > 1) {
      final avg = v.reduce((a, b) => a + b) / n;
      final y = r.bottom - r.height * avg / hi;
      _dashed(c, Offset(r.left, y), Offset(r.right, y),
          Paint()
            ..color = C.text.withValues(alpha: 0.4)
            ..strokeWidth = 1);
      _text(c, 'śr. ${_fmt(avg)}', Offset(r.right, y - 14),
          right: true, style: const TextStyle(fontSize: 10, color: C.text));
    }
    if (labels.isNotEmpty) {
      final every = max(1, (labels.length / 8).ceil());
      for (var i = 0; i < labels.length && i < n; i += every) {
        _text(c, labels[i], Offset(r.left + slot * i + slot / 2, r.bottom + 6), center: true);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarPainter old) => true;
}

// =========================================================================
// OCENA I PROPORCJE
// =========================================================================

/// Pierścień jakości snu z gradientem (jak „Sleep Quality” w Sleep Cycle).
class ScoreRing extends StatelessWidget {
  final int score;
  final double size;
  const ScoreRing({super.key, required this.score, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(score / 100),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$score%',
                style: TextStyle(fontSize: size * 0.27, fontWeight: FontWeight.w700, color: C.text, height: 1.05)),
            Text('jakość', style: TextStyle(fontSize: size * 0.11, color: C.muted)),
          ]),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double f;
  _RingPainter(this.f);

  @override
  void paint(Canvas c, Size s) {
    final stroke = s.width * 0.085;
    final r = Rect.fromLTWH(stroke / 2 + 2, stroke / 2 + 2, s.width - stroke - 4, s.height - stroke - 4);
    c.drawArc(
        r,
        0,
        2 * pi,
        false,
        Paint()
          ..color = C.surface2
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke);
    final sweep = 2 * pi * f.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    c.drawArc(
        r,
        -pi / 2,
        sweep,
        false,
        Paint()
          ..shader = ui.Gradient.sweep(
            r.center,
            const [Color(0xFF5EC8F2), Color(0xFF8C7BFF), C.gas, Color(0xFF5EC8F2)],
            const [0.0, 0.4, 0.8, 1.0],
            TileMode.clamp,
            -pi / 2,
            3 * pi / 2,
          )
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke);
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
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 14,
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
            Text('${p.$1.label} ${durHM(p.$2)} · ${(p.$2 * 100 / total).round()}%',
                style: const TextStyle(fontSize: 12, color: C.muted)),
          ]),
      ]),
    ]);
  }
}

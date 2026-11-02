import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

class ChartPoint {
  final DateTime x;
  final double y;
  const ChartPoint(this.x, this.y);
}

class LineSeries {
  final String name;
  final Color color;
  final List<ChartPoint> points; // rosnąco w czasie
  final bool area; // wypełnienie pod linią
  final bool dots; // kropki w punktach (przy rzadkich danych)
  final bool dashed;
  final String Function(double v)? format;
  const LineSeries(this.name, this.color, this.points, {this.area = false, this.dots = false, this.dashed = false, this.format});
}

/// Wykres liniowy w czasie: rysuje się przy pokazaniu, przesuwanie palcem pokazuje dymek z wartościami
/// wszystkich serii w najbliższym punkcie. Opcjonalnie pasmo normy i linia celu.
class InteractiveLineChart extends StatefulWidget {
  final List<LineSeries> series;
  final (double, double)? band; // pasmo normy (od, do)
  final String? bandLabel;
  final double? goal;
  final String? goalLabel;
  final double height;
  final String Function(double v) yFormat;
  final String Function(DateTime x)? xFormat; // etykieta w dymku
  final double? minY, maxY;
  final bool includeZero;
  final ValueChanged<ChartPoint?>? onSelect;
  const InteractiveLineChart({
    super.key,
    required this.series,
    this.band,
    this.bandLabel,
    this.goal,
    this.goalLabel,
    this.height = 220,
    this.yFormat = plAuto,
    this.xFormat,
    this.minY,
    this.maxY,
    this.includeZero = false,
    this.onSelect,
  });

  @override
  State<InteractiveLineChart> createState() => _InteractiveLineChartState();
}

class _InteractiveLineChartState extends State<InteractiveLineChart> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  DateTime? _sel;

  @override
  void didUpdateWidget(covariant InteractiveLineChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.series, widget.series)) {
      _sel = null;
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _pick(Offset p, Size size, _Geo g) {
    final t = g.xToTime(p.dx);
    DateTime? best;
    var bd = double.infinity;
    for (final s in widget.series) {
      for (final pt in s.points) {
        final d = (pt.x.difference(t).inMilliseconds).abs().toDouble();
        if (d < bd) {
          bd = d;
          best = pt.x;
        }
      }
    }
    if (best != _sel) {
      HapticFeedback.selectionClick();
      setState(() => _sel = best);
      if (widget.onSelect != null) {
        ChartPoint? cp;
        for (final s in widget.series) {
          for (final pt in s.points) {
            if (pt.x == best) cp = pt;
          }
        }
        widget.onSelect!(cp);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = [for (final s in widget.series) ...s.points];
    if (all.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(child: Text('Brak danych w tym okresie', style: TextStyle(color: theme.colorScheme.onSurfaceVariant))),
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      final g = _Geo.of(widget, size, theme);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _pick(d.localPosition, size, g),
        onHorizontalDragStart: (d) => _pick(d.localPosition, size, g),
        onHorizontalDragUpdate: (d) => _pick(d.localPosition, size, g),
        onLongPressMoveUpdate: (d) => _pick(d.localPosition, size, g),
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) => CustomPaint(
            size: size,
            painter: _LinePainter(widget, g, Curves.easeOutCubic.transform(_anim.value), _sel, theme),
          ),
        ),
      );
    });
  }
}

/// Geometria wykresu (wspólna dla rysowania i dotyku).
class _Geo {
  final DateTime t0, t1;
  final double lo, hi;
  final Rect plot;
  final List<double> ticks;
  _Geo(this.t0, this.t1, this.lo, this.hi, this.plot, this.ticks);

  static _Geo of(InteractiveLineChart w, Size size, ThemeData theme) {
    final pts = [for (final s in w.series) ...s.points];
    var t0 = pts.map((p) => p.x).reduce((a, b) => a.isBefore(b) ? a : b);
    var t1 = pts.map((p) => p.x).reduce((a, b) => a.isAfter(b) ? a : b);
    if (!t1.isAfter(t0)) {
      t0 = t0.subtract(const Duration(hours: 12));
      t1 = t1.add(const Duration(hours: 12));
    }
    var lo = pts.map((p) => p.y).reduce(min), hi = pts.map((p) => p.y).reduce(max);
    if (w.band != null) {
      lo = min(lo, w.band!.$1);
      hi = max(hi, w.band!.$2);
    }
    if (w.goal != null) {
      lo = min(lo, w.goal!);
      hi = max(hi, w.goal!);
    }
    if (w.includeZero) {
      lo = min(lo, 0);
      hi = max(hi, 0);
    }
    final pad = (hi - lo).abs() < 1e-9 ? max(1.0, hi.abs() * 0.1) : (hi - lo) * 0.08;
    lo = w.minY ?? (w.includeZero && lo >= 0 ? 0 : lo - pad);
    hi = w.maxY ?? hi + pad;
    final ticks = niceTicks(lo, hi);
    // szerokość etykiet osi Y
    final tp = TextPainter(textDirection: TextDirection.ltr);
    var lw = 0.0;
    for (final t in ticks) {
      tp.text = TextSpan(text: w.yFormat(t), style: theme.textTheme.labelSmall);
      tp.layout();
      lw = max(lw, tp.width);
    }
    final plot = Rect.fromLTRB(lw + 8, 8, size.width - 6, size.height - 22);
    return _Geo(t0, t1, lo, hi, plot, ticks);
  }

  double x(DateTime t) => plot.left + t.difference(t0).inMilliseconds / max(1, t1.difference(t0).inMilliseconds) * plot.width;
  double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
  DateTime xToTime(double px) =>
      t0.add(Duration(milliseconds: ((px - plot.left) / plot.width * t1.difference(t0).inMilliseconds).round()));
}

class _LinePainter extends CustomPainter {
  final InteractiveLineChart w;
  final _Geo g;
  final double t;
  final DateTime? sel;
  final ThemeData theme;
  _LinePainter(this.w, this.g, this.t, this.sel, this.theme);

  TextPainter _tp(String s, TextStyle? st) => TextPainter(text: TextSpan(text: s, style: st), textDirection: TextDirection.ltr)..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    final label = theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant);
    final grid = Paint()
      ..color = cs.outlineVariant.withValues(alpha: 0.5)
      ..strokeWidth = 1;

    // siatka i oś Y
    for (final v in g.ticks) {
      final y = g.y(v);
      canvas.drawLine(Offset(g.plot.left, y), Offset(g.plot.right, y), grid);
      final tp = _tp(w.yFormat(v), label);
      tp.paint(canvas, Offset(g.plot.left - tp.width - 6, y - tp.height / 2));
    }

    // oś X: kilka etykiet
    final days = g.t1.difference(g.t0).inDays;
    final n = max(2, min(5, (g.plot.width / 70).floor()));
    for (var i = 0; i < n; i++) {
      final tt = g.t0.add(Duration(milliseconds: (g.t1.difference(g.t0).inMilliseconds * i / (n - 1)).round()));
      final s = days > 400 ? plMonth(tt) : (days >= 2 ? plDay(tt) : '${tt.hour}:${tt.minute.toString().padLeft(2, '0')}');
      final tp = _tp(s, label);
      final x = (g.x(tt) - tp.width / 2).clamp(g.plot.left - 4, size.width - tp.width).toDouble();
      tp.paint(canvas, Offset(x, g.plot.bottom + 5));
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(g.plot.left - 4, 0, g.plot.left + (g.plot.width + 8) * t, size.height));

    // pasmo normy
    if (w.band != null) {
      final r = Rect.fromLTRB(g.plot.left, g.y(w.band!.$2), g.plot.right, g.y(w.band!.$1));
      canvas.drawRect(r, Paint()..color = Colors.green.withValues(alpha: 0.10));
      if (w.bandLabel != null) _tp(w.bandLabel!, label?.copyWith(color: Colors.green.shade700)).paint(canvas, Offset(g.plot.right - 60, r.top + 2));
    }
    // cel
    if (w.goal != null) {
      final y = g.y(w.goal!);
      final p = Paint()
        ..color = cs.tertiary
        ..strokeWidth = 1.4;
      for (var x = g.plot.left; x < g.plot.right; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(min(x + 4, g.plot.right), y), p);
      }
      if (w.goalLabel != null) _tp(w.goalLabel!, label?.copyWith(color: cs.tertiary)).paint(canvas, Offset(g.plot.left + 4, y - 14));
    }

    for (final s in w.series) {
      if (s.points.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < s.points.length; i++) {
        final o = Offset(g.x(s.points[i].x), g.y(s.points[i].y));
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          // gładka krzywa (punkty kontrolne w połowie odcinka)
          final prev = Offset(g.x(s.points[i - 1].x), g.y(s.points[i - 1].y));
          final mx = (prev.dx + o.dx) / 2;
          path.cubicTo(mx, prev.dy, mx, o.dy, o.dx, o.dy);
        }
      }
      if (s.area) {
        final area = Path.from(path)
          ..lineTo(g.x(s.points.last.x), g.plot.bottom)
          ..lineTo(g.x(s.points.first.x), g.plot.bottom)
          ..close();
        canvas.drawPath(
            area,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [s.color.withValues(alpha: 0.28), s.color.withValues(alpha: 0.02)],
              ).createShader(g.plot));
      }
      final stroke = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (s.dashed) {
        for (final m in path.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += 10) {
            canvas.drawPath(m.extractPath(d, min(d + 6, m.length)), stroke);
          }
        }
      } else {
        canvas.drawPath(path, stroke);
      }
      if (s.dots || s.points.length <= 40) {
        for (final p in s.points) {
          canvas.drawCircle(Offset(g.x(p.x), g.y(p.y)), 2.6, Paint()..color = s.color);
        }
      }
    }
    canvas.restore();

    // zaznaczenie
    final selT = sel;
    if (selT == null) return;
    final x = g.x(selT);
    canvas.drawLine(Offset(x, g.plot.top), Offset(x, g.plot.bottom), Paint()
      ..color = cs.onSurface.withValues(alpha: 0.35)
      ..strokeWidth = 1);
    final lines = <(Color, String)>[];
    for (final s in w.series) {
      for (final p in s.points) {
        if (p.x != selT) continue;
        final o = Offset(x, g.y(p.y));
        canvas.drawCircle(o, 6, Paint()..color = cs.surface);
        canvas.drawCircle(o, 4.5, Paint()..color = s.color);
        lines.add((s.color, '${w.series.length > 1 ? '${s.name}: ' : ''}${(s.format ?? w.yFormat)(p.y)}'));
      }
    }
    if (lines.isEmpty) return;
    final head = (w.xFormat ?? (DateTime d) => g.t1.difference(g.t0).inDays >= 2 ? plDayYear(d) : '${d.hour}:${d.minute.toString().padLeft(2, '0')}')(selT);
    final hs = theme.textTheme.labelSmall?.copyWith(color: cs.onInverseSurface.withValues(alpha: 0.8));
    final vs = theme.textTheme.labelLarge?.copyWith(color: cs.onInverseSurface, fontWeight: FontWeight.w700);
    final tps = [_tp(head, hs), for (final l in lines) _tp(l.$2, vs)];
    final bw = tps.map((e) => e.width).reduce(max) + 20;
    final bh = tps.fold<double>(0, (a, e) => a + e.height) + 12;
    var bx = x + 10;
    if (bx + bw > size.width) bx = x - 10 - bw;
    final box = RRect.fromRectAndRadius(Rect.fromLTWH(bx, g.plot.top, bw, bh), const Radius.circular(10));
    canvas.drawRRect(box, Paint()..color = cs.inverseSurface.withValues(alpha: 0.92));
    var yy = g.plot.top + 6;
    for (var i = 0; i < tps.length; i++) {
      if (i > 0) canvas.drawCircle(Offset(bx + 8, yy + tps[i].height / 2), 3, Paint()..color = lines[i - 1].$1);
      tps[i].paint(canvas, Offset(bx + (i > 0 ? 14 : 8), yy));
      yy += tps[i].height;
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.t != t || old.sel != sel || old.w != w;
}

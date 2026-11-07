import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../cpap/cpap_data.dart';
import '../theme.dart';

/// Kolory zdarzeń (podobne do OSCAR).
Color cpapEventColor(String kind) => switch (kind) {
      'oa' => const Color(0xFF4FA3FF),
      'ca' => const Color(0xFFB98CFF),
      'ua' => const Color(0xFFFF6B6B),
      'h' => const Color(0xFFFFC857),
      'rera' => const Color(0xFF7FD18B),
      'fl' => const Color(0xFF9AA4B2),
      'csr' => const Color(0xFF2FBF71),
      _ => C.muted,
    };

Color cpapSignalColor(String key) => switch (key) {
      'flow' => const Color(0xFF5EC8F2),
      'pressBrp' || 'maskPress' || 'press' => const Color(0xFF7FE3A0),
      'epr' => const Color(0xFF4CB782),
      'leak' => const Color(0xFFFF8F6B),
      'flim' => const Color(0xFFB0B8C8),
      'snore' => const Color(0xFFFFC857),
      'rr' => const Color(0xFFB49BFF),
      'tv' => const Color(0xFF8FD3FF),
      'mv' => const Color(0xFF6FA8FF),
      'spo2' => const Color(0xFFFF6B9A),
      'pulse' => const Color(0xFFFF8FA3),
      _ => const Color(0xFF9FB4D0),
    };

String _two(int v) => v.toString().padLeft(2, '0');
String tLabel(double t, {bool sec = false}) {
  final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
  return sec ? '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}' : '${_two(d.hour)}:${_two(d.minute)}';
}

/// Wspólny widok czasu dla wszystkich wykresów dnia.
class CpapViewport extends ChangeNotifier {
  double minT, maxT; // granice danych
  double t0, t1; // widoczny zakres
  double? cursor;
  CpapViewport(this.minT, this.maxT)
      : t0 = minT,
        t1 = maxT;

  double get span => t1 - t0;

  void set(double a, double b) {
    var s = (b - a).clamp(20.0, max(20.0, maxT - minT));
    var na = a, nb = a + s;
    if (na < minT) {
      na = minT;
      nb = minT + s;
    }
    if (nb > maxT) {
      nb = maxT;
      na = max(minT, maxT - s);
    }
    t0 = na;
    t1 = nb;
    notifyListeners();
  }

  void all() => set(minT, maxT);
  void zoom(double factor, [double? around]) {
    final c = around ?? (cursor != null && cursor! >= t0 && cursor! <= t1 ? cursor! : (t0 + t1) / 2);
    final s = span * factor;
    final f = (c - t0) / span;
    set(c - s * f, c - s * f + s);
  }

  void window(double seconds, [double? center]) {
    final c = center ?? cursor ?? (t0 + t1) / 2;
    set(c - seconds / 2, c + seconds / 2);
  }

  void pan(double dt) => set(t0 + dt, t1 + dt);

  void setCursor(double? t) {
    cursor = t;
    notifyListeners();
  }
}

/// Gesty: przeciąganie w poziomie = przesuwanie, dotknięcie = kursor, dwuklik = powiększenie.
class _Gestures extends StatelessWidget {
  final CpapViewport vp;
  final Widget child;
  final double leftPad;
  const _Gestures({required this.vp, required this.child, this.leftPad = 0});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = max(1.0, box.maxWidth - leftPad);
      double tAt(double x) => vp.t0 + ((x - leftPad) / w).clamp(0.0, 1.0) * vp.span;
      Offset? lastTap;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => vp.pan(-d.delta.dx / w * vp.span),
        onTapDown: (d) => lastTap = d.localPosition,
        onTap: () {
          if (lastTap != null) vp.setCursor(tAt(lastTap!.dx));
        },
        onDoubleTapDown: (d) => lastTap = d.localPosition,
        onDoubleTap: () {
          if (lastTap != null) vp.zoom(1 / 3, tAt(lastTap!.dx));
        },
        child: child,
      );
    });
  }
}

const double kAxisW = 40;

/// Wykres przebiegu (min/max na piksel — szybki nawet dla 25 Hz przez całą noc).
class CpapWaveChart extends StatelessWidget {
  final CpapSeries series;
  final CpapViewport vp;
  final double height;
  final List<CpapEvent> events; // cieniowanie zdarzeń (na wykresie przepływu)
  final List<(double, double)> regions; // np. CSR
  final double? refLine; // np. 24 L/min dla nieszczelności
  final bool symmetric;
  final int decimals;
  const CpapWaveChart({
    super.key,
    required this.series,
    required this.vp,
    this.height = 90,
    this.events = const [],
    this.regions = const [],
    this.refLine,
    this.symmetric = false,
    this.decimals = 1,
  });

  @override
  Widget build(BuildContext context) {
    final col = cpapSignalColor(series.key);
    return AnimatedBuilder(
      animation: vp,
      builder: (context, _) {
        final cv = vp.cursor;
        final atCursor = cv == null ? null : series.at(cv);
        final stats = _visibleStats(series, vp.t0, vp.t1);
        final valText = atCursor != null
            ? '${tLabel(cv!, sec: vp.span < 900)} · ${atCursor.toStringAsFixed(decimals)}'
            : (stats == null ? '' : 'śr. ${stats.$3.toStringAsFixed(decimals)} · ${stats.$1.toStringAsFixed(decimals)}–${stats.$2.toStringAsFixed(decimals)}');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 10, bottom: 2),
            child: Row(children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(series.label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              if (series.unit.isNotEmpty) Text('  ${series.unit}', style: const TextStyle(fontSize: 11, color: C.muted)),
              const Spacer(),
              Text(valText, style: const TextStyle(fontSize: 11, color: C.muted, fontFeatures: [ui.FontFeature.tabularFigures()])),
            ]),
          ),
          _Gestures(
            vp: vp,
            leftPad: kAxisW,
            child: SizedBox(
              height: height,
              child: CustomPaint(
                painter: _WavePainter(series, vp.t0, vp.t1, cv, col, events, regions, refLine, symmetric),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

(double, double, double)? _visibleStats(CpapSeries s, double t0, double t1) {
  var lo = double.infinity, hi = -double.infinity, sum = 0.0;
  var n = 0;
  for (final g in s.segs) {
    if (g.t1 < t0 || g.t0 > t1) continue;
    final a = max(0, ((t0 - g.t0) / g.dt).floor()), b = min(g.v.length, ((t1 - g.t0) / g.dt).ceil());
    final step = max(1, (b - a) ~/ 20000);
    for (var i = a; i < b; i += step) {
      final x = g.v[i];
      if (x.isNaN) continue;
      if (x < lo) lo = x;
      if (x > hi) hi = x;
      sum += x;
      n++;
    }
  }
  return n == 0 ? null : (lo, hi, sum / n);
}

class _WavePainter extends CustomPainter {
  final CpapSeries s;
  final double t0, t1;
  final double? cursor;
  final Color col;
  final List<CpapEvent> events;
  final List<(double, double)> regions;
  final double? refLine;
  final bool symmetric;
  _WavePainter(this.s, this.t0, this.t1, this.cursor, this.col, this.events, this.regions, this.refLine, this.symmetric);

  @override
  void paint(Canvas c, Size size) {
    final w = size.width - kAxisW, h = size.height;
    if (w <= 2 || t1 <= t0) return;
    final plot = Rect.fromLTWH(kAxisW, 0, w, h);
    c.drawRRect(RRect.fromRectAndRadius(plot, const Radius.circular(6)), Paint()..color = C.surface2);
    double xOf(double t) => kAxisW + (t - t0) / (t1 - t0) * w;

    // regiony i zdarzenia
    for (final (a, b) in regions) {
      if (b < t0 || a > t1) continue;
      c.drawRect(Rect.fromLTRB(max(kAxisW, xOf(a)), 0, min(size.width, xOf(b)), h),
          Paint()..color = cpapEventColor('csr').withValues(alpha: 0.18));
    }
    for (final e in events) {
      final a = e.t, b = e.t + max(e.dur, (t1 - t0) / w * 2);
      if (b < t0 || a > t1) continue;
      c.drawRect(Rect.fromLTRB(max(kAxisW, xOf(a)), 0, min(size.width, xOf(b)), h),
          Paint()..color = cpapEventColor(e.kind).withValues(alpha: 0.28));
    }

    // min/max na kolumnę pikseli
    final cols = w.floor();
    final mn = List<double>.filled(cols, double.nan), mx = List<double>.filled(cols, double.nan);
    var lo = double.infinity, hi = -double.infinity;
    var dense = true;
    final pts = <List<Offset>>[];
    for (final g in s.segs) {
      if (g.t1 < t0 || g.t0 > t1) continue;
      final a = max(0, ((t0 - g.t0) / g.dt).floor() - 1), b = min(g.v.length, ((t1 - g.t0) / g.dt).ceil() + 1);
      final perPx = (b - a) / max(1, (min(t1, g.t1) - max(t0, g.t0)) / (t1 - t0) * cols);
      if (perPx < 2) dense = false;
      for (var i = a; i < b; i++) {
        final x = g.v[i];
        if (x.isNaN) continue;
        final t = g.t0 + i * g.dt;
        final ci = ((t - t0) / (t1 - t0) * cols).floor();
        if (ci < 0 || ci >= cols) continue;
        if (mn[ci].isNaN || x < mn[ci]) mn[ci] = x;
        if (mx[ci].isNaN || x > mx[ci]) mx[ci] = x;
        if (x < lo) lo = x;
        if (x > hi) hi = x;
      }
    }
    if (lo == double.infinity) {
      _txt(c, 'brak danych w tym zakresie', Offset(kAxisW + w / 2, h / 2 - 7), center: true);
      _cursor(c, size, xOf);
      return;
    }
    if (refLine != null) hi = max(hi, refLine! * 1.1);
    if (symmetric) {
      final m = max(lo.abs(), hi.abs());
      lo = -m;
      hi = m;
    } else {
      if (lo >= 0 && lo < (hi - lo) * 0.6) lo = 0;
      final pad = (hi - lo) * 0.08;
      hi += pad;
      if (lo != 0) lo -= pad;
    }
    if (hi - lo < 1e-6) {
      hi += 1;
      lo -= 1;
    }
    double yOf(double v) => h - (v - lo) / (hi - lo) * h;

    // siatka i oś
    final grid = Paint()
      ..color = C.muted.withValues(alpha: 0.18)
      ..strokeWidth = 1;
    for (final v in symmetric ? [lo, 0.0, hi] : [lo, (lo + hi) / 2, hi]) {
      final y = yOf(v).clamp(0.0, h);
      c.drawLine(Offset(kAxisW, y), Offset(size.width, y), grid);
      _txt(c, _fmtAxis(v), Offset(kAxisW - 4, (y - 7).clamp(0.0, h - 14)), right: true);
    }
    if (refLine != null) {
      final y = yOf(refLine!);
      _dash(c, Offset(kAxisW, y), Offset(size.width, y), C.danger.withValues(alpha: 0.7));
    }

    final p = Paint()
      ..color = col
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    c.save();
    c.clipRect(plot);
    if (dense) {
      // pionowe kreski min–max + łączenie sąsiednich kolumn
      final path = Path();
      double? prevMx, prevMn;
      for (var i = 0; i < cols; i++) {
        if (mn[i].isNaN) {
          prevMx = prevMn = null;
          continue;
        }
        final x = kAxisW + i + 0.5;
        var a = yOf(mx[i]), b = yOf(mn[i]);
        if (prevMx != null) {
          a = min(a, yOf(prevMn!));
          b = max(b, yOf(prevMx));
        }
        if ((b - a).abs() < 1) b = a + 1;
        path.moveTo(x, a);
        path.lineTo(x, b);
        prevMx = mx[i];
        prevMn = mn[i];
      }
      c.drawPath(path, p);
    } else {
      for (final g in s.segs) {
        if (g.t1 < t0 || g.t0 > t1) continue;
        final a = max(0, ((t0 - g.t0) / g.dt).floor() - 1), b = min(g.v.length, ((t1 - g.t0) / g.dt).ceil() + 1);
        final path = Path();
        var started = false;
        for (var i = a; i < b; i++) {
          final x = g.v[i];
          if (x.isNaN) {
            started = false;
            continue;
          }
          final o = Offset(xOf(g.t0 + i * g.dt), yOf(x));
          if (!started) {
            path.moveTo(o.dx, o.dy);
            started = true;
          } else {
            path.lineTo(o.dx, o.dy);
          }
        }
        c.drawPath(path, p..strokeWidth = 1.6);
      }
    }
    c.restore();
    pts.clear();
    _cursor(c, size, xOf);
  }

  void _cursor(Canvas c, Size size, double Function(double) xOf) {
    if (cursor == null || cursor! < t0 || cursor! > t1) return;
    final x = xOf(cursor!);
    c.drawLine(Offset(x, 0), Offset(x, size.height), Paint()
      ..color = Colors.white.withValues(alpha: 0.8)
      ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(covariant _WavePainter o) =>
      o.t0 != t0 || o.t1 != t1 || o.cursor != cursor || o.s != s || o.events != events;
}

String _fmtAxis(double v) {
  final a = v.abs();
  if (a >= 100) return v.toStringAsFixed(0);
  if (a >= 10) return v.toStringAsFixed(0);
  return v.toStringAsFixed(1);
}

void _txt(Canvas c, String t, Offset o, {bool right = false, bool center = false, Color color = C.muted, double size = 10}) {
  final tp = TextPainter(
    text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)),
    textDirection: TextDirection.ltr,
  )..layout();
  var dx = o.dx;
  if (right) dx -= tp.width;
  if (center) dx -= tp.width / 2;
  tp.paint(c, Offset(dx, o.dy));
}

void _dash(Canvas c, Offset a, Offset b, Color col) {
  final p = Paint()
    ..color = col
    ..strokeWidth = 1;
  const d = 5.0;
  final len = (b - a).distance;
  final dir = (b - a) / len;
  for (var s = 0.0; s < len; s += d * 2) {
    c.drawLine(a + dir * s, a + dir * min(len, s + d), p);
  }
}

/// Pasek flag zdarzeń (jak w OSCAR) z osią czasu.
class CpapFlagsChart extends StatelessWidget {
  final List<CpapEvent> events;
  final List<(double, double)> csr;
  final List<(double, double)> sessions; // okresy z maską
  final CpapViewport vp;
  const CpapFlagsChart({super.key, required this.events, required this.csr, required this.sessions, required this.vp});

  @override
  Widget build(BuildContext context) {
    final kinds = [
      for (final (k, _, short) in cpapEventKinds)
        if (events.any((e) => e.kind == k)) (k, short)
    ];
    if (csr.isNotEmpty) kinds.add(('csr', 'CSR'));
    final rowH = 16.0;
    return AnimatedBuilder(
      animation: vp,
      builder: (context, _) => _Gestures(
        vp: vp,
        leftPad: kAxisW,
        child: SizedBox(
          height: 18 + max(1, kinds.length) * rowH + 18,
          child: CustomPaint(painter: _FlagsPainter(events, csr, sessions, kinds, vp.t0, vp.t1, vp.cursor, rowH)),
        ),
      ),
    );
  }
}

class _FlagsPainter extends CustomPainter {
  final List<CpapEvent> events;
  final List<(double, double)> csr, sessions;
  final List<(String, String)> kinds;
  final double t0, t1, rowH;
  final double? cursor;
  _FlagsPainter(this.events, this.csr, this.sessions, this.kinds, this.t0, this.t1, this.cursor, this.rowH);

  @override
  void paint(Canvas c, Size size) {
    final w = size.width - kAxisW;
    if (w <= 2) return;
    double xOf(double t) => kAxisW + (t - t0) / (t1 - t0) * w;
    // pasek sesji (maska założona)
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(kAxisW, 2, w, 10), const Radius.circular(3)),
        Paint()..color = C.surface2);
    for (final (a, b) in sessions) {
      if (b < t0 || a > t1) continue;
      c.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(max(kAxisW, xOf(a)), 2, min(size.width, xOf(b)), 12), const Radius.circular(3)),
          Paint()..color = const Color(0xFF5EC8F2).withValues(alpha: 0.55));
    }
    _txt(c, 'maska', const Offset(kAxisW - 4, 0), right: true, size: 9);

    for (var r = 0; r < kinds.length; r++) {
      final (k, short) = kinds[r];
      final y = 18 + r * rowH;
      _txt(c, short, Offset(kAxisW - 4, y + 2), right: true, color: cpapEventColor(k), size: 10);
      c.drawLine(Offset(kAxisW, y + rowH / 2), Offset(size.width, y + rowH / 2),
          Paint()..color = C.muted.withValues(alpha: 0.12));
      final col = Paint()..color = cpapEventColor(k);
      if (k == 'csr') {
        for (final (a, b) in csr) {
          if (b < t0 || a > t1) continue;
          c.drawRect(Rect.fromLTRB(max(kAxisW, xOf(a)), y + 3, min(size.width, xOf(b)), y + rowH - 3), col);
        }
        continue;
      }
      for (final e in events) {
        if (e.kind != k || e.t + e.dur < t0 || e.t > t1) continue;
        final x = xOf(e.t);
        final x2 = max(x + 2, xOf(e.t + e.dur));
        c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x, y + 2, min(size.width, x2), y + rowH - 2), const Radius.circular(1.5)),
            col);
      }
    }
    // oś czasu
    final yAxis = 18 + max(1, kinds.length) * rowH + 3;
    final span = t1 - t0;
    final step = <double>[30, 60, 120, 300, 600, 900, 1800, 3600, 7200].firstWhere((s) => span / s <= 6, orElse: () => 7200);
    var t = (t0 / step).ceil() * step;
    while (t <= t1) {
      final x = xOf(t);
      c.drawLine(Offset(x, yAxis - 3), Offset(x, yAxis), Paint()..color = C.muted);
      _txt(c, tLabel(t, sec: step < 60), Offset(x, yAxis), center: true);
      t += step;
    }
    if (cursor != null && cursor! >= t0 && cursor! <= t1) {
      final x = xOf(cursor!);
      c.drawLine(Offset(x, 0), Offset(x, yAxis), Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(covariant _FlagsPainter o) => o.t0 != t0 || o.t1 != t1 || o.cursor != cursor || o.events != events;
}

/// Słupki dzienne (przegląd): wartości [values] (może być kilka warstw — skumulowane),
/// opcjonalna druga seria jako kropki i linia progu.
class DailyBars extends StatelessWidget {
  final List<DateTime> days;
  final List<List<double?>> stacks; // [warstwa][dzień]
  final List<Color> colors;
  final List<double?>? dots;
  final Color dotColor;
  final double? threshold;
  final double height;
  final int? selected;
  final void Function(int)? onSelect;
  final List<int> markers; // indeksy dni ze zmianą ustawień
  const DailyBars({
    super.key,
    required this.days,
    required this.stacks,
    required this.colors,
    this.dots,
    this.dotColor = Colors.white,
    this.threshold,
    this.height = 120,
    this.selected,
    this.onSelect,
    this.markers = const [],
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          if (days.isEmpty || onSelect == null) return;
          final i = ((d.localPosition.dx - kAxisW) / max(1, w - kAxisW) * days.length).floor();
          if (i >= 0 && i < days.length) onSelect!(i);
        },
        child: SizedBox(
          height: height + 16,
          width: w,
          child: CustomPaint(painter: _BarsPainter(days, stacks, colors, dots, dotColor, threshold, selected, markers)),
        ),
      );
    });
  }
}

class _BarsPainter extends CustomPainter {
  final List<DateTime> days;
  final List<List<double?>> stacks;
  final List<Color> colors;
  final List<double?>? dots;
  final Color dotColor;
  final double? threshold;
  final int? selected;
  final List<int> markers;
  _BarsPainter(this.days, this.stacks, this.colors, this.dots, this.dotColor, this.threshold, this.selected, this.markers);

  @override
  void paint(Canvas c, Size size) {
    final n = days.length;
    final w = size.width - kAxisW, h = size.height - 16;
    if (n == 0 || w <= 0) return;
    var hi = 0.0;
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      for (final l in stacks) {
        s += l[i] ?? 0;
      }
      hi = max(hi, s);
      final d = dots?[i];
      if (d != null) hi = max(hi, d);
    }
    if (threshold != null) hi = max(hi, threshold! * 1.15);
    if (hi <= 0) hi = 1;
    hi *= 1.08;
    double yOf(double v) => h - v / hi * h;
    final grid = Paint()..color = C.muted.withValues(alpha: 0.15);
    for (final v in [0.0, hi / 2, hi]) {
      c.drawLine(Offset(kAxisW, yOf(v)), Offset(size.width, yOf(v)), grid);
      _txt(c, _fmtAxis(v), Offset(kAxisW - 4, (yOf(v) - 7).clamp(0.0, h - 12)), right: true);
    }
    final slot = w / n;
    final bw = max(1.0, slot * 0.7);
    for (final m in markers) {
      final x = kAxisW + slot * m;
      _dash(c, Offset(x, 0), Offset(x, h), const Color(0xFFFFC857).withValues(alpha: 0.6));
    }
    for (var i = 0; i < n; i++) {
      var base = 0.0;
      final x = kAxisW + slot * i + (slot - bw) / 2;
      for (var l = 0; l < stacks.length; l++) {
        final v = stacks[l][i];
        if (v == null || v <= 0) continue;
        final r = Rect.fromLTRB(x, yOf(base + v), x + bw, yOf(base));
        c.drawRect(r, Paint()..color = colors[l].withValues(alpha: selected == null || selected == i ? 1 : 0.55));
        base += v;
      }
      final d = dots?[i];
      if (d != null) c.drawCircle(Offset(x + bw / 2, yOf(d)), max(1.5, min(3, bw / 2)), Paint()..color = dotColor);
    }
    if (threshold != null) _dash(c, Offset(kAxisW, yOf(threshold!)), Offset(size.width, yOf(threshold!)), C.danger.withValues(alpha: 0.7));
    if (selected != null && selected! < n) {
      final x = kAxisW + slot * selected! + slot / 2;
      c.drawLine(Offset(x, 0), Offset(x, h), Paint()..color = Colors.white.withValues(alpha: 0.5));
    }
    // daty: pierwsza, środkowa, ostatnia
    String dl(DateTime d) => '${d.day}.${d.month.toString().padLeft(2, '0')}';
    _txt(c, dl(days.first), Offset(kAxisW, h + 2));
    if (n > 2) _txt(c, dl(days[n ~/ 2]), Offset(kAxisW + slot * (n ~/ 2) + slot / 2, h + 2), center: true);
    _txt(c, dl(days.last), Offset(size.width, h + 2), right: true);
  }

  @override
  bool shouldRepaint(covariant _BarsPainter o) => true;
}

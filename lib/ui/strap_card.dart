import 'dart:math';

import 'package:flutter/material.dart';

import '../core/fmt.dart';
import '../core/models.dart';
import 'theme.dart';

const _hrColor = Color(0xFFFF6B8A);
const _irrColor = Color(0xFFFFB74D);
const _afColor = Color(0xFFFF4D6D);
const _pauseColor = Color(0xFFB59BFF);
const _ectColor = Color(0xFF7BE3B0);

/// Tętno i rytm z opaski na tle faz snu: nieregularny rytm (z odstępów RR), napady AF z Polar EKG,
/// pauzy i pobudzenia dodatkowe – w tej samej skali czasu co wykres snu.
class StrapCard extends StatelessWidget {
  final Night night;
  final List<MinuteSample> minutes;
  final List<(DateTime, String, double?, double?)> ext;
  final List<(DateTime, DateTime)> polarAf;
  const StrapCard({super.key, required this.night, required this.minutes, required this.ext, required this.polarAf});

  @override
  Widget build(BuildContext context) {
    final end = night.end ?? DateTime.now();
    final irr = [for (final r in ext) if (r.$2 == 'h10af') (r.$1, r.$1.add(Duration(seconds: ((r.$4 ?? 0) * 60).round())))];
    final pauses = [for (final r in ext) if (r.$2 == 'h10pa') (r.$1, r.$3 ?? 2)];
    final ect = [for (final r in ext) if (r.$2 == 'h10pv') r.$1];
    final af = [
      for (final (a, b) in polarAf)
        if (a.isBefore(end) && b.isAfter(night.start)) (a.isBefore(night.start) ? night.start : a, b.isAfter(end) ? end : b)
    ];
    final afMin = af.fold<int>(0, (s, e) => s + e.$2.difference(e.$1).inMinutes);
    final irrMin = irr.fold<int>(0, (s, e) => s + e.$2.difference(e.$1).inMinutes);
    final hasStrap = ext.any((r) => r.$2.startsWith('h10')) || minutes.any((m) => m.hr != null);
    final longest = pauses.isEmpty ? null : pauses.map((p) => p.$2).reduce(max);

    return Section(
      title: 'Tętno i rytm',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          height: 150,
          child: CustomPaint(painter: _StrapPainter(night.start, end, minutes, irr, af, pauses, ect)),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 4, children: [
          _legend(_hrColor, 'tętno'),
          if (irr.isNotEmpty) _legend(_irrColor, 'nieregularny rytm'),
          if (af.isNotEmpty) _legend(_afColor, 'AF w EKG'),
          if (pauses.isNotEmpty) _legend(_pauseColor, 'pauza ≥ 2 s'),
          if (ect.isNotEmpty) _legend(_ectColor, 'pobudzenie dodatkowe'),
        ]),
        const SizedBox(height: 10),
        TileGrid(columns: 3, children: [
          StatTile(label: 'Tętno śr.', value: night.hrAvg == null ? '—' : '${night.hrAvg!.round()}', color: _hrColor),
          StatTile(label: 'Tętno min.', value: night.hrMin == null ? '—' : '${night.hrMin!.round()}', color: _hrColor),
          StatTile(label: 'Pauzy ≥ 2 s', value: '${pauses.length}', sub: longest == null ? null : 'maks. ${longest.toStringAsFixed(1)} s', color: _pauseColor),
          StatTile(label: 'Pobudzenia dodatkowe', value: '${ect.length}', color: _ectColor),
          StatTile(label: 'Nieregularny rytm', value: durHM(irrMin), color: _irrColor),
          StatTile(label: 'AF (Polar EKG)', value: af.isEmpty ? '—' : durHM(afMin), color: _afColor),
        ]),
        const SizedBox(height: 8),
        Text(
          hasStrap
              ? 'Z odstępów RR opaski. Nieregularny rytm to przesiew – potwierdza go EKG (Polar EKG nagrywany tej nocy). '
                  'Pojedyncze pobudzenia dodatkowe i krótkie pauzy we śnie zdarzają się u zdrowych osób.'
              : 'Brak danych z opaski tej nocy. Wybierz opaskę w Ustawieniach → Opaska na klatkę piersiową.',
          style: const TextStyle(fontSize: 11, color: C.muted),
        ),
      ]),
    );
  }

  Widget _legend(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(t, style: const TextStyle(fontSize: 11, color: C.muted)),
      ]);
}

class _StrapPainter extends CustomPainter {
  final DateTime start, end;
  final List<MinuteSample> ms;
  final List<(DateTime, DateTime)> irr, af;
  final List<(DateTime, double)> pauses;
  final List<DateTime> ect;
  _StrapPainter(this.start, this.end, this.ms, this.irr, this.af, this.pauses, this.ect);

  @override
  void paint(Canvas canvas, Size size) {
    const stageH = 10.0, bottom = 16.0;
    final span = max(1, end.difference(start).inSeconds).toDouble();
    double x(DateTime t) => (t.difference(start).inSeconds / span * size.width).clamp(0, size.width).toDouble();
    final top = stageH + 6, h = size.height - bottom - top;

    // fazy snu
    for (final m in ms) {
      final c = switch (m.stage) { Stage.deep => C.deep, Stage.light => C.light, Stage.rem => C.rem, Stage.wake => C.wake };
      final a = x(m.ts.subtract(const Duration(minutes: 1))), b = x(m.ts);
      canvas.drawRect(Rect.fromLTRB(a, 0, max(a + 0.5, b), stageH), Paint()..color = c);
    }
    // pasma: nieregularny rytm i AF z EKG
    for (final (a, b) in irr) {
      canvas.drawRect(Rect.fromLTRB(x(a), top, max(x(a) + 1, x(b)), top + h), Paint()..color = _irrColor.withValues(alpha: 0.25));
    }
    for (final (a, b) in af) {
      canvas.drawRect(Rect.fromLTRB(x(a), top, max(x(a) + 1, x(b)), top + h), Paint()..color = _afColor.withValues(alpha: 0.35));
    }
    // tętno
    final pts = [for (final m in ms) if (m.hr != null) (m.ts, m.hr!)];
    if (pts.isNotEmpty) {
      final lo = (pts.map((e) => e.$2).reduce(min) - 5).floorToDouble();
      final hi = (pts.map((e) => e.$2).reduce(max) + 5).ceilToDouble();
      double y(double v) => top + h - (v - lo) / max(1, hi - lo) * h;
      final path = Path();
      DateTime? prev;
      for (final (t, v) in pts) {
        if (prev == null || t.difference(prev).inMinutes > 3) {
          path.moveTo(x(t), y(v));
        } else {
          path.lineTo(x(t), y(v));
        }
        prev = t;
      }
      canvas.drawPath(path, Paint()
        ..color = _hrColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6);
      _text(canvas, '${hi.round()}', Offset(2, top));
      _text(canvas, '${lo.round()}', Offset(2, top + h - 12));
    }
    // pauzy i pobudzenia dodatkowe
    for (final (t, _) in pauses) {
      canvas.drawLine(Offset(x(t), top + h * 0.55), Offset(x(t), top + h), Paint()
        ..color = _pauseColor
        ..strokeWidth = 1.5);
    }
    for (final t in ect) {
      canvas.drawCircle(Offset(x(t), top + h - 3), 1.6, Paint()..color = _ectColor);
    }
    // oś czasu
    var t = DateTime(start.year, start.month, start.day, start.hour + 1);
    while (t.isBefore(end)) {
      if (t.hour % 2 == 0) _text(canvas, '${t.hour}', Offset(x(t) - 4, size.height - 13));
      t = t.add(const Duration(hours: 1));
    }
  }

  void _text(Canvas c, String s, Offset o) {
    final tp = TextPainter(text: TextSpan(text: s, style: const TextStyle(fontSize: 10, color: C.muted)), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _StrapPainter old) => true;
}

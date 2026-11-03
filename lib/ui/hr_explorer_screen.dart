import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/fmt.dart';
import '../core/models.dart';
import '../core/strap.dart';
import 'strap_card.dart';
import 'theme.dart';

/// Dokładny przegląd tętna z nocy: powiększanie (dwa palce, przyciski), przesuwanie, kursor z odczytem.
/// Przy powiększeniu do ≤ 20 min, gdy opaska była połączona z Rytmem Snu, widać tętno uderzenie po uderzeniu (z odstępów RR).
class HrExplorerScreen extends StatefulWidget {
  final Night night;
  final List<MinuteSample> minutes;
  final List<(DateTime, DateTime)> irr, af;
  final List<(DateTime, double)> pauses;
  final List<DateTime> ect;
  const HrExplorerScreen({
    super.key,
    required this.night,
    required this.minutes,
    required this.irr,
    required this.af,
    required this.pauses,
    required this.ect,
  });

  @override
  State<HrExplorerScreen> createState() => _HrExplorerScreenState();
}

/// Uderzenie: czas (ms) i tętno chwilowe.
typedef Beat = (double, double);

const _beatWindowMs = 20 * 60000.0; // poniżej tego okna rysujemy uderzenia
const _minWindowMs = 60000.0;

class _HrExplorerScreenState extends State<HrExplorerScreen> {
  late final double t0 = widget.night.start.millisecondsSinceEpoch.toDouble();
  late final double t1 = (widget.night.end ?? DateTime.now()).millisecondsSinceEpoch.toDouble();
  late double vs = t0, ve = t1;
  double? cursor;
  List<Beat> beats = const [];
  bool loading = true;

  // stan gestu
  double _gs = 0, _ge = 0, _gw = 1, _gx = 0;

  late final List<(double, double)> mins = [
    for (final m in widget.minutes)
      if (m.hr != null) (m.ts.millisecondsSinceEpoch - 30000.0, m.hr!)
  ];

  @override
  void initState() {
    super.initState();
    _loadBeats();
  }

  Future<void> _loadBeats() async {
    final id = widget.night.id;
    final rr = id == null ? const <(DateTime, double)>[] : await Strap.loadRr(id);
    final out = <Beat>[];
    for (final (t, v) in rr) {
      if (v < 260 || v > 2400) continue;
      out.add((t.millisecondsSinceEpoch.toDouble(), 60000 / v));
    }
    if (!mounted) return;
    setState(() {
      beats = out;
      loading = false;
    });
  }

  double get _span => ve - vs;

  void _setWindow(double s, double e, {bool haptic = false}) {
    var w = (e - s).clamp(_minWindowMs, t1 - t0);
    var a = s;
    if (a < t0) a = t0;
    if (a + w > t1) a = t1 - w;
    setState(() {
      vs = a;
      ve = a + w;
    });
    if (haptic) HapticFeedback.selectionClick();
  }

  void _zoomTo(double widthMs) {
    final c = cursor ?? (vs + ve) / 2;
    _setWindow(c - widthMs / 2, c + widthMs / 2, haptic: true);
  }

  void _step(int dir) => _setWindow(vs + dir * _span * 0.5, ve + dir * _span * 0.5, haptic: true);

  // --------------------------------------------------------------- odczyt

  MinuteSample? _minuteAt(double t) {
    MinuteSample? best;
    for (final m in widget.minutes) {
      final e = m.ts.millisecondsSinceEpoch.toDouble();
      if (t <= e && t > e - 60000) return m;
      if (best == null || (e - 30000 - t).abs() < (best.ts.millisecondsSinceEpoch - 30000 - t).abs()) best = m;
    }
    return best != null && (best.ts.millisecondsSinceEpoch - 30000 - t).abs() < 90000 ? best : null;
  }

  Beat? _beatAt(double t) {
    if (beats.isEmpty) return null;
    var lo = 0, hi = beats.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (beats[mid].$1 < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    Beat b = beats[lo];
    if (lo > 0 && (beats[lo - 1].$1 - t).abs() < (b.$1 - t).abs()) b = beats[lo - 1];
    return (b.$1 - t).abs() < 5000 ? b : null;
  }

  bool _inside(List<(DateTime, DateTime)> l, double t) =>
      l.any((e) => t >= e.$1.millisecondsSinceEpoch && t <= e.$2.millisecondsSinceEpoch);

  String _clock(double ms, {bool sec = false}) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms.round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}${sec ? ':${two(d.second)}' : ''}';
  }

  Widget _readout() {
    final t = cursor;
    if (t == null) {
      return const Text('Dotknij wykresu, żeby odczytać wartości. Dwa palce – powiększenie, jeden – przesuwanie.',
          style: TextStyle(fontSize: 12, color: C.muted));
    }
    final m = _minuteAt(t);
    final b = _span <= _beatWindowMs ? _beatAt(t) : null;
    final parts = <String>[
      if (b != null) 'tętno ${b.$2.round()} (uderzenie)',
      if (m?.hr != null) '${b != null ? 'minuta' : 'tętno'} ${m!.hr!.round()}',
      if (m?.hrv != null) 'HRV ${m!.hrv!.round()} ms',
      if (m != null) m.stage.label.toLowerCase(),
      if (m?.breathRate != null) 'oddech ${m!.breathRate!.round()}/min',
      if (m?.strapAct != null) 'ruch ${m!.strapAct} s',
    ];
    final flags = <(Color, String)>[
      if (_inside(widget.af, t)) (afColor, 'AF w EKG'),
      if (_inside(widget.irr, t)) (irrColor, 'nieregularny rytm'),
      for (final (p, s) in widget.pauses)
        if ((p.millisecondsSinceEpoch - t).abs() < max(4000, _span / 150)) (pauseColor, 'pauza ${s.toStringAsFixed(1)} s'),
      if (widget.ect.any((e) => (e.millisecondsSinceEpoch - t).abs() < max(3000, _span / 150))) (ectColor, 'pobudzenie dodatkowe'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_clock(t, sec: _span <= 3600000), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: C.text)),
      const SizedBox(height: 2),
      Text(parts.isEmpty ? 'brak danych w tej chwili' : parts.join(' · '), style: const TextStyle(fontSize: 13, color: C.text)),
      if (flags.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: [
          for (final (c, s) in flags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: c.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8)),
              child: Text(s, style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w600)),
            ),
        ]),
      ],
    ]);
  }

  Widget _windowStats() {
    final useBeats = _span <= _beatWindowMs && beats.isNotEmpty;
    final vals = useBeats
        ? [for (final b in beats) if (b.$1 >= vs && b.$1 <= ve) b.$2]
        : [for (final p in mins) if (p.$1 >= vs && p.$1 <= ve) p.$2];
    final afMs = widget.af.fold<double>(0, (s, e) {
      final a = max(vs, e.$1.millisecondsSinceEpoch.toDouble()), b = min(ve, e.$2.millisecondsSinceEpoch.toDouble());
      return s + max(0, b - a);
    });
    String f(double? v) => v == null ? '—' : '${v.round()}';
    final avg = vals.isEmpty ? null : vals.reduce((a, b) => a + b) / vals.length;
    return TileGrid(columns: 4, children: [
      StatTile(label: 'Średnio', value: f(avg), color: hrColor),
      StatTile(label: 'Min.', value: f(vals.isEmpty ? null : vals.reduce(min)), color: hrColor),
      StatTile(label: 'Maks.', value: f(vals.isEmpty ? null : vals.reduce(max)), color: hrColor),
      afMs > 0
          ? StatTile(label: 'AF', value: durHM(afMs / 60000), color: afColor)
          : StatTile(label: useBeats ? 'Uderzeń' : 'Minut', value: '${vals.length}'),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final presets = <(String, double)>[('Noc', t1 - t0), ('2 h', 7200000), ('30 min', 1800000), ('5 min', 300000)];
    final beatsShown = _span <= _beatWindowMs && beats.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text('Tętno · ${dayLabel(widget.night.start)}')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
        Row(children: [
          Expanded(
            child: Text('${_clock(vs, sec: _span < 600000)} – ${_clock(ve, sec: _span < 600000)}',
                style: const TextStyle(fontSize: 13, color: C.muted)),
          ),
          IconButton(onPressed: vs > t0 ? () => _step(-1) : null, icon: const Icon(Icons.chevron_left), tooltip: 'Wcześniej'),
          IconButton(onPressed: () => _zoomTo(_span * 2), icon: const Icon(Icons.zoom_out), tooltip: 'Pomniejsz'),
          IconButton(onPressed: () => _zoomTo(_span / 2), icon: const Icon(Icons.zoom_in), tooltip: 'Powiększ'),
          IconButton(onPressed: ve < t1 ? () => _step(1) : null, icon: const Icon(Icons.chevron_right), tooltip: 'Później'),
        ]),
        SizedBox(
          height: 300,
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            double tAt(double x) => vs + (x / w).clamp(0.0, 1.0) * _span;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onScaleStart: (d) {
                _gs = vs;
                _ge = ve;
                _gw = _span;
                _gx = d.localFocalPoint.dx;
              },
              onScaleUpdate: (d) {
                final scale = d.pointerCount >= 2 ? d.horizontalScale.clamp(0.05, 20.0) : 1.0;
                final nw = (_gw / scale).clamp(_minWindowMs, t1 - t0);
                // punkt pod palcami zostaje pod palcami
                final anchor = _gs + (_gx / w) * (_ge - _gs);
                final s = anchor - (d.localFocalPoint.dx / w) * nw;
                _setWindow(s, s + nw);
              },
              onTapDown: (d) => setState(() => cursor = tAt(d.localPosition.dx)),
              onLongPressStart: (d) => setState(() => cursor = tAt(d.localPosition.dx)),
              onLongPressMoveUpdate: (d) => setState(() => cursor = tAt(d.localPosition.dx)),
              onDoubleTapDown: (d) => cursor = tAt(d.localPosition.dx),
              onDoubleTap: () => _zoomTo(_span / 3),
              child: CustomPaint(
                size: Size(w, 300),
                painter: _HrPainter(
                  vs: vs,
                  ve: ve,
                  minutes: widget.minutes,
                  mins: mins,
                  beats: beatsShown ? beats : const [],
                  irr: widget.irr,
                  af: widget.af,
                  pauses: widget.pauses,
                  ect: widget.ect,
                  cursor: cursor,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        // podgląd całej nocy z zaznaczonym oknem – przeciągnij, żeby przesunąć
        SizedBox(
          height: 44,
          child: LayoutBuilder(builder: (context, c) {
            final w = c.maxWidth;
            void center(double x) {
              final t = t0 + (x / w).clamp(0.0, 1.0) * (t1 - t0);
              _setWindow(t - _span / 2, t + _span / 2);
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => center(d.localPosition.dx),
              onHorizontalDragUpdate: (d) => center(d.localPosition.dx),
              child: CustomPaint(size: Size(w, 44), painter: _OverviewPainter(t0, t1, vs, ve, mins, widget.af)),
            );
          }),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final (l, ms) in presets)
            ChoiceChip(
              label: Text(l),
              selected: (_span - min(ms, t1 - t0)).abs() < 1000,
              onSelected: (_) => _zoomTo(ms),
            ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14)),
          child: _readout(),
        ),
        const SizedBox(height: 12),
        _windowStats(),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 4, children: [
          _legend(hrColor, beatsShown ? 'tętno uderzenie po uderzeniu' : 'tętno (średnia minuty)'),
          if (widget.irr.isNotEmpty) _legend(irrColor, 'nieregularny rytm'),
          if (widget.af.isNotEmpty) _legend(afColor, 'AF w EKG'),
          if (widget.pauses.isNotEmpty) _legend(pauseColor, 'pauza ≥ 2 s'),
          if (widget.ect.isNotEmpty) _legend(ectColor, 'pobudzenie dodatkowe'),
        ]),
        const SizedBox(height: 8),
        Text(
          loading
              ? 'Wczytywanie odstępów RR…'
              : beats.isEmpty
                  ? 'Tętno minutowe. Uderzenia (odstępy RR) są zapisywane, gdy opaska jest połączona z Rytmem Snu.'
                  : 'Powiększ do 20 min lub mniej, żeby zobaczyć każde uderzenie serca (${beats.length} zapisanych). '
                      'Dwukrotne dotknięcie powiększa w tym miejscu.',
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

/// Krok podziałki czasu, żeby wyszło ok. 4–7 etykiet.
double _tickStep(double span) {
  const steps = [5e3, 15e3, 30e3, 60e3, 120e3, 300e3, 600e3, 900e3, 1800e3, 3600e3, 7200e3];
  for (final s in steps) {
    if (span / s <= 7) return s;
  }
  return 7200e3;
}

class _HrPainter extends CustomPainter {
  final double vs, ve;
  final List<MinuteSample> minutes;
  final List<(double, double)> mins;
  final List<Beat> beats;
  final List<(DateTime, DateTime)> irr, af;
  final List<(DateTime, double)> pauses;
  final List<DateTime> ect;
  final double? cursor;
  _HrPainter({
    required this.vs,
    required this.ve,
    required this.minutes,
    required this.mins,
    required this.beats,
    required this.irr,
    required this.af,
    required this.pauses,
    required this.ect,
    required this.cursor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stageH = 12.0, bottom = 18.0, left = 26.0;
    final w = size.width - left;
    final span = max(1.0, ve - vs);
    double x(double t) => left + ((t - vs) / span * w).clamp(-2.0, w + 2);
    final top = stageH + 8, h = size.height - bottom - top;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    // fazy snu
    for (final m in minutes) {
      final e = m.ts.millisecondsSinceEpoch.toDouble();
      if (e < vs || e - 60000 > ve) continue;
      final a = x(e - 60000), b = x(e);
      canvas.drawRect(Rect.fromLTRB(a, 0, max(a + 0.5, b), stageH), Paint()..color = C.stage(m.stage));
    }
    // pasma
    void band(List<(DateTime, DateTime)> l, Color c, double alpha) {
      for (final (a, b) in l) {
        final s = a.millisecondsSinceEpoch.toDouble(), e = b.millisecondsSinceEpoch.toDouble();
        if (e < vs || s > ve) continue;
        canvas.drawRect(Rect.fromLTRB(x(s), top, max(x(s) + 1.5, x(e)), top + h), Paint()..color = c.withValues(alpha: alpha));
      }
    }

    band(irr, irrColor, 0.22);
    band(af, afColor, 0.32);

    // skala pionowa z widocznych danych
    final vis = beats.isNotEmpty
        ? [for (final b in beats) if (b.$1 >= vs && b.$1 <= ve) b.$2]
        : [for (final p in mins) if (p.$1 >= vs - 60000 && p.$1 <= ve + 60000) p.$2];
    if (vis.isNotEmpty) {
      final s = [...vis]..sort();
      // przy uderzeniach pomijamy skrajne 1% (artefakty), żeby nie spłaszczyć wykresu
      final lo0 = beats.isNotEmpty ? s[(s.length * 0.01).floor()] : s.first;
      final hi0 = beats.isNotEmpty ? s[min(s.length - 1, (s.length * 0.99).ceil())] : s.last;
      final lo = ((lo0 - 6) / 5).floorToDouble() * 5, hi = ((hi0 + 6) / 5).ceilToDouble() * 5;
      double y(double v) => (top + h - (v - lo) / max(1, hi - lo) * h).clamp(top, top + h).toDouble();

      // siatka pozioma
      final gstep = (hi - lo) > 60 ? 20.0 : 10.0;
      for (var v = (lo / gstep).ceil() * gstep; v <= hi; v += gstep) {
        canvas.drawLine(Offset(left, y(v)), Offset(size.width, y(v)), Paint()
          ..color = C.surface2
          ..strokeWidth = 1);
        _text(canvas, '${v.round()}', Offset(0, y(v) - 6));
      }

      final line = Paint()
        ..color = hrColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = beats.isNotEmpty ? 1.2 : 1.8
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      if (beats.isNotEmpty) {
        double? prev;
        for (final (t, v) in beats) {
          if (t < vs - 5000 || t > ve + 5000) continue;
          if (prev == null || t - prev > 4000) {
            path.moveTo(x(t), y(v));
          } else {
            path.lineTo(x(t), y(v));
          }
          prev = t;
        }
        canvas.drawPath(path, line);
        if (span <= 5 * 60000) {
          final dot = Paint()..color = hrColor;
          for (final (t, v) in beats) {
            if (t >= vs && t <= ve) canvas.drawCircle(Offset(x(t), y(v)), 2, dot);
          }
        }
      } else {
        double? prev;
        for (final (t, v) in mins) {
          if (t < vs - 180000 || t > ve + 180000) continue;
          if (prev == null || t - prev > 180000) {
            path.moveTo(x(t), y(v));
          } else {
            path.lineTo(x(t), y(v));
          }
          prev = t;
        }
        canvas.drawPath(path, line);
        if (span <= 3 * 3600000) {
          final dot = Paint()..color = hrColor;
          for (final (t, v) in mins) {
            if (t >= vs && t <= ve) canvas.drawCircle(Offset(x(t), y(v)), span <= 3600000 ? 2.4 : 1.5, dot);
          }
        }
      }
    } else {
      _text(canvas, 'brak tętna w tym przedziale', Offset(left + 8, top + h / 2 - 6));
    }

    // pauzy i pobudzenia dodatkowe
    for (final (t, _) in pauses) {
      final m = t.millisecondsSinceEpoch.toDouble();
      if (m < vs || m > ve) continue;
      canvas.drawLine(Offset(x(m), top + h * 0.5), Offset(x(m), top + h), Paint()
        ..color = pauseColor
        ..strokeWidth = 2);
    }
    for (final t in ect) {
      final m = t.millisecondsSinceEpoch.toDouble();
      if (m < vs || m > ve) continue;
      canvas.drawCircle(Offset(x(m), top + h - 4), 2.4, Paint()..color = ectColor);
    }

    // oś czasu
    final step = _tickStep(span);
    final off = DateTime.fromMillisecondsSinceEpoch(vs.round()).timeZoneOffset.inMilliseconds;
    for (var t = ((vs + off) / step).ceil() * step - off; t <= ve; t += step) {
      final d = DateTime.fromMillisecondsSinceEpoch(t.round());
      String two(int v) => v.toString().padLeft(2, '0');
      final label = step < 60000 ? '${two(d.hour)}:${two(d.minute)}:${two(d.second)}' : '${two(d.hour)}:${two(d.minute)}';
      canvas.drawLine(Offset(x(t), top), Offset(x(t), top + h), Paint()
        ..color = C.surface2.withValues(alpha: 0.6)
        ..strokeWidth = 1);
      _text(canvas, label, Offset(x(t) - (step < 60000 ? 22 : 14), size.height - 14));
    }

    // kursor
    if (cursor != null && cursor! >= vs && cursor! <= ve) {
      canvas.drawLine(Offset(x(cursor!), 0), Offset(x(cursor!), top + h), Paint()
        ..color = C.text.withValues(alpha: 0.7)
        ..strokeWidth = 1);
    }
    canvas.restore();
  }

  void _text(Canvas c, String s, Offset o) {
    final tp = TextPainter(text: TextSpan(text: s, style: const TextStyle(fontSize: 10, color: C.muted)), textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, o);
  }

  @override
  bool shouldRepaint(covariant _HrPainter o) =>
      o.vs != vs || o.ve != ve || o.cursor != cursor || o.beats.length != beats.length;
}

class _OverviewPainter extends CustomPainter {
  final double t0, t1, vs, ve;
  final List<(double, double)> mins;
  final List<(DateTime, DateTime)> af;
  _OverviewPainter(this.t0, this.t1, this.vs, this.ve, this.mins, this.af);

  @override
  void paint(Canvas canvas, Size size) {
    final span = max(1.0, t1 - t0);
    double x(double t) => ((t - t0) / span * size.width).clamp(0.0, size.width);
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.drawRRect(r, Paint()..color = C.surface);
    for (final (a, b) in af) {
      canvas.drawRect(Rect.fromLTRB(x(a.millisecondsSinceEpoch.toDouble()), 0, max(x(a.millisecondsSinceEpoch.toDouble()) + 1.5, x(b.millisecondsSinceEpoch.toDouble())), size.height),
          Paint()..color = afColor.withValues(alpha: 0.4));
    }
    if (mins.isNotEmpty) {
      final lo = mins.map((e) => e.$2).reduce(min) - 3, hi = mins.map((e) => e.$2).reduce(max) + 3;
      double y(double v) => size.height - 4 - (v - lo) / max(1, hi - lo) * (size.height - 8);
      final p = Path();
      double? prev;
      for (final (t, v) in mins) {
        if (prev == null || t - prev > 180000) {
          p.moveTo(x(t), y(v));
        } else {
          p.lineTo(x(t), y(v));
        }
        prev = t;
      }
      canvas.drawPath(p, Paint()
        ..color = hrColor.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1);
    }
    final win = Rect.fromLTRB(x(vs), 0, max(x(vs) + 3, x(ve)), size.height);
    canvas.drawRect(win, Paint()..color = C.text.withValues(alpha: 0.12));
    canvas.drawRect(win, Paint()
      ..color = C.text.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2);
  }

  @override
  bool shouldRepaint(covariant _OverviewPainter o) => o.vs != vs || o.ve != ve;
}

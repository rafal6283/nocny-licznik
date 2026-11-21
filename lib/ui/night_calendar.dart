import 'package:flutter/material.dart';

import '../core/models.dart';
import 'chart_fx.dart';
import 'night_detail_screen.dart';
import 'theme.dart';

const _days = ['pn', 'wt', 'śr', 'cz', 'pt', 'sb', 'nd'];
const _months = ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];

/// Data „nocy”: zaśnięcie przed południem liczymy do poprzedniego wieczoru.
DateTime nightDate(Night n) {
  final s = n.start;
  final d = DateTime(s.year, s.month, s.day);
  return s.hour < 12 ? d.subtract(const Duration(days: 1)) : d;
}

/// Kolor jakości snu: czerwony (słabo) → żółty → zielony (dobrze).
Color scoreColor(int score) =>
    HSVColor.fromAHSV(1, (score.clamp(0, 100) / 100) * 135, 0.62, 0.92).toColor();

/// Kalendarz nocy (ostatnie [weeks] tygodni): kratka = noc, kolor = jakość snu.
/// Kratki rozkwitają falą od najstarszego tygodnia; dotknięcie lub przeciąganie pokazuje noc,
/// przycisk pod spodem ją otwiera.
class NightCalendarCard extends StatefulWidget {
  final List<Night> nights;
  final int weeks;
  const NightCalendarCard({super.key, required this.nights, this.weeks = 12});

  @override
  State<NightCalendarCard> createState() => _NightCalendarCardState();
}

class _NightCalendarCardState extends State<NightCalendarCard> {
  int? _sel;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final t0 = DateTime(today.year, today.month, today.day);
    final firstMonday = t0.subtract(Duration(days: t0.weekday - 1 + 7 * (widget.weeks - 1)));
    final days = [for (var i = 0; i < widget.weeks * 7; i++) DateTime(firstMonday.year, firstMonday.month, firstMonday.day + i)];
    // najlepiej oceniona noc danego dnia (gdy kilka – np. drzemka)
    final byDay = <DateTime, Night>{};
    for (final n in widget.nights) {
      if (n.end == null) continue;
      final d = nightDate(n);
      final old = byDay[d];
      if (old == null || n.durationMin > old.durationMin) byDay[d] = n;
    }
    final cells = [for (final d in days) byDay[d]];
    final withData = cells.whereType<Night>().toList();
    final avg = withData.isEmpty ? null : withData.map((n) => n.score).reduce((a, b) => a + b) / withData.length;
    const left = 22.0, top = 16.0;
    final weeks = widget.weeks;

    return LayoutBuilder(builder: (context, box) {
      final cell = ((box.maxWidth - left) / weeks).clamp(8.0, 30.0);
      final height = top + cell * 7 + 4;
      int? indexAt(Offset p, Size _) {
        final col = ((p.dx - left) / cell).floor();
        final row = ((p.dy - top) / cell).floor();
        if (p.dx < left || p.dy < top || row < 0 || row > 6 || col < 0 || col >= weeks) return null;
        return col * 7 + row;
      }

      final sel = _sel;
      final selNight = sel == null ? null : cells[sel];
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InteractiveChart(
          height: height,
          dataKey: Object.hashAll([withData.length, avg, weeks]),
          count: days.length,
          duration: const Duration(milliseconds: 1100),
          indexAt: indexAt,
          onSelect: (i) => setState(() => _sel = i),
          painter: (t, s, a) => _CalendarPainter(days, cells, cell, left, top, weeks, t, s, a, t0),
        ),
        const SizedBox(height: 4),
        if (sel != null && selNight != null)
          TextButton.icon(
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => NightDetailScreen(nightId: selNight.id!))),
            icon: const Icon(Icons.nightlight_round, size: 18),
            label: Text('Otwórz noc ${days[sel].day}.${days[sel].month.toString().padLeft(2, '0')}'),
          )
        else
          Text(
            avg == null
                ? 'Brak nocy w ostatnich $weeks tygodniach.'
                : '${withData.length} nocy · średnia jakość ${avg.round()}%. Dotknij kratki, aby zobaczyć noc.',
            style: const TextStyle(color: C.muted, fontSize: 12.5),
          ),
      ]);
    });
  }
}

class _CalendarPainter extends CustomPainter {
  final List<DateTime> days;
  final List<Night?> cells;
  final double cell, left, top;
  final int weeks;
  final double t, selA;
  final int? sel;
  final DateTime today;
  _CalendarPainter(this.days, this.cells, this.cell, this.left, this.top, this.weeks, this.t, this.sel, this.selA, this.today);

  @override
  void paint(Canvas c, Size size) {
    const label = TextStyle(fontSize: 10, color: C.muted);
    for (var r = 0; r < 7; r += 2) {
      final tp = TextPainter(text: TextSpan(text: _days[r], style: label), textDirection: TextDirection.ltr)..layout();
      tp.paint(c, Offset(0, top + r * cell + (cell - tp.height) / 2));
    }
    var lastMonthX = -1000.0;
    final pad = (cell * 0.09).clamp(1.0, 3.0);
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      final col = i ~/ 7, row = i % 7;
      final x = left + col * cell, y = top + row * cell;
      if (row == 0 && (d.day <= 7 || i == 0) && x - lastMonthX > cell * 2.5) {
        final tp = TextPainter(text: TextSpan(text: _months[d.month - 1], style: label), textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(c, Offset(x, 0));
        lastMonthX = x;
      }
      // fala: tydzień po tygodniu, kratki „rozkwitają” od środka
      final q = stagger(t, col, weeks, spread: 0.55);
      final n = cells[i];
      final future = d.isAfter(today);
      final base = future ? C.surface2.withValues(alpha: 0.35) : C.surface2;
      final rect = Rect.fromLTWH(x + pad, y + pad, cell - 2 * pad, cell - 2 * pad);
      final rr = RRect.fromRectAndRadius(rect, Radius.circular(cell * 0.2));
      c.drawRRect(rr, Paint()..color = base);
      if (n != null) {
        var col2 = scoreColor(n.score);
        if (sel != null && selA > 0 && sel != i) col2 = col2.withValues(alpha: 1 - 0.55 * selA);
        final s = 0.35 + 0.65 * q;
        c.drawRRect(
            RRect.fromRectAndRadius(Rect.fromCenter(center: rect.center, width: rect.width * s, height: rect.height * s),
                Radius.circular(cell * 0.2 * s)),
            Paint()..color = col2.withValues(alpha: col2.a * q));
        if (n.fartCount > 0 && q > 0.95 && cell > 12) {
          c.drawCircle(rect.bottomRight - Offset(cell * 0.18, cell * 0.18), cell * 0.07, Paint()..color = C.gas);
        }
      }
    }
    final s = sel;
    if (s != null && selA > 0 && s < days.length) {
      final col = s ~/ 7, row = s % 7;
      final r = Rect.fromLTWH(left + col * cell, top + row * cell, cell, cell);
      c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(cell * 0.22)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..color = C.text.withValues(alpha: selA));
      final d = days[s];
      final n = cells[s];
      final date = '${_days[d.weekday - 1]} ${d.day}.${d.month.toString().padLeft(2, '0')}';
      final txt = n == null
          ? '$date · brak nocy'
          : '$date · ${n.score}% · ${n.durationMin ~/ 60} h ${(n.durationMin % 60).toString().padLeft(2, '0')} min'
              '${n.fartCount > 0 ? ' · ${n.fartCount}× FF' : ''}';
      paintTip(c, size, txt, r.center.dx, r.top, selA);
    }
  }

  @override
  bool shouldRepaint(covariant _CalendarPainter o) =>
      o.t != t || o.sel != sel || o.selA != selA || o.cells != cells || o.cell != cell;
}

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

/// Kalendarz-heatmapa: kolumny = tygodnie, wiersze = dni tygodnia; im większa wartość, tym mocniejszy kolor.
/// Kratki wypełniają się falą od najstarszego tygodnia. Dotknięcie albo przesuwanie palcem po kratkach
/// pokazuje datę i wartość (z lekką wibracją); nad kalendarzem skróty miesięcy. Gdy podano [onOpen],
/// pod wybranym dniem jest przycisk otwierający szczegóły (np. wpisy z tego dnia).
class CalendarHeatmap extends StatefulWidget {
  final Map<DateTime, double> values; // dzień (północ) → wartość
  final int weeks;
  final Color color;
  final String Function(double v) format;
  final ValueChanged<DateTime>? onTap;
  final DateTime? end;

  /// Opcjonalny przycisk pod wybranym dniem: (etykieta, akcja).
  final String? openLabel;
  final ValueChanged<DateTime>? onOpen;

  /// Kropka na kratce (np. osiągnięty cel, napad, wizyta).
  final bool Function(DateTime day, double v)? marker;

  const CalendarHeatmap({
    super.key,
    required this.values,
    required this.color,
    this.weeks = 18,
    this.format = plAuto,
    this.onTap,
    this.end,
    this.openLabel,
    this.onOpen,
    this.marker,
  });

  @override
  State<CalendarHeatmap> createState() => _CalendarHeatmapState();
}

const _monthsShort = ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];

class _CalendarHeatmapState extends State<CalendarHeatmap> {
  DateTime? _sel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = widget.end ?? DateTime.now();
    final end = DateTime(e.year, e.month, e.day);
    final start = end.subtract(Duration(days: (widget.weeks - 1) * 7 + end.weekday - 1));
    final vals = {for (final x in widget.values.entries) DateTime(x.key.year, x.key.month, x.key.day): x.value};
    final mx = vals.values.fold<double>(0, max);
    const labelW = 22.0, monthH = 14.0;
    return LayoutBuilder(builder: (context, c) {
      final cell = min(18.0, (c.maxWidth - labelW) / widget.weeks);
      DateTime? dayAt(Offset p) {
        final w = ((p.dx - labelW) / cell).floor();
        final d = ((p.dy - monthH) / cell).floor();
        if (p.dx < labelW || w < 0 || w >= widget.weeks || d < 0 || d > 6) return null;
        final day = DateTime(start.year, start.month, start.day + w * 7 + d);
        return day.isAfter(end) ? null : day;
      }

      void pick(DateTime? day, {bool toggle = false}) {
        if (day == null) return;
        if (toggle && day == _sel) {
          setState(() => _sel = null);
          return;
        }
        if (day == _sel) return;
        HapticFeedback.selectionClick();
        setState(() => _sel = day);
        widget.onTap?.call(day);
      }

      // skróty miesięcy nad pierwszym tygodniem każdego miesiąca
      final months = <Widget>[];
      var lastX = -100.0;
      for (var w = 0; w < widget.weeks; w++) {
        final d0 = DateTime(start.year, start.month, start.day + w * 7);
        final d6 = DateTime(d0.year, d0.month, d0.day + 6);
        // etykieta nad tygodniem, w którym wypada 1. dzień miesiąca; pierwsza kolumna – gdy do końca miesiąca daleko
        final hasFirst = d0.day == 1 || d6.month != d0.month;
        final int? m = hasFirst ? d6.month : (w == 0 && d0.day <= 18 ? d0.month : null);
        final x = labelW + w * cell;
        if (m != null && x - lastX > 2.6 * cell) {
          months.add(Positioned(left: x, top: 0, child: Text(_monthsShort[m - 1], style: theme.textTheme.labelSmall?.copyWith(fontSize: 9))));
          lastX = x;
        }
      }

      final sel = _sel;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => pick(dayAt(d.localPosition), toggle: true),
          onHorizontalDragStart: (d) => pick(dayAt(d.localPosition)),
          onHorizontalDragUpdate: (d) => pick(dayAt(d.localPosition)),
          child: SizedBox(
            height: monthH + 7 * cell,
            child: Stack(children: [
              ...months,
              for (var d = 0; d < 7; d += 2)
                Positioned(
                  left: 0,
                  top: monthH + d * cell,
                  child: SizedBox(
                    height: cell,
                    width: labelW,
                    child: Text(plWeekday(DateTime(2024, 1, 1 + d)), style: theme.textTheme.labelSmall?.copyWith(fontSize: 9)),
                  ),
                ),
              for (var w = 0; w < widget.weeks; w++)
                for (var d = 0; d < 7; d++)
                  Builder(builder: (context) {
                    final day = DateTime(start.year, start.month, start.day + w * 7 + d);
                    if (day.isAfter(end)) return const SizedBox.shrink();
                    final v = vals[day];
                    final k = v == null || mx <= 0 ? 0.0 : (0.25 + 0.75 * v / mx);
                    final selected = sel == day;
                    final dim = sel != null && !selected;
                    final mark = v != null && (widget.marker?.call(day, v) ?? false);
                    return Positioned(
                      left: labelW + w * cell,
                      top: monthH + d * cell,
                      child: TweenAnimationBuilder<double>(
                        // fala: tydzień po tygodniu – kratka rośnie i nabiera koloru
                        tween: Tween(begin: 0, end: 1),
                        duration: Duration(milliseconds: 380 + 22 * w),
                        curve: Curves.easeOutBack,
                        builder: (context, g, _) {
                          final grow = (g * (1 + 22 * w / 380) - 22 * w / 380).clamp(0.0, 1.2);
                          final size = (cell - 2) * (0.35 + 0.65 * grow.clamp(0.0, 1.0)) * (selected ? 1.12 : 1);
                          return SizedBox(
                            width: cell,
                            height: cell,
                            child: Center(
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                width: size,
                                height: size,
                                decoration: BoxDecoration(
                                  color: v == null
                                      ? cs.surfaceContainerHighest
                                      : widget.color.withValues(alpha: (k * grow.clamp(0.0, 1.0) * (dim ? 0.55 : 1)).clamp(0.08, 1.0)),
                                  borderRadius: BorderRadius.circular(3),
                                  border: selected ? Border.all(color: cs.onSurface, width: 1.5) : null,
                                ),
                                child: mark && grow >= 0.95
                                    ? Center(
                                        child: Container(
                                          width: max(2.0, cell * 0.22),
                                          height: max(2.0, cell * 0.22),
                                          decoration: BoxDecoration(color: cs.onPrimary, shape: BoxShape.circle),
                                        ),
                                      )
                                    : null,
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: sel == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    Expanded(
                      child: Text('${plWeekday(sel)}, ${plDayYear(sel)}: ${vals[sel] == null ? 'brak' : widget.format(vals[sel]!)}',
                          style: theme.textTheme.labelMedium),
                    ),
                    if (widget.onOpen != null)
                      TextButton(onPressed: () => widget.onOpen!(sel), child: Text(widget.openLabel ?? 'Otwórz')),
                  ]),
                ),
        ),
      ]);
    });
  }
}

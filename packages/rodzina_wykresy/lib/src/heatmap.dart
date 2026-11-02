import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

/// Kalendarz-heatmapa: kolumny = tygodnie, wiersze = dni tygodnia; im większa wartość, tym mocniejszy kolor.
/// Dotknięcie dnia pokazuje datę i wartość pod spodem.
class CalendarHeatmap extends StatefulWidget {
  final Map<DateTime, double> values; // dzień (północ) → wartość
  final int weeks;
  final Color color;
  final String Function(double v) format;
  final ValueChanged<DateTime>? onTap;
  final DateTime? end;
  const CalendarHeatmap({super.key, required this.values, required this.color, this.weeks = 18, this.format = plAuto, this.onTap, this.end});

  @override
  State<CalendarHeatmap> createState() => _CalendarHeatmapState();
}

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
    return LayoutBuilder(builder: (context, c) {
      final cell = min(18.0, (c.maxWidth - 24) / widget.weeks);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [
            for (var d = 0; d < 7; d++)
              SizedBox(
                height: cell,
                width: 22,
                child: d.isEven ? Text(plWeekday(DateTime(2024, 1, 1 + d)), style: theme.textTheme.labelSmall?.copyWith(fontSize: 9)) : null,
              ),
          ]),
          for (var w = 0; w < widget.weeks; w++)
            Column(children: [
              for (var d = 0; d < 7; d++)
                Builder(builder: (context) {
                  final day = start.add(Duration(days: w * 7 + d));
                  if (day.isAfter(end)) return SizedBox(width: cell, height: cell);
                  final v = vals[day];
                  final k = v == null || mx <= 0 ? 0.0 : (0.25 + 0.75 * v / mx);
                  return GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _sel = day);
                      widget.onTap?.call(day);
                    },
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: k),
                      duration: Duration(milliseconds: 300 + 15 * w),
                      builder: (context, kk, _) => Container(
                        width: cell - 2,
                        height: cell - 2,
                        margin: const EdgeInsets.all(1),
                        decoration: BoxDecoration(
                          color: v == null ? cs.surfaceContainerHighest : widget.color.withValues(alpha: kk.clamp(0.08, 1.0)),
                          borderRadius: BorderRadius.circular(3),
                          border: _sel == day ? Border.all(color: cs.onSurface, width: 1.5) : null,
                        ),
                      ),
                    ),
                  );
                }),
            ]),
        ]),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: _sel == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${plWeekday(_sel!)}, ${plDayYear(_sel!)}: ${vals[_sel!] == null ? 'brak' : widget.format(vals[_sel!]!)}',
                      style: theme.textTheme.labelMedium),
                ),
        ),
      ]);
    });
  }
}

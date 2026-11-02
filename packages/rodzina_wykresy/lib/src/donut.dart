import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

class DonutSlice {
  final String label;
  final double value;
  final Color color;
  const DonutSlice(this.label, this.value, this.color);
}

/// Wykres kołowy (pierścień) rysowany przy pokazaniu; dotknięcie wycinka lub pozycji legendy
/// pokazuje go w środku z udziałem procentowym.
class DonutChart extends StatefulWidget {
  final List<DonutSlice> slices;
  final double size;
  final String Function(double v) format;
  final String? centerLabel; // opis sumy, np. „razem”
  final bool legend;
  const DonutChart({super.key, required this.slices, this.size = 180, this.format = plAuto, this.centerLabel, this.legend = true});

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..forward();
  int? _sel;

  @override
  void didUpdateWidget(covariant DonutChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.slices, widget.slices)) {
      _sel = null;
      _a.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  void _select(int? i) {
    HapticFeedback.selectionClick();
    setState(() => _sel = i == _sel ? null : i);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sl = [for (final s in widget.slices) if (s.value > 0) s];
    final total = sl.fold<double>(0, (a, s) => a + s.value);
    if (total <= 0) return const SizedBox.shrink();
    final sel = _sel != null && _sel! < sl.length ? sl[_sel!] : null;
    final chart = SizedBox.square(
      dimension: widget.size,
      child: GestureDetector(
        onTapUp: (d) {
          final c = Offset(widget.size / 2, widget.size / 2);
          final v = d.localPosition - c;
          final r = v.distance / (widget.size / 2);
          if (r < 0.55 || r > 1.05) return _select(null);
          var ang = atan2(v.dy, v.dx) + pi / 2;
          if (ang < 0) ang += 2 * pi;
          var acc = 0.0;
          for (var i = 0; i < sl.length; i++) {
            acc += sl[i].value / total * 2 * pi;
            if (ang <= acc) return _select(i);
          }
        },
        child: AnimatedBuilder(
          animation: _a,
          builder: (context, _) => CustomPaint(
            painter: _DonutPainter(sl, total, Curves.easeOutCubic.transform(_a.value), _sel, theme.colorScheme.surface),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Column(
                  key: ValueKey(_sel),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(sel == null ? (widget.centerLabel ?? 'razem') : sel.label,
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    Text(widget.format(sel?.value ?? total), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    if (sel != null) Text(plNum(sel.value / total * 100, decimals: 1) + '%', style: theme.textTheme.labelMedium),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!widget.legend) return chart;
    return Column(children: [
      chart,
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 6, alignment: WrapAlignment.center, children: [
        for (var i = 0; i < sl.length; i++)
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _select(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _sel == i ? sl[i].color.withValues(alpha: 0.15) : null,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: sl[i].color, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text('${sl[i].label} ${plNum(sl[i].value / total * 100)}%', style: theme.textTheme.labelMedium),
              ]),
            ),
          ),
      ]),
    ]);
  }
}

class _DonutPainter extends CustomPainter {
  final List<DonutSlice> s;
  final double total, t;
  final int? sel;
  final Color gap;
  _DonutPainter(this.s, this.total, this.t, this.sel, this.gap);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    var a = -pi / 2;
    for (var i = 0; i < s.length; i++) {
      final sweep = s[i].value / total * 2 * pi * t;
      final out = sel == i ? r : r - 5;
      final width = sel == i ? r * 0.36 : r * 0.30;
      final p = Paint()
        ..color = sel == null || sel == i ? s[i].color : s[i].color.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = width;
      canvas.drawArc(Rect.fromCircle(center: c, radius: out - width / 2), a, max(0, sweep - 0.012), false, p);
      a += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.t != t || old.sel != sel || old.s != s;
}

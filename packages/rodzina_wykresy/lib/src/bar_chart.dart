import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'format.dart';

class BarItem {
  final String label;
  final double value;
  final Color? color;
  final String? detail; // dodatkowy opis w dymku
  const BarItem(this.label, this.value, {this.color, this.detail});
}

/// Słupki rosnące kaskadą; dotknięcie zaznacza słupek i pokazuje wartość. Obsługuje wartości ujemne
/// (np. strata). [horizontal] – poziome paski z etykietą (rankingi), inaczej kolumny (np. dni).
class InteractiveBarChart extends StatefulWidget {
  final List<BarItem> bars;
  final bool horizontal;
  final double height;
  final String Function(double v) format;
  final Color? color;
  final Color? negativeColor;
  final double? goal;
  final ValueChanged<int?>? onSelect;
  const InteractiveBarChart({
    super.key,
    required this.bars,
    this.horizontal = false,
    this.height = 200,
    this.format = plAuto,
    this.color,
    this.negativeColor,
    this.goal,
    this.onSelect,
  });

  @override
  State<InteractiveBarChart> createState() => _InteractiveBarChartState();
}

class _InteractiveBarChartState extends State<InteractiveBarChart> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();
  int? _sel;

  @override
  void didUpdateWidget(covariant InteractiveBarChart old) {
    super.didUpdateWidget(old);
    if (!identical(old.bars, widget.bars)) {
      _sel = null;
      _a.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  void _tap(int? i) {
    HapticFeedback.selectionClick();
    setState(() => _sel = i == _sel ? null : i);
    widget.onSelect?.call(_sel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bars = widget.bars;
    if (bars.isEmpty) {
      return SizedBox(height: 60, child: Center(child: Text('Brak danych', style: TextStyle(color: cs.onSurfaceVariant))));
    }
    final pos = widget.color ?? cs.primary;
    final neg = widget.negativeColor ?? cs.error;
    final maxAbs = bars.map((b) => b.value.abs()).fold<double>(0, max).clamp(1e-9, double.infinity);
    final hasNeg = bars.any((b) => b.value < 0);

    if (widget.horizontal) {
      return AnimatedBuilder(
        animation: _a,
        builder: (context, _) => Column(children: [
          for (var i = 0; i < bars.length; i++)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _tap(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                    width: 96,
                    child: Text(bars[i].label, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontWeight: _sel == i ? FontWeight.w700 : null)),
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, c) {
                      final p = _stagger(_a.value, i, bars.length);
                      final half = hasNeg ? c.maxWidth / 2 : 0.0;
                      final full = hasNeg ? c.maxWidth / 2 : c.maxWidth;
                      final w = full * (bars[i].value.abs() / maxAbs) * p;
                      final col = bars[i].color ?? (bars[i].value < 0 ? neg : pos);
                      return SizedBox(
                        height: 18,
                        child: Stack(children: [
                          if (hasNeg) Positioned(left: half, top: 0, bottom: 0, child: Container(width: 1, color: cs.outlineVariant)),
                          Positioned(
                            left: bars[i].value < 0 ? half - w : half,
                            top: 2,
                            bottom: 2,
                            child: Container(
                              width: max(2, w),
                              decoration: BoxDecoration(
                                color: _sel == null || _sel == i ? col : col.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                        ]),
                      );
                    }),
                  ),
                  SizedBox(
                    width: 84,
                    child: Text(widget.format(bars[i].value * _stagger(_a.value, i, bars.length)),
                        textAlign: TextAlign.right,
                        style: theme.textTheme.labelMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                  ),
                ]),
              ),
            ),
          if (_sel != null && bars[_sel!].detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(bars[_sel!].detail!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            ),
        ]),
      );
    }

    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, widget.height);
      final slot = size.width / bars.length;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _tap((d.localPosition.dx / slot).floor().clamp(0, bars.length - 1)),
        onHorizontalDragUpdate: (d) {
          final i = (d.localPosition.dx / slot).floor().clamp(0, bars.length - 1);
          if (i != _sel) _tap(i);
        },
        child: AnimatedBuilder(
          animation: _a,
          builder: (context, _) => CustomPaint(size: size, painter: _ColPainter(widget, _a.value, _sel, theme, pos, neg, maxAbs, hasNeg)),
        ),
      );
    });
  }
}

double _stagger(double t, int i, int n) {
  final d = n <= 1 ? 0.0 : 0.35 * i / (n - 1);
  return Curves.easeOutCubic.transform(((t - d) / (1 - 0.35)).clamp(0.0, 1.0));
}

class _ColPainter extends CustomPainter {
  final InteractiveBarChart w;
  final double t;
  final int? sel;
  final ThemeData theme;
  final Color pos, neg;
  final double maxAbs;
  final bool hasNeg;
  _ColPainter(this.w, this.t, this.sel, this.theme, this.pos, this.neg, this.maxAbs, this.hasNeg);

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    final bars = w.bars;
    const bottomPad = 18.0, topPad = 26.0;
    final h = size.height - bottomPad - topPad;
    final zero = hasNeg ? topPad + h / 2 : topPad + h;
    final scale = (hasNeg ? h / 2 : h) / max(maxAbs, w.goal ?? 0);
    final slot = size.width / bars.length;
    final bw = max(2.0, min(28.0, slot * 0.62));
    final label = theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant);
    canvas.drawLine(Offset(0, zero), Offset(size.width, zero), Paint()..color = cs.outlineVariant);
    final every = max(1, (bars.length / max(1, size.width / 34)).ceil());
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final p = _stagger(t, i, bars.length);
      final bh = b.value.abs() * scale * p;
      final x = slot * i + (slot - bw) / 2;
      final r = b.value >= 0 ? Rect.fromLTWH(x, zero - bh, bw, bh) : Rect.fromLTWH(x, zero, bw, bh);
      final col = b.color ?? (b.value < 0 ? neg : pos);
      canvas.drawRRect(
        RRect.fromRectAndCorners(r,
            topLeft: Radius.circular(b.value >= 0 ? 4 : 0),
            topRight: Radius.circular(b.value >= 0 ? 4 : 0),
            bottomLeft: Radius.circular(b.value < 0 ? 4 : 0),
            bottomRight: Radius.circular(b.value < 0 ? 4 : 0)),
        Paint()..color = sel == null || sel == i ? col : col.withValues(alpha: 0.35),
      );
      if (i % every == 0 || sel == i) {
        final tp = TextPainter(text: TextSpan(text: b.label, style: sel == i ? label?.copyWith(fontWeight: FontWeight.w700, color: cs.onSurface) : label), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset((slot * i + slot / 2 - tp.width / 2).clamp(0, size.width - tp.width).toDouble(), size.height - bottomPad + 3));
      }
    }
    if (w.goal != null) {
      final y = zero - w.goal! * scale;
      final pp = Paint()
        ..color = cs.tertiary
        ..strokeWidth = 1.4;
      for (var x = 0.0; x < size.width; x += 8) {
        canvas.drawLine(Offset(x, y), Offset(min(x + 4, size.width), y), pp);
      }
    }
    final s = sel;
    if (s != null) {
      final b = bars[s];
      final txt = '${w.format(b.value)}${b.detail != null ? ' · ${b.detail}' : ''}';
      final tp = TextPainter(
          text: TextSpan(text: txt, style: theme.textTheme.labelMedium?.copyWith(color: cs.onInverseSurface, fontWeight: FontWeight.w700)),
          textDirection: TextDirection.ltr)
        ..layout(maxWidth: size.width - 8);
      final bx = (slot * s + slot / 2 - tp.width / 2 - 8).clamp(0, size.width - tp.width - 16).toDouble();
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(bx, 0, tp.width + 16, tp.height + 8), const Radius.circular(8)),
          Paint()..color = cs.inverseSurface.withValues(alpha: 0.92));
      tp.paint(canvas, Offset(bx + 8, 4));
    }
  }

  @override
  bool shouldRepaint(covariant _ColPainter old) => old.t != t || old.sel != sel || old.w != w;
}

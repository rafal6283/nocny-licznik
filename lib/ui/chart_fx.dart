import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wspólne efekty wykresów: animacja wejścia (ponawiana przy zmianie danych),
/// wybór elementu dotknięciem lub przeciągnięciem palca, dymek z wartością
/// i delikatna wibracja przy przeskoku na kolejny element.

/// Kaskada: postęp i-tego z n elementów przy globalnym postępie [t] (0→1), z wygładzeniem ease-out.
double stagger(double t, int i, int n, {double spread = 0.35}) {
  final delay = n <= 1 ? 0.0 : spread * i / (n - 1);
  final p = ((t - delay) / (1 - spread)).clamp(0.0, 1.0);
  final q = 1 - p;
  return 1 - q * q * q;
}

/// Buduje malarza dla bieżącego stanu: [t] postęp wejścia 0→1, [sel] wybrany indeks
/// (zostaje ustawiony także podczas znikania dymka), [selA] widoczność wyboru 0→1.
typedef ChartPainterBuilder = CustomPainter Function(double t, int? sel, double selA);

class InteractiveChart extends StatefulWidget {
  final double height;

  /// Zmiana klucza = dane się zmieniły → animacja wejścia od nowa.
  final Object? dataKey;
  final int count;

  /// Który element jest pod palcem (null = żaden).
  final int? Function(Offset p, Size size) indexAt;
  final ChartPainterBuilder painter;
  final Duration duration;
  final bool animate;
  final ValueChanged<int?>? onSelect;

  const InteractiveChart({
    super.key,
    required this.height,
    required this.dataKey,
    required this.count,
    required this.indexAt,
    required this.painter,
    this.duration = const Duration(milliseconds: 850),
    this.animate = true,
    this.onSelect,
  });

  @override
  State<InteractiveChart> createState() => _InteractiveChartState();
}

class _InteractiveChartState extends State<InteractiveChart> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: widget.duration);
  late final AnimationController _sel = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 170), reverseDuration: const Duration(milliseconds: 240));
  int? _idx;
  int? _last;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _in.forward();
    } else {
      _in.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant InteractiveChart old) {
    super.didUpdateWidget(old);
    if (old.dataKey != widget.dataKey) {
      if (widget.animate) _in.forward(from: 0);
      if (old.count != widget.count) {
        _idx = null;
        _last = null;
        _sel.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _in.dispose();
    _sel.dispose();
    super.dispose();
  }

  void _pick(int? i) {
    if (i != null && (i < 0 || i >= widget.count)) i = null;
    if (i == _idx) return;
    setState(() {
      _idx = i;
      if (i != null) {
        _last = i;
        _sel.forward();
        HapticFeedback.selectionClick();
      } else {
        _sel.reverse();
      }
    });
    widget.onSelect?.call(i);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, widget.height);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final i = widget.indexAt(d.localPosition, size);
          _pick(i == _idx ? null : i);
        },
        onHorizontalDragStart: (d) => _pick(widget.indexAt(d.localPosition, size)),
        onHorizontalDragUpdate: (d) => _pick(widget.indexAt(d.localPosition, size)),
        child: AnimatedBuilder(
          animation: Listenable.merge([_in, _sel]),
          builder: (context, _) => CustomPaint(
            size: size,
            painter: widget.painter(_in.value, _last, _sel.value),
          ),
        ),
      );
    });
  }
}

/// Dymek z tekstem nad punktem ([x], [y]); dosuwany do krawędzi. Opcjonalnie pionowa linia pomocnicza.
void paintTip(
  Canvas c,
  Size size,
  String text,
  double x,
  double y,
  double a, {
  Color bg = const Color(0xFFF2F2F7),
  Color fg = const Color(0xFF111118),
  double? guideTop,
  double? guideBottom,
  Color guide = const Color(0x66FFFFFF),
}) {
  if (a <= 0) return;
  if (guideTop != null && guideBottom != null) {
    c.drawLine(Offset(x, guideTop), Offset(x, guideBottom),
        Paint()
          ..color = guide.withValues(alpha: guide.a * a)
          ..strokeWidth = 1);
  }
  final tp = TextPainter(
    text: TextSpan(
        text: text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: fg.withValues(alpha: a))),
    textDirection: TextDirection.ltr,
    maxLines: 2,
  )..layout(maxWidth: size.width - 16);
  const padH = 8.0, padV = 5.0;
  final w = tp.width + 2 * padH;
  final h = tp.height + 2 * padV;
  final lift = 6 * (1 - a);
  final left = (x - w / 2).clamp(0.0, (size.width - w).clamp(0.0, double.infinity)).toDouble();
  final top = (y - h - 8 + lift).clamp(0.0, double.infinity).toDouble();
  final rr = RRect.fromRectAndRadius(Rect.fromLTWH(left, top, w, h), const Radius.circular(8));
  c.drawRRect(rr.shift(const Offset(0, 1.5)), Paint()..color = Colors.black.withValues(alpha: 0.25 * a));
  c.drawRRect(rr, Paint()..color = bg.withValues(alpha: 0.96 * a));
  tp.paint(c, Offset(left + padH, top + padV));
}

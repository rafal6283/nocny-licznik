import 'package:flutter/material.dart';

/// Wejście elementu: pojawienie się i lekki wjazd od dołu, kaskadowo według [index].
class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final int index;
  final Duration duration;
  final double offset;
  const FadeSlideIn({super.key, required this.child, this.index = 0, this.duration = const Duration(milliseconds: 420), this.offset = 18});

  @override
  Widget build(BuildContext context) {
    final delay = (index.clamp(0, 12)) * 0.06;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration + Duration(milliseconds: (delay * 1000).round()),
      curve: Curves.linear,
      builder: (context, t, child) {
        // opóźnienie: pierwsza część czasu bez ruchu
        final total = 1 + delay / (duration.inMilliseconds / 1000);
        final p = ((t * total) - (total - 1)).clamp(0.0, 1.0);
        final e = Curves.easeOutCubic.transform(p);
        return Opacity(opacity: e, child: Transform.translate(offset: Offset(0, (1 - e) * offset), child: child));
      },
      child: child,
    );
  }
}

/// Przejście między stronami: zanikanie z lekkim przesunięciem (spójne we wszystkich aplikacjach).
class FadeThroughPageRoute<T> extends PageRouteBuilder<T> {
  FadeThroughPageRoute({required WidgetBuilder builder, super.settings})
      : super(
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (context, _, __) => builder(context),
          transitionsBuilder: (context, a, _, child) {
            final c = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
            return FadeTransition(
              opacity: c,
              child: SlideTransition(position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(c), child: child),
            );
          },
        );
}

/// Kaskadowe wejście elementów listy (np. `ListView(children: staggered([...]))`).
List<Widget> staggered(List<Widget> children, {int from = 0}) =>
    [for (var i = 0; i < children.length; i++) FadeSlideIn(index: from + i, child: children[i])];

/// Pasek proporcji (np. w normie / poza normą), który rośnie przy pokazaniu.
class AnimatedSplitBar extends StatelessWidget {
  final List<(double, Color)> parts;
  final double height;
  const AnimatedSplitBar({super.key, required this.parts, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final total = parts.fold<double>(0, (a, p) => a + p.$1);
    if (total <= 0) return SizedBox(height: height);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, c) => Row(children: [
              for (final p in parts) Container(width: c.maxWidth * t * p.$1 / total, color: p.$2),
            ]),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'format.dart';

/// Liczba, która płynnie dochodzi do nowej wartości (przy pierwszym pokazaniu – od zera).
class AnimatedNumber extends StatelessWidget {
  final double value;
  final String Function(double v)? format;
  final TextStyle? style;
  final Duration duration;
  final TextAlign? textAlign;
  const AnimatedNumber({super.key, required this.value, this.format, this.style, this.duration = const Duration(milliseconds: 900), this.textAlign});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: value),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => Text((format ?? plAuto)(v), style: style, textAlign: textAlign),
      );
}

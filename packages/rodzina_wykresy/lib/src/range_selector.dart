import 'package:flutter/material.dart';

/// Wybór zakresu dni: 7 / 30 / 90 / 365 / wszystko (0).
class RangeSelector extends StatelessWidget {
  final int days;
  final ValueChanged<int> onChanged;
  final List<int> options;
  const RangeSelector({super.key, required this.days, required this.onChanged, this.options = const [7, 30, 90, 365, 0]});

  static String label(int d) => switch (d) { 0 => 'wszystko', 7 => '7 dni', 30 => '30 dni', 90 => '3 mies.', 365 => 'rok', _ => '$d dni' };

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<int>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [for (final d in options) ButtonSegment(value: d, label: Text(label(d)))],
          selected: {days},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
      );
}

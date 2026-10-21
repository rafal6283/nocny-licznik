import 'package:flutter/material.dart';

import '../core/models.dart';

/// Nocna paleta: granat, księżycowy żółty, miętowy akcent „gazowy”.
class C {
  static const bg = Color(0xFF0B1020);
  static const surface = Color(0xFF151B33);
  static const surface2 = Color(0xFF1E2645);
  static const text = Color(0xFFE8EAF6);
  static const muted = Color(0xFF8C93B8);
  static const moon = Color(0xFFFFD66B);
  static const gas = Color(0xFF7BE3B0);
  static const danger = Color(0xFFFF7A85);

  static const wake = Color(0xFFFF9E7A);
  static const rem = Color(0xFFB59BFF);
  static const light = Color(0xFF6FA8FF);
  static const deep = Color(0xFF3A4FC4);

  static Color stage(Stage s) => switch (s) {
        Stage.wake => wake,
        Stage.rem => rem,
        Stage.light => light,
        Stage.deep => deep,
      };

  static Color sound(SoundType t) => switch (t) {
        SoundType.fart => gas,
        SoundType.snore => light,
        SoundType.talk => rem,
        SoundType.cough => wake,
        SoundType.apnea => danger,
      };
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: C.gas,
    brightness: Brightness.dark,
    surface: C.surface,
  ).copyWith(primary: C.gas, secondary: C.moon, surface: C.surface);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    appBarTheme: const AppBarTheme(backgroundColor: C.bg, elevation: 0, centerTitle: false),
    cardTheme: const CardThemeData(
      color: C.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
    ),
    navigationBarTheme: const NavigationBarThemeData(backgroundColor: C.surface, indicatorColor: C.surface2),
    chipTheme: const ChipThemeData(backgroundColor: C.surface2, side: BorderSide.none),
    textTheme: const TextTheme(
      displayLarge: TextStyle(fontWeight: FontWeight.w300, color: C.text, letterSpacing: -2),
      titleLarge: TextStyle(fontWeight: FontWeight.w700, color: C.text),
      bodyMedium: TextStyle(color: C.text),
      bodySmall: TextStyle(color: C.muted),
    ),
  );
}

/// Karta sekcji z tytułem.
class Section extends StatelessWidget {
  final String? title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;
  const Section({super.key, this.title, required this.child, this.trailing, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  Expanded(
                    child: Text(title!,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: C.text)),
                  ),
                  if (trailing != null) trailing!,
                ]),
              ),
            child,
          ],
        ),
      ),
    );
  }
}

/// Mały kafelek z liczbą.
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color color;
  const StatTile({super.key, required this.label, required this.value, this.sub, this.color = C.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 12, color: C.muted)),
        const SizedBox(height: 4),
        Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
        if (sub != null) Text(sub!, style: const TextStyle(fontSize: 11, color: C.muted)),
      ]),
    );
  }
}

/// Siatka kafelków 2 lub 3 w rzędzie.
class TileGrid extends StatelessWidget {
  final List<Widget> children;
  final int columns;
  const TileGrid({super.key, required this.children, this.columns = 2});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      final row = <Widget>[];
      for (var j = 0; j < columns; j++) {
        if (j > 0) row.add(const SizedBox(width: 8));
        row.add(Expanded(child: i + j < children.length ? children[i + j] : const SizedBox()));
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: row)));
    }
    return Column(children: rows);
  }
}

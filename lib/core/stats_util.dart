import 'dart:math';

import 'models.dart';

/// Dług snu z ostatnich 14 dni (w minutach; ujemny = nadwyżka).
/// Starsze noce ważą mniej, jak w Sleep as Android.
int sleepDebtMin(List<Night> nights, int goalMin) {
  final now = DateTime.now();
  var debt = 0.0;
  for (final n in nights) {
    final days = now.difference(n.start).inHours / 24.0;
    if (days > 14) continue;
    final w = 1.0 - days / 14 * 0.5;
    debt += (goalMin - n.durationMin) * w;
  }
  return debt.round();
}

double avg(Iterable<num> v) => v.isEmpty ? 0 : v.fold<double>(0, (a, b) => a + b) / v.length;

/// Wpływ tagu na wynik: średnia z tagiem vs bez.
class TagImpact {
  final String tag;
  final int nights;
  final double fartsWith, fartsWithout, scoreWith, scoreWithout;
  TagImpact(this.tag, this.nights, this.fartsWith, this.fartsWithout, this.scoreWith, this.scoreWithout);

  double get fartDeltaPct => fartsWithout <= 0 ? (fartsWith > 0 ? 100 : 0) : (fartsWith / fartsWithout - 1) * 100;
  double get scoreDelta => scoreWith - scoreWithout;
}

List<TagImpact> tagImpacts(List<Night> nights) {
  final tags = <String>{for (final n in nights) ...n.tags};
  final out = <TagImpact>[];
  for (final t in tags) {
    final w = nights.where((n) => n.tags.contains(t)).toList();
    final wo = nights.where((n) => !n.tags.contains(t)).toList();
    if (w.isEmpty) continue;
    out.add(TagImpact(
      t,
      w.length,
      avg(w.map((n) => n.fartCount)),
      avg(wo.map((n) => n.fartCount)),
      avg(w.map((n) => n.score)),
      avg(wo.map((n) => n.score)),
    ));
  }
  out.sort((a, b) => b.fartDeltaPct.compareTo(a.fartDeltaPct));
  return out;
}

/// Kategoria światła nocy: z pomiaru (średnia lx), a gdy go brak — z ręcznego wyboru.
String lightBucket(Night n) {
  final lux = n.avgLux;
  if (lux != null) {
    if (lux < 1) return 'dark';
    if (lux < 10) return 'dim';
    return 'bright';
  }
  return n.lightManual;
}

String lightBucketLabel(String b) => switch (b) {
      'dark' => 'Ciemno (<1 lx)',
      'dim' => 'Półmrok (1–10 lx)',
      'bright' => 'Jasno (>10 lx)',
      _ => 'Nieznane',
    };

/// Następne wystąpienie godziny (dziś lub jutro).
DateTime nextOccurrence(int hour, int minute) {
  final now = DateTime.now();
  var t = DateTime(now.year, now.month, now.day, hour, minute);
  if (!t.isAfter(now.add(const Duration(minutes: 1)))) t = t.add(const Duration(days: 1));
  return t;
}

int maxInt(Iterable<int> v) => v.isEmpty ? 0 : v.reduce(max);

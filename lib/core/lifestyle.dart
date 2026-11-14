import 'package:bakometr_native/bakometr_native.dart';

import 'db.dart';
import 'models.dart';
import 'settings.dart';

/// Treningi i posiłki przed nocą z Health Connect (np. Forma, Dziennik talerza, Huawei przez Health Sync).
/// Zapisywane przy nocy w tabeli ext:
///   lx_ex   (start, typ treningu, minuty)
///   lx_meal (czas, kcal)
///   lx_caf  (czas, mg kofeiny albo 0, gdy rozpoznana po nazwie)
///   lx_alc  (czas)
///   lx_ok   (znacznik: dane pobrane)
class Lifestyle {
  static final _caf = RegExp(
      r'kaw|espresso|cappuccino|latte|americano|flat white|macchiato|cola|coca|pepsi|energet|red ?bull|monster|tiger|yerba|matcha|herbata czarna|czarna herbata|earl grey',
      caseSensitive: false);
  static final _alc = RegExp(
      r'piwo|piwa|wino|wina|wódk|wodk|whisk|drink|gin\b|rum\b|nalewk|prosecco|szampan|cydr|likier|aperol|koniak|brandy|bimber|radler',
      caseSensitive: false);

  static bool isCaffeine(String name) => _caf.hasMatch(name);
  static bool isAlcohol(String name) => _alc.hasMatch(name) && !name.toLowerCase().contains('bezalkohol') && !name.toLowerCase().contains('0%');

  /// Pobiera dane z 18 h przed nocą; zwraca true, gdy zapisano.
  static Future<bool> fetchForNight(Night n) async {
    if (n.id == null) return false;
    final from = n.start.subtract(const Duration(hours: 18));
    final r = await BakometrNative.healthConnectReadLife(from.millisecondsSinceEpoch, n.start.millisecondsSinceEpoch);
    if (r == null) return false;
    final rows = <(DateTime, String, double?, double?)>[(n.start, 'lx_ok', null, null)];
    for (final e in (r['exercise'] as List? ?? const [])) {
      if (e is! List || e.length < 3) continue;
      final a = DateTime.fromMillisecondsSinceEpoch((e[0] as num).toInt());
      final b = DateTime.fromMillisecondsSinceEpoch((e[1] as num).toInt());
      final min = b.difference(a).inSeconds / 60;
      if (min < 5) continue;
      rows.add((a, 'lx_ex', (e[2] as num?)?.toDouble(), min));
    }
    for (final m in (r['meals'] as List? ?? const [])) {
      if (m is! List || m.length < 3) continue;
      final t = DateTime.fromMillisecondsSinceEpoch((m[0] as num).toInt());
      final name = (m[1] ?? '').toString();
      final kcal = (m[2] as num?)?.toDouble() ?? 0;
      final cafMg = m.length > 4 ? (m[4] as num?)?.toDouble() ?? 0 : 0.0;
      rows.add((t, 'lx_meal', kcal, null));
      if (cafMg > 0 || isCaffeine(name)) rows.add((t, 'lx_caf', cafMg, null));
      if (isAlcohol(name)) rows.add((t, 'lx_alc', 1, null));
    }
    await Db.instance.replaceExt(n.id!, 'lx_', rows);
    return true;
  }

  /// Uzupełnia ostatnie noce (raz na noc).
  static Future<int> backfill({int days = 45}) async {
    final s = Settings.instance;
    if (!s.lifestyleOn || !await BakometrNative.healthConnectHasLifePermission()) return 0;
    var c = 0;
    for (final n in await Db.instance.nights(limit: 60, naps: true)) {
      if (n.id == null || DateTime.now().difference(n.start).inDays > days) continue;
      final ext = await Db.instance.ext(n.id!);
      if (ext.any((r) => r.$2 == 'lx_ok')) continue;
      if (await fetchForNight(n)) c++;
    }
    return c;
  }
}

/// Czynniki stylu życia jednej nocy, wyliczone z wierszy ext.
class LifeFacts {
  final bool hasData;
  final bool caffeineAfter14, alcohol, lateMeal, workout, lateWorkout;
  final double? eveningKcal, workoutMin, hoursSinceMeal;
  const LifeFacts({
    this.hasData = false,
    this.caffeineAfter14 = false,
    this.alcohol = false,
    this.lateMeal = false,
    this.workout = false,
    this.lateWorkout = false,
    this.eveningKcal,
    this.workoutMin,
    this.hoursSinceMeal,
  });

  static LifeFacts of(Night n, List<(DateTime, String, double?, double?)> ext) {
    if (!ext.any((r) => r.$2 == 'lx_ok')) return const LifeFacts();
    final bed = n.start;
    final day = DateTime(bed.year, bed.month, bed.day);
    // dzień przed nocą (noc po północy: dzień poprzedni)
    final base = bed.hour < 12 ? day.subtract(const Duration(days: 1)) : day;
    final h14 = base.add(const Duration(hours: 14)), h18 = base.add(const Duration(hours: 18));
    final caf = ext.where((r) => r.$2 == 'lx_caf' && r.$1.isAfter(h14));
    final alc = ext.where((r) => r.$2 == 'lx_alc' && r.$1.isAfter(base.add(const Duration(hours: 12))));
    final meals = ext.where((r) => r.$2 == 'lx_meal').toList()..sort((a, b) => a.$1.compareTo(b.$1));
    final ex = ext.where((r) => r.$2 == 'lx_ex').toList();
    final eve = meals.where((m) => m.$1.isAfter(h18)).fold<double>(0, (s, m) => s + (m.$3 ?? 0));
    final lastMeal = meals.isEmpty ? null : meals.last.$1;
    final sinceMeal = lastMeal == null ? null : bed.difference(lastMeal).inMinutes / 60;
    final exMin = ex.fold<double>(0, (s, e) => s + (e.$4 ?? 0));
    final lateEx = ex.any((e) {
      final end = e.$1.add(Duration(seconds: ((e.$4 ?? 0) * 60).round()));
      return bed.difference(end).inMinutes <= 180;
    });
    return LifeFacts(
      hasData: true,
      caffeineAfter14: caf.isNotEmpty,
      alcohol: alc.isNotEmpty,
      lateMeal: sinceMeal != null && sinceMeal <= 2,
      workout: ex.isNotEmpty,
      lateWorkout: lateEx,
      eveningKcal: meals.isEmpty ? null : eve,
      workoutMin: exMin,
      hoursSinceMeal: sinceMeal,
    );
  }
}

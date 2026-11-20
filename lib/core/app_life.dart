import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'models.dart';

typedef LifeRow = (DateTime, String, double?, double?);

/// Posiłki z Dziennika talerza („czynniki-posilki”) i treningi z Formy („czynniki-forma”), pobrane przez Koofr,
/// jako styl życia nocy (wiersze `lx_` jak z Health Connect). Działa też na iPhonie i bez Health Connect.
///
/// Wiersze dodane z aplikacji mają znacznik: `lx_app`, a w `lx_ok`/`lx_caf`/`lx_alc`/`lx_ex` wartość −1
/// (Health Connect zapisuje tam ≥ 0). Dzięki temu dane z zegarka mają pierwszeństwo, a ponowne
/// przeliczenie podmienia tylko to, co przyszło z aplikacji.
class AppLife {
  static const files = ['czynniki-posilki', 'czynniki-forma'];

  static Future<File> _file(String name) async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$name.json');

  static Future<void> save(String name, List<int> data) async => (await _file(name)).writeAsBytes(data, flush: true);

  /// Plik „czynniki-dnia”: data → pole → wartość (zły plik = pusto).
  static Map<String, Map<String, num>> parseDays(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map || j['format'] != 'czynniki-dnia') return const {};
      return {
        for (final d in (j['days'] as List? ?? const []))
          if (d is Map && d['date'] is String)
            d['date'] as String: {for (final e in d.entries) if (e.value is num) '${e.key}': e.value as num},
      };
    } catch (_) {
      return const {};
    }
  }

  static bool isAppRow(LifeRow r) =>
      r.$2 == 'lx_app' || (const {'lx_ok', 'lx_caf', 'lx_alc', 'lx_ex'}.contains(r.$2) && (r.$3 ?? 0) < 0);

  /// Czy noc ma dane stylu życia z Health Connect (nie z aplikacji).
  static bool hasHealthConnect(List<LifeRow> ext) => ext.any((r) => r.$2 == 'lx_ok' && (r.$3 ?? 0) >= 0);

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Nowe wiersze `lx_` nocy: dane z Health Connect zostają, z aplikacji dochodzi to, czego tam brakuje.
  /// null = nic do zmiany (brak danych z aplikacji dla dnia przed tą nocą).
  static List<LifeRow>? rowsFor(Night n, List<LifeRow> ext, Map<String, Map<String, num>> meals,
      Map<String, Map<String, num>> forma) {
    final bed = n.start;
    final day = DateTime(bed.year, bed.month, bed.day);
    final base = bed.hour < 12 ? day.subtract(const Duration(days: 1)) : day; // jak w LifeFacts
    final m = meals[_iso(base)], f = forma[_iso(base)];
    final lx = ext.where((r) => r.$2.startsWith('lx_')).toList();
    final kept = lx.where((r) => !isAppRow(r)).toList();
    if (m == null && f == null) return lx.any(isAppRow) ? kept : null;
    final hc = hasHealthConnect(kept);
    DateTime at(num h) => base.add(Duration(minutes: (h * 60).round()));
    final add = <LifeRow>[(bed, 'lx_app', null, null)];
    if (!hc) add.add((bed, 'lx_ok', -1, null));
    if (m != null) {
      final coffee = (m['coffee'] ?? 0) > 0, alcohol = (m['alcohol'] ?? 0) > 0;
      // pora nieznana (starszy Dziennik): kawa rano, alkohol z ostatnim posiłkiem
      if (coffee && !kept.any((r) => r.$2 == 'lx_caf')) add.add((at(m['coffee_last_h'] ?? 9), 'lx_caf', -1, null));
      if (alcohol && !kept.any((r) => r.$2 == 'lx_alc')) {
        add.add((at(m['alcohol_last_h'] ?? m['last_meal_h'] ?? 19), 'lx_alc', -1, null));
      }
      final last = m['last_meal_h'];
      if (!hc && last != null) {
        // kalorie po 18:00 liczą się przy ostatnim posiłku (gdy był po 18:00)
        final eve = (m['eve_kcal'] ?? (last >= 18 ? m['big_meal_kcal'] : 0) ?? 0).toDouble();
        add.add((at(last), 'lx_meal', last >= 18 ? eve : 0, null));
      }
    }
    if (f != null && !kept.any((r) => r.$2 == 'lx_ex')) {
      final min = (f['train_min'] ?? 0).toDouble(), end = f['end_h'];
      if (min >= 5 && end != null) add.add((at(end).subtract(Duration(minutes: min.round())), 'lx_ex', -1, min));
    }
    return [...kept, ...add];
  }

  /// Uzupełnia noce z ostatnich [days] dni. Zwraca liczbę zmienionych nocy.
  static Future<int> applyAll({int days = 45}) async {
    Map<String, Map<String, num>> read(File f) => f.existsSync() ? parseDays(f.readAsStringSync()) : const {};
    final meals = read(await _file('czynniki-posilki')), forma = read(await _file('czynniki-forma'));
    var c = 0;
    for (final n in await Db.instance.nights(limit: 60, naps: true)) {
      if (n.id == null || n.end == null || DateTime.now().difference(n.start).inDays > days) continue;
      final ext = await Db.instance.ext(n.id!);
      final rows = rowsFor(n, ext, meals, forma);
      if (rows == null) continue;
      final before = ext.where((r) => r.$2.startsWith('lx_')).toList();
      if (before.length == rows.length && before.every(rows.contains)) continue;
      await Db.instance.replaceExt(n.id!, 'lx_', rows);
      c++;
    }
    return c;
  }
}

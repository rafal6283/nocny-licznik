import 'package:bakometr/core/lifestyle.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_sync/koofr_sync.dart';
import 'package:bakometr/core/app_life.dart';
import 'package:bakometr/core/cloud.dart';
import 'package:bakometr/core/models.dart';
import 'package:bakometr/core/strap.dart';

/// Kontrakt wymiany (packages/koofr_sync/WYMIANA.md) z perspektywy Rytmu Snu.
void main() {
  const sources = Cloud.exchangeSources;

  test('Rytm Snu pobiera dokładnie pliki, które zna', () {
    expect(przykladyDlaZrodel(sources), unorderedEquals(['polar-ekg', 'polar-noce', 'czynniki-posilki', 'czynniki-forma']));
    for (final p in kontraktWymiany) {
      if (p.odbiorcy.contains('rytm-snu')) expect(sources.any((s) => zrodloPasuje(s, p.przyklad)), isTrue, reason: p.nazwa);
    }
  });

  test('epizody AF z pliku polar-ekg', () {
    final af = PolarAf.parse(wymianaPrzyklady['polar-ekg']!);
    expect(af, hasLength(1));
    expect(af.first.$2.difference(af.first.$1).inSeconds, 46);
    expect(PolarAf.parse(wymianaPrzyklady['polar-noce']!), isEmpty); // inny format — pomijany
    expect(PolarAf.parse('{'), isEmpty);
  });

  group('posiłki z Dziennika i treningi z Formy jako czynniki snu', () {
    final meals = AppLife.parseDays(wymianaPrzyklady['czynniki-posilki']!);
    final forma = AppLife.parseDays(wymianaPrzyklady['czynniki-forma']!);
    // noc 19→20.11.2025: dzień przed nocą = 2025-11-19 (jak w przykładach)
    final night = Night(id: 1, start: DateTime(2025, 11, 19, 23, 30), end: DateTime(2025, 11, 20, 7));

    test('bez Health Connect: kawa po 14, alkohol, późny posiłek i trening', () {
      final rows = AppLife.rowsFor(night, const [], meals, forma)!;
      final f = LifeFacts.of(night, rows);
      expect(f.hasData, isTrue);
      expect(f.fromApps, isTrue);
      expect(f.caffeineAfter14, isTrue); // kawa o 15:00
      expect(f.alcohol, isTrue);
      expect(f.eveningKcal, 980);
      expect(f.hoursSinceMeal, 3); // 20:30 → 23:30
      expect(f.lateMeal, isFalse);
      expect(f.workout, isTrue);
      expect(f.workoutMin, 32);
      expect(f.lateWorkout, isFalse); // koniec 18:15, ponad 3 h przed snem
    });

    test('Health Connect ma pierwszeństwo; dochodzi tylko alkohol, którego tam nie było', () {
      final hc = <LifeRow>[
        (night.start, 'lx_ok', null, null),
        (DateTime(2025, 11, 19, 22, 45), 'lx_meal', 300, null),
        (DateTime(2025, 11, 19, 10), 'lx_caf', 80, null),
        (DateTime(2025, 11, 19, 17), 'lx_ex', 200, 45),
      ];
      final rows = AppLife.rowsFor(night, hc, meals, forma)!;
      final f = LifeFacts.of(night, rows);
      expect(f.caffeineAfter14, isFalse); // Health Connect: kawa rano — bez dopisywania z Dziennika
      expect(f.alcohol, isTrue);
      expect(f.lateMeal, isTrue); // posiłek z Health Connect o 22:45
      expect(f.workoutMin, 45);
      expect(rows.where((r) => r.$2 == 'lx_meal'), hasLength(1));
      // ponowne przeliczenie nie dubluje wierszy
      expect(AppLife.rowsFor(night, rows, meals, forma), unorderedEquals(rows));
    });

    test('brak danych dla tej nocy: nic się nie zmienia, stare wiersze z aplikacji znikają', () {
      final other = Night(id: 2, start: DateTime(2025, 12, 1, 23), end: DateTime(2025, 12, 2, 7));
      expect(AppLife.rowsFor(other, const [], meals, forma), isNull);
      final stale = <LifeRow>[(other.start, 'lx_app', null, null), (other.start, 'lx_ok', -1, null)];
      expect(AppLife.rowsFor(other, stale, meals, forma), isEmpty);
    });
  });
}

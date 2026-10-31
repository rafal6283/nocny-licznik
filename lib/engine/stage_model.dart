import 'dart:convert';
import 'dart:math';

import '../core/models.dart';

/// Cechy jednej minuty używane do rozpoznawania faz (wspólne dla dekodowania i uczenia).
class MinuteFeat {
  final int cat; // kategoria wzorca ruchu 0..6
  final bool snore;
  final bool? sound; // null = nieużywane (źródło ruchu = dźwięk)
  final bool? irregular; // oddech z sonaru nieregularny
  final int? hrBin; // tętno względem mediany nocy: 0 niższe, 1 typowe, 2 wyższe
  final int? rateBin; // tempo oddechu względem mediany nocy
  final int screen; // 0 brak, 1 ekran się włączył, 2 odblokowanie
  final bool? rustle; // szelest pościeli (null = nieużywane)
  const MinuteFeat(this.cat, this.snore, this.sound, this.irregular, this.hrBin, this.rateBin,
      {this.screen = 0, this.rustle});
}

/// Prawdopodobieństwa cech w każdej fazie (kolejność faz = Stage.values: wake, rem, light, deep).
/// Domyślne wartości to wiedza z literatury; po nocach z zegarkiem są dostrajane do konkretnej osoby.
class StageModel {
  final List<List<double>> em; // 4×7: P(kategoria ruchu | faza)
  final List<double> pSnore, pSound, pIrregular; // 4
  final List<List<double>> pRate, pHr; // 4×3
  final List<List<double>> pScreen; // 4×3: brak / ekran / odblokowanie
  final List<double> pRustle; // 4
  final int nights; // z ilu nocy z zegarkiem się nauczył (0 = domyślny)
  final int minutes;
  const StageModel(this.em, this.pSnore, this.pSound, this.pIrregular, this.pRate, this.pHr,
      {this.pScreen = _defScreen, this.pRustle = _defRustle, this.nights = 0, this.minutes = 0});

  static const _defScreen = [
    [0.86, 0.08, 0.06],
    [0.985, 0.013, 0.002],
    [0.985, 0.013, 0.002],
    [0.99, 0.0095, 0.0005],
  ];
  static const _defRustle = [0.35, 0.12, 0.10, 0.03];

  static const defaults = StageModel(
    [
      //   bezruch≥25  bezruch≥10  rzadkie-drobne  rzadkie-duże  częste-drobne  częste-duże  czuwanie
      [0.01, 0.03, 0.03, 0.06, 0.07, 0.12, 0.68],
      [0.03, 0.15, 0.22, 0.10, 0.33, 0.10, 0.07],
      [0.17, 0.33, 0.14, 0.18, 0.05, 0.08, 0.05],
      [0.70, 0.22, 0.04, 0.025, 0.005, 0.005, 0.005],
    ],
    [0.02, 0.06, 0.30, 0.38],
    [0.30, 0.06, 0.05, 0.01],
    [0.50, 0.45, 0.15, 0.06],
    [
      [0.15, 0.40, 0.45],
      [0.10, 0.35, 0.55],
      [0.25, 0.50, 0.25],
      [0.55, 0.40, 0.05],
    ],
    [
      [0.10, 0.30, 0.60],
      [0.12, 0.38, 0.50],
      [0.25, 0.50, 0.25],
      [0.55, 0.38, 0.07],
    ],
  );

  /// Model używany przy analizie nocy (ustawiany przez kalibrację).
  static StageModel current = defaults;

  bool get personalized => nights > 0;

  Map<String, Object?> toJson() => {
        'em': em,
        'snore': pSnore,
        'sound': pSound,
        'irr': pIrregular,
        'rate': pRate,
        'hr': pHr,
        'screen': pScreen,
        'rustle': pRustle,
        'nights': nights,
        'minutes': minutes,
      };

  static StageModel? fromJson(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      List<double> v(Object? x) => [for (final e in x as List) (e as num).toDouble()];
      List<List<double>> mx(Object? x) => [for (final r in x as List) v(r)];
      final out = StageModel(mx(m['em']), v(m['snore']), v(m['sound']), v(m['irr']), mx(m['rate']), mx(m['hr']),
          pScreen: m['screen'] != null ? mx(m['screen']) : _defScreen,
          pRustle: m['rustle'] != null ? v(m['rustle']) : _defRustle,
          nights: (m['nights'] as num?)?.toInt() ?? 0, minutes: (m['minutes'] as num?)?.toInt() ?? 0);
      if (out.em.length != 4 || out.em.any((r) => r.length != 7)) return null;
      return out;
    } catch (_) {
      return null;
    }
  }
}

/// Zliczenia cech w fazach wskazanych przez zegarek — z nich powstaje dostrojony model.
class StageCounts {
  final em = List.generate(4, (_) => List<double>.filled(7, 0));
  final snore = List.generate(4, (_) => List<double>.filled(2, 0)); // [nie, tak]
  final sound = List.generate(4, (_) => List<double>.filled(2, 0));
  final irr = List.generate(4, (_) => List<double>.filled(2, 0));
  final rate = List.generate(4, (_) => List<double>.filled(3, 0));
  final hr = List.generate(4, (_) => List<double>.filled(3, 0));
  final screen = List.generate(4, (_) => List<double>.filled(3, 0));
  final rustle = List.generate(4, (_) => List<double>.filled(2, 0));
  int nights = 0;
  int minutes = 0;

  void addMinute(int k, MinuteFeat f) {
    em[k][f.cat]++;
    snore[k][f.snore ? 1 : 0]++;
    if (f.sound != null) sound[k][f.sound! ? 1 : 0]++;
    if (f.irregular != null) irr[k][f.irregular! ? 1 : 0]++;
    if (f.rateBin != null) rate[k][f.rateBin!]++;
    if (f.hrBin != null) hr[k][f.hrBin!]++;
    screen[k][f.screen]++;
    if (f.rustle != null) rustle[k][f.rustle! ? 1 : 0]++;
    minutes++;
  }

  void _acc(List<List<double>> a, List<List<double>> b, double sign) {
    for (var i = 0; i < a.length; i++) {
      for (var j = 0; j < a[i].length; j++) {
        a[i][j] += sign * b[i][j];
      }
    }
  }

  void add(StageCounts o, [double sign = 1]) {
    _acc(em, o.em, sign);
    _acc(snore, o.snore, sign);
    _acc(sound, o.sound, sign);
    _acc(irr, o.irr, sign);
    _acc(rate, o.rate, sign);
    _acc(hr, o.hr, sign);
    _acc(screen, o.screen, sign);
    _acc(rustle, o.rustle, sign);
    nights += sign > 0 ? o.nights : -o.nights;
    minutes += sign > 0 ? o.minutes : -o.minutes;
  }

  StageCounts copy() => StageCounts()..add(this);

  /// Model bayesowski: domyślne prawdopodobieństwa jako „pseudo-obserwacje” o sile [w] minut na fazę.
  /// Przy kilku nocach dominuje wiedza ogólna, przy kilkunastu — Twoje dane.
  StageModel toModel({StageModel prior = StageModel.defaults, double w = 150}) {
    if (nights <= 0 || minutes < 60) return prior;
    List<double> row(List<double> p, List<double> c) {
      final tot = c.fold<double>(0, (a, b) => a + b);
      return [for (var j = 0; j < p.length; j++) max(1e-4, (p[j] * w + c[j]) / (w + tot))];
    }

    List<double> bin(List<double> p, List<List<double>> c) => [
          for (var k = 0; k < 4; k++) row([1 - p[k], p[k]], c[k])[1]
        ];
    return StageModel(
      [for (var k = 0; k < 4; k++) row(prior.em[k], em[k])],
      bin(prior.pSnore, snore),
      bin(prior.pSound, sound),
      bin(prior.pIrregular, irr),
      [for (var k = 0; k < 4; k++) row(prior.pRate[k], rate[k])],
      [for (var k = 0; k < 4; k++) row(prior.pHr[k], hr[k])],
      pScreen: [for (var k = 0; k < 4; k++) row(prior.pScreen[k], screen[k])],
      pRustle: bin(prior.pRustle, rustle),
      nights: nights,
      minutes: minutes,
    );
  }
}

/// Fazy z zegarka przypisane do minut nocy (null = brak danych w tej minucie lub „sen” bez fazy).
/// [rows] — zapisane w bazie odcinki: (start, 'wst', indeks fazy, długość w minutach).
List<int?> watchStagesFor(List<MinuteSample> ms, List<(DateTime, String, double?, double?)> rows) {
  final segs = [
    for (final r in rows)
      if (r.$2 == 'wst' && r.$3 != null && r.$4 != null)
        (r.$1, r.$1.add(Duration(seconds: (r.$4! * 60).round())), r.$3!.round())
  ];
  if (segs.isEmpty) return List<int?>.filled(ms.length, null);
  return [
    for (final m in ms)
      () {
        final mid = m.ts.subtract(const Duration(seconds: 30));
        for (final (a, b, k) in segs) {
          if (!mid.isBefore(a) && mid.isBefore(b)) return (k >= 0 && k < 4) ? k : null;
        }
        return null;
      }()
  ];
}

/// Indeks fazy (Stage.values) dla nazwy z Health Connect; null dla „sen” bez rozróżnienia.
int? watchStageIndex(String s) => switch (s) {
      'wake' => Stage.wake.index,
      'rem' => Stage.rem.index,
      'light' => Stage.light.index,
      'deep' => Stage.deep.index,
      _ => null,
    };

import 'dart:math';

import 'models.dart';
import 'weather.dart';

/// Czynnik pogodowy do porównań.
class WeatherFactor {
  final String id, label, emoji, unit, lowWord, highWord;
  final double? Function(Night) value;
  final int decimals;
  const WeatherFactor(this.id, this.label, this.emoji, this.unit, this.lowWord, this.highWord, this.value,
      [this.decimals = 0]);

  String fmt(double v) => '${v.toStringAsFixed(decimals)}$unit';
}

final weatherFactors = <WeatherFactor>[
  WeatherFactor('temp', 'Temperatura', '🌡️', '°C', 'chłodniej', 'cieplej', (n) => n.wTemp, 1),
  WeatherFactor('press', 'Ciśnienie', '🧭', ' hPa', 'niższe', 'wyższe', (n) => n.wPress),
  WeatherFactor('trend', 'Zmiana ciśnienia (24 h)', '📉', ' hPa', 'spadek', 'wzrost', (n) => n.wPressTrend, 1),
  WeatherFactor('hum', 'Wilgotność', '💧', '%', 'suszej', 'wilgotniej', (n) => n.wHum),
  WeatherFactor('wind', 'Wiatr', '🌬️', ' km/h', 'słabszy', 'silniejszy', (n) => n.wWind),
  WeatherFactor('cloud', 'Zachmurzenie', '☁️', '%', 'pogodniej', 'pochmurniej', (n) => n.wCloud),
  WeatherFactor('rain', 'Opady', '🌧️', ' mm', 'sucho', 'deszcz', (n) => n.wRain, 1),
  WeatherFactor('moon', 'Księżyc (oświetlenie)', '🌕', '%', 'bliżej nowiu', 'bliżej pełni',
      (n) => n.moonPhase == null ? null : WeatherService.illumination(n.moonPhase!) * 100),
];

/// Miara snu porównywana z pogodą.
class SleepOutcome {
  final String id, label;
  final double? Function(Night) value;
  final String Function(double delta) fmtDelta;
  final bool higherIsBetter;
  const SleepOutcome(this.id, this.label, this.value, this.fmtDelta, this.higherIsBetter);
}

String _signed(double v, String unit, [int dec = 0]) => '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(dec)}$unit';

List<SleepOutcome> sleepOutcomes({bool farts = false}) => [
      SleepOutcome('score', 'ocena', (n) => n.score.toDouble(), (d) => _signed(d, ' pkt'), true),
      SleepOutcome('sleep', 'sen', (n) => n.durationMin.toDouble(), (d) => _signed(d, ' min'), true),
      SleepOutcome('latency', 'zasypianie', (n) => n.latencyMin.toDouble(), (d) => _signed(d, ' min'), false),
      SleepOutcome('wake', 'przebudzenia', (n) => n.awakenings.toDouble(), (d) => _signed(d, '', 1), false),
      SleepOutcome('snore', 'chrapanie', (n) => n.snoreMin.toDouble(), (d) => _signed(d, ' min'), false),
      if (farts) SleepOutcome('farts', 'FF', (n) => n.fartCount.toDouble(), (d) => _signed(d, '', 1), false),
    ];

class OutcomeEffect {
  final SleepOutcome outcome;
  final double lowMean, highMean, r;
  const OutcomeEffect(this.outcome, this.lowMean, this.highMean, this.r);
  double get delta => highMean - lowMean;

  /// Czy przy WYŻSZEJ wartości czynnika sen jest lepszy.
  bool get highBetter => outcome.higherIsBetter ? delta > 0 : delta < 0;
}

class FactorImpact {
  final WeatherFactor factor;
  final int nights;
  final double lowMax, highMin; // granice tercyli
  final List<OutcomeEffect> effects;
  const FactorImpact(this.factor, this.nights, this.lowMax, this.highMin, this.effects);

  OutcomeEffect get score => effects.firstWhere((e) => e.outcome.id == 'score');
  double get strength => score.r.abs();
}

double pearson(List<double> x, List<double> y) {
  final n = x.length;
  if (n < 3) return 0;
  final mx = x.reduce((a, b) => a + b) / n, my = y.reduce((a, b) => a + b) / n;
  var sxy = 0.0, sxx = 0.0, syy = 0.0;
  for (var i = 0; i < n; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) * (x[i] - mx);
    syy += (y[i] - my) * (y[i] - my);
  }
  if (sxx <= 0 || syy <= 0) return 0;
  return sxy / sqrt(sxx * syy);
}

String strengthWord(double r) {
  final a = r.abs();
  if (a < 0.15) return 'brak wyraźnego związku';
  if (a < 0.3) return 'słaby związek';
  if (a < 0.5) return 'umiarkowany związek';
  return 'wyraźny związek';
}

/// Porównuje noce z najniższą i najwyższą 1/3 wartości czynnika. Minimum 6 nocy.
List<FactorImpact> weatherImpacts(List<Night> nights, {bool farts = false}) {
  final out = <FactorImpact>[];
  final outcomes = sleepOutcomes(farts: farts);
  for (final f in weatherFactors) {
    final pts = [
      for (final n in nights)
        if (f.value(n) != null && n.durationMin > 0) (n, f.value(n)!)
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    if (pts.length < 6) continue;
    // Opady: większość nocy ma 0 mm — porównujemy noce suche z deszczowymi.
    List<Night> low, high;
    double lowMax, highMin;
    if (f.id == 'rain') {
      low = [for (final p in pts) if (p.$2 < 0.2) p.$1];
      high = [for (final p in pts) if (p.$2 >= 0.2) p.$1];
      if (low.length < 2 || high.length < 2) continue;
      lowMax = 0.2;
      highMin = 0.2;
    } else {
      final k = max(2, pts.length ~/ 3);
      low = [for (final p in pts.take(k)) p.$1];
      high = [for (final p in pts.skip(pts.length - k)) p.$1];
      lowMax = pts[k - 1].$2;
      highMin = pts[pts.length - k].$2;
      if (highMin - lowMax <= 0 && f.id != 'trend') continue; // wszystkie wartości prawie takie same
    }
    final effects = <OutcomeEffect>[];
    for (final o in outcomes) {
      double m(List<Night> g) {
        final v = g.map(o.value).whereType<double>().toList();
        return v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
      }

      final xs = <double>[], ys = <double>[];
      for (final p in pts) {
        final y = o.value(p.$1);
        if (y == null) continue;
        xs.add(p.$2);
        ys.add(y);
      }
      effects.add(OutcomeEffect(o, m(low), m(high), pearson(xs, ys)));
    }
    out.add(FactorImpact(f, pts.length, lowMax, highMin, effects));
  }
  out.sort((a, b) => b.strength.compareTo(a.strength));
  return out;
}

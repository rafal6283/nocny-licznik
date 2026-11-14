import 'dart:math';

import 'db.dart';
import 'lifestyle.dart';
import 'models.dart';
import 'settings.dart';

typedef Ext = List<(DateTime, String, double?, double?)>;

/// Dane nocy do analizy czynników.
class NightCtx {
  final Night n;
  final Ext ext;
  final LifeFacts life;
  final Night? prev; // poprzednia noc
  NightCtx(this.n, this.ext, this.prev) : life = LifeFacts.of(n, ext);
}

/// Czynnik, który może wpływać na sen.
class Factor {
  final String id, emoji, label;
  final bool isBool;
  final String highWord, lowWord; // dla liczbowych: „cieplej” / „chłodniej”
  final String unit;
  final double? Function(NightCtx c, FactorEnv env) value;
  const Factor(this.id, this.emoji, this.label, this.value,
      {this.isBool = true, this.highWord = '', this.lowWord = '', this.unit = ''});
}

/// Wspólne dane do liczenia czynników (np. typowa pora snu).
class FactorEnv {
  final double medianBedMin; // minuty od 18:00
  const FactorEnv(this.medianBedMin);
}

double _bedMin(DateTime t) {
  var m = (t.hour - 18) * 60.0 + t.minute;
  if (m < 0) m += 24 * 60;
  return m;
}

/// Miara snu (wynik).
class Outcome {
  final String id, label, unit;
  final bool higherBetter;
  final double? Function(Night n) value;
  final int decimals;
  const Outcome(this.id, this.label, this.unit, this.higherBetter, this.value, [this.decimals = 0]);

  String fmtDelta(double d) => '${d >= 0 ? '+' : '−'}${d.abs().toStringAsFixed(decimals)}$unit';
}

final outcomes = <Outcome>[
  Outcome('score', 'ocena', ' pkt', true, (n) => n.score.toDouble()),
  Outcome('sleep', 'czas snu', ' min', true, (n) => n.durationMin.toDouble()),
  Outcome('deep', 'sen głęboki', ' min', true, (n) => n.deepMin.toDouble()),
  Outcome('latency', 'zasypianie', ' min', false, (n) => n.latencyMin.toDouble()),
  Outcome('wake', 'przebudzenia', '', false, (n) => n.awakenings.toDouble(), 1),
  Outcome('ahi', 'AHI z aparatu', '/h', false, (n) => n.cpapAhi, 1),
  Outcome('hr', 'tętno w nocy', '/min', false, (n) => n.hrAvg, 0),
];

List<Factor> factorsFor(List<NightCtx> all) {
  final tags = <String, int>{};
  for (final c in all) {
    for (final t in c.n.tags) {
      tags[t] = (tags[t] ?? 0) + 1;
    }
  }
  return [
    Factor('late_bed', '🌙', 'Późno do łóżka (≥45 min po zwykłej porze)',
        (c, e) => (_bedMin(c.n.start) - e.medianBedMin) >= 45 ? 1 : 0),
    Factor('early_bed', '🌆', 'Wcześnie do łóżka (≥45 min przed zwykłą porą)',
        (c, e) => (e.medianBedMin - _bedMin(c.n.start)) >= 45 ? 1 : 0),
    Factor('short_prev', '😵', 'Poprzednia noc krótsza niż 6 h',
        (c, e) => c.prev == null ? null : (c.prev!.durationMin < 360 ? 1 : 0)),
    Factor('caf', '☕', 'Kofeina po 14:00', (c, e) => c.life.hasData ? (c.life.caffeineAfter14 ? 1 : 0) : null),
    Factor('alc', '🍷', 'Alkohol wieczorem', (c, e) {
      final tag = c.n.tags.any((t) => Lifestyle.isAlcohol(t) || t.toLowerCase().contains('alko'));
      if (tag) return 1;
      return c.life.hasData ? (c.life.alcohol ? 1 : 0) : null;
    }),
    Factor('late_meal', '🍽️', 'Posiłek mniej niż 2 h przed snem',
        (c, e) => c.life.hasData && c.life.hoursSinceMeal != null ? (c.life.lateMeal ? 1 : 0) : null),
    Factor('eve_kcal', '🍕', 'Kalorie po 18:00', (c, e) => c.life.eveningKcal,
        isBool: false, highWord: 'więcej', lowWord: 'mniej', unit: ' kcal'),
    Factor('workout', '🏃', 'Trening tego dnia', (c, e) => c.life.hasData ? (c.life.workout ? 1 : 0) : null),
    Factor('late_workout', '🏋️', 'Trening mniej niż 3 h przed snem',
        (c, e) => c.life.hasData ? (c.life.lateWorkout ? 1 : 0) : null),
    Factor('room_temp', '🌡️', 'Temperatura w sypialni', (c, e) => c.n.roomTemp,
        isBool: false, highWord: 'cieplej', lowWord: 'chłodniej', unit: ' °C'),
    Factor('room_hum', '💧', 'Wilgotność w sypialni', (c, e) => c.n.roomHum,
        isBool: false, highWord: 'wilgotniej', lowWord: 'suszej', unit: '%'),
    Factor('w_temp', '🌤️', 'Temperatura na zewnątrz', (c, e) => c.n.wTemp,
        isBool: false, highWord: 'cieplej', lowWord: 'chłodniej', unit: ' °C'),
    Factor('w_press', '📉', 'Zmiana ciśnienia (24 h)', (c, e) => c.n.wPressTrend,
        isBool: false, highWord: 'wzrost', lowWord: 'spadek', unit: ' hPa'),
    Factor('noise', '🔊', 'Hałas w nocy', (c, e) => c.n.avgNoise,
        isBool: false, highWord: 'głośniej', lowWord: 'ciszej', unit: ' dB'),
    Factor('light', '💡', 'Światło w sypialni', (c, e) => c.n.avgLux,
        isBool: false, highWord: 'jaśniej', lowWord: 'ciemniej', unit: ' lx'),
    Factor('leak', '😷', 'Nieszczelność maski (95%)', (c, e) => c.n.cpap ? c.n.cpapLeak95 : null,
        isBool: false, highWord: 'większa', lowWord: 'mniejsza', unit: ' L/min'),
    for (final t in tags.entries)
      if (t.value >= 3) Factor('tag:${t.key}', '#', '#${t.key}', (c, e) => c.n.tags.contains(t.key) ? 1 : 0),
  ];
}

/// Efekt czynnika na miarę snu.
class Effect {
  final Factor factor;
  final Outcome outcome;
  final int nHigh, nLow;
  final double meanHigh, meanLow, d; // d = efekt w odchyleniach standardowych
  final double lowMax, highMin; // granice tercyli (liczbowe)
  const Effect(this.factor, this.outcome, this.nHigh, this.nLow, this.meanHigh, this.meanLow, this.d, this.lowMax, this.highMin);
  double get delta => meanHigh - meanLow;

  /// true, gdy „wysoka”/obecna wartość czynnika poprawia sen.
  bool get helps => outcome.higherBetter ? delta > 0 : delta < 0;
}

class FactorReport {
  final List<NightCtx> nights;
  final List<Factor> factors;
  final List<Effect> effects; // tylko istotne praktycznie (|d| ≥ 0,35)
  final FactorEnv env;
  FactorReport(this.nights, this.factors, this.effects, this.env);

  /// Stan czynnika danej nocy: 1 = obecny/wysoki, -1 = niski (liczbowe), 0 = typowy, null = brak danych.
  int? state(Factor f, NightCtx c) {
    final v = f.value(c, env);
    if (v == null) return null;
    if (f.isBool) return v >= 0.5 ? 1 : 0;
    final e = effects.where((x) => x.factor.id == f.id).firstOrNull;
    if (e == null) return 0;
    if (v >= e.highMin) return 1;
    if (v <= e.lowMax) return -1;
    return 0;
  }
}

class Insights {
  static Future<FactorReport> build({int limit = 180}) async {
    final ns = (await Db.instance.nights(limit: limit)).reversed.toList(); // od najstarszej
    final ctx = <NightCtx>[];
    Night? prev;
    for (final n in ns) {
      if (n.id == null || n.durationMin < 120) {
        prev = n;
        continue;
      }
      ctx.add(NightCtx(n, await Db.instance.ext(n.id!), prev));
      prev = n;
    }
    final beds = [for (final c in ctx) _bedMin(c.n.start)]..sort();
    final env = FactorEnv(beds.isEmpty ? 300 : beds[beds.length ~/ 2]);
    final factors = factorsFor(ctx);
    final effects = <Effect>[];
    final useFarts = Settings.instance.detectFarts;
    final outs = [
      ...outcomes,
      if (useFarts) Outcome('farts', 'wiatry', '', false, (n) => n.fartCount.toDouble(), 1),
    ];
    for (final f in factors) {
      final pts = <(NightCtx, double)>[];
      for (final c in ctx) {
        final v = f.value(c, env);
        if (v != null) pts.add((c, v));
      }
      if (pts.length < 8) continue;
      List<NightCtx> hi, lo;
      double lowMax = 0, highMin = 1;
      if (f.isBool) {
        hi = [for (final p in pts) if (p.$2 >= 0.5) p.$1];
        lo = [for (final p in pts) if (p.$2 < 0.5) p.$1];
      } else {
        pts.sort((a, b) => a.$2.compareTo(b.$2));
        final k = max(3, pts.length ~/ 3);
        lo = [for (final p in pts.take(k)) p.$1];
        hi = [for (final p in pts.skip(pts.length - k)) p.$1];
        lowMax = pts[k - 1].$2;
        highMin = pts[pts.length - k].$2;
        if (highMin <= lowMax) continue;
      }
      if (hi.length < 4 || lo.length < 4) continue;
      for (final o in outs) {
        final a = [for (final c in hi) if (o.value(c.n) != null) o.value(c.n)!];
        final b = [for (final c in lo) if (o.value(c.n) != null) o.value(c.n)!];
        if (a.length < 4 || b.length < 4) continue;
        final ma = a.reduce((x, y) => x + y) / a.length, mb = b.reduce((x, y) => x + y) / b.length;
        double vr(List<double> v, double m) => v.map((x) => (x - m) * (x - m)).reduce((x, y) => x + y) / max(1, v.length - 1);
        final sd = sqrt((vr(a, ma) * (a.length - 1) + vr(b, mb) * (b.length - 1)) / max(1, a.length + b.length - 2));
        if (sd <= 1e-9) continue;
        final d = (ma - mb) / sd;
        if (d.abs() < 0.35) continue;
        effects.add(Effect(f, o, a.length, b.length, ma, mb, d, lowMax, highMin));
      }
    }
    effects.sort((x, y) => y.d.abs().compareTo(x.d.abs()));
    return FactorReport(ctx, factors, effects, env);
  }

  /// Wyjaśnienia dla jednej nocy: czynniki obecne tej nocy i ich typowy wpływ.
  static List<NightExplanation> explain(FactorReport r, Night n) {
    final c = r.nights.where((x) => x.n.id == n.id).firstOrNull;
    if (c == null) return [];
    final out = <NightExplanation>[];
    for (final f in r.factors) {
      final st = r.state(f, c);
      if (st == null || st == 0) continue;
      final effs = r.effects.where((e) => e.factor.id == f.id).toList();
      if (effs.isEmpty) continue;
      // dla niskiej wartości liczbowego czynnika efekt odwrotny
      final sign = st == 1 ? 1.0 : -1.0;
      final parts = <String>[];
      var weight = 0.0;
      var good = 0.0;
      for (final e in effs.take(3)) {
        parts.add('${e.outcome.label} ${e.outcome.fmtDelta(sign * e.delta)}');
        weight = max(weight, e.d.abs());
        good += (e.helps ? 1 : -1) * sign * e.d.abs();
      }
      final what = f.isBool ? f.label : '${f.label}: ${st == 1 ? f.highWord : f.lowWord}';
      final v = f.value(c, r.env);
      final valTxt = f.isBool || v == null ? '' : ' (${v.toStringAsFixed(v.abs() >= 100 ? 0 : 1)}${f.unit})';
      out.add(NightExplanation(f.emoji, '$what$valTxt', 'zwykle: ${parts.join(', ')}', good >= 0, weight));
    }
    out.sort((a, b) => b.weight.compareTo(a.weight));
    return out;
  }
}

class NightExplanation {
  final String emoji, title, detail;
  final bool positive;
  final double weight;
  const NightExplanation(this.emoji, this.title, this.detail, this.positive, this.weight);
}

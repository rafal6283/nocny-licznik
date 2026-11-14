import 'dart:convert';
import 'dart:math';

import 'db.dart';
import 'fmt.dart';
import 'insights.dart';
import 'models.dart';
import 'settings.dart';

/// Eksperyment snu: porównanie dwóch wariantów (A/B).
/// • 'ab' — noce losowane w parach (jedna A, druga B), aplikacja mówi wieczorem, który wariant dziś;
/// • 'before' — A = noce przed startem (do [days] wstecz), B = noce od startu.
class Experiment {
  final String id, name, a, b, mode;
  final DateTime start;
  final int days;
  bool stopped;
  Experiment(this.id, this.name, this.a, this.b, this.mode, this.start, this.days, {this.stopped = false});

  DateTime get end => start.add(Duration(days: days));
  bool get active => !stopped && DateTime.now().isBefore(end);

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'a': a,
        'b': b,
        'mode': mode,
        'start': start.millisecondsSinceEpoch,
        'days': days,
        'stopped': stopped,
      };

  static Experiment fromJson(Map<String, dynamic> m) => Experiment(
        m['id'] as String,
        m['name'] as String,
        m['a'] as String,
        m['b'] as String,
        m['mode'] as String,
        DateTime.fromMillisecondsSinceEpoch((m['start'] as num).toInt()),
        (m['days'] as num).toInt(),
        stopped: m['stopped'] == true,
      );

  /// Wariant dla nocy z datą [day] (data wieczoru) albo null, gdy noc nie należy do eksperymentu.
  String? armFor(DateTime day) {
    final d0 = DateTime(start.year, start.month, start.day);
    final d = DateTime(day.year, day.month, day.day);
    final idx = d.difference(d0).inDays;
    if (mode == 'before') {
      if (idx < 0 && idx >= -days) return 'A';
      if (idx >= 0 && idx < days) return 'B';
      return null;
    }
    if (idx < 0 || idx >= days) return null;
    // pary nocy: w każdej parze losowo A/B i odwrotnie (stałe ziarno = id eksperymentu)
    final pair = idx ~/ 2;
    final r = Random(_seed(id) ^ (pair * 7919));
    final firstA = r.nextBool();
    return (idx % 2 == 0) == firstA ? 'A' : 'B';
  }

  String armLabel(String arm) => arm == 'A' ? a : b;

  static int _seed(String s) {
    var h = 17;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }
}

class ArmStats {
  final int n;
  final double mean, sd;
  const ArmStats(this.n, this.mean, this.sd);
}

class ExperimentResult {
  final Outcome outcome;
  final ArmStats a, b;
  final double p; // przybliżone p (test t Welcha)
  const ExperimentResult(this.outcome, this.a, this.b, this.p);
  double get diff => b.mean - a.mean;
  bool get bBetter => outcome.higherBetter ? diff > 0 : diff < 0;

  String get verdict {
    if (a.n < 3 || b.n < 3) return 'za mało nocy';
    if (p < 0.05) return bBetter ? 'B wyraźnie lepiej' : 'B wyraźnie gorzej';
    if (p < 0.2) return bBetter ? 'B możliwie lepiej — przedłuż' : 'B możliwie gorzej — przedłuż';
    return 'bez wyraźnej różnicy';
  }
}

class Experiments {
  static List<Experiment> all() {
    final s = Settings.instance.experimentsJson;
    if (s.isEmpty) return [];
    try {
      return [for (final m in jsonDecode(s) as List) Experiment.fromJson(m as Map<String, dynamic>)];
    } catch (_) {
      return [];
    }
  }

  static void save(List<Experiment> l) => Settings.instance.experimentsJson = jsonEncode([for (final e in l) e.toJson()]);

  static void add(Experiment e) => save([...all(), e]);

  static void update(Experiment e) => save([for (final x in all()) x.id == e.id ? e : x]);

  static void remove(String id) => save([for (final x in all()) if (x.id != id) x]);

  /// Aktywny eksperyment A/B i wariant na dzisiejszą noc.
  static (Experiment, String)? tonight() {
    final now = DateTime.now();
    final day = now.hour < 12 ? now.subtract(const Duration(days: 1)) : now;
    for (final e in all()) {
      if (!e.active || e.mode != 'ab') continue;
      final arm = e.armFor(day);
      if (arm != null) return (e, arm);
    }
    return null;
  }

  static Future<List<ExperimentResult>> results(Experiment e) async {
    final nights = await Db.instance.nights(limit: 400);
    final a = <Night>[], b = <Night>[];
    for (final n in nights) {
      if (n.durationMin < 120) continue;
      final arm = e.armFor(nightOf(n.start));
      if (arm == 'A') a.add(n);
      if (arm == 'B') b.add(n);
    }
    final out = <ExperimentResult>[];
    for (final o in outcomes) {
      final va = [for (final n in a) if (o.value(n) != null) o.value(n)!];
      final vb = [for (final n in b) if (o.value(n) != null) o.value(n)!];
      if (va.isEmpty && vb.isEmpty) continue;
      final sa = _stats(va), sb = _stats(vb);
      out.add(ExperimentResult(o, sa, sb, _welchP(sa, sb)));
    }
    return out;
  }

  static ArmStats _stats(List<double> v) {
    if (v.isEmpty) return const ArmStats(0, 0, 0);
    final m = v.reduce((x, y) => x + y) / v.length;
    final sd = v.length < 2 ? 0.0 : sqrt(v.map((x) => (x - m) * (x - m)).reduce((x, y) => x + y) / (v.length - 1));
    return ArmStats(v.length, m, sd);
  }

  /// p dwustronne testu t Welcha (przybliżenie rozkładu t przez normalny z poprawką).
  static double _welchP(ArmStats a, ArmStats b) {
    if (a.n < 2 || b.n < 2) return 1;
    final va = a.sd * a.sd / a.n, vb = b.sd * b.sd / b.n;
    final se = sqrt(va + vb);
    if (se <= 1e-12) return a.mean == b.mean ? 1 : 0;
    final t = (b.mean - a.mean).abs() / se;
    final df = pow(va + vb, 2) / (va * va / (a.n - 1) + vb * vb / (b.n - 1));
    final z = t * (1 - 1 / (4 * df)) / sqrt(1 + t * t / (2 * df));
    return (2 * (1 - _phi(z))).clamp(0.0, 1.0);
  }

  static double _phi(double z) {
    // dystrybuanta rozkładu normalnego (Abramowitz–Stegun 26.2.17)
    final t = 1 / (1 + 0.2316419 * z.abs());
    final d = 0.3989423 * exp(-z * z / 2);
    final p = d * t * (0.3193815 + t * (-0.3565638 + t * (1.781478 + t * (-1.821256 + t * 1.330274))));
    return z >= 0 ? 1 - p : p;
  }
}

/// Gotowe pomysły na eksperymenty.
const experimentPresets = <(String, String, String, String)>[
  ('Kawa po 14:00', 'kawa jak zwykle', 'bez kawy i herbaty po 14:00', 'ab'),
  ('Ekran przed snem', 'telefon do zaśnięcia', 'bez ekranu 1 h przed snem', 'ab'),
  ('Szum do zasypiania', 'w ciszy', 'z kołysanką/szumem', 'ab'),
  ('Chłodniejsza sypialnia', 'jak zwykle', 'wywietrzone, chłodniej', 'ab'),
  ('Późna kolacja', 'kolacja jak zwykle', 'ostatni posiłek ≥3 h przed snem', 'ab'),
  ('Alkohol', 'bez alkoholu', 'lampka/piwo wieczorem', 'ab'),
  ('Wcześniejsza pora snu', 'jak dotąd', '30 min wcześniej', 'before'),
  ('Rampa CPAP', 'rampa jak dotąd', 'zmieniona rampa', 'before'),
  ('Nawilżacz CPAP', 'nawilżacz jak dotąd', 'nawilżacz o poziom wyżej', 'before'),
  ('Nowa maska / poduszka', 'dotychczasowa', 'nowa', 'before'),
];

import 'dart:convert';
import 'dart:math';

import '../engine/night_engine.dart';
import '../engine/sleep_analysis.dart';
import '../engine/stage_model.dart';
import 'bus.dart';
import 'db.dart';
import 'models.dart';
import 'settings.dart';
import 'sound_thresholds.dart';

typedef ExtRow = (DateTime, String, double?, double?);

/// Dane jednej nocy potrzebne do oceny dokładności i kalibracji.
class CalibNight {
  final Night night;
  final List<MinuteSample> ms;
  final List<SoundEvent> evs;
  final List<ExtRow> ext;
  final List<int?> watch;
  CalibNight(this.night, this.ms, this.evs, this.ext) : watch = watchStagesFor(ms, ext);

  int get watchMinutes => watch.where((w) => w != null).length;
  bool get hasWatch => watchMinutes >= 60;

  static const respKinds = {'ev_oa', 'ev_ca', 'ev_h', 'ev_a'};
  List<ExtRow> get cpapEvents => [for (final r in ext) if (respKinds.contains(r.$2)) r];
  bool get hasCpapEvents => usage.isNotEmpty && ext.any((r) => r.$2.startsWith('ev_'));
  bool get hasCpapSnore => ext.any((r) => r.$2 == 'snore');

  /// Minuty (od epoki), w których aparat pracował — z przebiegów PLD.
  late final Set<int> usage = {
    for (final r in ext)
      if (r.$2 == 'press' || r.$2 == 'leak') r.$1.millisecondsSinceEpoch ~/ 60000
  };

  bool inUsage(DateTime t) => usage.contains(t.millisecondsSinceEpoch ~/ 60000);
}

/// Zgodność faz snu z zegarkiem.
class StageAccuracy {
  final Night night;
  final int minutes;
  final double agreeDefault, agreeTuned; // 0..1, sam telefon (bez zegarka)
  final double kappaDefault, kappaTuned;
  const StageAccuracy(this.night, this.minutes, this.agreeDefault, this.agreeTuned, this.kappaDefault, this.kappaTuned);
}

/// Porównanie wykryć z danymi aparatu (bezdechy lub chrapanie).
class DeviceMatch {
  int nights = 0;
  double hours = 0;
  int device = 0, ours = 0, matchedDevice = 0, matchedOurs = 0;
  double? get sensitivity => device == 0 ? null : matchedDevice / device;
  double? get precision => ours == 0 ? null : matchedOurs / ours;
}

class LabelStats {
  int yes = 0, no = 0;
  double? threshold;
}

class CalibReport {
  final List<StageAccuracy> stages = [];
  StageModel model = StageModel.defaults;
  final DeviceMatch apnea = DeviceMatch();
  final DeviceMatch snore = DeviceMatch(); // w minutach
  final Map<SoundType, LabelStats> labels = {};
  final List<String> changes = [];

  double? _avg(double Function(StageAccuracy) f) {
    if (stages.isEmpty) return null;
    final w = stages.fold<int>(0, (s, a) => s + a.minutes);
    return stages.fold<double>(0, (s, a) => s + f(a) * a.minutes) / max(1, w);
  }

  double? get agreeDefault => _avg((a) => a.agreeDefault);
  double? get agreeTuned => _avg((a) => a.agreeTuned);
  double? get kappaDefault => _avg((a) => a.kappaDefault);
  double? get kappaTuned => _avg((a) => a.kappaTuned);
}

class Calibration {
  static const snoreDeviceThr = 0.2; // średni indeks chrapania ResMed w minucie
  static const _matchPad = Duration(seconds: 30);
  static bool _running = false;

  /// Przy starcie aplikacji: wczytuje zapisany model i progi.
  static void load() {
    final s = Settings.instance;
    StageModel.current = StageModel.fromJson(s.stageModelJson) ?? StageModel.defaults;
    SoundThresholds.loadJson(s.minConfJson);
  }

  static Future<List<CalibNight>> gather({int limit = 150}) async {
    final out = <CalibNight>[];
    for (final n in await Db.instance.nights(limit: limit)) {
      if (n.id == null) continue;
      final ext = await Db.instance.ext(n.id!);
      final evs = await Db.instance.events(n.id!);
      final hasExt = ext.any((r) => r.$2 == 'wst' || r.$2.startsWith('ev_') || r.$2 == 'snore');
      final hasLabels = evs.any((e) => e.verified != null);
      if (!hasExt && !hasLabels) continue;
      final ms = hasExt ? await Db.instance.minutes(n.id!) : <MinuteSample>[];
      out.add(CalibNight(n, ms, evs, ext));
    }
    return out;
  }

  // ------------------------------------------------------------------ fazy
  static StageCounts? countsFor(CalibNight d) {
    if (!d.hasWatch || d.ms.isEmpty) return null;
    final f = SleepAnalysis.features(d.ms);
    if (f == null) return null;
    final c = StageCounts()..nights = 1;
    for (var i = 0; i < d.ms.length; i++) {
      final w = d.watch[i];
      if (w != null) c.addMinute(w, f.$1[i]);
    }
    return c.minutes >= 60 ? c : null;
  }

  /// Fazy „sam telefon” (bez zegarka) dla danego modelu; nie zmienia zapisanych faz.
  static List<int> phoneOnly(List<MinuteSample> ms, StageModel m) {
    final saved = [for (final x in ms) x.stage];
    SleepAnalysis.analyze(ms, goalMin: Settings.instance.sleepGoalMin, model: m);
    final out = [for (final x in ms) x.stage.index];
    for (var i = 0; i < ms.length; i++) {
      ms[i].stage = saved[i];
    }
    return out;
  }

  static (double, double) agreement(List<int> pred, List<int?> truth) {
    final cm = List.generate(4, (_) => List<int>.filled(4, 0));
    var n = 0;
    for (var i = 0; i < pred.length && i < truth.length; i++) {
      final t = truth[i];
      if (t == null) continue;
      cm[t][pred[i]]++;
      n++;
    }
    if (n == 0) return (0, 0);
    var agree = 0;
    var pe = 0.0;
    for (var k = 0; k < 4; k++) {
      agree += cm[k][k];
      final row = cm[k].fold<int>(0, (a, b) => a + b);
      final col = [for (var j = 0; j < 4; j++) cm[j][k]].fold<int>(0, (a, b) => a + b);
      pe += (row / n) * (col / n);
    }
    final po = agree / n;
    final kappa = pe >= 1 ? 0.0 : (po - pe) / (1 - pe);
    return (po, kappa);
  }

  // ------------------------------------------------------------------ aparat CPAP
  static bool _overlap(DateTime a0, DateTime a1, DateTime b0, DateTime b1) =>
      !a1.add(_matchPad).isBefore(b0) && !b1.add(_matchPad).isBefore(a0);

  /// Dopasowanie naszych bezdechów/spłyceń do zdarzeń z aparatu. Zwraca etykiety (pewność, trafienie)
  /// dla naszych niezweryfikowanych zdarzeń z czasu pracy aparatu.
  static List<(SoundType, double, bool)> _matchApnea(CalibNight d, DeviceMatch acc) {
    final labels = <(SoundType, double, bool)>[];
    if (!d.hasCpapEvents) return labels;
    final dev = [
      for (final r in d.cpapEvents)
        (r.$1, r.$1.add(Duration(milliseconds: ((r.$4 ?? 10) * 1000).round())))
    ];
    final ours = [
      for (final e in d.evs)
        if ((e.type == SoundType.apnea || e.type == SoundType.hypopnea) && d.inUsage(e.ts)) e
    ];
    acc.nights++;
    acc.hours += d.usage.length / 60.0;
    acc.device += dev.length;
    final counted = ours.where((e) => e.counts).toList();
    acc.ours += counted.length;
    for (final (a, b) in dev) {
      if (counted.any((e) => _overlap(a, b, e.ts, e.ts.add(Duration(milliseconds: max(10000, e.durationMs)))))) {
        acc.matchedDevice++;
      }
    }
    for (final e in ours) {
      final e1 = e.ts.add(Duration(milliseconds: max(10000, e.durationMs)));
      final hit = dev.any((x) => _overlap(x.$1, x.$2, e.ts, e1));
      if (e.counts && hit) acc.matchedOurs++;
      if (e.verified == null) labels.add((e.type, e.confidence, hit));
    }
    return labels;
  }

  static List<(SoundType, double, bool)> _matchSnore(CalibNight d, DeviceMatch acc) {
    final labels = <(SoundType, double, bool)>[];
    if (!d.hasCpapSnore || d.ms.isEmpty) return labels;
    final dev = <int, double>{
      for (final r in d.ext)
        if (r.$2 == 'snore' && r.$3 != null) r.$1.millisecondsSinceEpoch ~/ 60000: r.$3!
    };
    bool devSnore(int minute) => [minute - 1, minute, minute + 1].any((m) => (dev[m] ?? 0) >= snoreDeviceThr);
    acc.nights++;
    var used = 0;
    for (final m in d.ms) {
      final minute = m.ts.subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 60000;
      if (!d.usage.contains(minute) || !dev.containsKey(minute)) continue;
      used++;
      final ds = (dev[minute] ?? 0) >= snoreDeviceThr;
      if (ds) acc.device++;
      if (m.snore) acc.ours++;
      if (ds && m.snore) {
        acc.matchedDevice++;
        acc.matchedOurs++;
      }
    }
    acc.hours += used / 60.0;
    for (final e in d.evs) {
      if (e.type != SoundType.snore || e.verified != null || !d.inUsage(e.ts)) continue;
      labels.add((SoundType.snore, e.confidence, devSnore(e.ts.millisecondsSinceEpoch ~/ 60000)));
    }
    return labels;
  }

  // ------------------------------------------------------------------ progi
  /// Próg pewności maksymalizujący F1; null = za mało danych, 0 = próg niepotrzebny.
  static double? bestThreshold(List<(double, bool)> lab) {
    final pos = lab.where((l) => l.$2).length, neg = lab.length - pos;
    if (lab.length < 8 || pos < 2 || neg < 2) return null;
    double f1(double t) {
      var tp = 0, fp = 0, fn = 0;
      for (final (c, y) in lab) {
        final keep = c >= t;
        if (keep && y) tp++;
        if (keep && !y) fp++;
        if (!keep && y) fn++;
      }
      return 2 * tp / max(1, 2 * tp + fp + fn);
    }

    final base = f1(0);
    var best = 0.0, bestF = base;
    for (final c in {for (final l in lab) l.$1}) {
      final f = f1(c);
      if (f > bestF + 1e-9) {
        bestF = f;
        best = c;
      }
    }
    return bestF - base >= 0.05 ? best : 0;
  }

  // ------------------------------------------------------------------ całość
  /// Ocenia dokładność i (gdy [apply]) zapisuje dostrojony model, progi i czułość chrapania,
  /// a potem przelicza noce. Zwraca raport do ekranu „Dokładność”.
  static Future<CalibReport> run({bool apply = true}) async {
    final rep = CalibReport();
    while (_running) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _running = true;
    try {
      final data = await gather();
      final s = Settings.instance;

      // Fazy: model z wszystkich nocy z zegarkiem; ocena „z pominięciem” danej nocy.
      final per = <CalibNight, StageCounts>{};
      for (final d in data) {
        final c = countsFor(d);
        if (c != null) per[d] = c;
      }
      final total = StageCounts();
      for (final c in per.values) {
        total.add(c);
      }
      rep.model = total.toModel();
      for (final e in per.entries) {
        final loo = total.copy()..add(e.value, -1);
        final tuned = loo.toModel();
        final pd = phoneOnly(e.key.ms, StageModel.defaults);
        final pt = phoneOnly(e.key.ms, tuned);
        final (ad, kd) = agreement(pd, e.key.watch);
        final (at, kt) = agreement(pt, e.key.watch);
        rep.stages.add(StageAccuracy(e.key.night, e.key.watchMinutes, ad, at, kd, kt));
      }
      rep.stages.sort((a, b) => b.night.start.compareTo(a.night.start));

      // Aparat CPAP + oceny nagrań → etykiety do progów
      final lab = <SoundType, List<(double, bool)>>{};
      for (final d in data) {
        for (final (t, c, y) in [..._matchApnea(d, rep.apnea), ..._matchSnore(d, rep.snore)]) {
          lab.putIfAbsent(t, () => []).add((c, y));
        }
        for (final e in d.evs) {
          if (e.verified == null) continue;
          final st = rep.labels.putIfAbsent(e.type, () => LabelStats());
          e.verified! ? st.yes++ : st.no++;
          lab.putIfAbsent(e.type, () => []).add((e.confidence, e.verified!));
        }
      }
      final newThr = <String, double>{};
      for (final e in lab.entries) {
        final t = bestThreshold(e.value);
        rep.labels.putIfAbsent(e.key, () => LabelStats()).threshold = t;
        if (t != null && t > 0) newThr[e.key.name] = t;
      }

      if (apply && s.autoCalibration) {
        var reanalyze = false;
        // model faz
        if (total.nights > 0 && total.nights != StageModel.current.nights) {
          StageModel.current = rep.model;
          s.stageModelJson = (StageModel.current.personalized) ? _json(StageModel.current) : '';
          rep.changes.add('fazy snu dostrojone na ${total.nights} ${total.nights == 1 ? 'nocy' : 'nocach'} z zegarkiem');
          reanalyze = true;
        }
        // progi pewności
        String fmt(Map<String, double> m) => (m.keys.toList()..sort()).map((k) => '$k:${m[k]!.toStringAsFixed(2)}').join(',');
        if (fmt(newThr) != fmt(SoundThresholds.map)) {
          SoundThresholds.map = newThr;
          s.minConfJson = SoundThresholds.toJson();
          rep.changes.add('progi pewności dźwięków: ${newThr.isEmpty ? 'bez progów' : newThr.keys.length}');
          reanalyze = true;
        }
        // czułość chrapania (na żywo) — tylko gdy przybyły noce z danymi z aparatu
        final sn = rep.snore;
        if (sn.nights >= 3 && sn.hours >= 6 && sn.nights > s.calibSnoreNights) {
          final old = s.snoreSensitivity;
          var v = old;
          final prec = sn.precision, sens = sn.sensitivity;
          if (prec != null && prec < 0.5 && sn.ours > sn.device * 1.5 + 10) v -= 0.05;
          if (sens != null && sens < 0.5 && sn.device >= 20) v += 0.05;
          v = v.clamp(0.2, 0.9);
          if ((v - old).abs() > 1e-6) {
            s.snoreSensitivity = v;
            rep.changes.add('czułość chrapania ${(old * 100).round()}% → ${(v * 100).round()}%');
          }
          s.calibSnoreNights = sn.nights;
        }
        if (reanalyze) {
          await NightEngine.reanalyzeAll();
          dataChanged();
        }
      }
    } finally {
      _running = false;
    }
    return rep;
  }

  static String _json(StageModel m) => jsonEncode(m.toJson());
}

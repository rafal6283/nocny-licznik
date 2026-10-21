import 'dart:math';

import '../core/models.dart';

/// Wynik analizy nocy.
class SleepSummary {
  final int inBedMin, sleepMin, deepMin, lightMin, remMin, awakeMin, latencyMin, awakenings, score;
  const SleepSummary({
    required this.inBedMin,
    required this.sleepMin,
    required this.deepMin,
    required this.lightMin,
    required this.remMin,
    required this.awakeMin,
    required this.latencyMin,
    required this.awakenings,
    required this.score,
  });
}

/// Szacowanie faz snu z aktygrafii (ruch telefonu leżącego na materacu) i dźwięku.
/// To estymacja, nie polisomnografia.
class SleepAnalysis {
  static double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }

  /// Wygładzona, znormalizowana aktywność na minutę.
  static List<double> activity(List<MinuteSample> ms) {
    if (ms.isEmpty) return [];
    final motion = ms.map((m) => m.motion).toList();
    final hasMotion = motion.any((m) => m > 0.05);
    final base = <double>[];
    if (hasMotion) {
      final med = _median(motion.where((m) => m > 0).toList());
      final scale = max(med, 0.02);
      for (final m in ms) {
        base.add(m.motion / scale + m.farts * 0.3);
      }
    } else {
      // Brak ruchu (telefon nie leży na łóżku) — zastępczo z głośności otoczenia.
      final noise = ms.map((m) => m.noiseDb).toList();
      final med = _median(noise);
      for (final m in ms) {
        base.add(max(0.0, (m.noiseDb - med) / 3.0) + m.farts * 0.3);
      }
    }
    const w = [0.15, 0.15, 0.3, 0.6, 1.0, 0.5, 0.25]; // przesunięcia -4..+2
    final out = <double>[];
    for (var i = 0; i < base.length; i++) {
      var acc = 0.0, ws = 0.0;
      for (var k = 0; k < w.length; k++) {
        final j = i + k - 4;
        if (j < 0 || j >= base.length) continue;
        acc += base[j] * w[k];
        ws += w[k];
      }
      out.add(ws > 0 ? acc / ws : 0);
    }
    return out;
  }

  /// Przypisuje fazy do minut (modyfikuje [ms]) i zwraca podsumowanie.
  ///
  /// Algorytm: ukryty model Markowa (4 stany) dekodowany Viterbim.
  /// • Emisje: aktywność (aktygrafia w stylu Cole'a–Kripkego, skala log), chrapanie
  ///   (częste w N2/N3, rzadkie w REM), mowa/kaszel (czuwanie/płytki sen).
  /// • Prior fizjologiczny: sen głęboki dominuje w pierwszej części nocy, REM w drugiej;
  ///   REM zwykle nie pojawia się w pierwszej godzinie po zaśnięciu.
  /// • Przejścia: fazy trwają minuty, nie skaczą co minutę (wygładzenie bez ręcznych reguł).
  static SleepSummary analyze(List<MinuteSample> ms, {required int goalMin}) {
    if (ms.isEmpty) {
      return const SleepSummary(
          inBedMin: 0, sleepMin: 0, deepMin: 0, lightMin: 0, remMin: 0, awakeMin: 0,
          latencyMin: 0, awakenings: 0, score: 0);
    }
    final a = activity(ms);
    final n = ms.length;

    // Wstępne zaśnięcie (do priorów czasowych): 10 kolejnych spokojnych minut.
    var onset0 = 0;
    var run = 0;
    for (var i = 0; i < n; i++) {
      run = a[i] < 3.0 ? run + 1 : 0;
      if (run >= 10) {
        onset0 = i - 9;
        break;
      }
    }

    // Kolejność stanów = Stage.values: wake, rem, light, deep
    const mu = [1.6, 0.55, 0.35, -0.9]; // oczekiwane ln(aktywność + 0,2)
    const sd = [1.0, 0.6, 0.65, 0.6];
    const pSnore = [0.02, 0.06, 0.30, 0.38];
    const pSound = [0.30, 0.06, 0.05, 0.01];

    double gauss(double x, double m, double s) => -0.5 * pow((x - m) / s, 2) - log(s);

    final emis = List.generate(n, (i) {
      final x = log(a[i] + 0.2);
      final sinceOnset = max(0, i - onset0);
      final t = sinceOnset / max(1, n - onset0); // 0..1 postęp nocy
      final out = List<double>.filled(4, 0);
      for (var k = 0; k < 4; k++) {
        var e = gauss(x, mu[k], sd[k]);
        e += log(ms[i].snore ? pSnore[k] : 1 - pSnore[k]);
        e += log(ms[i].sounds > 0 ? pSound[k] : 1 - pSound[k]);
        out[k] = e;
      }
      // Priory fizjologiczne
      out[3] += log(0.25 + 1.5 * pow(1 - t, 2)); // głęboki: wcześnie
      out[1] += log(0.2 + 1.3 * t); // REM: później
      if (sinceOnset < 60) out[1] += log(0.15);
      if (i < onset0) out[0] += 1.5; // przed zaśnięciem raczej czuwanie
      return out;
    });

    // Macierz przejść (log), na minutę
    final tr = [
      [0.90, 0.01, 0.085, 0.005], // z czuwania
      [0.03, 0.92, 0.05, 0.0001], // z REM
      [0.025, 0.02, 0.92, 0.035], // z płytkiego
      [0.01, 0.0005, 0.06, 0.9295], // z głębokiego
    ].map((r) => r.map((v) => log(v)).toList()).toList();

    // Viterbi
    final score = List.generate(n, (_) => List<double>.filled(4, -1e18));
    final back = List.generate(n, (_) => List<int>.filled(4, 0));
    const init = [0.85, 0.01, 0.13, 0.01];
    for (var k = 0; k < 4; k++) {
      score[0][k] = log(init[k]) + emis[0][k];
    }
    for (var i = 1; i < n; i++) {
      for (var k = 0; k < 4; k++) {
        var best = -1e18;
        var arg = 0;
        for (var j = 0; j < 4; j++) {
          final v = score[i - 1][j] + tr[j][k];
          if (v > best) {
            best = v;
            arg = j;
          }
        }
        score[i][k] = best + emis[i][k];
        back[i][k] = arg;
      }
    }
    final path = List<int>.filled(n, 0);
    var last = 0;
    for (var k = 1; k < 4; k++) {
      if (score[n - 1][k] > score[n - 1][last]) last = k;
    }
    path[n - 1] = last;
    for (var i = n - 1; i > 0; i--) {
      path[i - 1] = back[i][path[i]];
    }
    final st = [for (final k in path) Stage.values[k]];

    // Zaśnięcie i ostateczne przebudzenie z wyniku dekodowania
    var onset = n;
    run = 0;
    for (var i = 0; i < n; i++) {
      run = st[i] != Stage.wake ? run + 1 : 0;
      if (run >= 10) {
        onset = i - 9;
        break;
      }
    }
    var finalWake = n;
    for (var i = n - 1; i >= onset && i >= 0; i--) {
      if (st[i] != Stage.wake) {
        finalWake = i + 1;
        break;
      }
    }
    for (var i = 0; i < n; i++) {
      if (i < onset || i >= finalWake) st[i] = Stage.wake;
      ms[i].stage = st[i];
    }

    var deep = 0, light = 0, rem = 0, wake = 0, awakenings = 0;
    for (var i = 0; i < n; i++) {
      switch (st[i]) {
        case Stage.deep:
          deep++;
        case Stage.light:
          light++;
        case Stage.rem:
          rem++;
        case Stage.wake:
          wake++;
          if (i > onset && i < finalWake && st[i - 1] != Stage.wake) awakenings++;
      }
    }
    final sleep = deep + light + rem;
    final inBed = n;
    final snoreMin = ms.where((m) => m.snore).length;
    final apneas = ms.fold<int>(0, (s, m) => s + m.apneas);

    // Ocena 0–100
    final durScore = min(1.0, sleep / max(goalMin, 1)) * 38;
    final eff = inBed > 0 ? sleep / inBed : 0.0;
    final effScore = (eff.clamp(0.5, 0.95) - 0.5) / 0.45 * 20;
    final deepScore = sleep > 0 ? min(1.0, deep / (0.18 * sleep)) * 14 : 0.0;
    final remScore = sleep > 0 ? min(1.0, rem / (0.18 * sleep)) * 10 : 0.0;
    final disrupt = max(0.0, 1 - awakenings / 8) * 10;
    final snore = sleep > 0 ? (1 - min(1.0, snoreMin / sleep * 4)) * 4 : 0.0;
    final ahi = sleep >= 60 ? apneas / (sleep / 60) : 0.0;
    final breath = (1 - min(1.0, ahi / 30)) * 4;
    final score = (durScore + effScore + deepScore + remScore + disrupt + snore + breath).round().clamp(0, 100);

    return SleepSummary(
      inBedMin: inBed,
      sleepMin: sleep,
      deepMin: deep,
      lightMin: light,
      remMin: rem,
      awakeMin: wake,
      latencyMin: min(onset, inBed),
      awakenings: awakenings,
      score: score,
    );
  }

  /// Głębokość snu 0 (czuwanie) … 1 (głęboki) na minutę — do „fali” w stylu Sleep Cycle.
  /// Łączy fazę z wygładzoną aktywnością, żeby krzywa była płynna jak oddech nocy.
  static List<double> depthCurve(List<MinuteSample> ms) {
    if (ms.isEmpty) return [];
    final a = activity(ms);
    final raw = <double>[];
    for (var i = 0; i < ms.length; i++) {
      final base = switch (ms[i].stage) {
        Stage.wake => 0.04,
        Stage.rem => 0.38,
        Stage.light => 0.58,
        Stage.deep => 0.92,
      };
      final act = (log(a[i] + 0.2) + 0.9) / 3.1; // ~0..1
      raw.add((base - 0.12 * act.clamp(0.0, 1.0)).clamp(0.0, 1.0));
    }
    // wygładzenie gaussowskie σ≈3 min
    const k = [0.05, 0.12, 0.2, 0.26, 0.2, 0.12, 0.05];
    return List.generate(raw.length, (i) {
      var acc = 0.0, ws = 0.0;
      for (var j = 0; j < k.length; j++) {
        final x = i + j - 3;
        if (x < 0 || x >= raw.length) continue;
        acc += raw[x] * k[j];
        ws += k[j];
      }
      return acc / ws;
    });
  }

  /// Czy w ostatnich minutach śpiący jest w lekkim śnie / się wierci (inteligentny budzik).
  static bool lightPhaseNow(List<MinuteSample> ms, double currentMinuteMotion) {
    if (ms.length < 15) return true;
    final motion = ms.map((m) => m.motion).where((m) => m > 0).toList();
    final med = max(_median(motion), 0.02);
    final recent = [...ms.skip(max(0, ms.length - 2)).map((m) => m.motion), currentMinuteMotion];
    final peak = recent.reduce(max);
    return peak / med >= 4.0;
  }
}

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

/// Szacowanie faz snu z aktygrafii (ruch telefonu leżącego na materacu) i dźwięku,
/// w duchu algorytmu Cole'a–Kripkego + typowego rytmu ~90-minutowych cykli.
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
  static SleepSummary analyze(List<MinuteSample> ms, {required int goalMin}) {
    if (ms.isEmpty) {
      return const SleepSummary(
          inBedMin: 0, sleepMin: 0, deepMin: 0, lightMin: 0, remMin: 0, awakeMin: 0,
          latencyMin: 0, awakenings: 0, score: 0);
    }
    final a = activity(ms);
    const wakeT = 6.0;
    // Próg głębokiego snu: 30. percentyl aktywności (ok. 15–25% nocy po filtrze bloków).
    final sorted = [...a]..sort();
    final lightT = min(1.6, sorted[(sorted.length * 0.3).floor().clamp(0, sorted.length - 1)] + 1e-6);

    // Zaśnięcie: pierwsze 10 kolejnych minut spokoju.
    var onset = ms.length;
    var run = 0;
    for (var i = 0; i < a.length; i++) {
      run = a[i] < 3.0 ? run + 1 : 0;
      if (run >= 10) {
        onset = i - 9;
        break;
      }
    }
    // Ostateczne przebudzenie: ostatnia minuta, po której jest już tylko czuwanie.
    var finalWake = ms.length;
    for (var i = a.length - 1; i > onset; i--) {
      if (a[i] < wakeT) {
        finalWake = i + 1;
        break;
      }
    }

    final st = List<Stage>.filled(ms.length, Stage.light);
    for (var i = 0; i < ms.length; i++) {
      if (i < onset || i >= finalWake) {
        st[i] = Stage.wake;
      } else if (a[i] >= wakeT) {
        st[i] = Stage.wake;
      } else if (a[i] < lightT) {
        st[i] = Stage.deep;
      }
    }
    // Głęboki sen tylko w spokojnych blokach >= 10 min.
    _keepRuns(st, Stage.deep, 10, Stage.light);

    // REM: płytkie, spokojne fragmenty w drugiej części każdego ~90-min cyklu,
    // bez chrapania (w REM mięśnie są zwiotczałe, chrapanie rzadsze).
    for (var i = onset; i < finalWake; i++) {
      if (st[i] != Stage.light) continue;
      final sinceOnset = i - onset;
      final pos = sinceOnset % 90;
      final cycle = sinceOnset ~/ 90;
      final remStart = max(55, 75 - cycle * 8); // REM wydłuża się nad ranem
      if (sinceOnset >= 60 && pos >= remStart && a[i] < 3.5 && !ms[i].snore) {
        st[i] = Stage.rem;
      }
    }
    _keepRuns(st, Stage.rem, 5, Stage.light);
    _keepRuns(st, Stage.wake, 2, Stage.light, protectEdges: true, onset: onset, finalWake: finalWake);

    for (var i = 0; i < ms.length; i++) {
      ms[i].stage = st[i];
    }

    var deep = 0, light = 0, rem = 0, wake = 0, awakenings = 0;
    for (var i = 0; i < st.length; i++) {
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
    final inBed = ms.length;
    final snoreMin = ms.where((m) => m.snore).length;

    // Ocena 0–100
    final durScore = min(1.0, sleep / max(goalMin, 1)) * 40;
    final eff = inBed > 0 ? sleep / inBed : 0.0;
    final effScore = (eff.clamp(0.5, 0.95) - 0.5) / 0.45 * 20;
    final deepScore = sleep > 0 ? min(1.0, deep / (0.18 * sleep)) * 15 : 0.0;
    final remScore = sleep > 0 ? min(1.0, rem / (0.18 * sleep)) * 10 : 0.0;
    final disrupt = max(0.0, 1 - awakenings / 8) * 10;
    final snore = sleep > 0 ? (1 - min(1.0, snoreMin / sleep * 4)) * 5 : 0.0;
    final score = (durScore + effScore + deepScore + remScore + disrupt + snore).round().clamp(0, 100);

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

  /// Zamienia zbyt krótkie bloki fazy [s] na [replace].
  static void _keepRuns(List<Stage> st, Stage s, int minLen, Stage replace,
      {bool protectEdges = false, int onset = 0, int finalWake = 0}) {
    var i = 0;
    while (i < st.length) {
      if (st[i] != s) {
        i++;
        continue;
      }
      var j = i;
      while (j < st.length && st[j] == s) {
        j++;
      }
      final edge = protectEdges && (i < onset || j > finalWake);
      if (j - i < minLen && !edge) {
        for (var k = i; k < j; k++) {
          st[k] = replace;
        }
      }
      i = j;
    }
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

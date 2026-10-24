import 'dart:math';

import '../core/models.dart';

/// Wynik analizy nocy.
class SleepSummary {
  final int inBedMin, sleepMin, deepMin, lightMin, remMin, awakeMin, latencyMin, awakenings, score;
  /// Skąd fazy: 'ruch' (telefon na materacu), 'sonar', 'dźwięk', 'szablon' (brak sygnału).
  final String source;
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
    this.source = 'ruch',
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
    } else if (ms.any((m) => (m.sonarMotion ?? 0) > 0)) {
      // Telefon na szafce, ale sonar widzi ruch ciała.
      final sm = ms.map((m) => m.sonarMotion ?? 0).where((v) => v > 0).toList();
      final med = max(_median(sm), 1e-9);
      for (final m in ms) {
        base.add((m.sonarMotion ?? med) / med + m.farts * 0.3);
      }
    } else {
      // Brak ruchu (telefon nie leży na łóżku) — zastępczo z głośności otoczenia.
      final noise = ms.map((m) => max(m.noiseDb, -100.0)).toList();
      final med = _median(noise);
      for (final m in ms) {
        base.add(max(0.0, (max(m.noiseDb, -100.0) - med) / 3.0) + m.farts * 0.3);
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
    final n = ms.length;
    final mv = movementSignal(ms);
    List<Stage> st;
    if (mv == null) {
      // Brak jakiegokolwiek sygnału ruchu (telefon nie na łóżku, bez sonaru, cicho) —
      // zamiast „głębokiego snu przez całą noc” typowy przebieg cykli.
      st = _template(n);
    } else {
      st = _decode(ms, mv);
    }

    // Zaśnięcie i ostateczne przebudzenie z wyniku dekodowania
    var onset = n;
    var run = 0;
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
      source: mv?.source ?? 'szablon',
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

  /// Wybiera źródło ruchu: akcelerometr (telefon na materacu) → sonar → dźwięki (szelest, mowa)
  /// i ustala próg „zdarzenia ruchowego”. null = brak użytecznego sygnału.
  static MovementSignal? movementSignal(List<MinuteSample> ms) {
    final n = ms.length;
    MovementSignal? tryValues(List<double> v, String source) {
      final sorted = [...v]..sort();
      final frac = v.where((x) => x > 0).length / n;
      // Czujnik z szumem (ruch w prawie każdej minucie) — próg względem typowej minuty.
      final thr = frac > 0.6 ? max(3 * sorted[n ~/ 2], 1e-9) : 1e-9;
      final events = v.where((x) => x > thr).length;
      if (events < max(5, (0.02 * n).ceil())) return null;
      if (events > 0.9 * n) return null; // „ruch” cały czas — to szum, nie sygnał
      return MovementSignal(v, thr, source);
    }

    final accel = tryValues([for (final m in ms) m.motion], 'ruch');
    if (accel != null) return accel;
    if (ms.any((m) => m.sonarMotion != null)) {
      final son = tryValues([for (final m in ms) m.sonarMotion ?? 0], 'sonar');
      if (son != null) return son;
    }
    // Dźwięki: nagły szelest (szczyt minuty ≥12 dB nad jej średnią), mowa, kaszel.
    final snd = [
      for (final m in ms)
        (m.sounds > 0 ? 3.0 : 0.0) +
            ((m.noiseMax != null && m.noiseDb > -120 && m.noiseMax! - m.noiseDb >= 12) ? (m.noiseMax! - m.noiseDb) / 12 : 0.0)
    ];
    return tryValues(snd, 'dźwięk');
  }

  /// HMM na wzorcu ruchów w czasie (a nie na sile ruchu w pojedynczej minucie):
  /// • sen głęboki — długie (≥20–25 min) okresy bez żadnego ruchu,
  /// • płytki — pojedyncze, większe zmiany pozycji co kilka–kilkanaście minut,
  /// • REM — częstsze, drobne drgnięcia (zwykle w drugiej połowie nocy),
  /// • czuwanie — gęsty lub silny ruch.
  static List<Stage> _decode(List<MinuteSample> ms, MovementSignal mv) {
    final n = ms.length;
    final v = mv.values;
    final ev = [for (final x in v) x > mv.threshold];
    final nz = [for (var i = 0; i < n; i++) if (ev[i]) v[i]]..sort();
    final med = nz.isEmpty ? 1.0 : nz[nz.length ~/ 2];
    final bigThr = 2.5 * med;

    int countIn(List<bool> b, int i, int r) {
      var c = 0;
      for (var j = max(0, i - r); j <= min(n - 1, i + r); j++) {
        if (b[j]) c++;
      }
      return c;
    }

    final big = [for (var i = 0; i < n; i++) v[i] > bigThr];
    final dens = [for (var i = 0; i < n; i++) countIn(ev, i, 7)];
    final bigd = [for (var i = 0; i < n; i++) countIn(big, i, 3)];
    final runLen = List<int>.filled(n, 0);
    var i0 = 0;
    while (i0 < n) {
      if (ev[i0]) {
        i0++;
        continue;
      }
      var j = i0;
      while (j < n && !ev[j]) {
        j++;
      }
      for (var k = i0; k < j; k++) {
        runLen[k] = j - i0;
      }
      i0 = j;
    }
    double wmag(int i) {
      var sum = 0.0, c = 0;
      for (var j = max(0, i - 7); j <= min(n - 1, i + 7); j++) {
        if (ev[j]) {
          sum += v[j];
          c++;
        }
      }
      return c == 0 ? 0 : sum / c;
    }

    int cat(int i) {
      if ((bigd[i] >= 2 && dens[i] >= 4) || dens[i] >= 8) return 6; // czuwanie
      if (runLen[i] >= 25) return 0;
      if (runLen[i] >= 10) return 1;
      final small = wmag(i) < med;
      if (dens[i] <= 2) return small ? 2 : 3;
      return small ? 4 : 5;
    }

    // P(kategoria | faza); kolejność faz = Stage.values: wake, rem, light, deep
    //   bezruch≥25  bezruch≥10  rzadkie-drobne  rzadkie-duże  częste-drobne  częste-duże  czuwanie
    const em = [
      [0.01, 0.03, 0.03, 0.06, 0.07, 0.12, 0.68],
      [0.03, 0.15, 0.22, 0.10, 0.33, 0.10, 0.07],
      [0.17, 0.33, 0.14, 0.18, 0.05, 0.08, 0.05],
      [0.70, 0.22, 0.04, 0.025, 0.005, 0.005, 0.005],
    ];
    const pSnore = [0.02, 0.06, 0.30, 0.38];
    const pSound = [0.30, 0.06, 0.05, 0.01];
    const pIrregular = [0.50, 0.45, 0.15, 0.06];

    var onset0 = 0;
    var run = 0;
    for (var i = 0; i < n; i++) {
      run = (!ev[i] || v[i] < bigThr) ? run + 1 : 0;
      if (run >= 10) {
        onset0 = i - 9;
        break;
      }
    }

    final emis = List.generate(n, (i) {
      final c = cat(i);
      final sinceOnset = max(0, i - onset0);
      final t = sinceOnset / max(1, n - onset0);
      final out = List<double>.filled(4, 0);
      for (var k = 0; k < 4; k++) {
        var e = log(em[k][c]);
        e += log(ms[i].snore ? pSnore[k] : 1 - pSnore[k]);
        if (mv.source != 'dźwięk') e += log(ms[i].sounds > 0 ? pSound[k] : 1 - pSound[k]);
        final bv = ms[i].breathVar;
        if (bv != null) e += log(bv > 0.25 ? pIrregular[k] : 1 - pIrregular[k]);
        out[k] = e;
      }
      out[3] += log(0.25 + 1.5 * pow(1 - t, 2)); // głęboki: wcześnie
      out[1] += log(0.2 + 1.3 * t); // REM: później
      if (sinceOnset < 60) out[1] += log(0.15);
      if (i < onset0) out[0] += 1.5;
      return out;
    });

    final tr = [
      [0.90, 0.01, 0.085, 0.005],
      [0.03, 0.92, 0.05, 0.0001],
      [0.025, 0.02, 0.92, 0.035],
      [0.01, 0.0005, 0.06, 0.9295],
    ].map((r) => r.map((x) => log(x)).toList()).toList();

    final vit = List.generate(n, (_) => List<double>.filled(4, -1e18));
    final back = List.generate(n, (_) => List<int>.filled(4, 0));
    const init = [0.85, 0.01, 0.13, 0.01];
    for (var k = 0; k < 4; k++) {
      vit[0][k] = log(init[k]) + emis[0][k];
    }
    for (var i = 1; i < n; i++) {
      for (var k = 0; k < 4; k++) {
        var best = -1e18;
        var arg = 0;
        for (var j = 0; j < 4; j++) {
          final x = vit[i - 1][j] + tr[j][k];
          if (x > best) {
            best = x;
            arg = j;
          }
        }
        vit[i][k] = best + emis[i][k];
        back[i][k] = arg;
      }
    }
    final path = List<int>.filled(n, 0);
    var last = 0;
    for (var k = 1; k < 4; k++) {
      if (vit[n - 1][k] > vit[n - 1][last]) last = k;
    }
    path[n - 1] = last;
    for (var i = n - 1; i > 0; i--) {
      path[i - 1] = back[i][path[i]];
    }
    return [for (final k in path) Stage.values[k]];
  }

  /// Typowy przebieg nocy (cykle ~90 min), gdy brak sygnału ruchu.
  static List<Stage> _template(int n) {
    final out = List<Stage>.filled(n, Stage.light);
    const latency = 15;
    for (var i = 0; i < n; i++) {
      if (i < min(latency, n)) {
        out[i] = Stage.wake;
        continue;
      }
      final t = i - latency;
      final c = t ~/ 90, pos = t % 90;
      final deepLen = max(5, 40 - c * 10);
      final remLen = min(35, 10 + c * 6);
      if (pos >= 20 && pos < 20 + deepLen) {
        out[i] = Stage.deep;
      } else if (pos >= 90 - remLen && t >= 60) {
        out[i] = Stage.rem;
      }
    }
    if (n > latency + 5) out[n - 1] = Stage.wake;
    return out;
  }

  /// Czy w ostatnich minutach śpiący jest w lekkim śnie / się wierci (inteligentny budzik).
  static bool lightPhaseNow(List<MinuteSample> ms, double currentMinuteMotion) {
    if (ms.length < 15) return true;
    // Lekki sen = jakikolwiek wyraźny ruch w ostatnich ~3 minutach (jak w Sleep as Android).
    final motion = ms.map((m) => m.motion).where((m) => m > 0).toList();
    if (motion.isEmpty) return currentMinuteMotion > 0;
    final med = _median(motion);
    final recent = [...ms.skip(max(0, ms.length - 2)).map((m) => m.motion), currentMinuteMotion];
    return recent.reduce(max) >= 0.5 * med;
  }
}

/// Sygnał ruchu użyty do faz snu.
class MovementSignal {
  final List<double> values;
  final double threshold;
  final String source;
  const MovementSignal(this.values, this.threshold, this.source);
}

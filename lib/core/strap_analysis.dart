import 'dart:math';

/// Analiza odstępów RR z opaski piersiowej (np. Polar H10) z jednej nocy. Czysty Dart.
///
/// Opaska podaje tylko odstępy między uderzeniami (bez EKG), więc to przesiew:
/// - pauzy: odstęp ≥ 2 s,
/// - pobudzenia dodatkowe: uderzenie przedwczesne (< 80% mediany 5 poprzednich) z pauzą wyrównawczą,
/// - nieregularny rytm (możliwe AF): okna 64 uderzeń, w których większość różnic kolejnych odstępów
///   przekracza 8% średniej, a znormalizowane RMSSD > 0,10 – przez co najmniej 2 minuty.
/// Rozpoznanie AF potwierdza EKG (Polar EKG) – wyniki są opisane jako „nieregularny rytm”.
class StrapResult {
  final Map<int, double> hrByMinute; // minuta od epoki → średnie tętno
  final List<(DateTime, DateTime)> irregular;
  final List<(DateTime, double)> pauses; // czas, długość [s]
  final List<DateTime> ectopic;
  final int beats;
  final double? hrAvg, hrMin;
  const StrapResult(this.hrByMinute, this.irregular, this.pauses, this.ectopic, this.beats, this.hrAvg, this.hrMin);

  int get irregularMin => irregular.fold(0, (s, e) => s + e.$2.difference(e.$1).inMinutes);
}

double _median(List<double> v) {
  final s = [...v]..sort();
  return s.length.isOdd ? s[s.length ~/ 2] : (s[s.length ~/ 2 - 1] + s[s.length ~/ 2]) / 2;
}

/// [rr] – (czas uderzenia, odstęp RR w ms), rosnąco w czasie.
StrapResult analyzeStrap(List<(DateTime, double)> rr) {
  final ok = [for (final x in rr) if (x.$2 >= 280 && x.$2 <= 3500) x];
  final pauses = [for (final x in ok) if (x.$2 >= 2000) (x.$1, x.$2 / 1000)];

  // tętno minutowe
  final sum = <int, double>{}, cnt = <int, int>{};
  for (final (t, v) in ok) {
    final m = t.millisecondsSinceEpoch ~/ 60000;
    sum[m] = (sum[m] ?? 0) + 60000 / v;
    cnt[m] = (cnt[m] ?? 0) + 1;
  }
  final hr = {for (final e in sum.entries) if (cnt[e.key]! >= 10) e.key: e.value / cnt[e.key]!};

  // nieregularny rytm
  const w = 64, step = 16;
  final irr = <(DateTime, DateTime)>[];
  for (var i = 0; i + w <= ok.length; i += step) {
    final seg = ok.sublist(i, i + w);
    if (seg.last.$1.difference(seg.first.$1).inSeconds > w * 3) continue; // przerwa w danych
    final vals = seg.map((e) => e.$2).toList();
    final mean = vals.reduce((a, b) => a + b) / w;
    var ss = 0.0, big = 0;
    for (var k = 1; k < w; k++) {
      final d = vals[k] - vals[k - 1];
      ss += d * d;
      if (d.abs() > 0.08 * mean) big++;
    }
    final nrmssd = sqrt(ss / (w - 1)) / mean;
    if (nrmssd > 0.10 && big / (w - 1) > 0.6) {
      final a = seg.first.$1, b = seg.last.$1;
      if (irr.isNotEmpty && !a.isAfter(irr.last.$2.add(const Duration(seconds: 30)))) {
        irr[irr.length - 1] = (irr.last.$1, b.isAfter(irr.last.$2) ? b : irr.last.$2);
      } else {
        irr.add((a, b));
      }
    }
  }
  final irregular = [for (final x in irr) if (x.$2.difference(x.$1).inSeconds >= 120) x];
  bool inIrr(DateTime t) => irregular.any((x) => !t.isBefore(x.$1) && !t.isAfter(x.$2));

  // pobudzenia dodatkowe (poza nieregularnym rytmem)
  final ect = <DateTime>[];
  for (var i = 5; i + 1 < ok.length; i++) {
    final med = _median([for (var k = i - 5; k < i; k++) ok[k].$2]);
    if (ok[i].$2 < 0.8 * med && ok[i + 1].$2 > 1.1 * med && !inIrr(ok[i].$1)) ect.add(ok[i].$1);
  }

  final hv = hr.values.toList();
  return StrapResult(
    hr,
    irregular,
    pauses,
    ect,
    ok.length,
    hv.isEmpty ? null : hv.reduce((a, b) => a + b) / hv.length,
    hv.isEmpty ? null : hv.reduce(min),
  );
}

/// Parsowanie pomiaru tętna BLE (0x2A37): (tętno, odstępy RR w ms).
(int, List<double>)? parseHeartRate(List<int> d) {
  if (d.length < 2) return null;
  final flags = d[0];
  var i = 1;
  int bpm;
  if (flags & 0x01 != 0) {
    if (d.length < 3) return null;
    bpm = d[1] | (d[2] << 8);
    i = 3;
  } else {
    bpm = d[1];
    i = 2;
  }
  if (flags & 0x08 != 0) i += 2;
  final rr = <double>[];
  if (flags & 0x10 != 0) {
    while (i + 1 < d.length) {
      rr.add((d[i] | (d[i + 1] << 8)) * 1000.0 / 1024.0);
      i += 2;
    }
  }
  return (bpm, rr);
}

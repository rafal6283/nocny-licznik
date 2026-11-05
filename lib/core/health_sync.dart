import 'dart:io';

import 'package:bakometr_native/bakometr_native.dart';

import 'db.dart';
import 'models.dart';
import 'settings.dart';
import 'strap.dart';

/// Noce → Health Connect (sesje snu z fazami). Inne aplikacje, np. Life Cycle, czytają je stamtąd.
class HealthSync {
  HealthSync._();

  static bool get supported => Platform.isAndroid;

  /// Stały identyfikator nocy – ponowny zapis (np. po weryfikacji zdarzeń) aktualizuje rekord.
  static String _id(Night n) => 'nocny-licznik-${n.start.millisecondsSinceEpoch}';

  static String _stage(Stage s) => switch (s) {
        Stage.wake => 'wake',
        Stage.light => 'light',
        Stage.deep => 'deep',
        Stage.rem => 'rem',
      };

  static Map<String, Object?> _night(Night n, List<MinuteSample> ms) {
    final stages = <Map<String, Object?>>[];
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final start = m.ts.millisecondsSinceEpoch;
      final end = i + 1 < ms.length ? ms[i + 1].ts.millisecondsSinceEpoch : start + 60000;
      final st = _stage(m.stage);
      if (stages.isNotEmpty && stages.last['stage'] == st && stages.last['end'] == start) {
        stages.last['end'] = end;
      } else {
        stages.add({'start': start, 'end': end, 'stage': st});
      }
    }
    final notes = [
      if (Settings.instance.detectFarts) 'FF: ${n.fartCount}',
      if (n.snoreMin > 0) 'chrapanie: ${n.snoreMin} min',
      if (n.score > 0) 'ocena: ${n.score}',
      if (n.tags.isNotEmpty) n.tags.map((t) => '#$t').join(' '),
    ].join(' · ');
    return {
      'id': _id(n),
      'start': n.start.millisecondsSinceEpoch,
      'end': n.end!.millisecondsSinceEpoch,
      'title': 'Rytm Snu',
      'notes': notes,
      'stages': stages,
    };
  }

  /// Po zakończeniu lub edycji nocy – po cichu, jeśli zapis jest włączony.
  static Future<void> pushNight(Night n, List<MinuteSample> ms) async {
    if (!supported || !Settings.instance.healthConnect || n.end == null) return;
    if (n.end!.difference(n.start).inMinutes < 30) return; // przerwane w kilka minut – to nie noc
    await BakometrNative.healthConnectWriteSleep([_night(n, ms)]);
  }

  /// Wywoływane po zakończeniu nocy: sen i (po przeliczeniu danych opaski) tętno/HRV/oddech.
  static Future<void> pushNightAll(Night n, List<MinuteSample> ms) async {
    await pushNight(n, ms);
    await pushVitals(n);
  }

  // ------------------------------------------------------------------ tętno, HRV, oddech

  /// Dane nocy dla Health Connect. Tętno i HRV tylko z własnej opaski (dane z zegarka już tam są,
  /// a noce przejęte z Polar EKG zapisuje do Health Connect sam Polar EKG). Oddech – z opaski albo z mikrofonu.
  static Future<Map<String, Object?>?> _vitals(Night n) async {
    if (n.id == null || n.end == null || n.end!.difference(n.start).inMinutes < 30) return null;
    final ms = await Db.instance.minutes(n.id!);
    if (ms.isEmpty) return null;
    final ext = await Db.instance.ext(n.id!);
    final fromPolar = ext.any((r) => r.$2 == 'h10pe');
    final ownStrap = !fromPolar && ms.any((m) => m.hrv != null || m.strapAct != null);
    // tętno minutowe prosto z odstępów RR opaski (kolumna tętna w nocy może być uzupełniona danymi z zegarka)
    final hr = <List<num>>[];
    if (ownStrap) {
      final byMin = <int, List<double>>{};
      for (final (t, rr) in await Strap.loadRr(n.id!)) {
        if (rr < 260 || rr > 2400) continue;
        byMin.putIfAbsent(t.millisecondsSinceEpoch ~/ 60000, () => []).add(rr);
      }
      for (final e in byMin.entries) {
        if (e.value.length < 10) continue;
        final avg = e.value.reduce((a, b) => a + b) / e.value.length;
        hr.add([e.key * 60000 + 30000, double.parse((60000 / avg).toStringAsFixed(1))]);
      }
      hr.sort((a, b) => a[0].compareTo(b[0]));
    }
    // HRV i oddech – mediany z 5 minut (pojedyncze minuty są zbyt rozchwiane)
    List<List<num>> per5(double? Function(MinuteSample) f) {
      final out = <List<num>>[];
      final byBlock = <int, List<double>>{};
      for (final m in ms) {
        final v = f(m);
        if (v != null) byBlock.putIfAbsent(m.ts.millisecondsSinceEpoch ~/ 300000, () => []).add(v);
      }
      for (final e in byBlock.entries) {
        if (e.value.length < 3) continue;
        final v = [...e.value]..sort();
        out.add([e.key * 300000 + 150000, double.parse(v[v.length ~/ 2].toStringAsFixed(1))]);
      }
      out.sort((a, b) => a[0].compareTo(b[0]));
      return out;
    }

    final hrv = ownStrap ? per5((m) => m.hrv) : const <List<num>>[];
    final resp = per5((m) => m.breathRate);
    // tętno spoczynkowe nocy: najniższa średnia 5 min z opaski
    List<num>? resting;
    if (hr.length >= 30) {
      double? best;
      int bestT = 0;
      for (var i = 0; i + 5 <= hr.length; i++) {
        if (hr[i + 4][0] - hr[i][0] > 6 * 60000) continue;
        final avg = hr.sublist(i, i + 5).fold<double>(0, (s, e) => s + e[1].toDouble()) / 5;
        if (best == null || avg < best) {
          best = avg;
          bestT = hr[i + 2][0].toInt();
        }
      }
      if (best != null) resting = [bestT, double.parse(best.toStringAsFixed(1))];
    }
    if (hr.isEmpty && hrv.isEmpty && resp.isEmpty) return null;
    return {'id': _id(n), 'hr': hr, 'hrv': hrv, 'resp': resp, if (resting != null) 'resting': resting};
  }

  /// Tętno, HRV i oddech jednej nocy – po cichu, jeśli włączone. Ponowny zapis aktualizuje rekordy.
  static Future<void> pushVitals(Night n) async {
    if (!supported || !Settings.instance.healthVitals) return;
    final v = await _vitals(n);
    if (v != null) await BakometrNative.healthConnectWriteVitals([v]);
  }

  /// Tętno, HRV i oddech ze wszystkich nocy. Zwraca liczbę zapisanych rekordów albo -1.
  static Future<int> pushAllVitals() async {
    if (!supported) return -1;
    var total = 0;
    for (final n in await Db.instance.nights()) {
      final v = await _vitals(n);
      if (v == null) continue;
      final r = await BakometrNative.healthConnectWriteVitals([v]);
      if (r < 0) return -1;
      total += r;
    }
    return total;
  }

  /// Wszystkie zapisane noce (np. po włączeniu). Zwraca liczbę zapisanych albo -1.
  static Future<int> pushAll() async {
    if (!supported) return -1;
    final out = <Map<String, Object?>>[];
    for (final n in await Db.instance.nights()) {
      if (n.id == null || n.end == null || n.end!.difference(n.start).inMinutes < 30) continue;
      out.add(_night(n, await Db.instance.minutes(n.id!)));
    }
    if (out.isEmpty) return 0;
    return BakometrNative.healthConnectWriteSleep(out);
  }
}

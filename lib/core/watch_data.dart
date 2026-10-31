import 'dart:io';
import 'dart:math';

import 'package:bakometr_native/bakometr_native.dart';

import '../engine/night_engine.dart';
import '../engine/stage_model.dart';
import 'bus.dart';
import 'db.dart';
import 'models.dart';
import 'settings.dart';

/// Dane z zegarka dla jednej nocy, odczytane z Health Connect.
/// Huawei nie zapisuje do Health Connect sam — robi to aplikacja Health Sync (Appyhapps).
class WatchNight {
  final List<(DateTime, double)> hr;
  final List<(DateTime, double)> spo2;
  final List<(DateTime, DateTime, String)> stages;
  final List<String> sources;
  const WatchNight(this.hr, this.spo2, this.stages, this.sources);

  bool get isEmpty => hr.isEmpty && spo2.isEmpty && stages.isEmpty;

  static bool get supported => Platform.isAndroid;

  static Future<WatchNight?> load(Night n) async {
    if (!supported || !Settings.instance.watchData || n.end == null) return null;
    final r = await BakometrNative.healthConnectReadNight(
        n.start.millisecondsSinceEpoch, n.end!.millisecondsSinceEpoch);
    if (r == null) return null;
    List<(DateTime, double)> series(Object? v) => [
          for (final e in (v as List? ?? const []))
            if (e is List && e.length >= 2)
              (DateTime.fromMillisecondsSinceEpoch((e[0] as num).toInt()), (e[1] as num).toDouble())
        ];
    return WatchNight(
      series(r['hr']),
      series(r['spo2']),
      [
        for (final e in (r['stages'] as List? ?? const []))
          if (e is List && e.length >= 3)
            (
              DateTime.fromMillisecondsSinceEpoch((e[0] as num).toInt()),
              DateTime.fromMillisecondsSinceEpoch((e[1] as num).toInt()),
              e[2].toString()
            )
      ],
      [for (final s in (r['sources'] as List? ?? const [])) s.toString()],
    );
  }

  /// Spadki saturacji ≥3% względem mediany z poprzednich 10 min (min. 2 min odstępu).
  /// Przy rzadkich pomiarach z zegarka to przybliżenie wskaźnika ODI.
  int desaturations() {
    var c = 0;
    DateTime? last;
    for (var i = 0; i < spo2.length; i++) {
      final (t, v) = spo2[i];
      final prev = [
        for (var j = i - 1; j >= 0 && t.difference(spo2[j].$1).inMinutes <= 10; j--) spo2[j].$2
      ]..sort();
      if (prev.length < 2) continue;
      final base = prev[prev.length ~/ 2];
      if (v <= base - 3 && (last == null || t.difference(last).inSeconds >= 120)) {
        c++;
        last = t;
      }
    }
    return c;
  }

  /// Zapisuje tętno minutowe i podsumowanie do nocy, po czym przelicza fazy (tętno = dodatkowy sygnał).
  /// Zwraca true, gdy coś zapisano.
  static Future<bool> applyToNight(Night n, WatchNight w) async {
    if (n.id == null || w.isEmpty) return false;
    final stages = w.stages;
    final ms = await Db.instance.minutes(n.id!);
    if (w.hr.isNotEmpty && ms.isNotEmpty) {
      final byIdx = <int, double?>{};
      var j = 0;
      for (final m in ms) {
        final from = m.ts.subtract(const Duration(minutes: 1));
        var sum = 0.0, c = 0;
        while (j < w.hr.length && !w.hr[j].$1.isAfter(m.ts)) {
          if (w.hr[j].$1.isAfter(from)) {
            sum += w.hr[j].$2;
            c++;
          }
          j++;
        }
        byIdx[m.idx] = c == 0 ? null : sum / c;
      }
      // Pojedyncze pomiary co kilka minut — uzupełniamy luki do 5 min ostatnią wartością.
      double? lastV;
      var gap = 0;
      for (final m in ms) {
        final v = byIdx[m.idx];
        if (v != null) {
          lastV = v;
          gap = 0;
        } else if (lastV != null && ++gap <= 5) {
          byIdx[m.idx] = lastV;
        }
      }
      await Db.instance.setMinuteHr(n.id!, byIdx);
      final vals = w.hr.map((e) => e.$2).toList();
      n.hrAvg = vals.reduce((a, b) => a + b) / vals.length;
      n.hrMin = vals.reduce(min);
    }
    if (w.spo2.isNotEmpty) {
      final vals = w.spo2.map((e) => e.$2).toList();
      n.spo2Avg = vals.reduce((a, b) => a + b) / vals.length;
      n.spo2Min = vals.reduce(min);
      final hours = max(1, n.durationMin) / 60.0;
      n.odi = w.spo2.length >= 20 ? w.desaturations() / hours : null;
    }
    // Fazy z zegarka — do łączenia z danymi telefonu, nauki modelu i oceny dokładności.
    final wst = [
      for (final (a, b, st) in stages)
        if (watchStageIndex(st) != null && b.isAfter(a))
          (a, 'wst', watchStageIndex(st)!.toDouble(), b.difference(a).inSeconds / 60.0)
    ];
    if (wst.isNotEmpty) await Db.instance.replaceExt(n.id!, 'wst', wst);
    await Db.instance.updateNight(n);
    // Przeliczenie faz z tętnem i fazami z zegarka
    final fresh = await Db.instance.minutes(n.id!);
    final evs = await Db.instance.events(n.id!);
    await NightEngine.summarize(n, fresh, evs, push: false);
    dataChanged();
    return true;
  }

  /// Przy starcie: dane z zegarka dla ostatnich nocy, które ich jeszcze nie mają.
  static Future<int> backfillRecent({int days = 7}) async {
    if (!supported || !Settings.instance.watchData) return 0;
    var c = 0;
    // Jednorazowo: fazy z zegarka dla nocy z ostatnich 30 dni (do kalibracji).
    final once = !Settings.instance.watchStagesBackfilled;
    for (final n in await Db.instance.nights(limit: once ? 40 : 14)) {
      if (n.end == null) continue;
      final age = DateTime.now().difference(n.start).inDays;
      if (once) {
        if (age > 30) continue;
      } else {
        if (n.hrAvg != null || n.spo2Avg != null) continue;
        if (age > days) continue;
      }
      final w = await load(n);
      if (w != null && !w.isEmpty && await applyToNight(n, w)) c++;
    }
    if (once) Settings.instance.watchStagesBackfilled = true;
    return c;
  }

  /// Przyjazna nazwa źródła danych.
  static String sourceName(String pkg) => switch (pkg) {
        'nl.appyhapps.healthsync' => 'Health Sync (np. Huawei)',
        'com.huawei.health' => 'Huawei Health',
        'com.google.android.apps.fitness' => 'Google Fit',
        'com.fitbit.FitbitMobile' => 'Fitbit',
        'com.sec.android.app.shealth' => 'Samsung Health',
        'com.xiaomi.wearable' || 'com.mi.health' => 'Mi Fitness',
        'com.garmin.android.apps.connectmobile' => 'Garmin Connect',
        'com.withings.wiscale2' => 'Withings',
        'com.google.android.apps.healthdata' => 'Health Connect',
        _ => pkg,
      };

  /// Średnie w kubełkach po [minutes] minut, od początku do końca nocy (null = brak pomiaru).
  static List<double?> buckets(List<(DateTime, double)> s, DateTime start, DateTime end, int minutes) {
    final n = max(1, (end.difference(start).inMinutes / minutes).ceil());
    final sum = List<double>.filled(n, 0), cnt = List<int>.filled(n, 0);
    for (final (t, v) in s) {
      final i = (t.difference(start).inMinutes ~/ minutes).clamp(0, n - 1);
      sum[i] += v;
      cnt[i]++;
    }
    return [for (var i = 0; i < n; i++) cnt[i] == 0 ? null : sum[i] / cnt[i]];
  }

  /// Minuty w fazach wg zegarka: deep, light, rem, wake (inne „sen” liczone jako lekki).
  Map<String, int> stageMinutes() {
    final m = {'deep': 0, 'light': 0, 'rem': 0, 'wake': 0};
    for (final (a, b, st) in stages) {
      final k = m.containsKey(st) ? st : 'light';
      m[k] = m[k]! + b.difference(a).inMinutes;
    }
    return m;
  }

  /// Średnie tętno w oknie ±2 min wokół zdarzeń (np. bezdechów) i średnia z całej nocy.
  (double, double)? hrAround(List<DateTime> events) {
    if (hr.length < 10 || events.length < 3) return null;
    final all = hr.map((e) => e.$2).reduce((a, b) => a + b) / hr.length;
    final near = <double>[];
    for (final (t, v) in hr) {
      if (events.any((e) => t.difference(e).inSeconds.abs() <= 120)) near.add(v);
    }
    if (near.length < 3) return null;
    return (near.reduce((a, b) => a + b) / near.length, all);
  }
}

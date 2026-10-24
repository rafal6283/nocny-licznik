import 'dart:io';
import 'dart:math';

import 'package:bakometr_native/bakometr_native.dart';

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

import 'dart:io';

import 'package:bakometr_native/bakometr_native.dart';

import 'db.dart';
import 'models.dart';
import 'settings.dart';

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

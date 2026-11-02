import 'dart:io';

import 'package:bakometr_native/bakometr_native.dart';

import 'db.dart';
import 'fmt.dart';

/// Widżet Rytmu Snu: ostatnia zakończona noc (ocena, sen, tętno, przerwy w oddechu).
Future<void> updateSleepWidget() async {
  if (!Platform.isAndroid) return;
  try {
    final nights = await Db.instance.nights(limit: 5);
    final n = nights.where((x) => x.end != null && x.durationMin >= 60).firstOrNull;
    if (n == null) return;
    final extra = [
      if (n.hrAvg != null) '♥ ${n.hrAvg!.round()}',
      if (n.apneaIndex >= 1) 'przerwy ${n.apneaIndex.toStringAsFixed(1)}/h',
      if (n.awakenings > 0) 'przebudzeń ${n.awakenings}',
    ].join(' · ');
    await BakometrNative.updateWidget(
      score: '${n.score}',
      sleep: '${durHM(n.durationMin)} snu',
      extra: extra,
      date: 'noc ${dayLabel(nightOf(n.start)).toLowerCase()}',
    );
  } catch (_) {}
}

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'db.dart';
import 'models.dart';

/// Eksport wiatrów do Kreski (wspólny format „wymiana-zdarzen” v1).
///
/// {
///   "format": "wymiana-zdarzen", "version": 1, "source": "rytm-snu", "exported_at": ms,
///   (do wersji 2.8 źródło nazywało się "nocny-licznik" — aplikacje odbierające akceptują oba)
///   "windows": [{"start": ms, "end": ms}],     // noce, w których aplikacja nasłuchiwała
///   "events":  [{"id": "...", "type": "fart", "start": ms, "confidence": 0.8, "verified": true|false|null},
///               {"id": "...", "type": "af", "start": ms, "end": ms}]   // nieregularny rytm z opaski (odstępy RR)
/// }
/// Czasy w milisekundach od epoki (UTC). Plik zawiera całą historię – import w Kresce
/// zastępuje poprzednie dane z tego źródła, więc można eksportować wielokrotnie.
class ExchangeExport {
  final File file;
  final int nights;
  final int farts;

  ExchangeExport(this.file, this.nights, this.farts);
}

/// Treść pliku wymiany (cała historia wiatrów).
Future<(List<int>, int, int)> buildFartExchange() async {
  final db = Db.instance;
  final nights = await db.nights();
  final finished = {for (final n in nights) n.id};
  final farts = (await db.allEvents(SoundType.fart)).where((e) => finished.contains(e.nightId)).toList()
    ..sort((a, b) => a.ts.compareTo(b.ts));

  // nieregularny rytm (podejrzenie AF) z odstępów RR własnej opaski – noce z Polar EKG go nie mają
  final af = (await db.extOfKind('h10af')).where((e) => finished.contains(e.$1) && (e.$4 ?? 0) > 0).toList();

  final now = DateTime.now();
  final bytes = utf8.encode(jsonEncode({
    'format': 'wymiana-zdarzen',
    'version': 1,
    'source': 'rytm-snu',
    'exported_at': now.millisecondsSinceEpoch,
    'windows': [
      for (final n in nights.reversed)
        {'start': n.start.millisecondsSinceEpoch, 'end': n.end!.millisecondsSinceEpoch},
    ],
    'events': [
      for (final e in farts)
        {
          'id': 'n${e.nightId}-e${e.id}',
          'type': 'fart',
          'start': e.ts.millisecondsSinceEpoch,
          'confidence': double.parse(e.confidence.toStringAsFixed(3)),
          'verified': e.verified,
        },
      for (final (i, (night, t, _, dur)) in af.indexed)
        {
          'id': 'n$night-af$i',
          'type': 'af',
          'start': t.millisecondsSinceEpoch,
          'end': t.millisecondsSinceEpoch + (dur! * 60000).round(),
        },
    ],
  }));
  return (bytes, nights.length, farts.where((e) => e.counts).length);
}

Future<ExchangeExport> exportFartExchange() async {
  final (bytes, nights, farts) = await buildFartExchange();
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final out = File('${(await getTemporaryDirectory()).path}/rytm-snu-ff-${now.year}-${two(now.month)}-${two(now.day)}.json');
  await out.writeAsBytes(bytes);
  return ExchangeExport(out, nights, farts);
}

/// Sen jako „czynniki-dnia” v1 – dla Polar EKG (co poprzedza napady AF). Noc przypisana do dnia pobudki.
///
/// {"format": "czynniki-dnia", "version": 1, "source": "rytm-snu", "exported_at": ms,
///  "days": [{"date": "RRRR-MM-DD", "sleep_min": 412, "score": 78, "awakenings": 3,
///            "apnea_idx": 4.2, "snore_min": 12, "hr_avg": 58.1, "bed_h": 23.5}]}
Future<List<int>> buildSleepFactors() async {
  final nights = await Db.instance.nights();
  final byDay = <String, Map<String, Object?>>{};
  String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  for (final n in nights) {
    final end = n.end;
    if (end == null || n.durationMin < 60) continue;
    final day = iso(end);
    final prev = byDay[day];
    if (prev != null && (prev['sleep_min'] as int) >= n.durationMin) continue; // drzemka obok nocy – liczy się dłuższy sen
    final s = n.start;
    byDay[day] = {
      'date': day,
      'sleep_min': n.durationMin,
      'score': n.score,
      'awakenings': n.awakenings,
      'apnea_idx': double.parse(n.apneaIndex.toStringAsFixed(1)),
      'snore_min': n.snoreMin,
      if (n.hrAvg != null) 'hr_avg': double.parse(n.hrAvg!.toStringAsFixed(1)),
      'bed_h': double.parse((s.hour + s.minute / 60).toStringAsFixed(2)),
    };
  }
  final days = byDay.values.toList()..sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
  return utf8.encode(jsonEncode({
    'format': 'czynniki-dnia',
    'version': 1,
    'source': 'rytm-snu',
    'exported_at': DateTime.now().millisecondsSinceEpoch,
    'days': days,
  }));
}

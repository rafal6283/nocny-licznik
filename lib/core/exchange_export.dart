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
///   "events":  [{"id": "...", "type": "fart", "start": ms, "confidence": 0.8, "verified": true|false|null}]
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
    ],
  }));
  return (bytes, nights.length, farts.where((e) => e.counts).length);
}

Future<ExchangeExport> exportFartExchange() async {
  final (bytes, nights, farts) = await buildFartExchange();
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final out = File('${(await getTemporaryDirectory()).path}/rytm-snu-wiatry-${now.year}-${two(now.month)}-${two(now.day)}.json');
  await out.writeAsBytes(bytes);
  return ExchangeExport(out, nights, farts);
}

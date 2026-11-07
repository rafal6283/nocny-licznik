import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bakometr_native/bakometr_native.dart';
import 'package:file_picker/file_picker.dart';

import '../core/calibration.dart';
import '../core/db.dart';
import '../core/metrics.dart';
import '../core/resmed_import.dart';
import '../core/settings.dart';
import 'cpap_data.dart';

/// Import danych z karty SD ResMed: kopia całej karty do pamięci aplikacji (do analizy jak w OSCAR)
/// + dopisanie podsumowań, zdarzeń i przebiegów do nocy nagranych w aplikacji.
class CardImport {
  /// Zwraca komunikat dla użytkownika albo null, gdy anulowano.
  static Future<String?> run() async {
    final keep = Settings.instance.cpapWaveDays;
    final waveFrom = keep <= 0 ? '00000000' : ymd(DateTime.now().subtract(Duration(days: keep)));
    List<String> copied;
    var unchanged = 0;
    if (Platform.isAndroid) {
      final r = await BakometrNative.pickCpapCard(waveFrom: waveFrom);
      if (r == null) return null;
      if (r['found'] != true) {
        return 'Nie znalazłem STR.edf ani folderu DATALOG. Wskaż główny folder karty SD z aparatu.';
      }
      copied = [for (final p in (r['copied'] as List? ?? const [])) p.toString()];
      unchanged = (r['unchanged'] as num?)?.toInt() ?? 0;
    } else {
      final picked = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['edf', 'tgt']);
      if (picked.isEmpty) return null;
      final files = <(String, Uint8List)>[];
      for (final f in picked) {
        files.add((f.name, await f.readAsBytes()));
      }
      copied = await CpapStore.ingest(files);
    }
    CpapStore.invalidate();
    await CpapStore.pruneWaveforms(keep);
    final days = await CpapStore.days();

    // Noce nagrane w aplikacji: STR + EVE/PLD z dni w pobliżu nagranych nocy.
    var linked = '';
    final nights = await Db.instance.nights();
    if (nights.isNotEmpty) {
      final near = <String>{};
      for (final n in nights) {
        final d = nightDay(n);
        for (final k in [-1, 0, 1]) {
          near.add(ymd(DateTime(d.year, d.month, d.day + k)));
        }
      }
      final root = (await CpapStore.root()).path;
      final sep = Platform.pathSeparator;
      final paths = <String>[];
      final str = File('$root${sep}STR.edf');
      if (str.existsSync()) paths.add(str.path);
      for (final day in await CpapStore.dayFolders()) {
        if (!near.contains(day)) continue;
        final dir = Directory('$root${sep}DATALOG$sep$day');
        for (final f in dir.listSync().whereType<File>()) {
          final u = f.path.toUpperCase();
          if (u.endsWith('_EVE.EDF') || u.endsWith('_PLD.EDF')) paths.add(f.path);
        }
      }
      if (paths.isNotEmpty) {
        final res = await ResmedImport.importPaths(paths);
        if (res.nightsDetail > 0) unawaited(Calibration.run());
        if (res.nightsSummary + res.nightsDetail > 0) {
          linked = ' · noce w aplikacji: ${res.nightsSummary} z podsumowaniem, ${res.nightsDetail} ze szczegółami';
        }
      }
    }
    final mb = (await CpapStore.sizeBytes()) / 1048576;
    return 'Karta: ${copied.length} nowych/zmienionych plików'
        '${unchanged > 0 ? ', $unchanged bez zmian' : ''}'
        ' · ${days.length} nocy z aparatem$linked · zajęte ${mb.toStringAsFixed(0)} MB.';
  }
}

/// Test przywracania kopii w aplikacji: eksport adaptera → szyfrowanie → Koofr (w pamięci) →
/// nowy telefon z samym kodem odzyskiwania → dane do [BackupAdapter.import].
///
/// ```dart
/// final r = await kopiaAdapteraNaNowyTelefon(MyBackup());
/// // wyczyść dane aplikacji
/// await MyBackup().import(r, (_) {});
/// // sprawdź, że dane wróciły
/// ```
library;

import 'package:koofr_sync/koofr_sync.dart';
import 'package:koofr_sync/testing.dart';

import 'src/backup.dart';

export 'package:koofr_sync/testing.dart';

Future<RestoredBackup> kopiaAdapteraNaNowyTelefon(BackupAdapter a) async {
  final c = await a.export();
  return kopiaNaNowyTelefon(a.appId, c.data, blobs: c.blobs);
}

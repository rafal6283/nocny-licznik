/// Narzędzia do testów: serwer WebDAV w pamięci i pełna droga kopii „stary telefon → Koofr → nowy telefon”.
///
/// ```dart
/// final r = await kopiaNaNowyTelefon('portfel', bytes);
/// // wyczyść dane aplikacji, wczytaj r.data jak przy przywracaniu i porównaj
/// ```
library;

import 'dart:typed_data';

import 'koofr_sync.dart';
import 'src/testing/fake_dav.dart';

export 'src/testing/fake_dav.dart';

/// Kopia z jednego telefonu i przywrócenie na drugim (pusty magazyn kluczy, tylko kod odzyskiwania),
/// przez prawdziwe szyfrowanie i serwer WebDAV w pamięci. Zwraca to, co dostaje przywracanie.
Future<RestoredBackup> kopiaNaNowyTelefon(String appId, List<int> data, {List<BackupBlob> blobs = const []}) async {
  final server = FakeDav();
  await server.start();
  try {
    const cfg = KoofrConfig(email: 'rodzina@example.com', appPassword: 'haslo');
    final code = await RecoveryCode.generate();
    final old = KoofrSync(appId: appId, store: MemoryStore(), davBase: server.base);
    await old.load();
    await old.connect(cfg);
    await old.join(newName: 'Test', code: code);
    await old.backupNow(data, blobs: blobs);

    final fresh = KoofrSync(appId: appId, store: MemoryStore(), davBase: server.base);
    await fresh.load();
    await fresh.connect(cfg);
    await fresh.join(existingId: 'test', code: (await RecoveryCode.parse(await code.format()))!);
    final list = await fresh.backups();
    if (list.isEmpty) throw StateError('Nowy telefon nie widzi kopii');
    final r = await fresh.restoreFull(list.first);
    // załączniki pobieramy od razu, póki serwer działa
    final got = <String, Uint8List>{};
    for (final id in r.blobs.values) {
      got[id] = await r.blob(id);
    }
    return RestoredBackup(r.data, r.blobs, (id) async => got[id] ?? (throw StateError('Brak załącznika $id')));
  } finally {
    await server.stop();
  }
}

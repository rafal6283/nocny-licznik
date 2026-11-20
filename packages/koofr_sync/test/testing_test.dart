import 'dart:convert';

import 'package:koofr_sync/koofr_sync.dart';
import 'package:koofr_sync/testing.dart';
import 'package:test/test.dart';

void main() {
  test('kopia na nowy telefon: dane i załączniki wracają bez zmian', () async {
    final r = await kopiaNaNowyTelefon('teczka', utf8.encode('baza'), blobs: [
      BackupBlob('pliki/a.pdf', () async => utf8.encode('PDF-A')),
      BackupBlob('pliki/b.jpg', () async => utf8.encode('JPG-B')),
    ]);
    expect(utf8.decode(r.data), 'baza');
    expect(r.blobs.keys, unorderedEquals(['pliki/a.pdf', 'pliki/b.jpg']));
    expect(utf8.decode(await r.blob(r.blobs['pliki/a.pdf']!)), 'PDF-A');
  });
}

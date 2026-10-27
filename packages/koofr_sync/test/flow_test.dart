import 'dart:convert';

import 'package:koofr_sync/koofr_sync.dart';
import 'package:test/test.dart';

import 'fake_dav.dart';

/// Pełne scenariusze na serwerze WebDAV w pamięci: połączenie, rodzina, kopie, podgląd za zgodą.
void main() {
  late FakeDav server;
  const cfg = KoofrConfig(email: 'rodzina@example.com', appPassword: 'haslo');

  setUp(() async {
    server = FakeDav();
    await server.start();
  });
  tearDown(() => server.stop());

  KoofrSync phone([String app = 'rytm-snu']) => KoofrSync(appId: app, store: MemoryStore(), davBase: server.base);

  test('złe hasło daje czytelny błąd', () async {
    final s = phone();
    await s.load();
    expect(
      () => s.connect(const KoofrConfig(email: 'rodzina@example.com', appPassword: 'zle')),
      throwsA(isA<KoofrException>().having((e) => e.status, 'status', 401)),
    );
  });

  test('kopia z załącznikami: bez duplikatów, przywracanie i sprzątanie', () async {
    final s = phone('teczka');
    await s.load();
    await s.connect(cfg);
    await s.join(newName: 'Rafał', code: await RecoveryCode.generate());
    expect(s.ready, isTrue);

    final pdf = List<int>.generate(5000, (i) => i % 251);
    final photo = utf8.encode('zdjęcie');
    await s.backupNow(utf8.encode('baza v1'), blobs: [
      BackupBlob('docs/a.pdf', () async => pdf),
      BackupBlob('docs/b.jpg', () async => photo),
    ]);
    final blobDir = server.files.keys.where((k) => k.startsWith('Rodzina/teczka/pliki/rafal/')).toList();
    expect(blobDir.length, 2);
    // nic nie leży jawnie
    for (final k in server.files.keys) {
      expect(utf8.decode(server.files[k]!, allowMalformed: true), isNot(contains('baza v1')));
    }

    await Future<void>.delayed(const Duration(milliseconds: 1100)); // nazwy kopii mają sekundy
    // druga kopia tego samego dnia: PDF nie jest wysyłany ponownie, zdjęcie usunięto z aplikacji
    await s.backupNow(utf8.encode('baza v2'), blobs: [BackupBlob('docs/a.pdf', () async => pdf)]);
    final blobPuts = server.puts.where((k) => k.startsWith('Rodzina/teczka/pliki/')).length;
    expect(blobPuts, 2); // tylko przy pierwszej kopii

    // z jednego dnia zostaje najnowsza kopia, a nieużywane zdjęcie znika
    final list = await s.backups();
    expect(list.length, 1);
    expect(server.files.keys.where((k) => k.startsWith('Rodzina/teczka/pliki/rafal/')).length, 1);
    final r = await s.restoreFull(list.single);
    expect(utf8.decode(r.data), 'baza v2');
    expect(r.blobs.keys, ['docs/a.pdf']);
    expect(await r.blob(r.blobs['docs/a.pdf']!), pdf);
  });

  test('nowy telefon: ten sam kod odtwarza kopię, inny kod jest odrzucany', () async {
    final a = phone('portfel');
    await a.load();
    await a.connect(cfg);
    final code = await RecoveryCode.generate();
    await a.join(newName: 'Ola', code: code);
    await a.backupNow(utf8.encode('portfel Oli'));

    final b = phone('portfel');
    await b.load();
    await b.connect(cfg);
    final members = await b.members();
    expect(members.map((m) => m.name), ['Ola']);
    final wrong = await RecoveryCode.generate();
    expect(() => b.join(existingId: 'ola', code: wrong), throwsA(isA<KsCryptoException>()));
    await b.join(existingId: 'ola', code: (await RecoveryCode.parse(await code.format()))!);
    final list = await b.backups();
    expect(utf8.decode(await b.restore(list.single)), 'portfel Oli');
  });

  test('podgląd tylko za zgodą obu stron, cofnięcie kasuje dane', () async {
    final owner = phone();
    await owner.load();
    await owner.connect(cfg);
    await owner.join(newName: 'Rafał', code: await RecoveryCode.generate());
    final viewer = phone();
    await viewer.load();
    await viewer.connect(cfg);
    await viewer.join(newName: 'Ania', code: await RecoveryCode.generate());

    Future<List<int>> build(String v, Map<String, Object?> scope) async => utf8.encode(jsonEncode({'scope': scope}));

    // tylko prośba oglądającego — nic nie płynie
    await viewer.requestView('rafal');
    expect(await owner.publishShares(build), 0);
    expect(await viewer.fetchShared('rafal'), isNull);

    // zgoda właściciela — dane płyną
    await owner.allowView('ania', {'stages': true});
    expect(await owner.publishShares(build), 1);
    final got = await viewer.fetchShared('rafal');
    expect(jsonDecode(utf8.decode(got!.$1)), {'scope': {'stages': true}});
    expect(await owner.safetyNumberWith('ania'), await viewer.safetyNumberWith('rafal'));

    // oglądający rezygnuje — właściciel przy następnej wysyłce sprząta i przestaje wysyłać
    await viewer.revokeAsViewer('rafal');
    expect(await owner.publishShares(build), 0);
    expect(await owner.myConsents(), isEmpty);
    expect(server.files.keys.where((k) => k.contains('/dane/')), isEmpty);
    expect(server.dirs.where((d) => d.contains('rafal__ania')), isEmpty);

    // propozycja właściciela bez akceptacji — nic nie płynie; odrzucenie usuwa powiązanie
    await owner.allowView('ania', {});
    expect(await owner.publishShares(build), 0);
    await viewer.dismissLink('rafal', 'ania');
    expect(await owner.publishShares(build), 0);
    expect(await owner.myConsents(), isEmpty);
  });
}

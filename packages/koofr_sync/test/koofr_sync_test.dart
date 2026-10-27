import 'dart:convert';

import 'package:koofr_sync/koofr_sync.dart';
import 'package:test/test.dart';

void main() {
  group('kod odzyskiwania', () {
    test('format i odczyt w obie strony', () async {
      final c = await RecoveryCode.generate();
      final text = await c.format();
      expect(text, matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')));
      final back = await RecoveryCode.parse(text.toLowerCase().replaceAll('-', ' '));
      expect(back, isNotNull);
      expect(back!.entropy, c.entropy);
    });

    test('literówka jest wykrywana', () async {
      final text = await (await RecoveryCode.generate()).format();
      final i = text.indexOf(RegExp(r'[0-9A-Z]'));
      final wrong = text.replaceRange(i, i + 1, text[i] == 'A' ? 'B' : 'A');
      expect(await RecoveryCode.parse(wrong), isNull);
      expect(await RecoveryCode.parse(text.substring(0, 20)), isNull);
    });

    test('ten sam kod daje te same klucze', () async {
      final c = await RecoveryCode.generate();
      final a = await KsCrypto.fromCode(c, 'rytm-snu');
      final b = await KsCrypto.fromCode((await RecoveryCode.parse(await c.format()))!, 'rytm-snu');
      expect(a.publicKeyB64, b.publicKeyB64);
      expect(a.codeCheck, b.codeCheck);
      final other = await KsCrypto.fromCode(c, 'doba');
      expect(other.publicKeyB64, isNot(a.publicKeyB64));
      expect(other.codeCheck, a.codeCheck);
    });
  });

  group('szyfrowanie', () {
    test('kopia: zapis i odczyt, obca osoba nie odczyta', () async {
      final me = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final data = utf8.encode('noc ' * 1000);
      final sealed = await me.sealBackup(data);
      expect(sealed.length, lessThan(data.length)); // gzip
      expect(await me.openBackup(sealed), data);

      final stranger = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      expect(() => stranger.openBackup(sealed), throwsA(isA<KsCryptoException>()));

      // ta sama osoba, inna aplikacja — też nie (AAD z identyfikatorem aplikacji)
      final code = await RecoveryCode.generate();
      final a = await KsCrypto.fromCode(code, 'rytm-snu');
      final b = await KsCrypto.fromCode(code, 'doba');
      final sealedA = await a.sealBackup(data);
      expect(() => b.openBackup(sealedA), throwsA(isA<KsCryptoException>()));
    });

    test('podgląd: tylko adresat, z weryfikacją nadawcy', () async {
      final owner = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final viewer = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final third = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final data = utf8.encode('{"nights":[]}');

      final sealed = await owner.sealFor(viewer.publicKey, data);
      expect(await viewer.openFrom(owner.publicKey, sealed), data);
      // osoba trzecia nie odczyta
      expect(() => third.openFrom(owner.publicKey, sealed), throwsA(isA<KsCryptoException>()));
      // podszywanie się: dane od trzeciej osoby nie przejdą jako dane właściciela
      final forged = await third.sealFor(viewer.publicKey, data);
      expect(() => viewer.openFrom(owner.publicKey, forged), throwsA(isA<KsCryptoException>()));
      // zmieniony bajt
      final broken = [...sealed]..[sealed.length - 1] ^= 1;
      expect(() => viewer.openFrom(owner.publicKey, broken), throwsA(isA<KsCryptoException>()));
    });

    test('kod bezpieczeństwa jest taki sam po obu stronach', () async {
      final a = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final b = await KsCrypto.fromCode(await RecoveryCode.generate(), 'rytm-snu');
      final ab = await KsCrypto.safetyNumber('rytm-snu', a.publicKey, b.publicKey);
      final ba = await KsCrypto.safetyNumber('rytm-snu', b.publicKey, a.publicKey);
      expect(ab, ba);
      expect(ab, matches(RegExp(r'^\d{4} \d{4} \d{4}$')));
    });
  });

  group('rotacja kopii', () {
    BackupInfo at(DateTime t) => BackupInfo('rafal', BackupInfo.nameFor(t, 'abc123'), t, 'abc123', 1);

    test('7 dni + 4 tygodnie, najnowsza z dnia zostaje', () {
      final now = DateTime(2026, 10, 27, 8);
      final all = [
        for (var d = 0; d < 60; d++) ...[
          at(now.subtract(Duration(days: d))),
          at(now.subtract(Duration(days: d, hours: 3))), // druga kopia tego samego dnia
        ]
      ];
      final del = KoofrSync.selectForPrune(all);
      final kept = all.where((b) => !del.contains(b)).toList()..sort((a, b) => b.at.compareTo(a.at));
      expect(kept.length, 11);
      expect(kept.first.at, now);
      // 7 ostatnich dni po jednej kopii (najnowszej z dnia)
      for (var d = 0; d < 7; d++) {
        expect(kept[d].at, now.subtract(Duration(days: d)));
      }
      // potem po jednej na tydzień
      final weeks = kept.skip(7).map((b) => b.at.difference(kept[6].at).inDays).toList();
      expect(weeks.every((w) => w < 0), isTrue);
    });

    test('nazwa pliku w obie strony', () {
      final t = DateTime(2026, 1, 5, 7, 9, 3);
      final name = BackupInfo.nameFor(t, 'x1y2z3');
      expect(name, '20260105-070903_x1y2z3.ksy');
      // starszy format bez sekund też jest rozpoznawany
      expect(BackupInfo.parse('ola', DavEntry('20260105-0709_x1y2z3.ksy', false, 1, null))!.at, DateTime(2026, 1, 5, 7, 9));
      final b = BackupInfo.parse('ola', DavEntry(name, false, 42, null))!;
      expect(b.at, t);
      expect(b.device, 'x1y2z3');
      expect(BackupInfo.parse('ola', DavEntry('cos.txt', false, 1, null)), isNull);
    });
  });

  group('WebDAV', () {
    test('odczyt odpowiedzi PROPFIND (różne prefiksy)', () {
      const xml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/dav/Koofr/Rodzina/rytm-snu/kopie/rafal/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
 <d:response><d:href>/dav/Koofr/Rodzina/rytm-snu/kopie/rafal/20260105-0709_abc.ksy</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1234</d:getcontentlength>
  <d:getlastmodified>Mon, 05 Jan 2026 07:09:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
 <D:response xmlns:D="DAV:"><D:href>https://app.koofr.net/dav/Koofr/Rodzina/x%20y/</D:href>
  <D:propstat><D:prop><D:resourcetype><D:collection /></D:resourcetype></D:prop></D:propstat></D:response>
</d:multistatus>''';
      final r = WebDav.parseMultistatus(xml);
      expect(r.length, 3);
      expect(r[0].$2.isDir, isTrue);
      expect(r[1].$2.name, '20260105-0709_abc.ksy');
      expect(r[1].$2.size, 1234);
      expect(r[1].$2.modified, DateTime.utc(2026, 1, 5, 7, 9));
      expect(r[2].$2.name, 'x y');
      expect(r[2].$2.isDir, isTrue);
    });
  });

  group('konfiguracja', () {
    test('kod konfiguracji w obie strony', () {
      const c = KoofrConfig(email: 'rafal@example.com', appPassword: 'abcd efgh', root: 'Rodzina');
      final back = KoofrConfig.fromCode(c.toCode())!;
      expect(back.email, c.email);
      expect(back.appPassword, c.appPassword);
      expect(KoofrConfig.fromCode('śmieci'), isNull);
    });

    test('identyfikator z imienia', () {
      expect(slugify('Rafał Szarek'), 'rafal-szarek');
      expect(slugify('  Żółć! '), 'zolc');
      expect(slugify('***'), 'osoba');
    });
  });
}

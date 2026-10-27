import 'dart:convert';
import 'dart:io';

import 'package:koofr_sync/koofr_sync.dart';
import 'package:test/test.dart';

/// Zgodność z niezależną implementacją (test/reference_impl.py) — te same wektory
/// sprawdza wersja w Kotlinie (Doba, Kreska), więc wszystkie aplikacje czytają te same pliki.
void main() {
  final v = jsonDecode(File('test/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final app = v['app'] as String;
  List<int> hex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

  test('klucze z kodu', () async {
    for (final who in ['owner', 'viewer']) {
      final o = v[who] as Map<String, dynamic>;
      final code = (await RecoveryCode.parse(o['code'] as String))!;
      expect(await code.format(), o['code']);
      final k = await KsCrypto.fromCode(code, app);
      expect(k.codeCheck, o['check']);
      expect(k.publicKeyB64, o['pub']);
    }
  });

  test('odczyt kopii, podglądu, kod bezpieczeństwa i nazwa załącznika', () async {
    final owner = await KsCrypto.fromCode((await RecoveryCode.parse(v['owner']['code'] as String))!, app);
    final viewer = await KsCrypto.fromCode((await RecoveryCode.parse(v['viewer']['code'] as String))!, app);
    expect(utf8.decode(await owner.openBackup(hex(v['backup'] as String))), v['backupPlain']);
    expect(utf8.decode(await viewer.openFrom(owner.publicKey, hex(v['share'] as String))), v['sharePlain']);
    expect(await KsCrypto.safetyNumber(app, owner.publicKey, viewer.publicKey), v['safety']);
    expect(await owner.blobId(utf8.encode('załącznik')), v['blobId']);
  });
}

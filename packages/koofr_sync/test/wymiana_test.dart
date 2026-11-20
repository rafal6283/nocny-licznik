import 'dart:convert';
import 'dart:io';

import 'package:koofr_sync/koofr_sync.dart';
import 'package:test/test.dart';

/// Kontrakt plików wymiany: przykłady, walidator i reguła źródeł.
void main() {
  test('stałe przykładów odpowiadają plikom wymiana/*.json', () {
    final files = Directory('wymiana').listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    final fromDisk = {
      for (final f in files) f.uri.pathSegments.last.replaceAll('.json', ''): jsonDecode(f.readAsStringSync()),
    };
    expect(fromDisk.keys.toSet(), wymianaPrzyklady.keys.toSet(),
        reason: 'uruchom python3 tool/gen_przyklady.py po zmianie przykładów');
    for (final e in fromDisk.entries) {
      expect(jsonDecode(wymianaPrzyklady[e.key]!), e.value, reason: e.key);
    }
  });

  test('każdy plik kontraktu ma przykład, który przechodzi walidację', () {
    for (final p in kontraktWymiany) {
      final txt = wymianaPrzyklady[p.przyklad];
      expect(txt, isNotNull, reason: 'brak przykładu ${p.przyklad}');
      expect(plikWymiany(p.przyklad), same(p), reason: 'przykład ${p.przyklad} pasuje do innego wpisu');
      expect(sprawdzWymiane(p.przyklad, utf8.encode(txt!)), isEmpty, reason: p.przyklad);
    }
  });

  test('nadawcy i odbiorcy to znane aplikacje', () {
    for (final p in kontraktWymiany) {
      expect(nazwyAplikacji, contains(p.nadawca), reason: p.nazwa);
      for (final o in p.odbiorcy) {
        expect(nazwyAplikacji, contains(o), reason: '${p.nazwa} → $o');
      }
      expect(p.odbiorcy, isNot(contains(p.nadawca)), reason: '${p.nazwa} wysyła sam do siebie');
    }
  });

  test('rozpoznawanie nazw: kreska-z nie jest licznikiem, polar-noce nie jest polar-ekg', () {
    expect(plikWymiany('kreska-ff')!.nazwa, 'kreska-<licznik>');
    expect(plikWymiany('kreska-z-afib')!.nazwa, 'kreska-z-<zdarzenie>');
    expect(plikWymiany('polar-noce')!.format, 'noc-polar');
    expect(plikWymiany('cos-nowego'), isNull);
    expect(zrodloPasuje('polar-ekg', 'polar-noce'), isFalse);
    expect(zrodloPasuje('rytm-snu', 'rytm-snu-rytm'), isTrue); // dlatego odbiorca FF musi pominąć plik rytmu
    expect(zrodloPasuje('kreska', 'kreska-z-afib'), isTrue);
    expect(przykladyDlaZrodel(['polar-ekg']), ['polar-ekg']);
  });

  test('walidator wykrywa typowe błędy', () {
    List<String> check(String name, Map<String, Object?> j) => sprawdzWymiane(name, utf8.encode(jsonEncode(j)));
    final ok = jsonDecode(wymianaPrzyklady['polar-ekg']!) as Map<String, Object?>;
    expect(check('polar-ekg', {...ok, 'version': 2}), isNotEmpty);
    expect(check('polar-ekg', {...ok, 'source': 'rytm-snu'}), isNotEmpty);
    expect(check('polar-ekg', {...ok, 'events': [{'type': 'fart', 'start': 1}]}), isNotEmpty);
    expect(check('polar-ekg', {...ok, 'windows': [{'start': 5, 'end': 1}]}), isNotEmpty);
    expect(check('polar-ekg', {...ok, 'events': [{'type': 'af', 'start': 1.5}]}), isNotEmpty);
    final cz = jsonDecode(wymianaPrzyklady['czynniki-sen']!) as Map<String, Object?>;
    expect(check('czynniki-sen', {...cz, 'days': [{'date': '19.11.2025'}]}), isNotEmpty);
    expect(check('czynniki-sen', {...cz, 'days': [{'date': '2025-11-19', 'score': 'dobry'}]}), isNotEmpty);
    expect(check('czynniki-sen', {...cz, 'days': [{'date': '2025-11-19'}, {'date': '2025-11-19'}]}), isNotEmpty);
    expect(check('czynniki-sen', {...cz, 'days': [{'date': '2025-11-19', 'hr_avg': null}]}), isEmpty);
    expect(sprawdzWymiane('polar-ekg', utf8.encode('{')), isNotEmpty);
    expect(sprawdzWymiane('nieznany', utf8.encode('{}')), isNotEmpty);
    final noc = jsonDecode(wymianaPrzyklady['polar-noce']!) as Map<String, Object?>;
    expect(check('polar-noce', {...noc, 'columns': ['t', 'hr']}), isNotEmpty);
  });
}

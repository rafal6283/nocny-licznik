import 'dart:convert';

/// Kontrakt plików wymiany między aplikacjami (folder `_wymiana/<osoba>/` na Koofr).
///
/// Jedno źródło prawdy: kto wysyła który plik, w jakim formacie i kto go czyta. Opis dla ludzi
/// i dla Kotlina/Swifta (Doba, Kreska) jest w `WYMIANA.md`, przykłady w `wymiana/*.json`.
///
/// Zasady, które sprawdzają testy w każdej aplikacji:
/// 1. Plik, który aplikacja wysyła, przechodzi [sprawdzWymiane] bez błędów.
/// 2. Aplikacja, której źródła ([zrodloPasuje]) pasują do nazwy pliku, wczytuje każdy przykład
///    bez wyjątku — plik, którego nie potrzebuje, po prostu pomija.
/// 3. Zmiana kształtu pliku = nowa wersja (`version`) albo nowy plik; odbiorcy najpierw.
class PlikWymiany {
  /// Nazwa do wyświetlania, np. `kreska-<licznik>`.
  final String nazwa;
  final RegExp wzorzec;
  final String format;
  final int wersja;

  /// Dozwolone wartości pola `source` (pierwsza = obecna, kolejne = dawne nazwy).
  final List<String> zrodla;

  /// Identyfikator aplikacji wysyłającej (jak `appId` w KoofrSync).
  final String nadawca;

  /// Aplikacje, które z pliku korzystają.
  final List<String> odbiorcy;

  /// Dozwolone typy zdarzeń (`wymiana-zdarzen`); puste = dowolne.
  final Set<String> typyZdarzen;

  final String opis;

  /// Nazwa przykładu w [wymianaPrzyklady].
  final String przyklad;

  const PlikWymiany._(this.nazwa, this.wzorzec, this.format, this.wersja, this.zrodla, this.nadawca, this.odbiorcy,
      this.typyZdarzen, this.opis, this.przyklad);
}

/// Nazwy aplikacji (identyfikatory jak w KoofrSync) → nazwy dla ludzi.
const nazwyAplikacji = {
  'rytm-snu': 'Rytm Snu',
  'polar-ekg': 'Polar EKG',
  'kreska': 'Kreska',
  'doba': 'Doba',
  'dziennik-talerza': 'Dziennik talerza',
  'teczka': 'Teczka',
  'portfel': 'Portfel',
  'forma': 'Forma',
  'znicz': 'Znicz',
};

final List<PlikWymiany> kontraktWymiany = [
  PlikWymiany._('rytm-snu', RegExp(r'^rytm-snu$'), 'wymiana-zdarzen', 1, const ['rytm-snu', 'nocny-licznik'],
      'rytm-snu', const ['kreska', 'dziennik-talerza', 'doba'], const {'fart'},
      'Noce z nasłuchem i wykryte FF (tylko gdy liczenie włączone).', 'rytm-snu'),
  PlikWymiany._('rytm-snu-rytm', RegExp(r'^rytm-snu-rytm$'), 'wymiana-zdarzen', 1, const ['rytm-snu-rytm'], 'rytm-snu',
      const ['doba', 'kreska'], const {'af'}, 'Czas z tętnem z opaski i nieregularny rytm (podejrzenie AF).',
      'rytm-snu-rytm'),
  PlikWymiany._('czynniki-sen', RegExp(r'^czynniki-sen$'), 'czynniki-dnia', 1, const ['rytm-snu'], 'rytm-snu',
      const ['polar-ekg', 'forma', 'doba'], const {}, 'Sen noc po nocy (dzień pobudki).', 'czynniki-sen'),
  PlikWymiany._('polar-ekg', RegExp(r'^polar-ekg$'), 'wymiana-zdarzen', 1, const ['polar-ekg'], 'polar-ekg',
      const ['kreska', 'doba', 'rytm-snu'], const {'af'}, 'Okna zapisu EKG i epizody AF.', 'polar-ekg'),
  PlikWymiany._('polar-noce', RegExp(r'^polar-noce$'), 'noc-polar', 1, const ['polar-ekg'], 'polar-ekg',
      const ['rytm-snu'], const {}, 'Nocne zapisy minuta po minucie (tętno, HRV, ruch, S/V, AF), 21 dni.',
      'polar-noce'),
  PlikWymiany._('czynniki-polar', RegExp(r'^czynniki-polar$'), 'czynniki-dnia', 1, const ['polar-ekg'], 'polar-ekg',
      const ['doba', 'forma'], const {}, 'Poranne HRV i minuty AF dzień po dniu.', 'czynniki-polar'),
  PlikWymiany._('czynniki-posilki', RegExp(r'^czynniki-posilki$'), 'czynniki-dnia', 1, const ['dziennik-talerza'],
      'dziennik-talerza', const ['polar-ekg', 'forma', 'doba'], const {},
      'Posiłki dnia: kalorie, alkohol, kawa, pora ostatniego posiłku.', 'czynniki-posilki'),
  PlikWymiany._('czynniki-leki', RegExp(r'^czynniki-leki$'), 'czynniki-dnia', 1, const ['teczka'], 'teczka',
      const ['polar-ekg', 'doba'], const {}, 'Przyjmowanie leków (bez nazw leków).', 'czynniki-leki'),
  PlikWymiany._('czynniki-portfel', RegExp(r'^czynniki-portfel$'), 'czynniki-dnia', 1, const ['portfel'], 'portfel',
      const ['doba'], const {}, 'Wartość majątku dzień po dniu.', 'czynniki-portfel'),
  PlikWymiany._('czynniki-forma', RegExp(r'^czynniki-forma$'), 'czynniki-dnia', 1, const ['forma'], 'forma',
      const ['doba'], const {}, 'Treningi: minuty, kalorie, wysiłek, godzina końca.', 'czynniki-forma'),
  PlikWymiany._('czynniki-ruch', RegExp(r'^czynniki-ruch$'), 'czynniki-dnia', 1, const ['doba'], 'doba',
      const ['polar-ekg'], const {}, 'Kroki, sport, chód, praca, podróże.', 'czynniki-ruch'),
  PlikWymiany._('kreska-<licznik>', RegExp(r'^kreska-(?!z-).+$'), 'wymiana-zdarzen', 1, const ['kreska'], 'kreska',
      const ['dziennik-talerza', 'doba'], const {'tap'}, 'Licznik z godzinami kliknięć i sumami dni.', 'kreska-ff'),
  PlikWymiany._('kreska-z-<zdarzenie>', RegExp(r'^kreska-z-.+$'), 'wymiana-zdarzen', 1, const ['kreska'], 'kreska',
      const ['polar-ekg', 'doba'], const {'session'}, 'Zdarzenie (np. AFIB): odcinki bez pauz.', 'kreska-z-afib'),
];

/// Wpis kontraktu dla nazwy pliku (bez `.ksy`); null = plik nieznany.
PlikWymiany? plikWymiany(String name) {
  for (final p in kontraktWymiany) {
    if (p.wzorzec.hasMatch(name)) return p;
  }
  return null;
}

/// Wspólna reguła źródeł: przedrostek `polar-ekg` pasuje do `polar-ekg` i `polar-ekg-…`,
/// ale nie do `polar-noce`. Tak samo w Kotlinie i Swifcie.
bool zrodloPasuje(String prefix, String name) => name == prefix || name.startsWith('$prefix-');

/// Nazwy przykładów, które aplikacja z danymi źródłami pobierze.
List<String> przykladyDlaZrodel(Iterable<String> prefixes) => [
      for (final p in kontraktWymiany)
        if (prefixes.any((s) => zrodloPasuje(s, p.przyklad))) p.przyklad,
    ];

/// Sprawdza plik wymiany. Zwraca listę problemów (pusta = zgodny z kontraktem).
List<String> sprawdzWymiane(String name, List<int> bytes) {
  final p = plikWymiany(name);
  if (p == null) return ['nieznany plik „$name” — dopisz go do kontraktu (WYMIANA.md, wymiana.dart)'];
  final Object? j;
  try {
    j = jsonDecode(utf8.decode(bytes).replaceFirst('﻿', ''));
  } catch (e) {
    return ['niepoprawny JSON: $e'];
  }
  if (j is! Map) return ['oczekiwano obiektu JSON'];
  final out = <String>[];
  if (j['format'] != p.format) out.add('format „${j['format']}” zamiast „${p.format}”');
  if (j['version'] != p.wersja) out.add('wersja ${j['version']} zamiast ${p.wersja}');
  if (!p.zrodla.contains(j['source'])) out.add('source „${j['source']}” zamiast „${p.zrodla.first}”');
  if (j.containsKey('exported_at') && j['exported_at'] is! int) out.add('exported_at nie jest liczbą ms');
  if (out.isNotEmpty) return out;
  switch (p.format) {
    case 'wymiana-zdarzen':
      _zdarzenia(j, p, out);
    case 'czynniki-dnia':
      _czynniki(j, out);
    case 'noc-polar':
      _noce(j, out);
  }
  return out;
}

final _data = RegExp(r'^\d{4}-\d{2}-\d{2}$');

void _zdarzenia(Map j, PlikWymiany p, List<String> out) {
  final ws = j['windows'];
  if (ws is! List) {
    out.add('brak listy windows');
  } else {
    for (final (i, w) in ws.indexed) {
      if (w is! Map || w['start'] is! int || w['end'] is! int) {
        out.add('windows[$i]: wymagane start i end (ms)');
      } else if ((w['end'] as int) < (w['start'] as int)) {
        out.add('windows[$i]: koniec przed początkiem');
      }
    }
  }
  final es = j['events'];
  if (es is! List) {
    out.add('brak listy events');
    return;
  }
  for (final (i, e) in es.indexed) {
    if (e is! Map || e['start'] is! int || e['type'] is! String) {
      out.add('events[$i]: wymagane type i start (ms)');
      continue;
    }
    if (p.typyZdarzen.isNotEmpty && !p.typyZdarzen.contains(e['type'])) {
      out.add('events[$i]: typ „${e['type']}” spoza ${p.typyZdarzen}');
    }
    final end = e['end'];
    if (end != null && (end is! int || end < (e['start'] as int))) out.add('events[$i]: zły koniec');
    if (out.length > 20) return;
  }
  final dt = j['day_totals'];
  if (dt != null) {
    if (dt is! List) {
      out.add('day_totals nie jest listą');
    } else {
      for (final (i, d) in dt.indexed) {
        if (d is! Map || d['date'] is! String || !_data.hasMatch(d['date'] as String) || d['total'] is! num) {
          out.add('day_totals[$i]: wymagane date (RRRR-MM-DD) i total');
        }
      }
    }
  }
}

void _czynniki(Map j, List<String> out) {
  final days = j['days'];
  if (days is! List) {
    out.add('brak listy days');
    return;
  }
  final seen = <String>{};
  for (final (i, d) in days.indexed) {
    if (d is! Map || d['date'] is! String || !_data.hasMatch(d['date'] as String)) {
      out.add('days[$i]: wymagane date (RRRR-MM-DD)');
      continue;
    }
    if (!seen.add(d['date'] as String)) out.add('days[$i]: powtórzona data ${d['date']}');
    for (final e in d.entries) {
      if (e.key != 'date' && e.value != null && e.value is! num) out.add('days[$i].${e.key}: wartość nie jest liczbą');
    }
    if (out.length > 20) return;
  }
}

void _noce(Map j, List<String> out) {
  final cols = j['columns'];
  if (cols is! List || cols.isEmpty || cols.first != 't') {
    out.add('columns: wymagana lista zaczynająca się od „t”');
    return;
  }
  final recs = j['recordings'];
  if (recs is! List) {
    out.add('brak listy recordings');
    return;
  }
  for (final (i, r) in recs.indexed) {
    if (r is! Map || r['start'] is! int || r['end'] is! int || r['minutes'] is! List) {
      out.add('recordings[$i]: wymagane start, end i minutes');
      continue;
    }
    for (final m in r['minutes'] as List) {
      if (m is! List || m.length != cols.length || m.first is! int) {
        out.add('recordings[$i]: wiersz minut niezgodny z columns');
        break;
      }
    }
  }
}

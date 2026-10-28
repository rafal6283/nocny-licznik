import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'fmt.dart';

/// Dziennik zdarzeń jednej nocy (plik tekstowy) — do diagnozowania przerwanych nagrań.
class NightLog {
  static Future<File> _file(int nightId) async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(docs.path, 'logs'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return File(p.join(d.path, 'night_$nightId.txt'));
  }

  static Future<void> add(int? nightId, String line) async {
    if (nightId == null) return;
    try {
      final f = await _file(nightId);
      final now = DateTime.now();
      await f.writeAsString('${shortDate(now)} ${hhmmss(now)}  $line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<String> read(int nightId) async {
    try {
      final f = await _file(nightId);
      return f.existsSync() ? await f.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  static Future<void> delete(int nightId) async {
    try {
      final f = await _file(nightId);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}

/// Powód zakończenia procesu z Androida (ApplicationExitInfo).
class ExitReason {
  final DateTime ts;
  final int reason;
  final String description;
  final int importance;
  const ExitReason(this.ts, this.reason, this.description, this.importance);

  factory ExitReason.fromMap(Map<String, dynamic> m) => ExitReason(
        DateTime.fromMillisecondsSinceEpoch((m['ts'] as num).toInt()),
        (m['reason'] as num?)?.toInt() ?? 0,
        (m['description'] as String?) ?? '',
        (m['importance'] as num?)?.toInt() ?? 0,
      );

  /// Czy to zakończenie, które przerwałoby nagrywanie (a nie np. aktualizacja).
  bool get isKill => reason != 16 && reason != 15;

  String get label => switch (reason) {
        1 => 'aplikacja zakończyła się sama',
        2 => 'zamknięta sygnałem systemu (zwykle oszczędzanie baterii lub menedżer zadań producenta)',
        3 => 'zamknięta przez system z braku pamięci',
        4 => 'awaria aplikacji (błąd w kodzie)',
        5 => 'awaria aplikacji (błąd natywny)',
        6 => 'aplikacja przestała odpowiadać (ANR)',
        7 => 'błąd uruchamiania',
        8 => 'zmiana uprawnień (np. cofnięty dostęp do mikrofonu)',
        9 => 'zamknięta za nadmierne zużycie zasobów/baterii',
        10 => 'zamknięta przez użytkownika („Wymuś zatrzymanie” lub wyczyszczenie z ostatnich aplikacji)',
        11 => 'zatrzymana przez użytkownika w ustawieniach systemu',
        12 => 'zakończona, bo zakończył się proces, od którego zależała',
        13 => 'zamknięta przez system (inny powód)',
        14 => 'zamrożona przez system',
        15 => 'zmiana stanu pakietu (np. wyłączenie aplikacji)',
        16 => 'aktualizacja aplikacji',
        _ => 'nieznany powód',
      };

  String get tip => switch (reason) {
        2 || 9 || 13 || 14 =>
          'Wyłącz optymalizację baterii dla Rytmu Snu (przycisk na ekranie Noc lub Ustawienia → Diagnostyka). '
              'Na Xiaomi/Redmi/POCO włącz też „Autostart” i ustaw oszczędzanie baterii na „Bez ograniczeń”; '
              'na Samsungu ustaw baterię na „Bez ograniczeń” i usuń aplikację z „Uśpionych aplikacji”.',
        3 => 'Zamknij inne aplikacje na noc i nie uruchamiaj gier/aparatu w tle.',
        10 || 11 => 'Nie zamykaj aplikacji z listy ostatnich i nie czyść ich w nocy. Na Xiaomi możesz ją tam „przypiąć” (kłódka).',
        4 || 5 || 6 => 'To błąd w aplikacji — wyślij mi zrzut z ekranu Diagnostyka, poprawię go.',
        8 => 'Sprawdź, czy aplikacja ma stały dostęp do mikrofonu.',
        _ => '',
      };

  String get text => '${hhmm(ts)} (${shortDate(ts)}) — $label${description.isNotEmpty ? ' [$description]' : ''}';
}

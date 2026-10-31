import 'dart:convert';

/// Progi pewności (0..1) dla rodzajów dźwięków, wyuczone z ocen nagrań i danych aparatu CPAP.
/// Zdarzenie poniżej progu nie liczy się do wyniku nocy (chyba że ocenisz je ręcznie jako „to było to”).
class SoundThresholds {
  static Map<String, double> map = {};

  static double of(String typeName) => map[typeName] ?? 0;

  static void loadJson(String s) {
    try {
      final m = s.isEmpty ? const {} : jsonDecode(s) as Map<String, dynamic>;
      map = {for (final e in m.entries) e.key: (e.value as num).toDouble()};
    } catch (_) {
      map = {};
    }
  }

  static String toJson() => jsonEncode(map);
}

import 'dart:convert';

/// Dane logowania do wspólnego, rodzinnego konta Koofr.
class KoofrConfig {
  final String email;

  /// Hasło aplikacji z Koofr (Ustawienia konta → Hasła → Hasła aplikacji), nie hasło do konta.
  final String appPassword;

  /// Folder główny na Koofr, w którym leżą dane wszystkich aplikacji.
  final String root;

  const KoofrConfig({required this.email, required this.appPassword, this.root = 'Rodzina'});

  Map<String, Object?> toJson() => {'e': email, 'p': appPassword, 'r': root};

  factory KoofrConfig.fromJson(Map<String, Object?> j) => KoofrConfig(
        email: (j['e'] ?? '') as String,
        appPassword: (j['p'] ?? '') as String,
        root: (j['r'] as String?)?.trim().isNotEmpty == true ? j['r'] as String : 'Rodzina',
      );

  static const _prefix = 'KSYNC1:';

  /// Kod konfiguracji do przekazania na drugi telefon (zawiera hasło aplikacji!).
  String toCode() => _prefix + base64Url.encode(utf8.encode(jsonEncode(toJson()))).replaceAll('=', '');

  static KoofrConfig? fromCode(String text) {
    final t = text.trim().replaceAll(RegExp(r'\s'), '');
    if (!t.startsWith(_prefix)) return null;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(t.substring(_prefix.length)))));
      final c = KoofrConfig.fromJson((j as Map).cast<String, Object?>());
      return c.email.isEmpty || c.appPassword.isEmpty ? null : c;
    } catch (_) {
      return null;
    }
  }
}

/// Bezpieczny magazyn klucz–wartość dostarczany przez aplikację
/// (np. flutter_secure_storage: Keystore na Androidzie, Pęk kluczy na iOS).
abstract class KsStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Magazyn w pamięci — do testów.
class MemoryStore implements KsStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Identyfikator z imienia: małe litery ASCII, cyfry i myślniki („Zosia Ś.” → „zosia-s”).
String slugify(String name) {
  const pl = {'ą': 'a', 'ć': 'c', 'ę': 'e', 'ł': 'l', 'ń': 'n', 'ó': 'o', 'ś': 's', 'ź': 'z', 'ż': 'z'};
  final s = name
      .toLowerCase()
      .split('')
      .map((c) => pl[c] ?? c)
      .join()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? 'osoba' : (s.length > 24 ? s.substring(0, 24) : s);
}

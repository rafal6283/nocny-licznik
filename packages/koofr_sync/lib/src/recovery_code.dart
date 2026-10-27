import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Osobisty kod odzyskiwania członka rodziny — jeden na wszystkie aplikacje.
///
/// 18 losowych bajtów (144 bity) + 2 bajty sumy kontrolnej (SHA-256) = 20 bajtów,
/// zapisane jako 32 znaki base32 (Crockford, bez I/L/O/U) w 8 grupach po 4:
/// `K7QM-3XZD-…`. Literówka jest wykrywana dzięki sumie kontrolnej.
///
/// Z kodu wyprowadzane są: klucz kopii zapasowych i para kluczy do podglądu (osobno
/// dla każdej aplikacji). Kto zna kod, odtworzy kopie i tożsamość na nowym telefonie.
class RecoveryCode {
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const entropyBytes = 18;

  /// Losowa część kodu (bez sumy kontrolnej).
  final Uint8List entropy;

  RecoveryCode._(this.entropy);

  static Future<RecoveryCode> generate() async {
    final r = Random.secure();
    return RecoveryCode._(Uint8List.fromList(List.generate(entropyBytes, (_) => r.nextInt(256))));
  }

  /// Zwraca null, gdy kod jest niepełny lub ma literówkę.
  static Future<RecoveryCode?> parse(String text) async {
    final s = normalize(text);
    if (s.length != 32) return null;
    final bytes = _decode(s);
    if (bytes == null || bytes.length != 20) return null;
    final ent = Uint8List.fromList(bytes.sublist(0, entropyBytes));
    final sum = await _checksum(ent);
    if (bytes[18] != sum[0] || bytes[19] != sum[1]) return null;
    return RecoveryCode._(ent);
  }

  /// Wielkie litery, bez spacji i myślników; O→0, I/L→1 (częste pomyłki przy przepisywaniu).
  static String normalize(String text) => text
      .toUpperCase()
      .replaceAll(RegExp(r'[^0-9A-Z]'), '')
      .replaceAll('O', '0')
      .replaceAll('I', '1')
      .replaceAll('L', '1')
      .replaceAll('U', 'V');

  Future<String> format() async {
    final sum = await _checksum(entropy);
    final s = _encode([...entropy, sum[0], sum[1]]);
    return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4)].join('-');
  }

  static Future<List<int>> _checksum(List<int> ent) async => (await Sha256().hash(ent)).bytes.sublist(0, 2);

  static String _encode(List<int> bytes) {
    final out = StringBuffer();
    var buf = 0, bits = 0;
    for (final b in bytes) {
      buf = (buf << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buf >> bits) & 31]);
      }
      buf &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_alphabet[(buf << (5 - bits)) & 31]);
    return out.toString();
  }

  static List<int>? _decode(String s) {
    final out = <int>[];
    var buf = 0, bits = 0;
    for (final ch in s.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) return null;
      buf = (buf << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buf >> bits) & 255);
      }
      buf &= (1 << bits) - 1;
    }
    return out;
  }
}

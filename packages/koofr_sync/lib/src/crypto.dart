import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'recovery_code.dart';

/// Błąd odszyfrowania: zły kod odzyskiwania, plik od kogoś innego albo uszkodzony.
class KsCryptoException implements Exception {
  final String message;
  KsCryptoException(this.message);
  @override
  String toString() => message;
}

/// Format plików `.ksy` (wersja 1):
///
/// ```
/// "KSY1" | rodzaj (1 bajt) | …
///   rodzaj 1 = kopia:   nonce(12) | szyfrogram | tag(16)
///   rodzaj 2 = podgląd: klucz efemeryczny X25519(32) | nonce(12) | szyfrogram | tag(16)
/// ```
/// Treść przed szyfrowaniem jest kompresowana gzipem. Nagłówek i identyfikator
/// aplikacji wchodzą do AAD, więc pliku nie da się podmienić między aplikacjami.
class KsCrypto {
  static const _magic = [0x4B, 0x53, 0x59, 0x31]; // KSY1
  static const kindBackup = 1;
  static const kindShare = 2;

  static final _aes = AesGcm.with256bits();
  static final _x25519 = X25519();
  static Hkdf _hkdf() => Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final _salt = utf8.encode('koofr_sync v1');

  /// Klucze jednej osoby w jednej aplikacji, wyprowadzone z kodu odzyskiwania.
  final String appId;
  final SecretKey backupKey;
  final SimpleKeyPair identity;
  final SimplePublicKey publicKey;

  /// Skrót kodu do sprawdzenia, czy wpisano ten sam kod co na innym telefonie
  /// (zapisany w katalogu członków; nie pozwala odtworzyć kodu).
  final String codeCheck;

  KsCrypto._(this.appId, this.backupKey, this.identity, this.publicKey, this.codeCheck);

  static Future<KsCrypto> fromCode(RecoveryCode code, String appId) async {
    final master = await _derive(code.entropy, 'master');
    final backup = await _derive(master, 'backup/$appId');
    final seed = await _derive(master, 'x25519/$appId');
    final check = await _derive(master, 'check');
    final kp = await _x25519.newKeyPairFromSeed(seed);
    final pub = await kp.extractPublicKey();
    return KsCrypto._(appId, SecretKey(backup), kp, pub, hex(check.sublist(0, 8)));
  }

  /// Skrót kodu bez wyprowadzania kluczy aplikacji — do porównań przy dołączaniu.
  static Future<String> checkOf(RecoveryCode code) async {
    final master = await _derive(code.entropy, 'master');
    return hex((await _derive(master, 'check')).sublist(0, 8));
  }

  static Future<List<int>> _derive(List<int> ikm, String info, [List<int>? salt]) async {
    final k = await _hkdf().deriveKey(secretKey: SecretKey(ikm), nonce: salt ?? _salt, info: utf8.encode(info));
    return k.extractBytes();
  }

  String get publicKeyB64 => base64Url.encode(publicKey.bytes);

  static SimplePublicKey parsePublicKey(String b64) {
    final b = base64Url.decode(base64Url.normalize(b64));
    if (b.length != 32) throw KsCryptoException('Nieprawidłowy klucz publiczny');
    return SimplePublicKey(b, type: KeyPairType.x25519);
  }

  // ---------------------------------------------------------------- kopia

  Future<Uint8List> sealBackup(List<int> data) async {
    final header = [..._magic, kindBackup];
    final box = await _aes.encrypt(gzip.encode(data),
        secretKey: backupKey, nonce: _aes.newNonce(), aad: [...header, ...utf8.encode(appId)]);
    return Uint8List.fromList([...header, ...box.concatenation()]);
  }

  Future<Uint8List> openBackup(List<int> file) async {
    _checkHeader(file, kindBackup);
    final header = file.sublist(0, 5);
    try {
      final box = SecretBox.fromConcatenation(file.sublist(5), nonceLength: 12, macLength: 16);
      final clear = await _aes.decrypt(box, secretKey: backupKey, aad: [...header, ...utf8.encode(appId)]);
      return Uint8List.fromList(gzip.decode(clear));
    } on SecretBoxAuthenticationError {
      throw KsCryptoException('Nie da się odszyfrować kopii — to kopia innej osoby albo inny kod odzyskiwania.');
    }
  }

  // ---------------------------------------------------------------- podgląd

  /// Szyfruje dane dla jednej osoby. Klucz łączy klucz efemeryczny (poufność przy wycieku
  /// klucza nadawcy) i stały klucz nadawcy (odbiorca wie, że dane są od właściciela).
  Future<Uint8List> sealFor(SimplePublicKey recipient, List<int> data) async {
    final header = [..._magic, kindShare];
    final eph = await _x25519.newKeyPair();
    final ephPub = await eph.extractPublicKey();
    final key = await _shareKey(
      ss1: await _x25519.sharedSecretKey(keyPair: eph, remotePublicKey: recipient),
      ss2: await _x25519.sharedSecretKey(keyPair: identity, remotePublicKey: recipient),
      ephPub: ephPub.bytes,
      senderPub: publicKey.bytes,
      recipientPub: recipient.bytes,
    );
    final box = await _aes.encrypt(gzip.encode(data),
        secretKey: key, nonce: _aes.newNonce(), aad: [...header, ...utf8.encode(appId)]);
    return Uint8List.fromList([...header, ...ephPub.bytes, ...box.concatenation()]);
  }

  /// Odszyfrowuje dane od [sender] skierowane do mnie.
  Future<Uint8List> openFrom(SimplePublicKey sender, List<int> file) async {
    _checkHeader(file, kindShare);
    final header = file.sublist(0, 5);
    if (file.length < 5 + 32 + 28) throw KsCryptoException('Plik podglądu jest uszkodzony.');
    final ephPub = SimplePublicKey(file.sublist(5, 37), type: KeyPairType.x25519);
    final key = await _shareKey(
      ss1: await _x25519.sharedSecretKey(keyPair: identity, remotePublicKey: ephPub),
      ss2: await _x25519.sharedSecretKey(keyPair: identity, remotePublicKey: sender),
      ephPub: ephPub.bytes,
      senderPub: sender.bytes,
      recipientPub: publicKey.bytes,
    );
    try {
      final box = SecretBox.fromConcatenation(file.sublist(37), nonceLength: 12, macLength: 16);
      final clear = await _aes.decrypt(box, secretKey: key, aad: [...header, ...utf8.encode(appId)]);
      return Uint8List.fromList(gzip.decode(clear));
    } on SecretBoxAuthenticationError {
      throw KsCryptoException('Nie da się odszyfrować — dane nie pochodzą od tej osoby albo zmieniła kod.');
    }
  }

  Future<SecretKey> _shareKey({
    required SecretKey ss1,
    required SecretKey ss2,
    required List<int> ephPub,
    required List<int> senderPub,
    required List<int> recipientPub,
  }) async {
    final ikm = [...await ss1.extractBytes(), ...await ss2.extractBytes()];
    return _hkdf().deriveKey(
      secretKey: SecretKey(ikm),
      nonce: _salt,
      info: [...utf8.encode('share/$appId'), ...ephPub, ...senderPub, ...recipientPub],
    );
  }

  static void _checkHeader(List<int> file, int kind) {
    if (file.length < 5) throw KsCryptoException('Plik jest pusty lub uszkodzony.');
    for (var i = 0; i < 4; i++) {
      if (file[i] != _magic[i]) throw KsCryptoException('To nie jest plik kopii/podglądu.');
    }
    if (file[4] != kind) throw KsCryptoException('Nieoczekiwany rodzaj pliku.');
  }

  /// Kod bezpieczeństwa pary osób (12 cyfr) — taki sam na obu telefonach. Zgodność
  /// potwierdza, że nikt nie podmienił klucza w katalogu członków.
  static Future<String> safetyNumber(String appId, SimplePublicKey a, SimplePublicKey b) async {
    final ka = base64Url.encode(a.bytes), kb = base64Url.encode(b.bytes);
    final sorted = ka.compareTo(kb) <= 0 ? [ka, kb] : [kb, ka];
    final h = (await Sha256().hash(utf8.encode('safety/$appId/${sorted.join('/')}'))).bytes;
    var n = BigInt.zero;
    for (final x in h.sublist(0, 8)) {
      n = (n << 8) | BigInt.from(x);
    }
    final s = (n % BigInt.from(10).pow(12)).toString().padLeft(12, '0');
    return '${s.substring(0, 4)} ${s.substring(4, 8)} ${s.substring(8)}';
  }

  static String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}

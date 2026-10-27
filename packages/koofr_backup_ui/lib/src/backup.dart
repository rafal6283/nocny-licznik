import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:koofr_sync/koofr_sync.dart';

/// Hasło i klucze w Keystore (Android) / Pęku kluczy (iOS).
class SecureStore implements KsStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Co trafia do kopii: [data] (baza, ustawienia) i załączniki [blobs] wysyłane tylko raz.
class BackupContent {
  final List<int> data;
  final List<BackupBlob> blobs;
  BackupContent(this.data, [this.blobs = const []]);
}

/// Część zależna od aplikacji: jak spakować dane i jak je odtworzyć.
abstract class BackupAdapter {
  /// Identyfikator folderu na Koofr, np. „teczka”, „portfel”.
  String get appId;

  /// Nazwa aplikacji do komunikatów.
  String get appName;

  /// Dopisek na ekranie kopii (co jest, a czego nie ma w kopii).
  String get contentNote;

  Future<BackupContent> export();

  /// Zastępuje dane aplikacji danymi z kopii. Załączniki pobiera [r.blob].
  Future<void> import(RestoredBackup r, void Function(String step) progress);

  /// Kopię automatyczną wstrzymujemy, gdy aplikacja jest w trakcie czegoś ważnego (np. nagrywania).
  bool get busy => false;
}

/// Kopia zapasowa jednej aplikacji na rodzinnym koncie Koofr.
class KoofrBackup {
  static KoofrBackup? _instance;

  static KoofrBackup get instance {
    final i = _instance;
    if (i == null) throw StateError('KoofrBackup.setup() nie zostało wywołane');
    return i;
  }

  final BackupAdapter adapter;
  final KoofrSync sync;
  final lastError = ValueNotifier<String?>(null);
  final busy = ValueNotifier<bool>(false);
  final progress = ValueNotifier<String?>(null);

  KoofrBackup._(this.adapter) : sync = KoofrSync(appId: adapter.appId, store: SecureStore());

  /// Wywołaj raz przy starcie aplikacji; potem w tle zrobi kopię, jeśli jest pora.
  static Future<KoofrBackup> setup(BackupAdapter adapter, {bool autoRun = true}) async {
    final b = _instance ??= KoofrBackup._(adapter);
    await b.sync.load();
    if (autoRun) unawaited(Future.delayed(const Duration(seconds: 6), b.autoRun));
    return b;
  }

  Future<bool> wifiOnly() async => (await sync.store.read('ks.wifiOnly')) != '0';
  Future<void> setWifiOnly(bool v) => sync.store.write('ks.wifiOnly', v ? '1' : '0');

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  /// Kopia raz na dobę, jeśli włączona (domyślnie tylko przez Wi-Fi). Błędy trafiają do [lastError].
  Future<void> autoRun() async {
    if (busy.value || adapter.busy) return;
    try {
      if (!await sync.backupDue()) return;
      if (await wifiOnly() && !await _onWifi()) return;
      await backupNow();
      lastError.value = null;
    } catch (e) {
      lastError.value = '$e';
    }
  }

  Future<BackupInfo> backupNow() async {
    if (busy.value) throw KoofrException('Kopia już trwa.');
    busy.value = true;
    try {
      progress.value = 'Przygotowanie danych…';
      final c = await adapter.export();
      progress.value = c.blobs.isEmpty ? 'Wysyłanie…' : 'Wysyłanie załączników…';
      return await sync.backupNow(c.data,
          blobs: c.blobs, onProgress: (d, t) => progress.value = 'Załączniki: $d z $t');
    } finally {
      busy.value = false;
      progress.value = null;
    }
  }

  Future<void> restore(BackupInfo b) async {
    if (busy.value) throw KoofrException('Trwa kopia, spróbuj za chwilę.');
    busy.value = true;
    try {
      progress.value = 'Pobieranie kopii…';
      final r = await sync.restoreFull(b);
      await adapter.import(r, (s) => progress.value = s);
    } finally {
      busy.value = false;
      progress.value = null;
    }
  }
}

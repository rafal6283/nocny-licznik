import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:koofr_sync/koofr_sync.dart';

import 'background.dart';

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

  /// Co się stanie przy przywracaniu — pokazywane w potwierdzeniu.
  String get restoreWarning => 'Dane z kopii zastąpią obecne dane aplikacji $appName na tym telefonie.';

  /// Kopię automatyczną wstrzymujemy, gdy aplikacja jest w trakcie czegoś ważnego (np. nagrywania).
  bool get busy => false;

  /// Wymiana danych z innymi aplikacjami tej samej osoby (null = aplikacja nic nie wymienia).
  ExchangeAdapter? get exchange => null;
}

/// Automatyczna wymiana plików „wymiana-zdarzen” między moimi aplikacjami przez Koofr.
abstract class ExchangeAdapter {
  /// Co aplikacja udostępnia (opis do ustawień); null = nic.
  String? get publishes => null;

  /// Źródła do pobierania: (przedrostek nazwy pliku, opis), np. ('rytm-snu', 'Rytm Snu (wiatry w nocy)').
  List<(String, String)> get sources => const [];

  /// Pliki do opublikowania: nazwa → treść; null = usuń z Koofr.
  Future<Map<String, List<int>?>> export() async => const {};

  /// Wczytanie pobranego pliku (zastępuje poprzednie dane z tego źródła).
  Future<void> import(String name, Uint8List data) async {}

  /// Dodatkowe ustawienia w sekcji wymiany (np. dla której osoby zapisywać dane).
  Widget? extraSettings(BuildContext context) => null;
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

  /// Wywołaj raz przy starcie aplikacji; potem w tle zrobi kopię i wymianę, jeśli jest pora
  /// (także po każdym powrocie do aplikacji).
  static Future<KoofrBackup> setup(BackupAdapter adapter, {bool autoRun = true}) async {
    final first = _instance == null;
    final b = _instance ??= KoofrBackup._(adapter);
    await b.sync.load();
    if (autoRun) {
      unawaited(Future.delayed(const Duration(seconds: 6), b.autoRun));
      if (first) WidgetsBinding.instance.addObserver(_Resume(b));
    }
    return b;
  }

  // ------------------------------------------------------------ wymiana

  Future<bool> exchangeOn() async => (await sync.store.read('ks.ex.on')) == '1';
  Future<void> setExchangeOn(bool v) => sync.store.write('ks.ex.on', v ? '1' : '0');
  Future<bool> publishOn() async => (await sync.store.read('ks.ex.publish')) != '0';
  Future<void> setPublishOn(bool v) => sync.store.write('ks.ex.publish', v ? '1' : '0');
  Future<bool> sourceOn(String prefix) async => (await sync.store.read('ks.ex.src.$prefix')) != '0';
  Future<void> setSourceOn(String prefix, bool v) => sync.store.write('ks.ex.src.$prefix', v ? '1' : '0');

  final lastExchange = ValueNotifier<String?>(null);
  DateTime? _lastExchangeRun;
  bool _exchanging = false;

  /// Publikuje i pobiera dane wymiany; zwraca opis wyniku.
  /// [pull] = false: tylko wysyłka (w tle nie zmieniamy danych aplikacji, bo może być otwarta).
  Future<String> exchangeNow({bool force = false, bool pull = true}) async {
    final ex = adapter.exchange;
    if (ex == null || !sync.ready || !await exchangeOn() || _exchanging) return '';
    _exchanging = true;
    try {
      final sent = <String>[];
      if (ex.publishes != null) {
        final pub = await publishOn();
        for (final e in (await ex.export()).entries) {
          if (e.value == null || !pub) {
            await sync.removeExchange(e.key);
          } else if (await sync.publishExchange(e.key, e.value!, force: force)) {
            sent.add(e.key);
          }
        }
      }
      final on = {for (final s in ex.sources) s.$1: await sourceOn(s.$1)};
      final got = ex.sources.isEmpty || !pull
          ? const <String>[]
          : await sync.pullExchange(
              (n) => on.entries.any((s) => s.value && (n == s.key || n.startsWith('${s.key}-'))), ex.import,
              force: force);
      _lastExchangeRun = DateTime.now();
      final msg = [
        if (sent.isNotEmpty) 'wysłano: ${sent.join(', ')}',
        if (got.isNotEmpty) 'pobrano: ${got.join(', ')}',
      ].join(' · ');
      lastExchange.value = msg.isEmpty ? 'bez zmian' : msg;
      return lastExchange.value!;
    } finally {
      _exchanging = false;
    }
  }

  Future<bool> wifiOnly() async => (await sync.store.read('ks.wifiOnly')) != '0';
  Future<void> setWifiOnly(bool v) async {
    await sync.store.write('ks.wifiOnly', v ? '1' : '0');
    await KoofrBackground.refresh();
  }

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  /// Kopia raz na dobę, jeśli włączona (domyślnie tylko przez Wi-Fi). Błędy trafiają do [lastError].
  /// [background]: praca w tle (WorkManager) — tylko odczyt danych aplikacji: kopia i wysyłka.
  Future<void> autoRun({bool background = false}) async {
    if (busy.value || adapter.busy) return;
    try {
      // wymiana: małe pliki, także bez Wi-Fi; co najmniej co 15 min
      final last = _lastExchangeRun;
      if (adapter.exchange != null && (last == null || DateTime.now().difference(last).inMinutes >= 15)) {
        await exchangeNow(pull: !background);
      }
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

class _Resume with WidgetsBindingObserver {
  final KoofrBackup b;
  _Resume(this.b);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(b.autoRun());
  }
}

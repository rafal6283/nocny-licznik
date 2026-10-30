import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:koofr_sync/koofr_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../engine/night_engine.dart';
import 'bus.dart';
import 'db.dart';
import 'exchange_export.dart';
import 'models.dart';
import 'settings.dart';

/// Klucze i hasło Koofr w Keystore (Android) / Pęku kluczy (iOS).
class SecureStore implements KsStore {
  static const _s = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Zakres podglądu ustalany przez osobę udostępniającą.
class ShareScope {
  static const days = 'days';
  static const stages = 'stages';
  static const snore = 'snore';
  static const breath = 'breath';
  static const cpap = 'cpap';
  static const watch = 'watch';
  static const notes = 'notes';
  static const farts = 'farts';

  static Map<String, Object?> defaults() =>
      {days: 30, stages: true, snore: true, breath: true, cpap: false, watch: false, notes: false, farts: false};

  static String label(String k) => switch (k) {
        stages => 'Fazy snu (hipnogram)',
        snore => 'Chrapanie, mówienie, kaszel',
        breath => 'Oddech i przerwy w oddechu',
        cpap => 'Dane z aparatu CPAP',
        watch => 'Tętno i SpO₂ z zegarka',
        notes => 'Tagi, notatki i ocena',
        farts => 'FF',
        _ => k,
      };
}

/// Kopia zapasowa i podgląd snu przez rodzinne konto Koofr.
class Cloud {
  Cloud._();

  static final sync = KoofrSync(appId: 'rytm-snu', store: SecureStore());

  /// Ostatni błąd automatycznej kopii/wysyłki — pokazywany na ekranie Koofr.
  static final lastError = ValueNotifier<String?>(null);
  static final busy = ValueNotifier<bool>(false);

  static bool _loaded = false;

  /// Praca w tle (WorkManager, osobny proces Darta) — tylko odczyt danych.
  static bool _background = false;

  /// Czy trwa nagrywanie nocy. W tle silnik nocy nie działa w tym procesie,
  /// więc patrzymy na niezakończoną noc w bazie.
  static Future<bool> _nightActive() async =>
      _background ? (await Db.instance.unfinishedNights()).isNotEmpty : NightEngine.instance.isActive;

  static const _bgTask = 'rytm-snu-koofr';

  /// Rejestracja pracy w tle (Android) co 3 h; warunek sieci zależy od „tylko Wi-Fi”.
  static Future<void> startBackground() async {
    if (!Platform.isAndroid) return;
    try {
      await Workmanager().initialize(rytmSnuBackground);
      final wifi = await wifiOnly();
      final cfg = 'v1/${wifi ? 'wifi' : 'any'}';
      final p = await SharedPreferences.getInstance();
      if (p.getString('koofrBgCfg') case final prev? when prev != cfg) await Workmanager().cancelByUniqueName(_bgTask);
      await Workmanager().registerPeriodicTask(_bgTask, _bgTask,
          frequency: const Duration(hours: 3),
          constraints: Constraints(networkType: wifi ? NetworkType.unmetered : NetworkType.connected));
      await p.setString('koofrBgCfg', cfg);
    } catch (e) {
      debugPrint('Koofr w tle: $e');
    }
  }

  static Future<void> init() async {
    if (_loaded) return;
    await sync.load();
    _loaded = true;
  }

  // ------------------------------------------------------------ ustawienia lokalne

  static const _wifiKey = 'koofrWifiOnly';
  static Future<bool> wifiOnly() async => (await SharedPreferences.getInstance()).getBool(_wifiKey) ?? true;
  static Future<void> setWifiOnly(bool v) async {
    await (await SharedPreferences.getInstance()).setBool(_wifiKey, v);
    await startBackground();
  }

  static Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet);
    } catch (_) {
      return true;
    }
  }

  static DateTime? _lastPublish;

  /// Automatyka: po starcie, po powrocie do aplikacji i po zakończeniu nocy.
  /// Kopia raz na dobę (jeśli włączona), wysyłka podglądu co najmniej co 15 min.
  /// Nic nie robi w trakcie nagrywania nocy.
  static Future<void> autoRun({bool afterNight = false}) async {
    try {
      await init();
      if (!sync.ready || busy.value || await _nightActive()) return;
      if (afterNight || _lastExchange == null || DateTime.now().difference(_lastExchange!).inMinutes >= 15) {
        await exchangeNow();
      }
      final consents = await sync.myConsents();
      final wantBackup = await sync.backupDue();
      final wantPublish = consents.isNotEmpty &&
          (afterNight || _lastPublish == null || DateTime.now().difference(_lastPublish!).inMinutes >= 15);
      if (!wantBackup && !wantPublish) return;
      if (await wifiOnly() && !await _onWifi()) return;
      busy.value = true;
      if (wantBackup) await backupNow();
      if (wantPublish) await publish();
      lastError.value = null;
    } catch (e) {
      lastError.value = '$e';
    } finally {
      busy.value = false;
    }
  }

  // ------------------------------------------------------------ wymiana z moimi aplikacjami

  static DateTime? _lastExchange;
  static final lastExchangeMsg = ValueNotifier<String?>(null);

  static Future<bool> exchangeOn() async => (await sync.store.read('ks.ex.on')) == '1';
  static Future<void> setExchangeOn(bool v) => sync.store.write('ks.ex.on', v ? '1' : '0');

  /// Wiatry trafiają do Kreski, Doby i Dziennika talerza tylko przy włączonym liczeniu wiatrów;
  /// po wyłączeniu plik jest usuwany z Koofr.
  static Future<String> exchangeNow({bool force = false}) async {
    if (!sync.ready || !await exchangeOn()) return '';
    String msg;
    if (Settings.instance.detectFarts) {
      final (bytes, _, farts) = await buildFartExchange();
      msg = await sync.publishExchange('rytm-snu', bytes, force: force) ? 'wysłano FF ($farts)' : 'bez zmian';
    } else {
      await sync.removeExchange('rytm-snu');
      msg = 'licznik FF wyłączony — nic nie jest udostępniane';
    }
    _lastExchange = DateTime.now();
    lastExchangeMsg.value = msg;
    return msg;
  }

  // ------------------------------------------------------------ kopia zapasowa

  /// Kontener kopii: [4 bajty długości nagłówka][nagłówek JSON][plik bazy SQLite].
  static Future<BackupInfo> backupNow() async {
    if (await _nightActive()) throw KoofrException('Kopię można zrobić, gdy noc nie jest nagrywana.');
    final header = utf8.encode(jsonEncode({
      'format': 'rytm-snu-kopia',
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'prefs': await _exportPrefs(),
    }));
    final dbBytes = await _snapshotDb();
    final out = BytesBuilder(copy: false)
      ..add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List())
      ..add(header)
      ..add(dbBytes);
    return sync.backupNow(out.takeBytes());
  }

  /// Spójna kopia pliku bazy: VACUUM INTO (Android 11+), w razie braku — zwykła kopia pliku.
  static Future<Uint8List> _snapshotDb() async {
    final path = await Db.path;
    final tmp = File('$path.kopia');
    try {
      if (await tmp.exists()) await tmp.delete();
      final d = await Db.instance.db;
      await d.execute("VACUUM INTO '${tmp.path.replaceAll("'", "''")}'");
      final b = await tmp.readAsBytes();
      await tmp.delete();
      return b;
    } catch (_) {
      try {
        final d = await Db.instance.db;
        await d.rawQuery('PRAGMA wal_checkpoint(FULL)');
      } catch (_) {}
      return File(path).readAsBytes();
    }
  }

  /// Ustawienia do kopii (bez stanu bieżącej nocy i bez ustawień samej synchronizacji).
  static Future<Map<String, Object?>> _exportPrefs() async {
    final p = await SharedPreferences.getInstance();
    const skip = {'tonightTags', 'tonightLight', _wifiKey};
    return {
      for (final k in p.getKeys().where((k) => !skip.contains(k)))
        if (p.get(k) case final v?) k: v is List ? {'list': v} : v,
    };
  }

  /// Przywraca kopię: odkłada obecną bazę obok (bakometr.db.przed-przywroceniem) i podmienia plik.
  static Future<int> restore(BackupInfo b) async {
    if (NightEngine.instance.isActive) throw KoofrException('Zakończ najpierw nagrywanie nocy.');
    final data = await sync.restore(b);
    if (data.length < 4) throw KoofrException('Kopia jest uszkodzona.');
    final hLen = ByteData.sublistView(data, 0, 4).getUint32(0);
    final header = (jsonDecode(utf8.decode(data.sublist(4, 4 + hLen))) as Map).cast<String, Object?>();
    if (header['format'] != 'rytm-snu-kopia') throw KoofrException('To nie jest kopia Rytmu Snu.');
    final dbBytes = data.sublist(4 + hLen);
    // nagłówek pliku SQLite
    if (dbBytes.length < 100 || utf8.decode(dbBytes.sublist(0, 15), allowMalformed: true) != 'SQLite format 3') {
      throw KoofrException('Kopia nie zawiera bazy danych.');
    }

    final path = await Db.path;
    await Db.instance.close();
    final cur = File(path);
    if (await cur.exists()) await cur.copy('$path.przed-przywroceniem');
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
    await cur.writeAsBytes(dbBytes, flush: true);

    // Nagrań dźwięku nie ma w kopii — odpinamy brakujące pliki.
    final d = await Db.instance.db;
    for (final m in await d.query('events', columns: ['id', 'clip_path'], where: 'clip_path IS NOT NULL')) {
      if (!await File(m['clip_path'] as String).exists()) {
        await d.update('events', {'clip_path': null}, where: 'id = ?', whereArgs: [m['id']]);
      }
    }

    final p = await SharedPreferences.getInstance();
    final prefs = (header['prefs'] as Map?)?.cast<String, Object?>() ?? {};
    for (final e in prefs.entries) {
      final v = e.value;
      if (v is bool) await p.setBool(e.key, v);
      if (v is int) await p.setInt(e.key, v);
      if (v is double) await p.setDouble(e.key, v);
      if (v is String) await p.setString(e.key, v);
      if (v is Map && v['list'] is List) await p.setStringList(e.key, (v['list'] as List).cast<String>());
    }
    await Settings.instance.reload();
    dataChanged();
    return (await d.rawQuery('SELECT COUNT(*) AS n FROM nights')).first['n'] as int;
  }

  // ------------------------------------------------------------ podgląd snu

  static Future<int> publish() async {
    final n = await sync.publishShares((viewer, scope) async => utf8.encode(jsonEncode(await buildShare(scope))));
    _lastPublish = DateTime.now();
    return n;
  }

  /// Dane do podglądu — tylko to, na co pozwala zakres. Wiatry wyłącznie wtedy, gdy liczenie
  /// wiatrów jest włączone u udostępniającego i zaznaczone w zakresie.
  static Future<Map<String, Object?>> buildShare(Map<String, Object?> scope) async {
    bool on(String k) => scope[k] == true;
    final days = (scope[ShareScope.days] as num?)?.toInt() ?? 30;
    final farts = on(ShareScope.farts) && Settings.instance.detectFarts;
    final since = DateTime.now().subtract(Duration(days: days));
    final me = await sync.me();
    final nights = (await Db.instance.nights()).where((n) => n.start.isAfter(since)).toList();
    final out = <Map<String, Object?>>[];
    for (final n in nights) {
      final m = <String, Object?>{
        'start': n.start.millisecondsSinceEpoch,
        'end': n.end?.millisecondsSinceEpoch,
        'score': n.score,
        'sleep': n.durationMin,
        'inBed': n.inBedMin,
        'deep': n.deepMin,
        'light': n.lightMin,
        'rem': n.remMin,
        'awake': n.awakeMin,
        'latency': n.latencyMin,
        'awakenings': n.awakenings,
      };
      if (on(ShareScope.snore)) {
        m.addAll({'snoreMin': n.snoreMin, 'talk': n.talkCount, 'cough': n.coughCount});
      }
      if (on(ShareScope.breath)) {
        m.addAll({
          'apnea': n.apneaCount,
          'hypopnea': n.hypopneaCount,
          'apneaIndex': n.apneaIndex,
          'breathRate': n.breathRate,
        });
      }
      if (on(ShareScope.cpap) && n.cpap) {
        m.addAll({'cpapAhi': n.cpapAhi, 'cpapLeak': n.cpapLeak, 'cpapUsage': n.cpapUsageMin});
      }
      if (on(ShareScope.watch)) {
        m.addAll({'hrAvg': n.hrAvg, 'hrMin': n.hrMin, 'spo2Avg': n.spo2Avg, 'spo2Min': n.spo2Min});
      }
      if (on(ShareScope.notes)) {
        m.addAll({'tags': n.tags, 'note': n.note, 'rating': n.rating});
      }
      if (farts) m['farts'] = n.fartCount;
      if (on(ShareScope.stages) && n.id != null) {
        final ms = await Db.instance.minutes(n.id!);
        if (ms.isNotEmpty) {
          m['t0'] = ms.first.ts.millisecondsSinceEpoch;
          m['stages'] = ms.map((x) => x.stage.index).join();
          if (on(ShareScope.snore)) m['snoreMap'] = ms.map((x) => x.snore ? '1' : '0').join();
        }
      }
      m.removeWhere((k, v) => v == null);
      out.add(m);
    }
    return {
      'format': 'rytm-snu-podglad',
      'version': 1,
      'owner': sync.userId,
      'name': me?.name,
      'generatedAt': DateTime.now().millisecondsSinceEpoch,
      'scope': {...scope, ShareScope.farts: farts},
      'nights': out,
    };
  }
}

/// Noc z podglądu innej osoby (tylko do odczytu).
class SharedNight {
  final Map<String, Object?> raw;
  SharedNight(this.raw);

  int _i(String k) => (raw[k] as num?)?.toInt() ?? 0;
  double? _d(String k) => (raw[k] as num?)?.toDouble();

  DateTime get start => DateTime.fromMillisecondsSinceEpoch(raw['start'] as int);
  DateTime? get end => raw['end'] == null ? null : DateTime.fromMillisecondsSinceEpoch(raw['end'] as int);
  int get score => _i('score');
  double? get apneaIndex => _d('apneaIndex');
  bool has(String k) => raw.containsKey(k);
  num? numOf(String k) => raw[k] as num?;
  List<String> get tags => ((raw['tags'] as List?) ?? const []).cast<String>();

  /// Night do ponownego użycia wykresów (pasek faz, pierścień oceny).
  Night toNight() => Night(
        start: start,
        end: end,
        score: score,
        durationMin: _i('sleep'),
        inBedMin: _i('inBed'),
        deepMin: _i('deep'),
        lightMin: _i('light'),
        remMin: _i('rem'),
        awakeMin: _i('awake'),
        latencyMin: _i('latency'),
        awakenings: _i('awakenings'),
      );

  /// Minuty z samymi fazami (do hipnogramu).
  List<MinuteSample> minutes() {
    final s = raw['stages'] as String?;
    final t0 = raw['t0'] as int?;
    if (s == null || t0 == null) return const [];
    final snore = raw['snoreMap'] as String?;
    return [
      for (var i = 0; i < s.length; i++)
        MinuteSample(
          idx: i,
          ts: DateTime.fromMillisecondsSinceEpoch(t0 + i * 60000),
          motion: 0,
          noiseDb: -120,
          snore: snore != null && i < snore.length && snore[i] == '1',
          stage: Stage.values[(int.tryParse(s[i]) ?? 2).clamp(0, Stage.values.length - 1)],
        ),
    ];
  }
}

/// Zadanie w tle (WorkManager): kopia, wysyłka FF i podglądu snu — bez otwierania aplikacji.
@pragma('vm:entry-point')
void rytmSnuBackground() {
  Workmanager().executeTask((name, input) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await Settings.instance.load();
      Cloud._background = true;
      await Cloud.autoRun();
    } catch (e) {
      debugPrint('Koofr w tle: $e');
    }
    return true;
  });
}

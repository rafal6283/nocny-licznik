import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show Sha256;

import 'config.dart';
import 'crypto.dart';
import 'recovery_code.dart';
import 'webdav.dart';

/// Członek rodziny zapisany w `<root>/_czlonkowie/<id>.json` (wspólne dla wszystkich aplikacji).
class Member {
  final String id;
  final String name;

  /// Skrót kodu odzyskiwania — pozwala sprawdzić, czy na nowym telefonie wpisano ten sam kod.
  final String? codeCheck;

  /// Klucze publiczne do podglądu: identyfikator aplikacji → klucz X25519 (base64url).
  final Map<String, String> keys;
  final DateTime? updatedAt;

  Member({required this.id, required this.name, this.codeCheck, Map<String, String>? keys, this.updatedAt})
      : keys = keys ?? {};

  Map<String, Object?> toJson() => {
        'v': 1,
        'id': id,
        'name': name,
        'codeCheck': codeCheck,
        'keys': keys,
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
      };

  factory Member.fromJson(Map<String, Object?> j) => Member(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? j['id'] as String,
        codeCheck: j['codeCheck'] as String?,
        keys: ((j['keys'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v as String)),
        updatedAt: j['updatedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['updatedAt'] as int),
      );
}

/// Załącznik kopii (zdjęcie, PDF…): [path] to ścieżka względna w aplikacji, [read] wczytuje treść.
class BackupBlob {
  final String path;
  final Future<List<int>> Function() read;
  BackupBlob(this.path, this.read);
}

/// Odczytana kopia: dane aplikacji, załączniki (ścieżka → identyfikator) i ich pobieranie.
class RestoredBackup {
  final Uint8List data;
  final Map<String, String> blobs;
  final Future<Uint8List> Function(String id) blob;
  RestoredBackup(this.data, this.blobs, this.blob);
}

class BackupInfo {
  final String user;
  final String file;
  final DateTime at;
  final String device;
  final int size;
  BackupInfo(this.user, this.file, this.at, this.device, this.size);

  static final _re = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})?_([\w-]+)\.ksy$');

  static BackupInfo? parse(String user, DavEntry e) {
    final m = _re.firstMatch(e.name);
    if (m == null || e.isDir) return null;
    int g(int i) => int.parse(m.group(i)!);
    final sec = m.group(6) == null ? 0 : g(6);
    return BackupInfo(user, e.name, DateTime(g(1), g(2), g(3), g(4), g(5), sec), m.group(7)!, e.size);
  }

  static String nameFor(DateTime t, String device) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}_$device.ksy';
  }
}

/// Podgląd między dwiema osobami: [owner] udostępnia swoje dane, [viewer] je ogląda.
/// Działa tylko, gdy obie strony wyraziły zgodę (każda zapisuje własny plik zgody).
class ShareLink {
  final String owner;
  final String viewer;
  final bool ownerAgreed;
  final bool viewerAgreed;

  /// Zakres ustalony przez właściciela (np. {"stages": true, "events": false}).
  final Map<String, Object?> scope;
  final DateTime? since;

  ShareLink(this.owner, this.viewer, this.ownerAgreed, this.viewerAgreed, this.scope, this.since);

  bool get active => ownerAgreed && viewerAgreed;
  String get key => '${owner}__$viewer';
}

/// Wspólna kopia zapasowa i podgląd za zgodą na rodzinnym koncie Koofr.
///
/// Układ na Koofr (wszystkie pliki z danymi są zaszyfrowane na telefonie):
/// ```
/// <root>/_czlonkowie/<osoba>.json                    katalog członków i ich klucze publiczne
/// <root>/<aplikacja>/kopie/<osoba>/<data>_<tel>.ksy  kopie zapasowe
/// <root>/<aplikacja>/zgody/<właściciel>__<oglądający>/{wlasciciel,ogladajacy}.json
/// <root>/<aplikacja>/dane/<właściciel>__<oglądający>.ksy   dane do podglądu
/// ```
class KoofrSync {
  /// Krótki identyfikator aplikacji, np. „rytm-snu”, „doba”.
  final String appId;
  final KsStore store;

  /// [davBase] — inny serwer WebDAV (testy); domyślnie Koofr.
  KoofrSync({required this.appId, required this.store, this.davBase});

  final Uri? davBase;

  KoofrConfig? config;
  String? userId;
  String? deviceId;
  String? recoveryCode;
  KsCrypto? crypto;
  WebDav? _dav;

  final _changes = StreamController<void>.broadcast();

  /// Sygnał zmiany stanu (połączenie, kopie, zgody) — do odświeżania interfejsu.
  Stream<void> get changes => _changes.stream;
  void _changed() => _changes.add(null);

  bool get connected => config != null;
  bool get ready => config != null && userId != null && crypto != null;

  WebDav get dav {
    final c = config;
    if (c == null) throw KoofrException('Najpierw połącz z kontem Koofr.');
    return _dav ??= WebDav(user: c.email, password: c.appPassword, base: davBase);
  }

  String get _root => config!.root;
  String get _app => '$_root/$appId';
  String _memberPath(String id) => '$_root/_czlonkowie/$id.json';

  static const _k = 'ks.';

  Future<void> load() async {
    final c = await store.read('${_k}config');
    config = c == null ? null : KoofrConfig.fromJson((jsonDecode(c) as Map).cast<String, Object?>());
    userId = await store.read('${_k}user');
    deviceId = await store.read('${_k}device');
    if (deviceId == null) {
      final r = Random.secure();
      deviceId = List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join();
      await store.write('${_k}device', deviceId!);
    }
    recoveryCode = await store.read('${_k}code');
    crypto = null;
    if (recoveryCode != null) {
      final code = await RecoveryCode.parse(recoveryCode!);
      if (code != null) crypto = await KsCrypto.fromCode(code, appId);
    }
    _changed();
  }

  // ---------------------------------------------------------------- połączenie

  /// Sprawdza logowanie i zapisuje konfigurację.
  Future<void> connect(KoofrConfig c) async {
    final test = WebDav(user: c.email.trim(), password: c.appPassword.trim(), base: davBase);
    try {
      await test.check();
      await test.ensureDir('${c.root}/_czlonkowie');
    } finally {
      test.close();
    }
    _dav?.close();
    _dav = null;
    config = KoofrConfig(email: c.email.trim(), appPassword: c.appPassword.trim(), root: c.root);
    await store.write('${_k}config', jsonEncode(config!.toJson()));
    _changed();
  }

  /// Odłącza ten telefon (dane na Koofr zostają). Zgody udzielone z tego telefonu są cofane.
  Future<void> disconnect() async {
    if (ready) {
      try {
        for (final v in (await myConsents()).keys.toList()) {
          await revokeAsOwner(v);
        }
      } catch (_) {}
    }
    for (final k in ['config', 'user', 'code', 'consents', 'backup.enabled', 'backup.last', 'share.last']) {
      await store.delete('$_k$k');
    }
    _dav?.close();
    _dav = null;
    config = null;
    userId = null;
    recoveryCode = null;
    crypto = null;
    _changed();
  }

  // ---------------------------------------------------------------- członkowie

  Future<List<Member>> members() async {
    final entries = await dav.list('$_root/_czlonkowie');
    final out = <Member>[];
    for (final e in entries.where((e) => !e.isDir && e.name.endsWith('.json'))) {
      final m = await _member(e.name.substring(0, e.name.length - 5));
      if (m != null) out.add(m);
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<Member?> _member(String id) async {
    final b = await dav.get(_memberPath(id));
    if (b == null) return null;
    try {
      return Member.fromJson((jsonDecode(utf8.decode(b)) as Map).cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  Member? _meCache;

  Future<Member?> me() async => userId == null ? null : (_meCache ??= await _member(userId!));

  /// Dołączenie tego telefonu jako [existingId] (osoba już jest w rodzinie) albo nowa osoba [newName].
  /// Kod musi zgadzać się z kodem tej osoby z innych aplikacji/telefonów.
  Future<void> join({String? existingId, String? newName, required RecoveryCode code}) async {
    assert(existingId != null || newName != null);
    final check = await KsCrypto.checkOf(code);
    final keys = await KsCrypto.fromCode(code, appId);
    Member? m;
    String id;
    if (existingId != null) {
      id = existingId;
      m = await _member(id);
      if (m?.codeCheck != null && m!.codeCheck != check) {
        throw KsCryptoException('Ten kod odzyskiwania nie pasuje do osoby „${m.name}”. '
            'Wpisz kod zapisany przy pierwszym podłączeniu tej osoby.');
      }
    } else {
      final base = slugify(newName!);
      final taken = (await members()).map((m) => m.id).toSet();
      id = base;
      for (var i = 2; taken.contains(id); i++) {
        id = '$base-$i';
      }
    }
    final updated = Member(
      id: id,
      name: (m?.name ?? newName ?? id).trim(),
      codeCheck: check,
      keys: {...?m?.keys, appId: keys.publicKeyB64},
      updatedAt: DateTime.now(),
    );
    await dav.put(_memberPath(id), utf8.encode(jsonEncode(updated.toJson())));
    final text = await code.format();
    await store.write('${_k}user', id);
    await store.write('${_k}code', text);
    userId = id;
    recoveryCode = text;
    crypto = keys;
    _meCache = updated;
    _changed();
  }

  // ---------------------------------------------------------------- kopie zapasowe

  Future<bool> backupEnabled() async => (await store.read('${_k}backup.enabled')) == '1';

  Future<void> setBackupEnabled(bool v) async {
    await store.write('${_k}backup.enabled', v ? '1' : '0');
    _changed();
  }

  Future<DateTime?> lastBackup() async {
    final s = await store.read('${_k}backup.last');
    return s == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(s));
  }

  /// Czy pora na automatyczną kopię (włączona i od ostatniej minęło [every]).
  Future<bool> backupDue({Duration every = const Duration(hours: 20)}) async {
    if (!ready || !await backupEnabled()) return false;
    final last = await lastBackup();
    return last == null || DateTime.now().difference(last) >= every;
  }

  String get _myBackups => '$_app/kopie/$userId';
  String get _myBlobs => '$_app/pliki/$userId';

  static const _payloadMagic = [0x4B, 0x53, 0x42, 0x31]; // KSB1

  /// Zapisuje kopię: [data] (np. baza i ustawienia) oraz załączniki [blobs] (zdjęcia, PDF-y).
  /// Każdy załącznik trafia na Koofr tylko raz — kolejne kopie odwołują się do już wysłanych,
  /// więc codzienna kopia nie mnoży gigabajtów. [onProgress] dostaje (wysłane, wszystkie) załączniki.
  Future<BackupInfo> backupNow(List<int> data,
      {List<BackupBlob> blobs = const [], void Function(int done, int total)? onProgress}) async {
    _requireReady();
    final now = DateTime.now();
    final refs = <String, String>{};
    if (blobs.isNotEmpty) {
      final existing = {for (final e in await dav.list(_myBlobs)) e.name};
      var i = 0;
      for (final b in blobs) {
        final bytes = await b.read();
        final id = await crypto!.blobId(bytes);
        if (!existing.contains('$id.ksy')) {
          await dav.putAtomic('$_myBlobs/$id.ksy', await crypto!.sealBackup(bytes));
          existing.add('$id.ksy');
        }
        refs[b.path] = id;
        onProgress?.call(++i, blobs.length);
      }
    }
    final header = utf8.encode(jsonEncode({'v': 2, 'blobs': refs}));
    final payload = BytesBuilder(copy: false)
      ..add(_payloadMagic)
      ..add((ByteData(4)..setUint32(0, header.length)).buffer.asUint8List())
      ..add(header)
      ..add(data);
    final name = BackupInfo.nameFor(now, deviceId!);
    if (refs.isNotEmpty) {
      // Lista załączników obok kopii — sprzątanie nie musi pobierać całych kopii.
      await dav.putAtomic(
          '$_myBackups/${_refsName(name)}', await crypto!.sealBackup(utf8.encode(jsonEncode(refs.values.toSet().toList()))));
    }
    final sealed = await crypto!.sealBackup(payload.takeBytes());
    await dav.putAtomic('$_myBackups/$name', sealed);
    await store.write('${_k}backup.last', now.millisecondsSinceEpoch.toString());
    try {
      await prune();
    } catch (_) {}
    _changed();
    return BackupInfo(
        userId!, name, DateTime(now.year, now.month, now.day, now.hour, now.minute, now.second), deviceId!, sealed.length);
  }

  /// Moje kopie (ze wszystkich telefonów), od najnowszej.
  Future<List<BackupInfo>> backups() async {
    _requireReady();
    final list = (await dav.list(_myBackups)).map((e) => BackupInfo.parse(userId!, e)).whereType<BackupInfo>().toList()
      ..sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  /// Dane kopii (bez załączników).
  Future<Uint8List> restore(BackupInfo b) async => (await restoreFull(b)).data;

  /// Kopia wraz z listą załączników do pobrania przez [RestoredBackup.blob].
  Future<RestoredBackup> restoreFull(BackupInfo b) async {
    _requireReady();
    final file = await dav.get('$_app/kopie/${b.user}/${b.file}');
    if (file == null) throw KoofrException('Kopia zniknęła z Koofr.');
    return _parsePayload(await crypto!.openBackup(file), b.user);
  }

  RestoredBackup _parsePayload(Uint8List p, String user) {
    final hasHeader = p.length >= 8 && List.generate(4, (i) => p[i]).join(',') == _payloadMagic.join(',');
    if (!hasHeader) return RestoredBackup(p, const {}, (_) async => throw KoofrException('Brak załącznika.'));
    final len = ByteData.sublistView(p, 4, 8).getUint32(0);
    final h = (jsonDecode(utf8.decode(p.sublist(8, 8 + len))) as Map).cast<String, Object?>();
    final refs = ((h['blobs'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v as String));
    return RestoredBackup(Uint8List.sublistView(p, 8 + len), refs, (id) async {
      final f = await dav.get('$_app/pliki/$user/$id.ksy');
      if (f == null) throw KoofrException('Na Koofr brakuje załącznika kopii.');
      return crypto!.openBackup(f);
    });
  }

  static String _refsName(String backupFile) => backupFile.replaceAll(RegExp(r'\.ksy$'), '.refs');

  Future<void> deleteBackup(BackupInfo b) async {
    await dav.delete('$_app/kopie/${b.user}/${_refsName(b.file)}');
    await dav.delete('$_app/kopie/${b.user}/${b.file}');
    _changed();
  }

  /// Usuwa stare kopie: zostaje najnowsza z każdego z [daily] ostatnich dni
  /// i najnowsza z każdego z [weekly] wcześniejszych tygodni. Potem kasuje załączniki,
  /// do których nie odwołuje się już żadna kopia.
  Future<int> prune({int daily = 7, int weekly = 4}) async {
    final all = await backups();
    final del = selectForPrune(all, daily: daily, weekly: weekly);
    for (final b in del) {
      await dav.delete('$_app/kopie/${b.user}/${_refsName(b.file)}');
      await dav.delete('$_app/kopie/${b.user}/${b.file}');
    }
    final blobFiles = await dav.list(_myBlobs);
    if (blobFiles.isNotEmpty) {
      final used = <String>{};
      for (final b in all.where((b) => !del.contains(b))) {
        try {
          final r = await dav.get('$_app/kopie/${b.user}/${_refsName(b.file)}');
          if (r != null) {
            used.addAll((jsonDecode(utf8.decode(await crypto!.openBackup(r))) as List).cast<String>());
          }
        } catch (_) {
          return del.length; // nie wiemy na pewno, co jest używane — nic nie kasujemy
        }
      }
      for (final f in blobFiles) {
        final id = f.name.replaceAll('.ksy', '');
        if (f.name.endsWith('.ksy') && !used.contains(id)) await dav.delete('$_myBlobs/${f.name}');
      }
    }
    return del.length;
  }

  static List<BackupInfo> selectForPrune(List<BackupInfo> all, {int daily = 7, int weekly = 4}) {
    final sorted = [...all]..sort((a, b) => b.at.compareTo(a.at));
    final days = <String>{}, weeks = <String>{};
    final keep = <BackupInfo>{};
    String day(DateTime t) => '${t.year}-${t.month}-${t.day}';
    String week(DateTime t) {
      // tydzień liczony od poniedziałku
      final monday = DateTime(t.year, t.month, t.day).subtract(Duration(days: t.weekday - 1));
      return day(monday);
    }

    for (final b in sorted) {
      if (days.length < daily && !days.contains(day(b.at))) {
        days.add(day(b.at));
        weeks.add(week(b.at));
        keep.add(b);
      }
    }
    final weeklyKept = <String>{};
    for (final b in sorted) {
      if (keep.contains(b)) continue;
      final w = week(b.at);
      if (weeks.contains(w) || weeklyKept.length >= weekly) continue;
      weeks.add(w);
      weeklyKept.add(w);
      keep.add(b);
    }
    return sorted.where((b) => !keep.contains(b)).toList();
  }

  // ---------------------------------------------------------------- wymiana między aplikacjami

  /// Folder wymiany danej osoby: `<root>/_wymiana/<osoba>/<nazwa>.ksy`. Pliki odczyta każda
  /// aplikacja tej osoby (ten sam kod odzyskiwania), nikt inny.
  String get _myExchange => '$_root/_wymiana/$userId';

  /// Publikuje plik wymiany (np. „rytm-snu”), o ile treść zmieniła się od ostatniej publikacji
  /// z tego telefonu. Zwraca true, gdy wysłano.
  Future<bool> publishExchange(String name, List<int> data, {bool force = false}) async {
    _requireReady();
    final digest = KsCrypto.hex((await Sha256().hash(data)).bytes.sublist(0, 16));
    final key = '${_k}ex.pub.$userId.$name';
    if (!force && await store.read(key) == digest) return false;
    await dav.putAtomic('$_myExchange/$name.ksy', await crypto!.sealExchange(data));
    await store.write(key, digest);
    return true;
  }

  /// Usuwa mój plik wymiany (wyłączenie publikowania).
  Future<void> removeExchange(String name) async {
    _requireReady();
    await dav.delete('$_myExchange/$name.ksy');
    await store.delete('${_k}ex.pub.$userId.$name');
  }

  /// Dostępne pliki wymiany tej osoby: nazwa → (czas zmiany, rozmiar).
  Future<Map<String, (DateTime?, int)>> exchangeFiles() async {
    _requireReady();
    return {
      for (final e in await dav.list(_myExchange))
        if (!e.isDir && e.name.endsWith('.ksy')) e.name.substring(0, e.name.length - 4): (e.modified, e.size),
    };
  }

  /// Pobiera pliki wymiany, które [want] akceptuje i które zmieniły się od ostatniego pobrania
  /// na tym telefonie, i przekazuje je do [handle]. Zwraca nazwy przetworzonych plików.
  Future<List<String>> pullExchange(bool Function(String name) want,
      Future<void> Function(String name, Uint8List data) handle, {bool force = false}) async {
    _requireReady();
    final done = <String>[];
    for (final e in (await exchangeFiles()).entries) {
      if (!want(e.key)) continue;
      final stamp = '${e.value.$1?.millisecondsSinceEpoch ?? 0}/${e.value.$2}';
      final key = '${_k}ex.seen.$userId.${e.key}';
      if (!force && await store.read(key) == stamp) continue;
      final file = await dav.get('$_myExchange/${e.key}.ksy');
      if (file == null) continue;
      await handle(e.key, await crypto!.openExchange(file));
      await store.write(key, stamp);
      done.add(e.key);
    }
    return done;
  }

  // ---------------------------------------------------------------- podgląd za zgodą

  static const _ownerFile = 'wlasciciel.json';
  static const _viewerFile = 'ogladajacy.json';

  String _linkDir(String owner, String viewer) => '$_app/zgody/${owner}__$viewer';
  String _dataPath(String owner, String viewer) => '$_app/dane/${owner}__$viewer.ksy';

  /// Zgody udzielone przeze mnie z TEGO telefonu: oglądający → {scope, at, seen}.
  /// To one decydują o wysyłaniu danych — sam plik na Koofr nie wystarczy.
  Future<Map<String, Map<String, Object?>>> myConsents() async {
    final s = await store.read('${_k}consents');
    if (s == null) return {};
    return (jsonDecode(s) as Map).map((k, v) => MapEntry(k as String, (v as Map).cast<String, Object?>()));
  }

  Future<void> _saveConsents(Map<String, Map<String, Object?>> c) =>
      store.write('${_k}consents', jsonEncode(c));

  /// Wszystkie powiązania, w których biorę udział (jako właściciel lub oglądający).
  Future<List<ShareLink>> links() async {
    _requireReady();
    final me = userId!;
    final out = <ShareLink>[];
    for (final d in (await dav.list('$_app/zgody')).where((e) => e.isDir)) {
      final parts = d.name.split('__');
      if (parts.length != 2 || (parts[0] != me && parts[1] != me)) continue;
      final files = {for (final f in await dav.list('$_app/zgody/${d.name}')) f.name};
      Map<String, Object?> scope = {};
      DateTime? since;
      if (files.contains(_ownerFile)) {
        final b = await dav.get('$_app/zgody/${d.name}/$_ownerFile');
        if (b != null) {
          try {
            final j = (jsonDecode(utf8.decode(b)) as Map).cast<String, Object?>();
            scope = ((j['scope'] as Map?) ?? {}).cast<String, Object?>();
            if (j['at'] is int) since = DateTime.fromMillisecondsSinceEpoch(j['at'] as int);
          } catch (_) {}
        }
      }
      out.add(ShareLink(parts[0], parts[1], files.contains(_ownerFile), files.contains(_viewerFile), scope, since));
    }
    return out;
  }

  /// Jako oglądający: proszę o podgląd danych [ownerId] albo przyjmuję jego propozycję.
  Future<void> requestView(String ownerId) async {
    _requireReady();
    final owner = await _member(ownerId);
    await dav.put('${_linkDir(ownerId, userId!)}/$_viewerFile',
        utf8.encode(jsonEncode({'v': 1, 'owner': ownerId, 'viewer': userId, 'at': _now(), 'ownerKey': owner?.keys[appId]})));
    _changed();
  }

  /// Jako właściciel: zgadzam się pokazywać swoje dane osobie [viewerId] w zakresie [scope]
  /// (propozycja albo przyjęcie prośby). Dane popłyną dopiero, gdy obie strony się zgodzą.
  Future<void> allowView(String viewerId, Map<String, Object?> scope) async {
    _requireReady();
    await dav.put('${_linkDir(userId!, viewerId)}/$_ownerFile',
        utf8.encode(jsonEncode({'v': 1, 'owner': userId, 'viewer': viewerId, 'at': _now(), 'scope': scope})));
    final c = await myConsents();
    c[viewerId] = {'scope': scope, 'at': _now(), 'seen': c[viewerId]?['seen'] ?? false};
    await _saveConsents(c);
    _changed();
  }

  /// Właściciel cofa zgodę: znikają plik zgody i dane do podglądu.
  Future<void> revokeAsOwner(String viewerId) async {
    _requireReady();
    final c = await myConsents();
    c.remove(viewerId);
    await _saveConsents(c);
    await dav.delete(_dataPath(userId!, viewerId));
    await dav.delete('${_linkDir(userId!, viewerId)}/$_ownerFile');
    await _cleanupLinkDir(userId!, viewerId);
    _changed();
  }

  /// Oglądający rezygnuje (lub odrzuca propozycję): kasuje swoją zgodę i pobrane dane.
  Future<void> revokeAsViewer(String ownerId) async {
    _requireReady();
    await dav.delete(_dataPath(ownerId, userId!));
    await dav.delete('${_linkDir(ownerId, userId!)}/$_viewerFile');
    await _cleanupLinkDir(ownerId, userId!);
    _changed();
  }

  /// Odrzucenie prośby lub propozycji drugiej osoby: znika całe powiązanie (pliki obu stron i dane).
  Future<void> dismissLink(String owner, String viewer) async {
    _requireReady();
    if (owner != userId && viewer != userId) throw KoofrException('To powiązanie nie dotyczy Ciebie.');
    if (owner == userId) {
      final c = await myConsents();
      if (c.remove(viewer) != null) await _saveConsents(c);
    }
    await dav.delete(_dataPath(owner, viewer));
    await dav.delete(_linkDir(owner, viewer));
    _changed();
  }

  Future<void> _cleanupLinkDir(String owner, String viewer) async {
    if ((await dav.list(_linkDir(owner, viewer))).isEmpty) await dav.delete(_linkDir(owner, viewer));
  }

  Future<void>? _publishing;

  /// Wysyła moje dane wszystkim, którzy mają aktywny podgląd, i sprząta po cofniętych zgodach.
  /// [build] dostaje zakres ustalony dla danej osoby i zwraca bajty do zaszyfrowania.
  /// Zwraca liczbę osób, którym wysłano dane.
  Future<int> publishShares(Future<List<int>> Function(String viewerId, Map<String, Object?> scope) build) async {
    if (!ready) return 0;
    while (_publishing != null) {
      await _publishing;
    }
    final done = Completer<void>();
    _publishing = done.future;
    try {
      return await _publish(build);
    } finally {
      _publishing = null;
      done.complete();
    }
  }

  Future<int> _publish(Future<List<int>> Function(String, Map<String, Object?>) build) async {
    final me = userId!;
    final consents = await myConsents();
    final byKey = {for (final l in await links()) l.key: l};
    var sent = 0;
    var changed = false;
    for (final viewer in consents.keys.toList()) {
      final l = byKey['${me}__$viewer'];
      final c = consents[viewer]!;
      if (l == null || !l.ownerAgreed) {
        // Zgodę cofnięto z innego mojego telefonu.
        consents.remove(viewer);
        changed = true;
        await dav.delete(_dataPath(me, viewer));
        continue;
      }
      if (!l.viewerAgreed) {
        if (c['seen'] == true) {
          // Oglądający zrezygnował — sprzątamy po obu stronach.
          consents.remove(viewer);
          changed = true;
          await dav.delete(_dataPath(me, viewer));
          await dav.delete('${_linkDir(me, viewer)}/$_ownerFile');
          await _cleanupLinkDir(me, viewer);
        }
        continue;
      }
      final m = await _member(viewer);
      final key = m?.keys[appId];
      if (key == null) continue; // ta osoba nie podłączyła jeszcze tej aplikacji
      if (c['seen'] != true) {
        c['seen'] = true;
        changed = true;
      }
      final data = await build(viewer, l.scope);
      await dav.putAtomic(_dataPath(me, viewer), await crypto!.sealFor(KsCrypto.parsePublicKey(key), data));
      sent++;
    }
    // Dane bez aktywnej zgody (np. po awarii w trakcie cofania) nie mogą zostać na Koofr.
    for (final f in await dav.list('$_app/dane')) {
      final parts = f.name.replaceAll('.ksy', '').replaceAll('.tmp', '').split('__');
      if (parts.length == 2 && parts[0] == me && !consents.containsKey(parts[1])) {
        await dav.delete('$_app/dane/${f.name}');
      }
    }
    if (changed) await _saveConsents(consents);
    await store.write('${_k}share.last', _now().toString());
    _changed();
    return sent;
  }

  /// Dane udostępnione mi przez [ownerId] (null, gdy jeszcze nic nie wysłał).
  Future<(Uint8List, DateTime?)?> fetchShared(String ownerId) async {
    _requireReady();
    final file = await dav.get(_dataPath(ownerId, userId!));
    if (file == null) return null;
    final m = await _member(ownerId);
    final key = m?.keys[appId];
    if (key == null) throw KoofrException('Ta osoba nie ma klucza w tej aplikacji.');
    final entry = (await dav.list('$_app/dane')).where((e) => e.name == '${ownerId}__$userId.ksy').firstOrNull;
    return (await crypto!.openFrom(KsCrypto.parsePublicKey(key), file), entry?.modified);
  }

  /// Kod bezpieczeństwa do porównania z drugą osobą (taki sam na obu telefonach).
  Future<String?> safetyNumberWith(String otherId) async {
    if (!ready) return null;
    final m = await _member(otherId);
    final key = m?.keys[appId];
    if (key == null) return null;
    return KsCrypto.safetyNumber(appId, crypto!.publicKey, KsCrypto.parsePublicKey(key));
  }

  void _requireReady() {
    if (!ready) throw KoofrException('Najpierw połącz z Koofr i wybierz osobę.');
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;
}

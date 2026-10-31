import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'night_log.dart';

class Db {
  Db._();
  static final Db instance = Db._();

  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  static Future<String> get path async => p.join(await getDatabasesPath(), 'bakometr.db');

  /// Zamknięcie bazy (przed podmianą pliku przy przywracaniu kopii). Następne użycie otworzy ją od nowa.
  Future<void> close() async {
    final d = _db;
    _db = null;
    await d?.close();
  }

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'bakometr.db'),
      version: 9,
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('ALTER TABLE nights ADD COLUMN apnea_count INTEGER');
          await db.execute('ALTER TABLE nights ADD COLUMN apnea_index REAL');
          await db.execute('ALTER TABLE nights ADD COLUMN mic_blocked_min INTEGER');
          await db.execute('ALTER TABLE minutes ADD COLUMN apneas INTEGER');
          await db.execute('ALTER TABLE minutes ADD COLUMN sounds INTEGER');
        }
        if (from < 3) {
          await db.execute('ALTER TABLE nights ADD COLUMN avg_noise REAL');
          await db.execute('ALTER TABLE nights ADD COLUMN max_noise REAL');
          await db.execute('ALTER TABLE minutes ADD COLUMN noise_max REAL');
          // Uzupełnienie starszych nocy z zapisanych minut
          await db.execute('''UPDATE nights SET
              avg_noise = (SELECT AVG(noise_db) FROM minutes WHERE minutes.night_id = nights.id AND noise_db > -120),
              max_noise = (SELECT MAX(noise_db) FROM minutes WHERE minutes.night_id = nights.id)''');
        }
        if (from < 4) {
          for (final c in [
            'hypopnea_count INTEGER',
            'cpap INTEGER',
            'sonar INTEGER',
            'breath_rate REAL',
            'cpap_ahi REAL',
            'cpap_leak REAL',
            'cpap_usage_min INTEGER',
          ]) {
            await db.execute('ALTER TABLE nights ADD COLUMN $c');
          }
          for (final c in ['breath_rate REAL', 'breath_var REAL', 'sonar_motion REAL']) {
            await db.execute('ALTER TABLE minutes ADD COLUMN $c');
          }
        }
        if (from < 5) {
          for (final c in ['w_temp', 'w_hum', 'w_press', 'w_press_trend', 'w_wind', 'w_rain', 'w_cloud', 'moon_phase']) {
            await db.execute('ALTER TABLE nights ADD COLUMN $c REAL');
          }
        }
        if (from < 6) {
          await db.execute('ALTER TABLE nights ADD COLUMN interrupt_reason TEXT');
        }
        if (from < 8) {
          for (final c in ['cpap_oai', 'cpap_cai', 'cpap_hi', 'cpap_leak95', 'cpap_press50', 'cpap_press95', 'cpap_rr', 'hr_avg', 'hr_min', 'spo2_min', 'spo2_avg', 'odi']) {
            await db.execute('ALTER TABLE nights ADD COLUMN $c REAL');
          }
          await db.execute('ALTER TABLE minutes ADD COLUMN hr REAL');
          await _createExt(db);
        }
        if (from < 9) {
          // telefon: sekundy z ruchem (aktygrafia), ekran/odblokowanie, szelesty
          await db.execute('ALTER TABLE minutes ADD COLUMN active_sec INTEGER');
          await db.execute('ALTER TABLE minutes ADD COLUMN screen INTEGER');
          await db.execute('ALTER TABLE minutes ADD COLUMN rustle INTEGER');
        }
        if (from < 7) {
          await db.execute('ALTER TABLE nights ADD COLUMN stage_source TEXT');
        }
      },
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE nights(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start INTEGER NOT NULL,
            end_ts INTEGER,
            alarm_at INTEGER,
            smart_window INTEGER,
            tags TEXT,
            note TEXT,
            rating INTEGER,
            light_manual TEXT,
            duration_min INTEGER,
            in_bed_min INTEGER,
            deep_min INTEGER,
            light_min INTEGER,
            rem_min INTEGER,
            awake_min INTEGER,
            latency_min INTEGER,
            awakenings INTEGER,
            score INTEGER,
            fart_count INTEGER,
            snore_min INTEGER,
            talk_count INTEGER,
            cough_count INTEGER,
            apnea_count INTEGER,
            apnea_index REAL,
            mic_blocked_min INTEGER,
            avg_noise REAL,
            max_noise REAL,
            hypopnea_count INTEGER,
            cpap INTEGER,
            sonar INTEGER,
            breath_rate REAL,
            cpap_ahi REAL,
            cpap_leak REAL,
            cpap_usage_min INTEGER,
            w_temp REAL,
            w_hum REAL,
            w_press REAL,
            w_press_trend REAL,
            w_wind REAL,
            w_rain REAL,
            w_cloud REAL,
            moon_phase REAL,
            interrupt_reason TEXT,
            stage_source TEXT,
            cpap_oai REAL,
            cpap_cai REAL,
            cpap_hi REAL,
            cpap_leak95 REAL,
            cpap_press50 REAL,
            cpap_press95 REAL,
            cpap_rr REAL,
            hr_avg REAL,
            hr_min REAL,
            spo2_min REAL,
            spo2_avg REAL,
            odi REAL,
            avg_lux REAL,
            max_lux REAL
          )''');
        await db.execute('''
          CREATE TABLE events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            night_id INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            type TEXT NOT NULL,
            confidence REAL,
            clip_path TEXT,
            duration_ms INTEGER,
            verified INTEGER
          )''');
        await db.execute('''
          CREATE TABLE minutes(
            night_id INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            ts INTEGER NOT NULL,
            motion REAL,
            noise_db REAL,
            noise_max REAL,
            breath_rate REAL,
            breath_var REAL,
            sonar_motion REAL,
            hr REAL,
            lux REAL,
            farts INTEGER,
            snore INTEGER,
            apneas INTEGER,
            sounds INTEGER,
            active_sec INTEGER,
            screen INTEGER,
            rustle INTEGER,
            stage INTEGER,
            PRIMARY KEY(night_id, idx)
          )''');
        await db.execute('CREATE INDEX ev_night ON events(night_id)');
        await _createExt(db);
      },
    );
  }

  /// Dane zewnętrzne nocy: przebiegi i zdarzenia z aparatu CPAP (kind: leak, press, rr, snore, flim,
  /// ev_oa, ev_ca, ev_h, ev_a, ev_arousal…).
  static Future<void> _createExt(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ext(
        night_id INTEGER NOT NULL,
        ts INTEGER NOT NULL,
        kind TEXT NOT NULL,
        value REAL,
        dur REAL
      )''');
    await db.execute('CREATE INDEX IF NOT EXISTS ext_night ON ext(night_id, kind)');
  }

  Future<void> replaceExt(int nightId, String kindPrefix, List<(DateTime, String, double?, double?)> rows) async {
    final d = await db;
    await d.transaction((tx) async {
      await tx.delete('ext', where: 'night_id = ? AND kind LIKE ?', whereArgs: [nightId, '$kindPrefix%']);
      final b = tx.batch();
      for (final (t, k, v, dur) in rows) {
        b.insert('ext', {'night_id': nightId, 'ts': t.millisecondsSinceEpoch, 'kind': k, 'value': v, 'dur': dur});
      }
      await b.commit(noResult: true);
    });
  }

  Future<List<(DateTime, String, double?, double?)>> ext(int nightId) async {
    final r = await (await db).query('ext', where: 'night_id = ?', whereArgs: [nightId], orderBy: 'ts ASC');
    return [
      for (final m in r)
        (
          DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
          m['kind'] as String,
          (m['value'] as num?)?.toDouble(),
          (m['dur'] as num?)?.toDouble()
        )
    ];
  }

  Future<void> setMinuteHr(int nightId, Map<int, double?> byIdx) async {
    final b = (await db).batch();
    for (final e in byIdx.entries) {
      b.update('minutes', {'hr': e.value}, where: 'night_id = ? AND idx = ?', whereArgs: [nightId, e.key]);
    }
    await b.commit(noResult: true);
  }

  // ---- noce ----
  Future<int> insertNight(Night n) async => (await db).insert('nights', n.toMap());

  Future<void> updateNight(Night n) async =>
      (await db).update('nights', n.toMap(), where: 'id = ?', whereArgs: [n.id]);

  Future<Night?> night(int id) async {
    final r = await (await db).query('nights', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Night.fromMap(r.first);
  }

  /// Zakończone noce, od najnowszej.
  Future<List<Night>> nights({int? limit}) async {
    final r = await (await db).query('nights',
        where: 'end_ts IS NOT NULL', orderBy: 'start DESC', limit: limit);
    return r.map(Night.fromMap).toList();
  }

  /// Noc przerwana (np. aplikacja ubita przez system) — do domknięcia przy starcie.
  Future<List<Night>> unfinishedNights() async {
    final r = await (await db).query('nights', where: 'end_ts IS NULL');
    return r.map(Night.fromMap).toList();
  }

  Future<void> deleteNight(int id) async {
    final d = await db;
    final evs = await events(id);
    for (final e in evs) {
      if (e.clipPath != null) {
        try {
          await File(e.clipPath!).delete();
        } catch (_) {}
      }
    }
    await d.delete('events', where: 'night_id = ?', whereArgs: [id]);
    await d.delete('minutes', where: 'night_id = ?', whereArgs: [id]);
    await d.delete('ext', where: 'night_id = ?', whereArgs: [id]);
    await d.delete('nights', where: 'id = ?', whereArgs: [id]);
    await NightLog.delete(id);
  }

  // ---- zdarzenia ----
  Future<int> insertEvent(SoundEvent e) async => (await db).insert('events', e.toMap());

  Future<void> updateEvent(SoundEvent e) async =>
      (await db).update('events', e.toMap(), where: 'id = ?', whereArgs: [e.id]);

  Future<List<SoundEvent>> events(int nightId) async {
    final r = await (await db)
        .query('events', where: 'night_id = ?', whereArgs: [nightId], orderBy: 'ts ASC');
    return r.map(SoundEvent.fromMap).toList();
  }

  /// Wszystkie wiatry (do rozkładu godzinowego w statystykach).
  Future<List<SoundEvent>> allEvents(SoundType type) async {
    final r = await (await db).query('events', where: 'type = ?', whereArgs: [type.name]);
    return r.map(SoundEvent.fromMap).toList();
  }

  Future<int> deleteAllClips() async {
    final d = await db;
    final r = await d.query('events', where: 'clip_path IS NOT NULL');
    var n = 0;
    for (final m in r) {
      try {
        await File(m['clip_path'] as String).delete();
        n++;
      } catch (_) {}
    }
    await d.update('events', {'clip_path': null});
    return n;
  }

  // ---- minuty ----
  Future<void> insertMinute(int nightId, MinuteSample m) async => (await db)
      .insert('minutes', m.toMap(nightId), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<MinuteSample>> minutes(int nightId) async {
    final r = await (await db)
        .query('minutes', where: 'night_id = ?', whereArgs: [nightId], orderBy: 'idx ASC');
    return r.map(MinuteSample.fromMap).toList();
  }

  Future<void> saveStages(int nightId, List<MinuteSample> ms) async {
    final b = (await db).batch();
    for (final m in ms) {
      b.update('minutes', {'stage': m.stage.index},
          where: 'night_id = ? AND idx = ?', whereArgs: [nightId, m.idx]);
    }
    await b.commit(noResult: true);
  }
}

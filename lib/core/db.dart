import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

class Db {
  Db._();
  static final Db instance = Db._();

  Database? _db;

  Future<Database> get db async => _db ??= await _open();

  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'bakometr.db'),
      version: 4,
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
            lux REAL,
            farts INTEGER,
            snore INTEGER,
            apneas INTEGER,
            sounds INTEGER,
            stage INTEGER,
            PRIMARY KEY(night_id, idx)
          )''');
        await db.execute('CREATE INDEX ev_night ON events(night_id)');
      },
    );
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
    await d.delete('nights', where: 'id = ?', whereArgs: [id]);
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

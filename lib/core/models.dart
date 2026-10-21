/// Typy wykrywanych zdarzeń dźwiękowych.
enum SoundType { fart, snore, talk, cough, apnea }

extension SoundTypeX on SoundType {
  String get label => switch (this) {
        SoundType.fart => 'Wiatr',
        SoundType.snore => 'Chrapanie',
        SoundType.talk => 'Mówienie',
        SoundType.cough => 'Kaszel',
        SoundType.apnea => 'Przerwa w oddechu',
      };
  String get emoji => switch (this) {
        SoundType.fart => '💨',
        SoundType.snore => '😴',
        SoundType.talk => '💬',
        SoundType.cough => '🤧',
        SoundType.apnea => '🫁',
      };
  static SoundType parse(String s) =>
      SoundType.values.firstWhere((e) => e.name == s, orElse: () => SoundType.fart);
}

/// Fazy snu w hipnogramie (kolejność = wysokość na wykresie od góry).
enum Stage { wake, rem, light, deep }

extension StageX on Stage {
  String get label => switch (this) {
        Stage.wake => 'Czuwanie',
        Stage.rem => 'REM',
        Stage.light => 'Płytki',
        Stage.deep => 'Głęboki',
      };
}

class Night {
  int? id;
  DateTime start;
  DateTime? end;
  DateTime? alarmAt;
  int smartWindowMin;
  List<String> tags;
  String note;
  int rating; // 0 = brak, 1..5
  String lightManual; // '', 'dark', 'dim', 'bright'

  // Podsumowanie wyliczane po zakończeniu nocy
  int durationMin; // sen (bez czuwania)
  int inBedMin;
  int deepMin;
  int lightMin;
  int remMin;
  int awakeMin;
  int latencyMin;
  int awakenings;
  int score;
  int fartCount;
  int snoreMin;
  int talkCount;
  int coughCount;
  int apneaCount;
  double apneaIndex; // przerwy w oddechu na godzinę snu
  int micBlockedMin; // minuty, gdy mikrofon dawał cyfrową ciszę (zajęty)
  double? avgLux;
  double? maxLux;

  Night({
    this.id,
    required this.start,
    this.end,
    this.alarmAt,
    this.smartWindowMin = 30,
    List<String>? tags,
    this.note = '',
    this.rating = 0,
    this.lightManual = '',
    this.durationMin = 0,
    this.inBedMin = 0,
    this.deepMin = 0,
    this.lightMin = 0,
    this.remMin = 0,
    this.awakeMin = 0,
    this.latencyMin = 0,
    this.awakenings = 0,
    this.score = 0,
    this.fartCount = 0,
    this.snoreMin = 0,
    this.talkCount = 0,
    this.coughCount = 0,
    this.apneaCount = 0,
    this.apneaIndex = 0,
    this.micBlockedMin = 0,
    this.avgLux,
    this.maxLux,
  }) : tags = tags ?? [];

  bool get finished => end != null;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'start': start.millisecondsSinceEpoch,
        'end_ts': end?.millisecondsSinceEpoch,
        'alarm_at': alarmAt?.millisecondsSinceEpoch,
        'smart_window': smartWindowMin,
        'tags': tags.join('|'),
        'note': note,
        'rating': rating,
        'light_manual': lightManual,
        'duration_min': durationMin,
        'in_bed_min': inBedMin,
        'deep_min': deepMin,
        'light_min': lightMin,
        'rem_min': remMin,
        'awake_min': awakeMin,
        'latency_min': latencyMin,
        'awakenings': awakenings,
        'score': score,
        'fart_count': fartCount,
        'snore_min': snoreMin,
        'talk_count': talkCount,
        'cough_count': coughCount,
        'apnea_count': apneaCount,
        'apnea_index': apneaIndex,
        'mic_blocked_min': micBlockedMin,
        'avg_lux': avgLux,
        'max_lux': maxLux,
      };

  static DateTime? _dt(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);

  factory Night.fromMap(Map<String, Object?> m) => Night(
        id: m['id'] as int?,
        start: _dt(m['start'])!,
        end: _dt(m['end_ts']),
        alarmAt: _dt(m['alarm_at']),
        smartWindowMin: (m['smart_window'] as int?) ?? 30,
        tags: ((m['tags'] as String?) ?? '').split('|').where((s) => s.isNotEmpty).toList(),
        note: (m['note'] as String?) ?? '',
        rating: (m['rating'] as int?) ?? 0,
        lightManual: (m['light_manual'] as String?) ?? '',
        durationMin: (m['duration_min'] as int?) ?? 0,
        inBedMin: (m['in_bed_min'] as int?) ?? 0,
        deepMin: (m['deep_min'] as int?) ?? 0,
        lightMin: (m['light_min'] as int?) ?? 0,
        remMin: (m['rem_min'] as int?) ?? 0,
        awakeMin: (m['awake_min'] as int?) ?? 0,
        latencyMin: (m['latency_min'] as int?) ?? 0,
        awakenings: (m['awakenings'] as int?) ?? 0,
        score: (m['score'] as int?) ?? 0,
        fartCount: (m['fart_count'] as int?) ?? 0,
        snoreMin: (m['snore_min'] as int?) ?? 0,
        talkCount: (m['talk_count'] as int?) ?? 0,
        coughCount: (m['cough_count'] as int?) ?? 0,
        apneaCount: (m['apnea_count'] as int?) ?? 0,
        apneaIndex: (m['apnea_index'] as num?)?.toDouble() ?? 0,
        micBlockedMin: (m['mic_blocked_min'] as int?) ?? 0,
        avgLux: (m['avg_lux'] as num?)?.toDouble(),
        maxLux: (m['max_lux'] as num?)?.toDouble(),
      );
}

class SoundEvent {
  int? id;
  int nightId;
  DateTime ts;
  SoundType type;
  double confidence;
  String? clipPath;
  int durationMs;

  /// null = niezweryfikowane, true = potwierdzone, false = odrzucone (fałszywy alarm)
  bool? verified;

  SoundEvent({
    this.id,
    required this.nightId,
    required this.ts,
    required this.type,
    required this.confidence,
    this.clipPath,
    this.durationMs = 0,
    this.verified,
  });

  bool get counts => verified != false;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'night_id': nightId,
        'ts': ts.millisecondsSinceEpoch,
        'type': type.name,
        'confidence': confidence,
        'clip_path': clipPath,
        'duration_ms': durationMs,
        'verified': verified == null ? null : (verified! ? 1 : 0),
      };

  factory SoundEvent.fromMap(Map<String, Object?> m) => SoundEvent(
        id: m['id'] as int?,
        nightId: m['night_id'] as int,
        ts: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
        type: SoundTypeX.parse(m['type'] as String),
        confidence: (m['confidence'] as num).toDouble(),
        clipPath: m['clip_path'] as String?,
        durationMs: (m['duration_ms'] as int?) ?? 0,
        verified: m['verified'] == null ? null : (m['verified'] as int) == 1,
      );
}

/// Zagregowana jedna minuta nocy.
class MinuteSample {
  final int idx;
  final DateTime ts;
  final double motion;
  final double noiseDb;
  final double? lux;
  final int farts;
  final bool snore;
  final int apneas;
  final int sounds; // inne zdarzenia dźwiękowe (mowa, kaszel) — oznaka płytkiego snu/czuwania
  Stage stage;

  MinuteSample({
    required this.idx,
    required this.ts,
    required this.motion,
    required this.noiseDb,
    this.lux,
    this.farts = 0,
    this.snore = false,
    this.apneas = 0,
    this.sounds = 0,
    this.stage = Stage.light,
  });

  Map<String, Object?> toMap(int nightId) => {
        'night_id': nightId,
        'idx': idx,
        'ts': ts.millisecondsSinceEpoch,
        'motion': motion,
        'noise_db': noiseDb,
        'lux': lux,
        'farts': farts,
        'snore': snore ? 1 : 0,
        'apneas': apneas,
        'sounds': sounds,
        'stage': stage.index,
      };

  factory MinuteSample.fromMap(Map<String, Object?> m) => MinuteSample(
        idx: m['idx'] as int,
        ts: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
        motion: (m['motion'] as num).toDouble(),
        noiseDb: (m['noise_db'] as num).toDouble(),
        lux: (m['lux'] as num?)?.toDouble(),
        farts: (m['farts'] as int?) ?? 0,
        snore: (m['snore'] as int?) == 1,
        apneas: (m['apneas'] as int?) ?? 0,
        sounds: (m['sounds'] as int?) ?? 0,
        stage: Stage.values[(m['stage'] as int?) ?? 2],
      );
}

/// Kategoria wskaźnika przerw w oddechu (progi jak dla AHI: 5 / 15 / 30 na godzinę).
String apneaCategory(double perHour) {
  if (perHour < 5) return 'w normie';
  if (perHour < 15) return 'łagodnie podwyższony';
  if (perHour < 30) return 'umiarkowanie podwyższony';
  return 'wysoki';
}

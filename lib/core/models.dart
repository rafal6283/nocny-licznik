/// Typy wykrywanych zdarzeń dźwiękowych.
enum SoundType { fart, snore, talk, cough, apnea, hypopnea }

extension SoundTypeX on SoundType {
  String get label => switch (this) {
        SoundType.fart => 'Wiatr',
        SoundType.snore => 'Chrapanie',
        SoundType.talk => 'Mówienie',
        SoundType.cough => 'Kaszel',
        SoundType.apnea => 'Przerwa w oddechu',
        SoundType.hypopnea => 'Spłycenie oddechu',
      };
  String get emoji => switch (this) {
        SoundType.fart => '💨',
        SoundType.snore => '😴',
        SoundType.talk => '💬',
        SoundType.cough => '🤧',
        SoundType.apnea => '🫁',
        SoundType.hypopnea => '〰️',
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
  int hypopneaCount; // spłycenia oddechu (tylko z sonaru)
  bool cpap; // noc z aparatem CPAP
  bool sonar; // noc z aktywnym sonarem
  double? breathRate; // średnia częstość oddechu (sonar), oddechy/min
  double? cpapAhi; // AHI odczytane z aparatu
  double? cpapLeak; // nieszczelność maski z aparatu, l/min
  int? cpapUsageMin; // czas użycia aparatu
  // Pogoda w nocy (Open-Meteo) i Księżyc
  double? wTemp; // °C, średnia
  double? wHum; // %, średnia
  double? wPress; // hPa, średnie ciśnienie
  double? wPressTrend; // hPa, zmiana ciśnienia w 24 h przed snem
  double? wWind; // km/h, maks.
  double? wRain; // mm, suma
  double? wCloud; // %, średnie zachmurzenie
  double? moonPhase; // 0 = nów, 0,5 = pełnia
  String? interruptReason; // gdy noc przerwał system/awaria — opis z Androida
  String? stageSource; // skąd fazy: ruch / sonar / dźwięk / szablon
  // Z karty SD aparatu ResMed (AirSense 10/11)
  double? cpapOai, cpapCai, cpapHi; // bezdechy obturacyjne / centralne / spłycenia na godzinę
  double? cpapLeak95; // l/min
  double? cpapPress50, cpapPress95; // cmH2O
  double? cpapRr; // oddechy/min (mediana)
  // Z zegarka (Health Connect)
  double? hrAvg, hrMin, spo2Min, spo2Avg;
  double? odi; // spadki saturacji ≥3% na godzinę
  double? avgNoise; // hałas otoczenia: Leq nocy w dBFS (dB SPL = + kalibracja)
  double? maxNoise; // najgłośniejsze 0,5 s nocy w dBFS
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
    this.avgNoise,
    this.maxNoise,
    this.hypopneaCount = 0,
    this.cpap = false,
    this.sonar = false,
    this.breathRate,
    this.cpapAhi,
    this.cpapLeak,
    this.cpapUsageMin,
    this.wTemp,
    this.wHum,
    this.wPress,
    this.wPressTrend,
    this.wWind,
    this.wRain,
    this.wCloud,
    this.moonPhase,
    this.interruptReason,
    this.stageSource,
    this.cpapOai,
    this.cpapCai,
    this.cpapHi,
    this.cpapLeak95,
    this.cpapPress50,
    this.cpapPress95,
    this.cpapRr,
    this.hrAvg,
    this.hrMin,
    this.spo2Min,
    this.spo2Avg,
    this.odi,
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
        'avg_noise': avgNoise,
        'hypopnea_count': hypopneaCount,
        'cpap': cpap ? 1 : 0,
        'sonar': sonar ? 1 : 0,
        'breath_rate': breathRate,
        'cpap_ahi': cpapAhi,
        'cpap_leak': cpapLeak,
        'cpap_usage_min': cpapUsageMin,
        'w_temp': wTemp,
        'w_hum': wHum,
        'w_press': wPress,
        'w_press_trend': wPressTrend,
        'w_wind': wWind,
        'w_rain': wRain,
        'w_cloud': wCloud,
        'moon_phase': moonPhase,
        'interrupt_reason': interruptReason,
        'stage_source': stageSource,
        'cpap_oai': cpapOai,
        'cpap_cai': cpapCai,
        'cpap_hi': cpapHi,
        'cpap_leak95': cpapLeak95,
        'cpap_press50': cpapPress50,
        'cpap_press95': cpapPress95,
        'cpap_rr': cpapRr,
        'hr_avg': hrAvg,
        'hr_min': hrMin,
        'spo2_min': spo2Min,
        'spo2_avg': spo2Avg,
        'odi': odi,
        'max_noise': maxNoise,
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
        avgNoise: (m['avg_noise'] as num?)?.toDouble(),
        hypopneaCount: (m['hypopnea_count'] as int?) ?? 0,
        cpap: (m['cpap'] as int?) == 1,
        sonar: (m['sonar'] as int?) == 1,
        breathRate: (m['breath_rate'] as num?)?.toDouble(),
        cpapAhi: (m['cpap_ahi'] as num?)?.toDouble(),
        cpapLeak: (m['cpap_leak'] as num?)?.toDouble(),
        cpapUsageMin: m['cpap_usage_min'] as int?,
        wTemp: (m['w_temp'] as num?)?.toDouble(),
        wHum: (m['w_hum'] as num?)?.toDouble(),
        wPress: (m['w_press'] as num?)?.toDouble(),
        wPressTrend: (m['w_press_trend'] as num?)?.toDouble(),
        wWind: (m['w_wind'] as num?)?.toDouble(),
        wRain: (m['w_rain'] as num?)?.toDouble(),
        wCloud: (m['w_cloud'] as num?)?.toDouble(),
        moonPhase: (m['moon_phase'] as num?)?.toDouble(),
        interruptReason: m['interrupt_reason'] as String?,
        stageSource: m['stage_source'] as String?,
        cpapOai: (m['cpap_oai'] as num?)?.toDouble(),
        cpapCai: (m['cpap_cai'] as num?)?.toDouble(),
        cpapHi: (m['cpap_hi'] as num?)?.toDouble(),
        cpapLeak95: (m['cpap_leak95'] as num?)?.toDouble(),
        cpapPress50: (m['cpap_press50'] as num?)?.toDouble(),
        cpapPress95: (m['cpap_press95'] as num?)?.toDouble(),
        cpapRr: (m['cpap_rr'] as num?)?.toDouble(),
        hrAvg: (m['hr_avg'] as num?)?.toDouble(),
        hrMin: (m['hr_min'] as num?)?.toDouble(),
        spo2Min: (m['spo2_min'] as num?)?.toDouble(),
        spo2Avg: (m['spo2_avg'] as num?)?.toDouble(),
        odi: (m['odi'] as num?)?.toDouble(),
        maxNoise: (m['max_noise'] as num?)?.toDouble(),
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
  final double noiseDb; // Leq minuty w dBFS
  final double? noiseMax; // najgłośniejsze 0,5 s minuty w dBFS
  final double? breathRate; // sonar: oddechy/min
  final double? breathVar; // sonar: zmienność odstępów między oddechami (CV)
  final double? sonarMotion; // sonar: ruch ciała (względny)
  final double? hr; // tętno z zegarka (średnia minuty)
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
    this.noiseMax,
    this.breathRate,
    this.breathVar,
    this.sonarMotion,
    this.hr,
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
        'noise_max': noiseMax,
        'breath_rate': breathRate,
        'breath_var': breathVar,
        'sonar_motion': sonarMotion,
        'hr': hr,
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
        noiseMax: (m['noise_max'] as num?)?.toDouble(),
        breathRate: (m['breath_rate'] as num?)?.toDouble(),
        breathVar: (m['breath_var'] as num?)?.toDouble(),
        sonarMotion: (m['sonar_motion'] as num?)?.toDouble(),
        hr: (m['hr'] as num?)?.toDouble(),
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

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const defaultTags = [
  'fasola',
  'kapusta',
  'cebula',
  'nabiał',
  'piwo',
  'alkohol',
  'kawa',
  'późna kolacja',
  'ostre jedzenie',
  'słodycze',
  'trening',
  'stres',
  'chory',
];

/// Ustawienia aplikacji (SharedPreferences) z powiadamianiem UI o zmianach.
class Settings extends ChangeNotifier {
  Settings._();
  static final Settings instance = Settings._();
  late SharedPreferences _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
  }

  int _i(String k, int d) => _p.getInt(k) ?? d;
  double _d(String k, double d) => _p.getDouble(k) ?? d;
  bool _b(String k, bool d) => _p.getBool(k) ?? d;
  String _s(String k, String d) => _p.getString(k) ?? d;

  Future<void> _set(String k, Object v) async {
    if (v is int) await _p.setInt(k, v);
    if (v is double) await _p.setDouble(k, v);
    if (v is bool) await _p.setBool(k, v);
    if (v is String) await _p.setString(k, v);
    if (v is List<String>) await _p.setStringList(k, v);
    notifyListeners();
  }

  // --- Budzik ---
  bool get alarmEnabled => _b('alarmEnabled', true);
  set alarmEnabled(bool v) => _set('alarmEnabled', v);
  int get alarmHour => _i('alarmHour', 7);
  set alarmHour(int v) => _set('alarmHour', v);
  int get alarmMinute => _i('alarmMinute', 0);
  set alarmMinute(int v) => _set('alarmMinute', v);
  int get smartWindowMin => _i('smartWindow', 30);
  set smartWindowMin(int v) => _set('smartWindow', v);
  int get snoozeMin => _i('snooze', 10);
  set snoozeMin(int v) => _set('snooze', v);
  int get rampSec => _i('rampSec', 60);
  set rampSec(int v) => _set('rampSec', v);
  bool get alarmVibrate => _b('alarmVibrate', true);
  set alarmVibrate(bool v) => _set('alarmVibrate', v);

  /// 'none' | 'math' | 'shake'
  String get captcha => _s('captcha', 'math');
  set captcha(String v) => _set('captcha', v);
  int get mathProblems => _i('mathProblems', 2);
  set mathProblems(int v) => _set('mathProblems', v);
  int get shakeCount => _i('shakeCount', 30);
  set shakeCount(int v) => _set('shakeCount', v);

  // --- Wykrywanie ---
  /// Czułość 0..1 (wyżej = czulej, więcej wykryć i fałszywych alarmów).
  double get fartSensitivity => _d('sensFart', 0.6);
  set fartSensitivity(double v) => _set('sensFart', v);
  double get snoreSensitivity => _d('sensSnore', 0.5);
  set snoreSensitivity(double v) => _set('sensSnore', v);
  /// Liczenie wiatrów — opcjonalne, domyślnie wyłączone.
  bool get detectFarts => _b('detectFarts', false);
  set detectFarts(bool v) => _set('detectFarts', v);

  /// Sonar (Android): niesłyszalny ton 19 kHz do pomiaru oddechu bez kontaktu.
  bool get sonarEnabled => _b('sonar', false);
  set sonarEnabled(bool v) => _set('sonar', v);
  /// Źródło mikrofonu dla sonaru: 'unprocessed' | 'voiceRecognition' | 'mic' | 'defaultSource'
  String get sonarSource => _s('sonarSource', 'unprocessed');
  set sonarSource(String v) => _set('sonarSource', v);
  double get sonarVolume => _d('sonarVol', 0.6);
  set sonarVolume(double v) => _set('sonarVol', v);

  /// Tryb CPAP — zapamiętany wybór na kolejne noce.
  bool get cpapDefault => _b('cpap', false);
  set cpapDefault(bool v) => _set('cpap', v);

  // --- Pogoda ---
  double? get weatherLat => _p.getDouble('wLat');
  double? get weatherLon => _p.getDouble('wLon');
  String get weatherPlace => _s('wPlace', '');
  bool get weatherReady => weatherLat != null && weatherLon != null;
  Future<void> setWeatherPlace(String name, double lat, double lon) async {
    await _p.setDouble('wLat', lat);
    await _p.setDouble('wLon', lon);
    await _p.setString('wPlace', name);
    notifyListeners();
  }

  Future<void> clearWeatherPlace() async {
    await _p.remove('wLat');
    await _p.remove('wLon');
    await _p.remove('wPlace');
    notifyListeners();
  }

  int get stagingVersion => _i('stagingVersion', 1);
  set stagingVersion(int v) => _set('stagingVersion', v);

  bool get detectTalk => _b('detectTalk', true);
  set detectTalk(bool v) => _set('detectTalk', v);
  bool get detectCough => _b('detectCough', true);
  set detectCough(bool v) => _set('detectCough', v);
  bool get recordClips => _b('recordClips', true);
  set recordClips(bool v) => _set('recordClips', v);
  bool get antiSnore => _b('antiSnore', false);
  set antiSnore(bool v) => _set('antiSnore', v);
  /// Kalibracja mikrofonu: dB SPL = dBFS + przesunięcie. Typowe telefony: 90–100.
  double get micOffset => _d('micOffset', 92);
  set micOffset(double v) => _set('micOffset', v);
  double spl(double dbfs) => (dbfs + micOffset).clamp(0, 140).toDouble();

  int get luxIntervalSec => _i('luxInterval', 60);
  set luxIntervalSec(int v) => _set('luxInterval', v);

  // --- Sen ---
  int get sleepGoalMin => _i('sleepGoal', 480);
  set sleepGoalMin(int v) => _set('sleepGoal', v);
  bool get bedtimeReminder => _b('bedReminder', false);
  set bedtimeReminder(bool v) => _set('bedReminder', v);
  int get bedtimeHour => _i('bedHour', 22);
  set bedtimeHour(int v) => _set('bedHour', v);
  int get bedtimeMinute => _i('bedMinute', 30);
  set bedtimeMinute(int v) => _set('bedMinute', v);
  int get delayStartMin => _i('delayStart', 0);
  set delayStartMin(int v) => _set('delayStart', v);
  /// Zapis każdej nocy do Health Connect (Android).
  bool get healthConnect => _b('healthConnect', false);
  set healthConnect(bool v) => _set('healthConnect', v);

  bool get keepScreenOn => _b('keepScreenOn', false);
  set keepScreenOn(bool v) => _set('keepScreenOn', v);

  // --- Kołysanki ---
  /// 'none' | 'white' | 'pink' | 'brown' | 'rain' | 'waves' | 'fan'
  String get lullaby => _s('lullaby', 'none');
  set lullaby(String v) => _set('lullaby', v);
  int get lullabyMin => _i('lullabyMin', 20);
  set lullabyMin(int v) => _set('lullabyMin', v);
  double get lullabyVolume => _d('lullabyVol', 0.5);
  set lullabyVolume(double v) => _set('lullabyVol', v);

  // --- Tagi ---
  List<String> get tags => _p.getStringList('tags') ?? defaultTags;
  set tags(List<String> v) => _set('tags', v);
  List<String> get tonightTags => _p.getStringList('tonightTags') ?? const [];
  set tonightTags(List<String> v) => _set('tonightTags', v);
  String get tonightLight => _s('tonightLight', '');
  set tonightLight(String v) => _set('tonightLight', v);
}

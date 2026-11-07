import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../core/edf.dart';

String ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

DateTime? parseYmd(String s) {
  if (s.length != 8) return null;
  final y = int.tryParse(s.substring(0, 4)), m = int.tryParse(s.substring(4, 6)), d = int.tryParse(s.substring(6, 8));
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// Dzień z pliku STR.edf (podsumowanie aparatu: wskaźniki, statystyki przebiegów, ustawienia, maska).
class CardDay {
  final DateTime date;
  final Map<String, double> v; // wartości jednoliczbowe (etykieta sygnału STR)
  final Map<String, List<double>> arr; // sygnały wielopróbkowe (MaskOn, MaskOff…)
  CardDay(this.date, this.v, this.arr);

  double? val(String k) {
    final x = v[k];
    return (x == null || x.isNaN || x < 0) ? null : x;
  }

  double? any(List<String> ks) {
    for (final k in ks) {
      final x = val(k);
      if (x != null) return x;
    }
    return null;
  }

  int get usageMin => (any(['Duration', 'OnDuration']) ?? 0).round();
  bool get used => usageMin >= 1;
  bool get compliant => usageMin >= 240;

  double? get ahi => val('AHI');
  double? get oai => val('OAI');
  double? get cai => val('CAI');
  double? get hi => val('HI');
  double? get uai => val('UAI');
  double? get ai => val('AI');
  double? get rin => val('RIN'); // RERA na godzinę
  double? get csr => val('CSR');

  double? get leak50 => val('Leak.50');
  double? get leak95 => val('Leak.95');
  double? get leakMax => val('Leak.Max');
  double? get press50 => any(['MaskPress.50', 'TgtIPAP.50', 'TgtEPAP.50']);
  double? get press95 => any(['MaskPress.95', 'TgtIPAP.95', 'TgtEPAP.95']);
  double? get pressMax => any(['MaskPress.Max', 'TgtIPAP.Max', 'TgtEPAP.Max']);
  double? get epr50 => any(['TgtEPAP.50']);
  double? get rr50 => val('RespRate.50');
  double? get rr95 => val('RespRate.95');
  double? get mv50 => val('MinVent.50');
  double? get mv95 => val('MinVent.95');
  double? get tv50 => val('TidVol.50');
  double? get tv95 => val('TidVol.95');
  double? get spo250 => val('SpO2.50');
  double? get spo295 => val('SpO2.95');

  /// Sesje z maską (czasy założenia/zdjęcia; ResMed liczy minuty od południa danego dnia).
  List<(DateTime, DateTime)> get maskSessions {
    final on = arr['MaskOn'] ?? const [], off = arr['MaskOff'] ?? const [];
    final noon = DateTime(date.year, date.month, date.day, 12);
    final out = <(DateTime, DateTime)>[];
    for (var i = 0; i < min(on.length, off.length); i++) {
      if (on[i] < 0 || off[i] <= on[i] || on[i].isNaN || off[i].isNaN) continue;
      out.add((noon.add(Duration(minutes: on[i].round())), noon.add(Duration(minutes: off[i].round()))));
    }
    return out;
  }

  int get maskEvents => (val('MaskEvents') ?? maskSessions.length * 2).round();

  // --- ustawienia ---
  String get modeName {
    final m = val('Mode')?.round();
    return switch (m) {
      0 => 'CPAP',
      1 => 'AutoSet',
      null => '—',
      _ => 'tryb $m',
    };
  }

  bool get isAuto => (val('Mode')?.round() ?? 0) != 0;
  double? get setPress => val('S.C.Press');
  double? get setMin => any(['S.AS.MinPress', 'S.A4H.MinPress', 'S.AA.MinPress']);
  double? get setMax => any(['S.AS.MaxPress', 'S.A4H.MaxPress', 'S.AA.MaxPress']);
  double? get setStart => any(['S.AS.StartPress', 'S.RampPress']);
  bool get eprOn => (val('S.EPR.EPREnable') ?? val('S.EPR.ClinEnable') ?? 0) > 0;
  int? get eprLevel => val('S.EPR.Level')?.round();
  bool get rampOn => (val('S.RampEnable') ?? 0) > 0;
  int? get rampTime => val('S.RampTime')?.round();
  bool get humOn => (val('S.HumEnable') ?? 0) > 0;
  int? get humLevel => val('S.HumLevel')?.round();
  bool get tempOn => (val('S.TempEnable') ?? 0) > 0;
  double? get temp => val('S.Temp');
  bool get smartStart => (val('S.SmartStart') ?? 0) > 0;
  String get maskName => switch (val('S.Mask')?.round()) {
        0 => 'poduszki nosowe',
        1 => 'pełnotwarzowa',
        2 => 'nosowa',
        _ => '—',
      };

  /// Podpis ustawień do porównań („co się zmieniło”).
  String get settingsKey => [
        modeName,
        setPress?.toStringAsFixed(1),
        setMin?.toStringAsFixed(1),
        setMax?.toStringAsFixed(1),
        eprOn ? eprLevel : 'off',
        rampOn ? '$rampTime' : 'off',
        humOn ? humLevel : 'off',
      ].join('|');
}

/// Fragment ciągłego przebiegu (jedna sesja).
class CpapSeg {
  final double t0; // sekundy od epoki
  final double dt; // odstęp próbek, s
  final Float32List v;
  CpapSeg(this.t0, this.dt, this.v);
  double get t1 => t0 + dt * v.length;
}

class CpapSeries {
  final String key, label, unit;
  final List<CpapSeg> segs;
  CpapSeries(this.key, this.label, this.unit, this.segs);

  /// Wartość najbliższa czasowi [t] albo null.
  double? at(double t) {
    for (final s in segs) {
      if (t < s.t0 || t >= s.t1) continue;
      final i = ((t - s.t0) / s.dt).floor().clamp(0, s.v.length - 1);
      final x = s.v[i];
      return x.isNaN ? null : x;
    }
    return null;
  }
}

class CpapEvent {
  final double t; // sekundy od epoki (początek zdarzenia)
  final double dur; // s
  final String kind; // oa, ca, h, ua, rera, fl, csr, other
  final String text;
  const CpapEvent(this.t, this.dur, this.kind, this.text);
}

class CpapDetail {
  final DateTime day;
  final List<(DateTime, DateTime)> sessions; // z plików
  final Map<String, CpapSeries> series;
  final List<CpapEvent> events;
  final List<(double, double)> csr; // okresy oddechu Cheyne'a-Stokesa
  CpapDetail(this.day, this.sessions, this.series, this.events, this.csr);
  bool get hasFlow => series.containsKey('flow');
  bool get isEmpty => sessions.isEmpty && series.isEmpty && events.isEmpty;
}

/// Katalog sygnałów: (klucz, nazwa, jednostka). Kolejność = kolejność wykresów.
const cpapSignalOrder = [
  ('flow', 'Przepływ', 'L/min'),
  ('pressBrp', 'Ciśnienie (25 Hz)', 'cmH₂O'),
  ('maskPress', 'Ciśnienie w masce', 'cmH₂O'),
  ('press', 'Ciśnienie', 'cmH₂O'),
  ('epr', 'Ciśnienie wydechu (EPR)', 'cmH₂O'),
  ('leak', 'Nieszczelność', 'L/min'),
  ('flim', 'Ograniczenie przepływu', ''),
  ('snore', 'Chrapanie', ''),
  ('rr', 'Częstość oddechu', '/min'),
  ('tv', 'Objętość oddechowa', 'mL'),
  ('mv', 'Wentylacja minutowa', 'L/min'),
  ('ti', 'Czas wdechu', 's'),
  ('ie', 'Wdech : wydech', ''),
  ('tgtVent', 'Wentylacja docelowa', 'L/min'),
  ('spo2', 'SpO₂', '%'),
  ('pulse', 'Tętno', '/min'),
];

const cpapEventKinds = [
  ('oa', 'Bezdech obturacyjny', 'OA'),
  ('ca', 'Bezdech centralny', 'CA'),
  ('ua', 'Bezdech niesklasyfikowany', 'UA'),
  ('h', 'Spłycenie (hipopnea)', 'H'),
  ('rera', 'Wybudzenie oddechowe (RERA)', 'RE'),
  ('fl', 'Ograniczenie przepływu', 'FL'),
  ('other', 'Inne', '•'),
];

String cpapEventKind(String t) {
  final s = t.toLowerCase();
  if (s.contains('obstructive')) return 'oa';
  if (s.contains('central')) return 'ca';
  if (s.contains('hypopnea')) return 'h';
  if (s.contains('arousal') || s.contains('rera')) return 'rera';
  if (s.contains('apnea')) return 'ua';
  if (s.contains('flow')) return 'fl';
  if (s.contains('csr') || s.contains('cheyne')) return 'csr';
  return 'other';
}

/// Nazwa sygnału → (klucz, przelicznik). [file] = typ pliku (BRP, PLD, SAD…).
(String, double)? _signalKey(EdfSignal s, String file) {
  final base = s.label.split('.').first.toLowerCase().replaceAll(' ', '');
  final dim = s.dim.toLowerCase();
  final perSec = dim.contains('/s') ? 60.0 : 1.0;
  switch (base) {
    case 'flow':
      return ('flow', perSec);
    case 'press':
      return (file == 'BRP' ? 'pressBrp' : 'press', 1);
    case 'maskpress':
      return ('maskPress', 1);
    case 'eprpress':
      return ('epr', 1);
    case 'leak':
      return ('leak', perSec);
    case 'resprate':
      return ('rr', 1);
    case 'tidvol':
      return ('tv', dim == 'l' || dim == 'liter' || dim == 'litre' ? 1000 : 1);
    case 'minvent':
      return ('mv', 1);
    case 'snore':
      return ('snore', 1);
    case 'flowlim':
      return ('flim', 1);
    case 'ti':
      return ('ti', 1);
    case 'ieratio':
      return ('ie', 1);
    case 'tgtvent':
      return ('tgtVent', 1);
    case 'spo2':
      return ('spo2', 1);
    case 'pulse':
      return ('pulse', 1);
    case 'crc16':
    case 'date':
      return null;
  }
  return null;
}

/// Odczyt jednego dnia z DATALOG/RRRRMMDD (do uruchomienia w osobnym isolate).
CpapDetail parseCpapDay((String dir, String day) a) {
  final (dirPath, dayStr) = a;
  final dir = Directory(dirPath);
  final day = parseYmd(dayStr) ?? DateTime(2000);
  final series = <String, List<CpapSeg>>{};
  final events = <CpapEvent>[];
  final csr = <(double, double)>[];
  final sess = <String, (double, double)>{};
  if (!dir.existsSync()) return CpapDetail(day, const [], const {}, const [], const []);
  final files = dir.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.edf')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final up = name.toUpperCase();
    final m = RegExp(r'_(BRP|PLD|EVE|CSL|SAD|SA2)\.EDF$').firstMatch(up);
    if (m == null) continue;
    final kind = m.group(1)!;
    EdfFile e;
    try {
      e = EdfFile.parse(f.readAsBytesSync());
    } catch (_) {
      continue;
    }
    final t0 = e.start.millisecondsSinceEpoch / 1000.0;
    final prefix = up.substring(0, max(0, up.length - 8)); // RRRRMMDD_GGMMSS
    if (kind == 'EVE' || kind == 'CSL') {
      double? csrStart;
      for (final an in e.annotations()) {
        final k = cpapEventKind(an.text);
        final t = t0 + an.onset;
        if (an.text.toLowerCase().contains('recording')) continue;
        if (k == 'csr') {
          final low = an.text.toLowerCase();
          if ((an.duration ?? 0) > 0) {
            csr.add((t, t + an.duration!));
          } else if (low.contains('start')) {
            csrStart = t;
          } else if (low.contains('end') && csrStart != null) {
            csr.add((csrStart, t));
            csrStart = null;
          }
          continue;
        }
        events.add(CpapEvent(t, an.duration ?? 0, k, an.text));
      }
      continue;
    }
    final dur = e.durationSec;
    final cur = sess[prefix];
    sess[prefix] = cur == null ? (t0, t0 + dur) : (min(cur.$1, t0), max(cur.$2, t0 + dur));
    for (var i = 0; i < e.signals.length; i++) {
      final sg = e.signals[i];
      if (sg.isAnnotation || sg.samplesPerRecord <= 0) continue;
      final key = _signalKey(sg, kind);
      if (key == null) continue;
      final (k, scale) = key;
      final v = e.signalF32(i, sentinelNaN: k != 'flow');
      for (var j = 0; j < v.length; j++) {
        final x = v[j];
        if (x.isNaN) continue;
        if (k != 'flow' && x < 0) {
          v[j] = double.nan;
        } else if (scale != 1) {
          v[j] = x * scale;
        }
      }
      series.putIfAbsent(k, () => []).add(CpapSeg(t0, e.interval(i), v));
    }
  }
  events.sort((a, b) => a.t.compareTo(b.t));
  final out = <String, CpapSeries>{};
  for (final (k, label, unit) in cpapSignalOrder) {
    final s = series[k];
    if (s == null) continue;
    s.sort((a, b) => a.t0.compareTo(b.t0));
    out[k] = CpapSeries(k, label, unit, s);
  }
  final sessions = [
    for (final s in sess.values)
      (DateTime.fromMillisecondsSinceEpoch((s.$1 * 1000).round()), DateTime.fromMillisecondsSinceEpoch((s.$2 * 1000).round()))
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return CpapDetail(day, sessions, out, events, csr);
}

/// Parsuje STR.edf do listy dni (z wartościami w jednostkach do wyświetlania).
List<CardDay> parseStrDays(Uint8List bytes) {
  final f = EdfFile.parse(bytes);
  final day0 = DateTime(f.start.year, f.start.month, f.start.day);
  final out = <CardDay>[];
  final scale = <int, double>{};
  for (var i = 0; i < f.signals.length; i++) {
    final s = f.signals[i];
    final base = s.label.split('.').first.toLowerCase();
    final dim = s.dim.toLowerCase();
    if (base == 'leak' && dim.contains('/s')) scale[i] = 60;
    if (base == 'tidvol' && (dim == 'l' || dim == 'liter')) scale[i] = 1000;
  }
  for (var r = 0; r < f.numRecords; r++) {
    final v = <String, double>{};
    final arr = <String, List<double>>{};
    for (var i = 0; i < f.signals.length; i++) {
      final s = f.signals[i];
      if (s.isAnnotation || s.samplesPerRecord <= 0) continue;
      final x = f.record(i, r);
      if (x.isEmpty) continue;
      final k = scale[i] ?? 1;
      if (s.samplesPerRecord == 1) {
        v[s.label] = x.first < 0 ? x.first : x.first * k;
      } else {
        arr[s.label] = x;
      }
    }
    out.add(CardDay(DateTime(day0.year, day0.month, day0.day + r), v, arr));
  }
  return out;
}

class CpapDevice {
  final String model, serial, product;
  const CpapDevice(this.model, this.serial, this.product);
}

/// Dane z karty zapisane w pamięci aplikacji (files/cpap, struktura jak na karcie).
class CpapStore {
  static Directory? _root;
  static List<CardDay>? _days;
  static int _strStamp = -1;

  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}cpap');
    if (!d.existsSync()) d.createSync(recursive: true);
    return _root = d;
  }

  static Future<File> _strFile() async {
    final r = await root();
    for (final f in r.listSync().whereType<File>()) {
      if (f.uri.pathSegments.last.toUpperCase() == 'STR.EDF') return f;
    }
    return File('${r.path}${Platform.pathSeparator}STR.edf');
  }

  static Future<bool> get hasData async => (await days()).any((d) => d.used) || (await dayFolders()).isNotEmpty;

  /// Dni z podsumowaniem (tylko z użyciem aparatu), od najstarszego.
  static Future<List<CardDay>> days() async {
    final f = await _strFile();
    if (!f.existsSync()) return _days = [];
    final stamp = f.lengthSync() ^ f.lastModifiedSync().millisecondsSinceEpoch;
    if (_days != null && stamp == _strStamp) return _days!;
    try {
      final bytes = await f.readAsBytes();
      _days = (await compute(parseStrDays, bytes)).where((d) => d.used).toList();
      _strStamp = stamp;
    } catch (_) {
      _days = [];
    }
    return _days!;
  }

  static void invalidate() {
    _days = null;
    _strStamp = -1;
  }

  /// Foldery dni w DATALOG (RRRRMMDD), od najstarszego.
  static Future<List<String>> dayFolders() async {
    final d = Directory('${(await root()).path}${Platform.pathSeparator}DATALOG');
    if (!d.existsSync()) return [];
    return d
        .listSync()
        .whereType<Directory>()
        .map((x) => x.uri.pathSegments.where((p) => p.isNotEmpty).last)
        .where((n) => RegExp(r'^\d{8}$').hasMatch(n))
        .toList()
      ..sort();
  }

  static Future<CpapDetail> detail(DateTime day) async {
    final r = await root();
    final s = ymd(day);
    final dir = '${r.path}${Platform.pathSeparator}DATALOG${Platform.pathSeparator}$s';
    return compute(parseCpapDay, (dir, s));
  }

  static Future<CpapDevice?> device() async {
    final r = await root();
    for (final f in r.listSync().whereType<File>()) {
      if (f.uri.pathSegments.last.toUpperCase() != 'IDENTIFICATION.TGT') continue;
      try {
        final t = await f.readAsString();
        String g(String k) => RegExp('#$k\\s+(.+)').firstMatch(t)?.group(1)?.trim().replaceAll('_', ' ') ?? '';
        return CpapDevice(g('PNA'), g('SRN'), g('PCD'));
      } catch (_) {}
    }
    return null;
  }

  /// Zapis plików wskazanych ręcznie (iOS / bez dostępu do karty): STR i Identification do katalogu
  /// głównego, pliki sesji (RRRRMMDD_GGMMSS_XXX.edf) do DATALOG/<dzień ResMed>.
  static Future<List<String>> ingest(List<(String, Uint8List)> files) async {
    final r = await root();
    final sep = Platform.pathSeparator;
    final out = <String>[];
    for (final (name, bytes) in files) {
      final up = name.toUpperCase();
      String? path;
      if (up == 'STR.EDF' || up.startsWith('IDENTIFICATION.')) {
        path = '${r.path}$sep$name';
      } else {
        final m = RegExp(r'^(\d{8})_(\d{2})\d{4}_').firstMatch(up);
        if (m == null) continue;
        var d = parseYmd(m.group(1)!)!;
        if (int.parse(m.group(2)!) < 12) d = d.subtract(const Duration(days: 1)); // dzień ResMed: od południa
        final dir = Directory('${r.path}${sep}DATALOG$sep${ymd(d)}');
        dir.createSync(recursive: true);
        path = '${dir.path}$sep$name';
      }
      await File(path).writeAsBytes(bytes, flush: true);
      out.add(path);
    }
    invalidate();
    return out;
  }

  /// Usuwa pełny zapis oddechu (BRP) starszy niż [keepDays] dni (0 = nie usuwaj).
  static Future<int> pruneWaveforms(int keepDays) async {
    if (keepDays <= 0) return 0;
    final cut = ymd(DateTime.now().subtract(Duration(days: keepDays)));
    final r = await root();
    final dl = Directory('${r.path}${Platform.pathSeparator}DATALOG');
    if (!dl.existsSync()) return 0;
    var n = 0;
    for (final d in dl.listSync().whereType<Directory>()) {
      final name = d.uri.pathSegments.where((p) => p.isNotEmpty).last;
      if (name.compareTo(cut) >= 0) continue;
      for (final f in d.listSync().whereType<File>()) {
        if (f.path.toUpperCase().contains('_BRP')) {
          try {
            f.deleteSync();
            n++;
          } catch (_) {}
        }
      }
    }
    return n;
  }

  /// Zajętość pamięci przez dane aparatu (bajty).
  static Future<int> sizeBytes() async {
    final r = await root();
    var n = 0;
    for (final f in r.listSync(recursive: true).whereType<File>()) {
      try {
        n += f.lengthSync();
      } catch (_) {}
    }
    return n;
  }
}

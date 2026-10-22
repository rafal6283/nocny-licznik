import 'dart:math';
import 'dart:ui' show Color;

import 'fmt.dart';
import 'models.dart';
import 'settings.dart';
import 'stats_util.dart';

enum Period { days, weeks, months, all }

extension PeriodX on Period {
  String get label => switch (this) {
        Period.days => 'Dni',
        Period.weeks => 'Tygodnie',
        Period.months => 'Miesiące',
        Period.all => 'Wszystko',
      };
}

enum ChartKind { bar, line }

/// Jedna statystyka w stylu Sleep Cycle.
class Metric {
  final String id;
  final String title;
  final Color color;
  final ChartKind kind;
  final double? Function(Night) value;
  final String Function(double) fmt;
  final int minNights;
  final bool zeroBased;
  final String about;
  final bool? higherIsBetter;
  final double? goal;
  const Metric({
    required this.id,
    required this.title,
    required this.color,
    required this.kind,
    required this.value,
    required this.fmt,
    this.minNights = 1,
    this.zeroBased = true,
    required this.about,
    this.higherIsBetter,
    this.goal,
  });
}

/// Punkt wykresu: noc albo uśredniony tydzień/miesiąc.
class MetricPoint {
  final String label;
  final double? value;
  final List<Night> nights;
  const MetricPoint(this.label, this.value, this.nights);
}

const _monthShort = ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];

/// Minuty od południa (żeby 23:30 i 00:30 leżały obok siebie na osi).
double noonMinutes(DateTime t) => (((t.hour * 60 + t.minute) - 720 + 1440) % 1440).toDouble();

String fmtNoonMinutes(double v) {
  final m = ((v.round() + 720) % 1440 + 1440) % 1440;
  return '${two(m ~/ 60)}:${two(m % 60)}';
}

String fmtHours(double minutes) {
  final m = minutes.round();
  final h = m ~/ 60;
  final r = m % 60;
  if (h == 0) return '${r}min';
  return r == 0 ? '${h}h' : '${h}h${two(r)}';
}

/// Regularność snu 0–100%: jak bardzo pora zaśnięcia i pobudki odbiega od średniej
/// z poprzednich (do 7) nocy z ostatnich 14 dni. Wymaga ≥4 wcześniejszych nocy.
Map<int, double> regularityScores(List<Night> chrono) {
  final out = <int, double>{};
  for (var i = 0; i < chrono.length; i++) {
    final n = chrono[i];
    if (n.id == null || n.end == null) continue;
    final prev = [
      for (var j = i - 1; j >= 0 && i - j <= 7; j--)
        if (n.start.difference(chrono[j].start).inDays <= 14 && chrono[j].end != null) chrono[j]
    ];
    if (prev.length < 4) continue;
    final mBed = prev.map((p) => noonMinutes(p.start)).reduce((a, b) => a + b) / prev.length;
    final mWake = prev.map((p) => noonMinutes(p.end!)).reduce((a, b) => a + b) / prev.length;
    final dev = ((noonMinutes(n.start) - mBed).abs() + (noonMinutes(n.end!) - mWake).abs()) / 2;
    out[n.id!] = (100 - dev / 1.2).clamp(0, 100).toDouble();
  }
  return out;
}

List<Metric> buildMetrics(Map<int, double> regularity, {bool farts = true, bool cpap = false, bool breath = false}) {
  final s = Settings.instance;
  final all = [
    Metric(
      id: 'quality',
      title: 'Jakość snu',
      color: const Color(0xFF5EC8F2),
      kind: ChartKind.bar,
      value: (n) => n.score.toDouble(),
      fmt: (v) => '${v.round()}%',
      higherIsBetter: true,
      about: 'Ocena nocy 0–100% z długości snu (wobec Twojego celu), efektywności, udziału snu głębokiego i REM, '
          'liczby przebudzeń, chrapania i przerw w oddechu.',
    ),
    Metric(
      id: 'regularity',
      title: 'Regularność',
      color: const Color(0xFFB59BFF),
      kind: ChartKind.line,
      value: (n) => n.id == null ? null : regularity[n.id!],
      fmt: (v) => '${v.round()}%',
      minNights: 5,
      zeroBased: false,
      higherIsBetter: true,
      about: 'Jak stałe są Twoje pory snu. 100% = kładziesz się i wstajesz o tej samej porze co w poprzednich nocach; '
          'każda godzina rozjazdu obniża wynik o ok. 50 punktów. Regularny rytm sprzyja lepszemu wypoczynkowi.',
    ),
    Metric(
      id: 'bedtime',
      title: 'Pora pójścia spać',
      color: const Color(0xFF6FA8FF),
      kind: ChartKind.line,
      value: (n) => noonMinutes(n.start),
      fmt: fmtNoonMinutes,
      zeroBased: false,
      about: 'Godzina rozpoczęcia śledzenia nocy.',
    ),
    Metric(
      id: 'wakeup',
      title: 'Pobudka',
      color: C2.moon,
      kind: ChartKind.line,
      value: (n) => n.end == null ? null : noonMinutes(n.end!),
      fmt: fmtNoonMinutes,
      zeroBased: false,
      about: 'Godzina zakończenia nocy (wyłączenie budzika albo „Zakończ noc”).',
    ),
    Metric(
      id: 'inbed',
      title: 'Czas w łóżku',
      color: const Color(0xFF4FB3D9),
      kind: ChartKind.bar,
      value: (n) => n.inBedMin.toDouble(),
      fmt: fmtHours,
      goal: s.sleepGoalMin.toDouble(),
      about: 'Od rozpoczęcia do zakończenia nocy, łącznie z zasypianiem i przebudzeniami.',
    ),
    Metric(
      id: 'asleep',
      title: 'Sen',
      color: const Color(0xFF3A4FC4),
      kind: ChartKind.bar,
      value: (n) => n.durationMin.toDouble(),
      fmt: fmtHours,
      goal: s.sleepGoalMin.toDouble(),
      higherIsBetter: true,
      about: 'Szacowany czas faktycznego snu (płytki + głęboki + REM), bez czuwania.',
    ),
    Metric(
      id: 'latency',
      title: 'Zaśnięcie po',
      color: const Color(0xFF8C93B8),
      kind: ChartKind.bar,
      value: (n) => n.latencyMin.toDouble(),
      fmt: (v) => '${v.round()} min',
      higherIsBetter: false,
      about: 'Ile czasu minęło od położenia się do zaśnięcia. Typowo 10–20 minut.',
    ),
    Metric(
      id: 'farts',
      title: 'Wiatry 💨',
      color: C2.gas,
      kind: ChartKind.bar,
      value: (n) => n.fartCount.toDouble(),
      fmt: (v) => v >= 10 || v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1),
      higherIsBetter: false,
      about: 'Liczba rozpoznanych wiatrów w nocy (bez odrzuconych przez Ciebie nagrań).',
    ),
    Metric(
      id: 'snore',
      title: 'Chrapanie',
      color: const Color(0xFF6FA8FF),
      kind: ChartKind.bar,
      value: (n) => n.snoreMin.toDouble(),
      fmt: fmtHours,
      higherIsBetter: false,
      about: 'Łączny czas minut, w których słychać było chrapanie.',
    ),
    Metric(
      id: 'cough',
      title: 'Kaszel',
      color: const Color(0xFFFF9E7A),
      kind: ChartKind.bar,
      value: (n) => n.coughCount.toDouble(),
      fmt: (v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1),
      higherIsBetter: false,
      about: 'Liczba epizodów kaszlu w nocy.',
    ),
    Metric(
      id: 'light',
      title: 'Światło',
      color: C2.moon,
      kind: ChartKind.line,
      value: (n) => n.avgLux,
      fmt: (v) => v < 10 ? '${v.toStringAsFixed(1)} lx' : '${v.round()} lx',
      higherIsBetter: false,
      about: 'Średnie natężenie światła w sypialni (luksy). Do snu najlepiej poniżej 1 lx — praktycznie ciemność.',
    ),
    Metric(
      id: 'noise',
      title: 'Hałas otoczenia',
      color: const Color(0xFF3DDC97),
      kind: ChartKind.bar,
      value: (n) => n.avgNoise == null ? null : s.spl(n.avgNoise!),
      fmt: (v) => '${v.round()} dB',
      higherIsBetter: false,
      about: 'Średni równoważny poziom dźwięku w nocy (Leq) mierzony mikrofonem. WHO zaleca w sypialni ok. 30 dB. '
          'Wartości są orientacyjne — kalibrację zmienisz w Ustawieniach.',
    ),
    Metric(
      id: 'breathing',
      title: 'Przerwy w oddechu',
      color: const Color(0xFFFF7A85),
      kind: ChartKind.bar,
      value: (n) => (n.apneaCount + n.hypopneaCount).toDouble(),
      fmt: (v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1),
      higherIsBetter: false,
      about: 'Liczba przerw w oddychaniu ≥10 s (z sonarem także spłyceń o ≥50%). Wskaźnik na godzinę snu '
          'poniżej 5 uznaje się za normę. To orientacyjny sygnał, nie diagnoza.',
    ),
    Metric(
      id: 'breath_rate',
      title: 'Częstość oddechu',
      color: const Color(0xFF6FA8FF),
      kind: ChartKind.line,
      value: (n) => n.breathRate,
      fmt: (v) => '${v.toStringAsFixed(1)}/min',
      zeroBased: false,
      about: 'Średnia liczba oddechów na minutę w czasie snu, mierzona sonarem. U dorosłych we śnie zwykle 12–20.',
    ),
    Metric(
      id: 'cpap_ahi',
      title: 'AHI z aparatu CPAP',
      color: const Color(0xFFFF9E7A),
      kind: ChartKind.bar,
      value: (n) => n.cpapAhi,
      fmt: (v) => v.toStringAsFixed(1),
      higherIsBetter: false,
      about: 'Wskaźnik bezdechów i spłyceń na godzinę zarejestrowany przez aparat CPAP (wpisany ręcznie albo '
          'zaimportowany z OSCAR). Cel terapii to zwykle AHI < 5.',
    ),
  ];
  return all.where((m) {
    if (m.id == 'farts') return farts;
    if (m.id == 'cpap_ahi') return cpap;
    if (m.id == 'breath_rate') return breath;
    return true;
  }).toList();
}

/// Kolory dostępne bez importu warstwy UI.
class C2 {
  static const moon = Color(0xFFFFD66B);
  static const gas = Color(0xFF7BE3B0);
}

DateTime _monday(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Noc „należy” do dnia, w którym się zaczęła (noc po północy — do poprzedniego dnia).
DateTime nightDay(Night n) {
  final s = n.start.hour < 12 ? n.start.subtract(const Duration(days: 1)) : n.start;
  return DateTime(s.year, s.month, s.day);
}

List<MetricPoint> metricSeries(Metric m, List<Night> chrono, Period p) {
  double? mean(List<Night> ns) {
    final v = ns.map(m.value).whereType<double>().toList();
    return v.isEmpty ? null : avg(v);
  }

  switch (p) {
    case Period.days:
      final last = chrono.length > 14 ? chrono.sublist(chrono.length - 14) : chrono;
      return [for (final n in last) MetricPoint(shortDate(nightDay(n)), m.value(n), [n])];
    case Period.all:
      return [for (final n in chrono) MetricPoint(shortDate(nightDay(n)), m.value(n), [n])];
    case Period.weeks:
      final groups = <DateTime, List<Night>>{};
      for (final n in chrono) {
        groups.putIfAbsent(_monday(nightDay(n)), () => []).add(n);
      }
      final keys = groups.keys.toList()..sort();
      final take = keys.length > 12 ? keys.sublist(keys.length - 12) : keys;
      return [for (final k in take) MetricPoint(shortDate(k), mean(groups[k]!), groups[k]!)];
    case Period.months:
      final groups = <DateTime, List<Night>>{};
      for (final n in chrono) {
        final d = nightDay(n);
        groups.putIfAbsent(DateTime(d.year, d.month), () => []).add(n);
      }
      final keys = groups.keys.toList()..sort();
      final take = keys.length > 12 ? keys.sublist(keys.length - 12) : keys;
      return [for (final k in take) MetricPoint(_monthShort[k.month - 1], mean(groups[k]!), groups[k]!)];
  }
}

/// Podsumowanie wartości metryki dla nocy w zakresie.
class MetricSummary {
  final double? avgV, minV, maxV, lastV;
  final Night? best, worst;
  const MetricSummary(this.avgV, this.minV, this.maxV, this.lastV, this.best, this.worst);
}

MetricSummary summarizeMetric(Metric m, List<Night> nights) {
  final pairs = [
    for (final n in nights)
      if (m.value(n) != null) (n, m.value(n)!)
  ];
  if (pairs.isEmpty) return const MetricSummary(null, null, null, null, null, null);
  final vals = pairs.map((e) => e.$2).toList();
  final hiP = pairs.reduce((a, b) => a.$2 >= b.$2 ? a : b);
  final loP = pairs.reduce((a, b) => a.$2 <= b.$2 ? a : b);
  Night? best, worst;
  if (m.higherIsBetter == true) {
    best = hiP.$1;
    worst = loP.$1;
  } else if (m.higherIsBetter == false) {
    best = loP.$1;
    worst = hiP.$1;
  }
  return MetricSummary(avg(vals), vals.reduce(min), vals.reduce(max), pairs.last.$2, best, worst);
}

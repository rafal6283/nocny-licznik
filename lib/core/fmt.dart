const _days = ['pon.', 'wt.', 'śr.', 'czw.', 'pt.', 'sob.', 'niedz.'];
const _months = ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];

String two(int v) => v.toString().padLeft(2, '0');

String hhmm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String hhmmss(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

String dayLabel(DateTime t) => '${_days[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';

String shortDate(DateTime t) => '${t.day}.${two(t.month)}';

/// „7 h 12 min”, „45 min”
String durHM(num minutes) {
  final m = minutes.round();
  if (m < 60) return '$m min';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '$h h' : '$h h $r min';
}

/// Odmiana: 1 bąk, 2 bąki, 5 bąków
String plural(int n, String one, String few, String many) {
  if (n == 1) return one;
  final d = n % 10, dd = n % 100;
  if (d >= 2 && d <= 4 && !(dd >= 12 && dd <= 14)) return few;
  return many;
}

String fartsLabel(int n) => '$n ${plural(n, 'bąk', 'bąki', 'bąków')}';

String luxLabel(double? lux) {
  if (lux == null) return '—';
  if (lux < 1) return '${lux.toStringAsFixed(1)} lx';
  return '${lux.round()} lx';
}

String luxWord(double? lux) {
  if (lux == null) return 'brak pomiaru';
  if (lux < 1) return 'ciemno';
  if (lux < 10) return 'półmrok';
  if (lux < 50) return 'przyciemnione';
  return 'jasno';
}

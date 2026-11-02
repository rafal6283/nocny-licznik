import 'dart:math';

const _months = ['sty', 'lut', 'mar', 'kwi', 'maj', 'cze', 'lip', 'sie', 'wrz', 'paź', 'lis', 'gru'];
const _weekdays = ['pn', 'wt', 'śr', 'cz', 'pt', 'sb', 'nd'];

/// Liczba po polsku: przecinek dziesiętny, spacja tysięcy.
String plNum(double v, {int decimals = 0}) {
  final neg = v < 0;
  final s = v.abs().toStringAsFixed(decimals);
  final parts = s.split('.');
  final ints = parts[0];
  final b = StringBuffer();
  for (var i = 0; i < ints.length; i++) {
    if (i > 0 && (ints.length - i) % 3 == 0) b.write(' ');
    b.write(ints[i]);
  }
  final frac = parts.length > 1 ? ',${parts[1]}' : '';
  return '${neg ? '−' : ''}$b$frac';
}

/// Liczba z rozsądną liczbą miejsc po przecinku zależnie od wielkości.
String plAuto(double v) {
  final a = v.abs();
  return plNum(v, decimals: a >= 100 ? 0 : (a >= 10 ? 1 : 2));
}

String plDay(DateTime d) => '${d.day} ${_months[d.month - 1]}';
String plDayYear(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
String plMonth(DateTime d) => '${_months[d.month - 1]} ${d.year}';
String plWeekday(DateTime d) => _weekdays[d.weekday - 1];
String plMonthShort(int month) => _months[month - 1];

/// „Ładne” podziałki osi: 1, 2, 2,5, 5 × 10^n.
List<double> niceTicks(double lo, double hi, {int target = 4}) {
  if (!lo.isFinite || !hi.isFinite) return const [];
  if (hi <= lo) {
    hi = lo + 1;
  }
  final raw = (hi - lo) / target;
  final mag = pow(10, (log(raw) / ln10).floor()).toDouble();
  final step = [1.0, 2.0, 2.5, 5.0, 10.0].map((m) => m * mag).firstWhere((s) => s >= raw, orElse: () => 10 * mag);
  final start = (lo / step).ceil() * step;
  return [for (var v = start; v <= hi + step * 1e-6; v += step) double.parse(v.toStringAsFixed(10))];
}

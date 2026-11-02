import 'dart:math';

/// Pozycja ciała z kierunku grawitacji w akcelerometrze opaski na klatce (Polar H10).
/// Osie opaski nie są znane z góry, więc wzorce „na plecach” i „na prawym boku” pochodzą z krótkiej
/// kalibracji w Ustawieniach; pozostałe pozycje to ich przeciwieństwa i kierunek prostopadły (siedzenie/stanie).
enum BodyPos { back, front, right, left, upright, unknown }

extension BodyPosX on BodyPos {
  String get label => switch (this) {
        BodyPos.back => 'na plecach',
        BodyPos.front => 'na brzuchu',
        BodyPos.right => 'na prawym boku',
        BodyPos.left => 'na lewym boku',
        BodyPos.upright => 'siedząc / stojąc',
        BodyPos.unknown => 'nieznana',
      };
}

List<double> _unit(List<double> v) {
  final n = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  return n < 1e-9 ? const [0, 0, 0] : [v[0] / n, v[1] / n, v[2] / n];
}

double _dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

/// [g] – średnia grawitacja z minuty; [back], [right] – wzorce z kalibracji.
BodyPos classifyPosition(List<double> g, List<double> back, List<double> right) {
  final u = _unit(g), b = _unit(back), r = _unit(right);
  if (u.every((x) => x == 0)) return BodyPos.unknown;
  final db = _dot(u, b), dr = _dot(u, r);
  // ani plecy/brzuch, ani bok – grawitacja wzdłuż ciała (pionowo)
  if (db.abs() < 0.5 && dr.abs() < 0.5) return BodyPos.upright;
  if (db.abs() >= dr.abs()) return db > 0 ? BodyPos.back : BodyPos.front;
  return dr > 0 ? BodyPos.right : BodyPos.left;
}

List<double>? parseVec(String s) {
  final p = s.split(',').map(double.tryParse).toList();
  if (p.length != 3 || p.any((x) => x == null)) return null;
  return [p[0]!, p[1]!, p[2]!];
}

/// Statystyka pozycji z nocy: minuty, przerwy w oddechu i minuty chrapania w każdej pozycji.
class PositionStats {
  final Map<BodyPos, int> minutes = {};
  final Map<BodyPos, int> apneas = {};
  final Map<BodyPos, int> snore = {};

  void add(BodyPos p, {int apnea = 0, bool snoring = false}) {
    minutes[p] = (minutes[p] ?? 0) + 1;
    apneas[p] = (apneas[p] ?? 0) + apnea;
    if (snoring) snore[p] = (snore[p] ?? 0) + 1;
  }

  /// Przerwy w oddechu na godzinę w danej pozycji (null przy < 20 min).
  double? apneaIndex(BodyPos p) {
    final m = minutes[p] ?? 0;
    return m < 20 ? null : (apneas[p] ?? 0) / (m / 60);
  }

  double? snorePct(BodyPos p) {
    final m = minutes[p] ?? 0;
    return m < 20 ? null : 100 * (snore[p] ?? 0) / m;
  }
}

import 'package:bakometr/engine/snore_minute.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 11, 21, 2);
  DateTime at(double s) => t0.add(Duration(milliseconds: (s * 1000).round()));

  test('stały szum (CPAP, wentylator) to nie chrapanie', () {
    final m = SnoreMinute();
    for (var i = 0; i < 120; i++) {
      m.add(at(i * 0.5)); // trafienie w każdym oknie przez całą minutę, bez przerw
    }
    expect(m.hits, 120);
    expect(m.bursts, 1);
    expect(m.snoring, isFalse);
  });

  test('pojedyncze trafienie to nie chrapanie', () {
    final m = SnoreMinute()..add(at(10));
    expect(m.snoring, isFalse);
  });

  test('chrapanie przy kolejnych oddechach (co ~4 s)', () {
    final m = SnoreMinute();
    for (var b = 0; b < 12; b++) {
      m.add(at(b * 4.0));
      m.add(at(b * 4.0 + 0.5));
    }
    expect(m.bursts, 12);
    expect(m.snoring, isTrue);
  });

  test('nowa minuta liczy od zera', () {
    final m = SnoreMinute();
    for (var b = 0; b < 5; b++) {
      m.add(at(b * 4.0));
    }
    expect(m.snoring, isTrue);
    m.reset();
    expect(m.snoring, isFalse);
  });
}

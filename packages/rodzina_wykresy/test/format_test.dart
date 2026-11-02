import 'package:flutter_test/flutter_test.dart';
import 'package:rodzina_wykresy/rodzina_wykresy.dart';

void main() {
  test('liczby po polsku', () {
    expect(plNum(1234567.891, decimals: 2), '1 234 567,89');
    expect(plNum(-12.5, decimals: 1), '−12,5');
    expect(plAuto(3.14159), '3,14');
  });
  test('podziałki osi', () {
    expect(niceTicks(0, 100), [0, 25, 50, 75, 100]);
    expect(niceTicks(52, 61).first, greaterThanOrEqualTo(52));
  });
}

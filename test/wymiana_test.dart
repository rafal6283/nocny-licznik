import 'package:flutter_test/flutter_test.dart';
import 'package:koofr_sync/koofr_sync.dart';
import 'package:bakometr/core/strap.dart';

/// Kontrakt wymiany (packages/koofr_sync/WYMIANA.md) z perspektywy Rytmu Snu.
void main() {
  const sources = ['polar-ekg', 'polar-noce'];

  test('Rytm Snu pobiera dokładnie pliki z Polar EKG, które zna', () {
    expect(przykladyDlaZrodel(sources), unorderedEquals(['polar-ekg', 'polar-noce']));
    for (final p in kontraktWymiany) {
      if (p.odbiorcy.contains('rytm-snu')) expect(sources.any((s) => zrodloPasuje(s, p.przyklad)), isTrue, reason: p.nazwa);
    }
  });

  test('epizody AF z pliku polar-ekg', () {
    final af = PolarAf.parse(wymianaPrzyklady['polar-ekg']!);
    expect(af, hasLength(1));
    expect(af.first.$2.difference(af.first.$1).inSeconds, 46);
    expect(PolarAf.parse(wymianaPrzyklady['polar-noce']!), isEmpty); // inny format — pomijany
    expect(PolarAf.parse('{'), isEmpty);
  });
}

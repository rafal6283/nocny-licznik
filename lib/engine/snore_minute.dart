/// Czy dana minuta to chrapanie.
///
/// Chrapanie jest rytmiczne: słychać je przy kolejnych oddechach (co kilka sekund), z ciszą pomiędzy.
/// Wcześniej wystarczało jedno okno 0,5 s z wynikiem powyżej progu, by cała minuta liczyła się jako
/// chrapanie – stały szum (CPAP, wentylator, oczyszczacz) albo pojedynczy dźwięk potrafił „zachrapać”
/// prawie całą noc. Teraz potrzeba kilku osobnych „uderzeń” rozdzielonych przerwą.
class SnoreMinute {
  /// Ile osobnych uderzeń (oddechów z chrapaniem) w minucie.
  static const minBursts = 3;

  /// Ile okien powyżej progu łącznie (0,5 s każde).
  static const minHits = 4;

  /// Przerwa, po której kolejne trafienie to nowe uderzenie (następny oddech).
  static const gapMs = 1200;

  int hits = 0;
  int bursts = 0;
  DateTime? _last;

  void add(DateTime t) {
    hits++;
    final last = _last;
    if (last == null || t.difference(last).inMilliseconds >= gapMs) bursts++;
    _last = t;
  }

  bool get snoring => hits >= minHits && bursts >= minBursts;

  void reset() {
    hits = 0;
    bursts = 0;
    // _last zostaje: oddech na przełomie minut nie liczy się podwójnie
  }
}

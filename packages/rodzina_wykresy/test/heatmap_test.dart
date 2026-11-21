import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodzina_wykresy/rodzina_wykresy.dart';

void main() {
  testWidgets('kalendarz: dotknięcie, przesuwanie i otwieranie dnia', (t) async {
    final end = DateTime(2026, 11, 22); // niedziela
    DateTime? opened;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          child: CalendarHeatmap(
            values: {DateTime(2026, 11, 16): 3, DateTime(2026, 11, 20): 7},
            color: Colors.teal,
            weeks: 4,
            end: end,
            openLabel: 'Wpisy',
            onOpen: (d) => opened = d,
            marker: (d, v) => v >= 5,
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('lis'), findsWidgets); // skrót miesiąca
    // komórka: szerokość (400-22)/4 → maks. 18; ostatni tydzień = kolumna 3; poniedziałek 16.11 = wiersz 0
    final box = t.getTopLeft(find.byType(CalendarHeatmap));
    const cell = 18.0;
    Offset at(int w, int d) => box + Offset(22 + w * cell + cell / 2, 14 + d * cell + cell / 2);
    await t.tapAt(at(3, 0));
    await t.pumpAndSettle();
    expect(find.textContaining('16 lis'), findsOneWidget);
    // przesuwanie palcem do piątku nie działa w pionie – przesuwamy w poziomie po wierszu piątku
    final g = await t.startGesture(at(1, 4));
    await g.moveTo(at(2, 4));
    await g.moveTo(at(3, 4));
    await g.up();
    await t.pumpAndSettle();
    expect(find.textContaining('20 lis'), findsOneWidget);
    await t.tap(find.text('Wpisy'));
    expect(opened, DateTime(2026, 11, 20));
    // drugie dotknięcie tego samego dnia chowa podpis
    await t.tapAt(at(3, 4));
    await t.pumpAndSettle();
    expect(find.textContaining('20 lis'), findsNothing);
  });
}

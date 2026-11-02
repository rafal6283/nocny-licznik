/// Interaktywne wykresy i animacje wspólne dla rodzinnych aplikacji.
///
/// ```dart
/// InteractiveLineChart(series: [LineSeries('Waga', kolor, punkty)], band: (60, 70))
/// InteractiveBarChart(bars: [BarItem('USD', 120.5)])
/// DonutChart(slices: [DonutSlice('Złoto', 5400, Colors.amber)])
/// CalendarHeatmap(values: {dzień: wartość})
/// AnimatedNumber(value: 1234.5, format: (v) => '${v.round()} zł')
/// FadeSlideIn(index: 2, child: Card(...))
/// ```
library;

export 'src/animated_number.dart';
export 'src/bar_chart.dart';
export 'src/donut.dart';
export 'src/entrance.dart';
export 'src/format.dart';
export 'src/heatmap.dart';
export 'src/line_chart.dart';
export 'src/range_selector.dart';

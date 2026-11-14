import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/body_position.dart';
import '../core/db.dart';
import '../core/fmt.dart';
import '../core/models.dart';
import '../cpap/cpap_data.dart';
import '../ui/position_screen.dart';

/// Raport dla lekarza (PDF): terapia CPAP z karty aparatu, sen z aplikacji, pozycja ciała,
/// natlenienie z zegarka i przykładowe zdarzenia z przebiegiem przepływu.
class DoctorReport {
  static Future<File> build({required int days, String? patient}) async {
    final font = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day).subtract(Duration(days: days));

    final allCpap = await CpapStore.days();
    final cpap = allCpap.where((d) => !d.date.isBefore(from)).toList();
    final device = await CpapStore.device();
    final nights = (await Db.instance.nights(limit: 1000)).where((n) => !n.start.isBefore(from) && n.durationMin >= 60).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final (pos, posNights) = await computePositionStats(days);
    var maskOff = 0, maskLeak = 0;
    for (final n in nights) {
      if (n.id == null || !n.cpap) continue;
      for (final r in await Db.instance.ext(n.id!)) {
        if (r.$2 == 'mic_off') maskOff++;
        if (r.$2 == 'mic_leak') maskLeak++;
      }
    }
    final examples = await _examples(cpap);

    final doc = pw.Document(
      title: 'Raport snu',
      author: 'Rytm Snu',
      theme: pw.ThemeData.withFont(base: font, bold: bold),
    );
    final h1 = pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold);
    final h2 = pw.TextStyle(fontSize: 12.5, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800);
    final small = const pw.TextStyle(fontSize: 8, color: PdfColors.grey700);

    String f(double? v, [int d = 1]) => v == null ? '—' : v.toStringAsFixed(d);
    double? wavg(double? Function(CardDay) g) {
      var s = 0.0, w = 0.0;
      for (final d in cpap) {
        final v = g(d);
        if (v == null) continue;
        s += v * d.usageMin;
        w += d.usageMin;
      }
      return w == 0 ? null : s / w;
    }

    double? avg<T>(Iterable<T> xs, double? Function(T) g) {
      final v = xs.map(g).whereType<double>().toList();
      return v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;
    }

    final calDays = days;
    final compliant = cpap.where((d) => d.compliant).length;
    final last = cpap.isEmpty ? null : cpap.last;

    pw.Widget kv(List<(String, String)> rows) => pw.TableHelper.fromTextArray(
          data: [for (final r in rows) [r.$1, r.$2]],
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignments: {0: pw.Alignment.centerLeft, 1: pw.Alignment.centerRight},
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey300, width: 0.5)),
          cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
        );

    pw.Widget bars(String title, List<double?> v, {double? thr, PdfColor color = PdfColors.blue400, String unit = ''}) {
      final hi = max(thr == null ? 0.0 : thr * 1.15, v.whereType<double>().fold<double>(0, max)) * 1.08;
      return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Text('$title${unit.isEmpty ? '' : ' ($unit)'}', style: const pw.TextStyle(fontSize: 9)),
        pw.SizedBox(height: 2),
        pw.CustomPaint(
          size: const PdfPoint(515, 60),
          painter: (g, size) {
            if (v.isEmpty || hi <= 0) return;
            g.setFillColor(PdfColors.grey100);
            g.drawRect(0, 0, size.x, size.y);
            g.fillPath();
            final slot = size.x / v.length;
            g.setFillColor(color);
            for (var i = 0; i < v.length; i++) {
              final x = v[i];
              if (x == null || x <= 0) continue;
              g.drawRect(i * slot + slot * 0.15, 0, max(0.6, slot * 0.7), x / hi * size.y);
            }
            g.fillPath();
            if (thr != null) {
              g.setStrokeColor(PdfColors.red);
              g.setLineWidth(0.6);
              g.moveTo(0, thr / hi * size.y);
              g.lineTo(size.x, thr / hi * size.y);
              g.strokePath();
            }
          },
        ),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(shortDate(from), style: small),
          if (thr != null) pw.Text('linia: ${_n(thr)} $unit', style: small),
          pw.Text(shortDate(now), style: small),
        ]),
        pw.SizedBox(height: 6),
      ]);
    }

    // dni kalendarzowe okresu
    final dates = [for (var i = 0; i < days; i++) DateTime(from.year, from.month, from.day + i)];
    final byDate = {for (final d in cpap) d.date: d};
    List<double?> col(double? Function(CardDay) g) => [for (final d in dates) byDate[d] == null ? null : g(byDate[d]!)];

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 32, 36, 32),
      footer: (ctx) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('Rytm Snu · wygenerowano ${dayLabel(now)} ${hhmm(now)} · nie jest to badanie diagnostyczne', style: small),
        pw.Text('${ctx.pageNumber}/${ctx.pagesCount}', style: small),
      ]),
      build: (ctx) => [
        pw.Text('Raport snu i terapii CPAP', style: h1),
        pw.SizedBox(height: 2),
        pw.Text(
            '${patient != null && patient.isNotEmpty ? '$patient · ' : ''}okres: ${shortDate(from)} – ${shortDate(now)} ($days dni)'
            '${device != null && device.model.isNotEmpty ? ' · aparat: ${device.model}${device.serial.isNotEmpty ? ' (nr ${device.serial})' : ''}' : ''}',
            style: const pw.TextStyle(fontSize: 9.5)),
        pw.SizedBox(height: 10),

        // ---------------- CPAP
        if (cpap.isNotEmpty) ...[
          pw.Text('1. Terapia CPAP (dane z karty aparatu)', style: h2),
          pw.SizedBox(height: 4),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: kv([
                ('Noce z aparatem', '${cpap.length} / $calDays'),
                ('Przestrzeganie (≥ 4 h)', '${(compliant / max(1, calDays) * 100).round()}%'),
                ('Średnie użycie (noce z aparatem)', durHM(cpap.fold<int>(0, (a, d) => a + d.usageMin) / cpap.length)),
                ('AHI (średnia ważona)', f(wavg((d) => d.ahi), 2)),
                ('  bezdechy obturacyjne (OAI)', f(wavg((d) => d.oai), 2)),
                ('  bezdechy centralne (CAI)', f(wavg((d) => d.cai), 2)),
                ('  bezdechy niesklasyfikowane (UAI)', f(wavg((d) => d.uai), 2)),
                ('  spłycenia (HI)', f(wavg((d) => d.hi), 2)),
                ('RERA / h', f(wavg((d) => d.rin), 2)),
              ]),
            ),
            pw.SizedBox(width: 14),
            pw.Expanded(
              child: kv([
                ('Nieszczelność mediana (L/min)', f(avg(cpap, (d) => d.leak50))),
                ('Nieszczelność 95% (L/min)', f(avg(cpap, (d) => d.leak95))),
                ('Noce z nieszczelnością 95% > 24', '${cpap.where((d) => (d.leak95 ?? 0) > 24).length}'),
                ('Ciśnienie mediana (cmH₂O)', f(avg(cpap, (d) => d.press50))),
                ('Ciśnienie 95% (cmH₂O)', f(avg(cpap, (d) => d.press95))),
                ('Oddechy / min (mediana)', f(avg(cpap, (d) => d.rr50), 0)),
                ('Objętość oddechowa (mL)', f(avg(cpap, (d) => d.tv50), 0)),
                ('Zdjęcia maski / noc', f(avg(cpap, (d) => d.maskSessions.length.toDouble()))),
                if (maskOff + maskLeak > 0) ('Przypomnienia o masce (aplikacja)', '$maskOff zdjęta · $maskLeak syk'),
              ]),
            ),
          ]),
          pw.SizedBox(height: 6),
          if (last != null)
            pw.Text(
                'Ustawienia (ostatnia noc): ${last.modeName}, '
                '${last.isAuto ? 'ciśnienie ${f(last.setMin)}–${f(last.setMax)} cmH₂O' : 'ciśnienie ${f(last.setPress)} cmH₂O'}, '
                'EPR ${last.eprOn ? last.eprLevel : 'wył.'}, rampa ${last.rampOn ? '${last.rampTime} min' : 'wył.'}, '
                'nawilżacz ${last.humOn ? last.humLevel : 'wył.'}, maska: ${last.maskName}.',
                style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 8),
          bars('Czas użycia aparatu', col((d) => d.usageMin / 60), thr: 4, unit: 'h'),
          bars('AHI', col((d) => d.ahi), thr: 5, color: PdfColors.indigo400, unit: '/h'),
          bars('Nieszczelność 95%', col((d) => d.leak95), thr: 24, color: PdfColors.orange400, unit: 'L/min'),
          bars('Ciśnienie 95%', col((d) => d.press95), color: PdfColors.green400, unit: 'cmH₂O'),
          if (_settingChanges(cpap).isNotEmpty) ...[
            pw.Text('Zmiany ustawień w okresie:', style: const pw.TextStyle(fontSize: 9)),
            for (final c in _settingChanges(cpap)) pw.Bullet(text: c, style: const pw.TextStyle(fontSize: 8.5)),
          ],
          pw.SizedBox(height: 10),
        ],

        // ---------------- Sen z aplikacji
        if (nights.isNotEmpty) ...[
          pw.Text('${cpap.isEmpty ? '1' : '2'}. Sen (pomiar telefonem${nights.any((n) => n.hrAvg != null) ? ', zegarkiem/opaską' : ''})',
              style: h2),
          pw.SizedBox(height: 4),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(
              child: kv([
                ('Zapisane noce', '${nights.length}'),
                ('Średni czas snu', durHM(avg(nights, (n) => n.durationMin.toDouble()) ?? 0)),
                ('Zasypianie (średnio)', '${f(avg(nights, (n) => n.latencyMin.toDouble()), 0)} min'),
                ('Przebudzenia / noc', f(avg(nights, (n) => n.awakenings.toDouble()))),
                ('Sen głęboki', '${f(avg(nights, (n) => n.durationMin > 0 ? n.deepMin / n.durationMin * 100 : null), 0)}%'),
                ('REM', '${f(avg(nights, (n) => n.durationMin > 0 ? n.remMin / n.durationMin * 100 : null), 0)}%'),
              ]),
            ),
            pw.SizedBox(width: 14),
            pw.Expanded(
              child: kv([
                ('Chrapanie (min / noc)', f(avg(nights, (n) => n.snoreMin.toDouble()), 0)),
                ('Przerwy w oddechu z mikrofonu/sonaru (/h)', f(avg(nights, (n) => n.apneaIndex))),
                if (nights.any((n) => n.spo2Avg != null)) ('SpO₂ średnio / minimum', '${f(avg(nights, (n) => n.spo2Avg), 0)}% / ${f(nights.map((n) => n.spo2Min).whereType<double>().fold<double>(100, min), 0)}%'),
                if (nights.any((n) => n.odi != null)) ('ODI (spadki ≥ 3% / h)', f(avg(nights, (n) => n.odi))),
                if (nights.any((n) => n.hrAvg != null)) ('Tętno w nocy (średnio)', f(avg(nights, (n) => n.hrAvg), 0)),
              ]),
            ),
          ]),
          pw.SizedBox(height: 4),
          pw.Text(
              'Fazy snu z telefonu są szacunkiem (ruch, oddech, dźwięk), nie polisomnografią. '
              'Przerwy w oddechu z mikrofonu/sonaru to wskazówka, nie wynik badania.',
              style: small),
          pw.SizedBox(height: 10),
        ],

        // ---------------- Pozycja
        if (posNights > 0) ...[
          pw.Text('Pozycja ciała a oddech (opaska, $posNights nocy)', style: h2),
          pw.SizedBox(height: 4),
          pw.TableHelper.fromTextArray(
            headers: ['Pozycja', 'Czas', 'Przerwy (aplikacja) /h', 'Zdarzenia aparatu /h', 'Chrapanie'],
            data: [
              for (final p in BodyPos.values)
                if (pos[p]!.minutes >= 20)
                  [
                    p.label,
                    durHM(pos[p]!.minutes),
                    f(pos[p]!.perHour(pos[p]!.appEvents, pos[p]!.minutes)),
                    f(pos[p]!.perHour(pos[p]!.cpapEvents, pos[p]!.cpapMinutes)),
                    '${(pos[p]!.snoreMin / max(1, pos[p]!.minutes) * 100).round()}%',
                  ],
            ],
            headerStyle: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 8.5),
            cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2.5),
          ),
          pw.SizedBox(height: 10),
        ],

        // ---------------- Przykłady
        if (examples.isNotEmpty) ...[
          pw.Text('Przykładowe zdarzenia z aparatu (przepływ, ±45 s)', style: h2),
          pw.SizedBox(height: 4),
          for (final ex in examples) _flowExample(ex, small),
        ],
        if (cpap.isEmpty && nights.isEmpty) pw.Text('Brak danych w wybranym okresie.'),
      ],
    ));

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/raport_snu_${now.year}${two(now.month)}${two(now.day)}.pdf');
    await file.writeAsBytes(await doc.save());
    return file;
  }

  static String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  static List<String> _settingChanges(List<CardDay> ds) {
    final out = <String>[];
    CardDay? prev;
    for (final d in ds) {
      if (prev != null && prev.settingsKey != d.settingsKey) {
        final p = d.isAuto ? '${d.setMin?.toStringAsFixed(1)}–${d.setMax?.toStringAsFixed(1)}' : '${d.setPress?.toStringAsFixed(1)}';
        out.add('${shortDate(d.date)}: ${d.modeName} $p cmH₂O, EPR ${d.eprOn ? d.eprLevel : 'wył.'}, '
            'rampa ${d.rampOn ? '${d.rampTime} min' : 'wył.'}, nawilżacz ${d.humOn ? d.humLevel : 'wył.'}');
      }
      prev = d;
    }
    return out;
  }

  /// Do 4 najdłuższych zdarzeń z ostatnich nocy z pełnym przepływem.
  static Future<List<(CpapEvent, CpapSeries, DateTime)>> _examples(List<CardDay> days) async {
    final out = <(CpapEvent, CpapSeries, DateTime)>[];
    for (final d in days.reversed.take(7)) {
      final det = await CpapStore.detail(d.date);
      final flow = det.series['flow'];
      if (flow == null) continue;
      final evs = [for (final e in det.events) if (const {'oa', 'ca', 'ua', 'h'}.contains(e.kind)) e]
        ..sort((a, b) => b.dur.compareTo(a.dur));
      final seen = <String>{};
      for (final e in evs) {
        if (seen.contains(e.kind)) continue;
        seen.add(e.kind);
        out.add((e, flow, d.date));
        if (out.length >= 4) return out;
      }
      if (out.isNotEmpty) return out;
    }
    return out;
  }

  static pw.Widget _flowExample((CpapEvent, CpapSeries, DateTime) ex, pw.TextStyle small) {
    final (e, flow, day) = ex;
    final t0 = e.t - 45, t1 = e.t + max(e.dur, 10) + 45;
    final pts = <(double, double)>[];
    for (final s in flow.segs) {
      if (s.t1 < t0 || s.t0 > t1) continue;
      final a = max(0, ((t0 - s.t0) / s.dt).floor()), b = min(s.v.length, ((t1 - s.t0) / s.dt).ceil());
      for (var i = a; i < b; i += 2) {
        final v = s.v[i];
        if (!v.isNaN) pts.add((s.t0 + i * s.dt, v));
      }
    }
    final name = cpapEventKinds.firstWhere((k) => k.$1 == e.kind, orElse: () => ('', e.text, '')).$2;
    final m = pts.isEmpty ? 1.0 : pts.map((p) => p.$2.abs()).reduce(max).clamp(1.0, 1000.0);
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Text('${dayLabel(day)} · ${tLabelPdf(e.t)} · $name · ${e.dur.round()} s', style: const pw.TextStyle(fontSize: 8.5)),
      pw.CustomPaint(
        size: const PdfPoint(515, 55),
        painter: (g, size) {
          g.setFillColor(PdfColors.grey100);
          g.drawRect(0, 0, size.x, size.y);
          g.fillPath();
          double x(double t) => (t - t0) / (t1 - t0) * size.x;
          double y(double v) => size.y / 2 + v / m * (size.y / 2 - 2);
          g.setFillColor(PdfColors.amber100);
          g.drawRect(x(e.t), 0, max(1, x(e.t + e.dur) - x(e.t)), size.y);
          g.fillPath();
          g.setStrokeColor(PdfColors.grey400);
          g.setLineWidth(0.3);
          g.moveTo(0, size.y / 2);
          g.lineTo(size.x, size.y / 2);
          g.strokePath();
          if (pts.isEmpty) return;
          g.setStrokeColor(PdfColors.blue700);
          g.setLineWidth(0.6);
          g.moveTo(x(pts.first.$1), y(pts.first.$2));
          for (final p in pts.skip(1)) {
            g.lineTo(x(p.$1), y(p.$2));
          }
          g.strokePath();
        },
      ),
      pw.SizedBox(height: 6),
    ]);
  }

  static String tLabelPdf(double t) {
    final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}

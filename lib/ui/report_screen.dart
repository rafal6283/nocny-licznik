import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../report/doctor_report.dart';
import 'theme.dart';

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  int days = 30;
  final name = TextEditingController();
  bool busy = false;
  File? file;
  String? error;

  Future<void> _make() async {
    setState(() {
      busy = true;
      error = null;
      file = null;
    });
    try {
      final f = await DoctorReport.build(days: days, patient: name.text.trim());
      if (mounted) setState(() => file = f);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/pdf')], subject: 'Raport snu'));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Raport dla lekarza')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'PDF na wizytę: terapia CPAP z karty aparatu (przestrzeganie, AHI i rodzaje zdarzeń, nieszczelność, '
          'ciśnienie, zmiany ustawień, wykresy dzień po dniu), sen z aplikacji, SpO₂ z zegarka, pozycja ciała '
          'i przykładowe zdarzenia z przebiegiem oddechu. Dane z aparatu odświeżysz importem karty SD.',
          style: TextStyle(color: C.muted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 6, children: [
          for (final (d, t) in [(14, '2 tygodnie'), (30, '30 dni'), (90, '90 dni'), (180, 'pół roku'), (365, 'rok')])
            ChoiceChip(label: Text(t), selected: days == d, onSelected: (_) => setState(() => days = d)),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: name,
          decoration: const InputDecoration(labelText: 'Imię i nazwisko (opcjonalnie, tylko w PDF)'),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: busy ? null : _make,
            icon: busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_as_pdf_outlined),
            label: Text(busy ? 'Tworzę raport…' : 'Utwórz i udostępnij PDF'),
          ),
        ),
        if (file != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: OutlinedButton.icon(
              onPressed: () => SharePlus.instance.share(ShareParams(files: [XFile(file!.path, mimeType: 'application/pdf')])),
              icon: const Icon(Icons.share),
              label: const Text('Udostępnij ponownie'),
            ),
          ),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: C.danger))),
      ]),
    );
  }
}

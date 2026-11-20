import 'package:flutter/material.dart';
import 'package:koofr_sync/koofr_sync.dart';

/// „Stan wymiany”: co ta aplikacja wysyła, co leży na Koofr od innych aplikacji tej osoby,
/// kiedy zostało wczytane i czy były błędy. Wspólny dla wszystkich aplikacji Fluttera.
class ExchangeStatusScreen extends StatefulWidget {
  final KoofrSync sync;

  /// Przedrostki źródeł, które ta aplikacja pobiera (jak w ExchangeAdapter.sources).
  final List<String> sources;

  /// Pliki, które ta aplikacja wysyła (do pokazania, nawet zanim pierwszy raz poszły).
  final List<String> publishes;

  const ExchangeStatusScreen({super.key, required this.sync, required this.sources, this.publishes = const []});

  @override
  State<ExchangeStatusScreen> createState() => _ExchangeStatusScreenState();
}

class _ExchangeStatusScreenState extends State<ExchangeStatusScreen> {
  Map<String, (DateTime?, int)>? remote;
  Map<String, ExchangeLogEntry> log = {};
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => error = null);
    final l = await widget.sync.exchangeLog();
    Map<String, (DateTime?, int)>? r;
    String? err;
    try {
      r = await widget.sync.exchangeFiles();
    } catch (e) {
      err = 'Nie udało się odczytać plików z Koofr: $e';
    }
    if (!mounted) return;
    setState(() {
      log = l;
      remote = r ?? {};
      error = err;
    });
  }

  bool _pulls(String name) => widget.sources.any((s) => zrodloPasuje(s, name));

  @override
  Widget build(BuildContext context) {
    final r = remote;
    final mine = {...widget.publishes, ...log.entries.where((e) => e.value.sent != null).map((e) => e.key)}.toList()
      ..sort();
    final others = r == null
        ? <String>[]
        : (r.keys.where((n) => !mine.contains(n)).toList()
          ..sort((a, b) => (_pulls(b) ? 1 : 0).compareTo(_pulls(a) ? 1 : 0)));
    return Scaffold(
      appBar: AppBar(title: const Text('Stan wymiany'), actions: [
        IconButton(icon: const Icon(Icons.refresh), tooltip: 'Odśwież', onPressed: _load),
      ]),
      body: r == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
                if (error != null)
                  ListTile(
                    leading: Icon(Icons.cloud_off, color: Theme.of(context).colorScheme.error),
                    title: Text(error!),
                  ),
                _head(context, 'Wysyłane z tej aplikacji'),
                if (mine.isEmpty) const ListTile(dense: true, title: Text('Ta aplikacja nic jeszcze nie wysłała.')),
                for (final n in mine) _sent(context, n, r[n]),
                _head(context, 'Od innych aplikacji'),
                if (others.isEmpty)
                  const ListTile(dense: true, title: Text('Na Koofr nie ma jeszcze plików od innych aplikacji.')),
                for (final n in others) _received(context, n, r[n]!),
                const ListTile(
                  dense: true,
                  leading: Icon(Icons.info_outline, size: 20),
                  title: Text('Pliki widzą tylko aplikacje z tym samym kodem odzyskiwania. Plik, który długo się '
                      'nie zmienia, zwykle oznacza, że aplikacja-nadawca nie była ostatnio otwierana.'),
                ),
              ]),
            ),
    );
  }

  Widget _head(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );

  String _title(String name) => plikWymiany(name)?.opis ?? name;

  Widget _sent(BuildContext context, String name, (DateTime?, int)? onServer) {
    final e = log[name];
    final p = plikWymiany(name);
    final readers = p == null ? '' : p.odbiorcy.map((o) => nazwyAplikacji[o] ?? o).join(', ');
    final lines = <String>[
      if (e?.sent != null) 'Wysłano ${_ago(e!.sent!)}' else if (onServer != null) 'Na Koofr od ${_ago(onServer.$1)}',
      if (e?.sent == null && onServer == null) 'Jeszcze nie wysłano',
      if (readers.isNotEmpty) 'Czytają: $readers',
    ];
    final warn = e?.problems ?? const [];
    return ListTile(
      leading: Icon(warn.isEmpty ? Icons.upload : Icons.warning_amber, color: warn.isEmpty ? null : Colors.orange),
      title: Text(_title(name)),
      subtitle: Text([...lines, if (warn.isNotEmpty) 'Niezgodność z kontraktem: ${warn.take(3).join('; ')}'].join('\n')),
      isThreeLine: lines.length + (warn.isEmpty ? 0 : 1) > 1,
    );
  }

  Widget _received(BuildContext context, String name, (DateTime?, int) onServer) {
    final p = plikWymiany(name);
    final from = p == null ? 'nieznana aplikacja' : (nazwyAplikacji[p.nadawca] ?? p.nadawca);
    final e = log[name];
    final pulls = _pulls(name);
    final stale = onServer.$1 != null && DateTime.now().difference(onServer.$1!).inDays >= 7;
    final err = e?.error;
    final lines = <String>[
      'Od: $from · zmieniony ${_ago(onServer.$1)}${stale ? ' (dawno)' : ''}',
      if (!pulls) 'Ta aplikacja go nie używa',
      if (pulls && err == null) e?.received == null ? 'Jeszcze nie wczytany' : 'Wczytany ${_ago(e!.received!)}',
      if (err != null) 'Błąd ${_ago(e!.errorAt)}: $err',
    ];
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      enabled: pulls,
      leading: Icon(
        err != null ? Icons.error_outline : (pulls ? (stale ? Icons.schedule : Icons.download_done) : Icons.remove),
        color: err != null ? scheme.error : (stale && pulls ? Colors.orange : null),
      ),
      title: Text(_title(name)),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 1,
    );
  }

  static String _ago(DateTime? t) {
    if (t == null) return 'nie wiadomo kiedy';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'przed chwilą';
    if (d.inMinutes < 60) return '${d.inMinutes} min temu';
    if (d.inHours < 24) return '${d.inHours} h temu';
    if (d.inDays == 1) return 'wczoraj';
    if (d.inDays < 30) return '${d.inDays} dni temu';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)}.${t.year}';
  }
}

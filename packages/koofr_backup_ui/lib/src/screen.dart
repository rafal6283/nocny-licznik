import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:koofr_sync/koofr_sync.dart';

import 'backup.dart';

/// Pozycja do ustawień aplikacji, otwierająca [KoofrBackupScreen].
class KoofrBackupTile extends StatelessWidget {
  final KoofrConfig? suggestedConfig;
  const KoofrBackupTile({super.key, this.suggestedConfig});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cloud_outlined),
      title: const Text('Kopia zapasowa (Koofr)'),
      subtitle: const Text('Szyfrowana kopia na rodzinnym koncie Koofr'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => KoofrBackupScreen(suggestedConfig: suggestedConfig)),
      ),
    );
  }
}

/// Połączenie z kontem, wybór osoby z rodziny, kopia i przywracanie.
class KoofrBackupScreen extends StatefulWidget {
  /// Dane logowania, które aplikacja już zna (np. z synchronizacji rodzinnej) — do podpowiedzi.
  final KoofrConfig? suggestedConfig;
  const KoofrBackupScreen({super.key, this.suggestedConfig});

  @override
  State<KoofrBackupScreen> createState() => _KoofrBackupScreenState();
}

class _KoofrBackupScreenState extends State<KoofrBackupScreen> {
  final kb = KoofrBackup.instance;
  KoofrSync get sync => kb.sync;
  bool loading = true;
  bool working = false;
  String? error;
  List<Member> members = [];
  bool backupOn = false;
  bool wifiOnly = true;
  DateTime? lastBackup;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = sync.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _refresh();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      wifiOnly = await kb.wifiOnly();
      if (sync.connected) members = await sync.members();
      if (sync.ready) {
        backupOn = await sync.backupEnabled();
        lastBackup = await sync.lastBackup();
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  Future<T?> _act<T>(Future<T> Function() f, {String? ok, bool refresh = true}) async {
    setState(() => working = true);
    try {
      final r = await f();
      if (ok != null) _snack(ok);
      if (refresh) await _refresh();
      return r;
    } catch (e) {
      _snack('$e');
      return null;
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  void _snack(String t) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  static String _initial(String name) => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kopia zapasowa'),
        actions: [if (sync.connected) IconButton(icon: const Icon(Icons.refresh), onPressed: working ? null : _refresh)],
        bottom: working
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: loading && members.isEmpty && sync.connected
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                if (error != null) _errorCard(error!),
                if (!sync.connected)
                  _ConnectForm(
                    suggested: widget.suggestedConfig,
                    appName: kb.adapter.appName,
                    onConnect: (c) => _act(() => sync.connect(c), ok: 'Połączono z Koofr'),
                  )
                else if (!sync.ready)
                  ..._joinView()
                else
                  ..._readyView(),
              ],
            ),
    );
  }

  Widget _errorCard(String e) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: ListTile(leading: const Icon(Icons.error_outline), title: Text(e)),
      );

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(t.toUpperCase(),
            style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700)),
      );

  Widget _muted(String t, {double size = 13}) =>
      Text(t, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: size));

  // ------------------------------------------------------------ wybór osoby

  List<Widget> _joinView() => [
        _head('Kim jesteś?'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: _muted('Jedno konto Koofr służy całej rodzinie. Wybierz siebie z listy albo dodaj nową osobę. '
              'Każda osoba ma własny kod odzyskiwania — ten sam we wszystkich rodzinnych aplikacjach.'),
        ),
        Card(
          child: Column(children: [
            for (final m in members)
              ListTile(
                leading: CircleAvatar(child: Text(_initial(m.name))),
                title: Text(m.name),
                subtitle: Text(m.keys.containsKey(sync.appId)
                    ? 'Używa już tej aplikacji'
                    : 'Podłączona w innej aplikacji — wpisz ten sam kod'),
                trailing: const Icon(Icons.chevron_right),
                onTap: working ? null : () => _joinExisting(m),
              ),
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_add_alt)),
              title: const Text('Nowa osoba'),
              subtitle: const Text('Pierwszy raz w którejkolwiek z rodzinnych aplikacji'),
              onTap: working ? null : _joinNew,
            ),
          ]),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          icon: const Icon(Icons.link_off),
          label: const Text('Odłącz konto Koofr'),
          onPressed: working ? null : () => _act(sync.disconnect, ok: 'Odłączono'),
        ),
      ];

  Future<void> _joinExisting(Member m) async {
    final ctl = TextEditingController();
    final code = await showDialog<RecoveryCode>(
      context: context,
      builder: (c) {
        String? err;
        return StatefulBuilder(
          builder: (c, set) => AlertDialog(
            title: Text('Kod odzyskiwania: ${m.name}'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Wpisz kod zapisany przy pierwszym podłączeniu tej osoby (32 znaki, myślniki dowolnie).'),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(hintText: 'XXXX-XXXX-…', errorText: err),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('Anuluj')),
              FilledButton(
                onPressed: () async {
                  final r = await RecoveryCode.parse(ctl.text);
                  if (r == null) {
                    set(() => err = 'Niepełny kod albo literówka');
                  } else if (c.mounted) {
                    Navigator.pop(c, r);
                  }
                },
                child: const Text('Dalej'),
              ),
            ],
          ),
        );
      },
    );
    if (code == null) return;
    await _act(() => sync.join(existingId: m.id, code: code), ok: 'Witaj, ${m.name}!');
  }

  Future<void> _joinNew() async {
    final nameCtl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nowa osoba'),
        content: TextField(
          controller: nameCtl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Imię, np. Rafał'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, nameCtl.text.trim()), child: const Text('Dalej')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    if (members.any((m) => m.name.toLowerCase() == name.toLowerCase())) {
      _snack('„$name” już jest na liście — wybierz tę osobę i wpisz jej kod.');
      return;
    }
    final code = await RecoveryCode.generate();
    final text = await code.format();
    if (!mounted) return;
    final saved = await _showCode(
      title: 'Kod odzyskiwania: $name',
      text: text,
      info: 'Zapisz go (np. w menedżerze haseł albo na kartce). Bez niego nie odtworzysz kopii '
          'po zgubieniu telefonu i nie podłączysz innych aplikacji jako ta sama osoba. '
          'Nikt — także Koofr — nie odzyska go za Ciebie.',
      requireConfirm: true,
    );
    if (saved != true) return;
    await _act(() => sync.join(newName: name, code: code), ok: 'Witaj, $name!');
  }

  Future<bool?> _showCode(
      {required String title, required String text, required String info, bool requireConfirm = false}) {
    var confirmed = false;
    return showDialog<bool>(
      context: context,
      barrierDismissible: !requireConfirm,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: Theme.of(c).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
                child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.5)),
              ),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Kopiuj'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  _snack('Skopiowano');
                },
              ),
              _muted(info),
              if (requireConfirm)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: confirmed,
                  onChanged: (v) => set(() => confirmed = v ?? false),
                  title: const Text('Zapisałem kod'),
                ),
            ]),
          ),
          actions: [
            if (requireConfirm) TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
            FilledButton(
              onPressed: requireConfirm && !confirmed ? null : () => Navigator.pop(c, true),
              child: Text(requireConfirm ? 'Dalej' : 'Zamknij'),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ połączone

  Member? get _me => members.where((m) => m.id == sync.userId).firstOrNull;

  List<Widget> _readyView() => [
        _head('Konto'),
        Card(
          child: Column(children: [
            ListTile(
              leading: CircleAvatar(child: Text(_initial(_me?.name ?? ''))),
              title: Text(_me?.name ?? sync.userId ?? ''),
              subtitle: Text('${sync.config!.email} · folder „${sync.config!.root}”'),
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_2),
              title: const Text('Kod konfiguracji dla innego telefonu'),
              onTap: () => _showCode(
                title: 'Kod konfiguracji',
                text: sync.config!.toCode(),
                info: 'Wklejasz go w innej aplikacji lub na innym telefonie zamiast e-maila i hasła. '
                    'Zawiera hasło aplikacji Koofr — przekaż go tylko domownikom.',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Mój kod odzyskiwania'),
              onTap: () => _showCode(
                title: 'Kod odzyskiwania',
                text: sync.recoveryCode ?? '',
                info: 'Ten sam kod wpisujesz w innych rodzinnych aplikacjach i na nowym telefonie.',
              ),
            ),
            ListTile(
              leading: Icon(Icons.link_off, color: Theme.of(context).colorScheme.error),
              title: const Text('Odłącz ten telefon'),
              subtitle: const Text('Kopie na Koofr zostają'),
              onTap: working ? null : _disconnect,
            ),
          ]),
        ),
        _head('Kopia zapasowa'),
        ValueListenableBuilder<String?>(
          valueListenable: kb.lastError,
          builder: (c, e, _) => e == null ? const SizedBox() : _errorCard('Ostatnia automatyczna kopia: $e'),
        ),
        Card(
          child: Column(children: [
            SwitchListTile(
              secondary: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Automatyczna kopia'),
              subtitle: const Text('Raz na dobę, przy otwarciu aplikacji'),
              value: backupOn,
              onChanged: working
                  ? null
                  : (v) => _act(() async {
                        await sync.setBackupEnabled(v);
                        if (v) unawaited(kb.autoRun());
                      }),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.wifi),
              title: const Text('Tylko przez Wi-Fi'),
              subtitle: const Text('Dotyczy kopii automatycznej'),
              value: wifiOnly,
              onChanged: (v) => _act(() => kb.setWifiOnly(v)),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: kb.progress,
              builder: (c, p, _) => ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Zrób kopię teraz'),
                subtitle: Text(p ??
                    (lastBackup == null
                        ? 'Jeszcze nie było kopii z tego telefonu'
                        : 'Ostatnia: ${_date(lastBackup!)}')),
                onTap: working ? null : () => _act(kb.backupNow, ok: 'Kopia zapisana na Koofr'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Przywróć z kopii'),
              subtitle: const Text('Zastępuje dane na tym telefonie'),
              onTap: working ? null : _pickRestore,
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.info_outline, size: 20),
              title: Text('${kb.adapter.contentNote} Wszystko jest szyfrowane na telefonie. '
                  'Zostaje 7 ostatnich dni i po jednej kopii z 4 wcześniejszych tygodni.'),
            ),
          ]),
        ),
        if (kb.adapter.exchange != null) ...[
          _head('Wymiana z moimi aplikacjami'),
          _ExchangeCard(kb: kb),
        ],
      ];

  static String _date(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.day}.${two(t.month)}.${t.year}, ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Odłączyć ten telefon?'),
        content: const Text('Kopie na Koofr zostaną. Żeby podłączyć się ponownie, będzie potrzebny kod odzyskiwania.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Odłącz')),
        ],
      ),
    );
    if (ok == true) await _act(sync.disconnect, ok: 'Telefon odłączony');
  }

  Future<void> _pickRestore() async {
    final list = await _act(sync.backups, refresh: false);
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      _snack('Na Koofr nie ma jeszcze Twoich kopii.');
      return;
    }
    final b = await showModalBottomSheet<BackupInfo>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Wybierz kopię', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            for (final b in list)
              ListTile(
                leading: Icon(b.device == sync.deviceId ? Icons.smartphone : Icons.devices_other),
                title: Text(_date(b.at)),
                subtitle: Text('${(b.size / 1024 / 1024).toStringAsFixed(1)} MB bez załączników · '
                    '${b.device == sync.deviceId ? 'ten telefon' : 'inny telefon'}'),
                onTap: () => Navigator.pop(c, b),
              ),
          ]),
        ),
      ),
    );
    if (b == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Przywrócić tę kopię?'),
        content: Text('Kopia z ${_date(b.at)}.\n\n${kb.adapter.restoreWarning}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Przywróć')),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => kb.restore(b), ok: 'Przywrócono kopię');
  }
}

class _ConnectForm extends StatefulWidget {
  final Future<void> Function(KoofrConfig) onConnect;
  final KoofrConfig? suggested;
  final String appName;
  const _ConnectForm({required this.onConnect, required this.appName, this.suggested});

  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
  late final email = TextEditingController(text: widget.suggested?.email ?? '');
  late final pass = TextEditingController(text: widget.suggested?.appPassword ?? '');
  late final root = TextEditingController(text: widget.suggested?.root ?? 'Rodzina');
  bool hide = true;
  bool busy = false;

  Future<void> _go() async {
    if (email.text.trim().isEmpty || pass.text.trim().isEmpty) return;
    setState(() => busy = true);
    await widget.onConnect(KoofrConfig(
        email: email.text, appPassword: pass.text, root: root.text.trim().isEmpty ? 'Rodzina' : root.text.trim()));
    if (mounted) setState(() => busy = false);
  }

  Future<void> _paste() async {
    final ctl = TextEditingController();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (clip?.text?.startsWith('KSYNC1:') == true) ctl.text = clip!.text!;
    if (!mounted) return;
    final c = await showDialog<KoofrConfig>(
      context: context,
      builder: (d) {
        String? err;
        return StatefulBuilder(
          builder: (d, set) => AlertDialog(
            title: const Text('Kod konfiguracji'),
            content: TextField(
              controller: ctl,
              maxLines: 3,
              decoration: InputDecoration(hintText: 'KSYNC1:…', errorText: err),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(d), child: const Text('Anuluj')),
              FilledButton(
                onPressed: () {
                  final c = KoofrConfig.fromCode(ctl.text);
                  if (c == null) {
                    set(() => err = 'To nie jest poprawny kod');
                  } else {
                    Navigator.pop(d, c);
                  }
                },
                child: const Text('Połącz'),
              ),
            ],
          ),
        );
      },
    );
    if (c == null) return;
    email.text = c.email;
    pass.text = c.appPassword;
    root.text = c.root;
    await _go();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Szyfrowana kopia zapasowa aplikacji ${widget.appName} na wspólnym, rodzinnym koncie Koofr. '
          'Dane są szyfrowane na telefonie, zanim trafią do Koofr. Domyślnie nic nie jest wysyłane.',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.suggested != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('Uzupełniono danymi z synchronizacji rodzinnej.', style: muted),
              ),
            FilledButton.tonalIcon(
              onPressed: busy ? null : _paste,
              icon: const Icon(Icons.content_paste),
              label: const Text('Wklej kod konfiguracji z innej aplikacji'),
            ),
            const SizedBox(height: 12),
            Text('albo wpisz ręcznie:', style: muted),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'E-mail konta Koofr'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pass,
              obscureText: hide,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Hasło aplikacji',
                suffixIcon: IconButton(
                  icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => hide = !hide),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Utwórz je na app.koofr.net w ustawieniach konta, w sekcji haseł aplikacji (nie podawaj hasła do konta).',
              style: muted,
            ),
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Folder na Koofr', style: TextStyle(fontSize: 14)),
                children: [
                  TextField(
                    controller: root,
                    decoration: const InputDecoration(helperText: 'Taki sam we wszystkich rodzinnych aplikacjach'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: busy ? null : _go,
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Połącz'),
            ),
          ]),
        ),
      ),
    ]);
  }
}

/// Automatyczna wymiana danych z innymi aplikacjami tej samej osoby.
class _ExchangeCard extends StatefulWidget {
  final KoofrBackup kb;
  const _ExchangeCard({required this.kb});

  @override
  State<_ExchangeCard> createState() => _ExchangeCardState();
}

class _ExchangeCardState extends State<_ExchangeCard> {
  bool loaded = false, on = false, publish = true, busy = false;
  final src = <String, bool>{};

  ExchangeAdapter get ex => widget.kb.adapter.exchange!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final kb = widget.kb;
    on = await kb.exchangeOn();
    publish = await kb.publishOn();
    for (final s in ex.sources) {
      src[s.$1] = await kb.sourceOn(s.$1);
    }
    if (mounted) setState(() => loaded = true);
  }

  Future<void> _run({bool force = true}) async {
    setState(() => busy = true);
    try {
      await widget.kb.exchangeNow(force: force);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!loaded) return const SizedBox(height: 48);
    final kb = widget.kb;
    final extra = on ? ex.extraSettings(context) : null;
    return Card(
      child: Column(children: [
        SwitchListTile(
          secondary: const Icon(Icons.swap_horiz),
          title: const Text('Automatyczna wymiana danych'),
          subtitle: const Text('Przez Koofr, bez ręcznego eksportu plików. Widzą je tylko Twoje aplikacje '
              '(ten sam kod odzyskiwania).'),
          value: on,
          onChanged: (v) async {
            await kb.setExchangeOn(v);
            setState(() => on = v);
            if (v) unawaited(_run());
          },
        ),
        if (on) ...[
          if (ex.publishes != null)
            SwitchListTile(
              title: const Text('Udostępniaj moim aplikacjom'),
              subtitle: Text(ex.publishes!),
              value: publish,
              onChanged: (v) async {
                await kb.setPublishOn(v);
                setState(() => publish = v);
                unawaited(_run());
              },
            ),
          for (final s in ex.sources)
            SwitchListTile(
              title: Text('Pobieraj: ${s.$2}'),
              value: src[s.$1] ?? true,
              onChanged: (v) async {
                await kb.setSourceOn(s.$1, v);
                setState(() => src[s.$1] = v);
                if (v) unawaited(_run());
              },
            ),
          if (extra != null) extra,
          ValueListenableBuilder<String?>(
            valueListenable: kb.lastExchange,
            builder: (c, last, _) => ListTile(
              leading: busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              title: const Text('Wymień teraz'),
              subtitle: Text(last == null ? 'Automatycznie przy otwarciu aplikacji' : 'Ostatnio: $last'),
              onTap: busy ? null : _run,
            ),
          ),
        ],
      ]),
    );
  }
}

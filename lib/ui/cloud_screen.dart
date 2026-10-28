import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:koofr_sync/koofr_sync.dart';
import 'package:share_plus/share_plus.dart';

import '../core/cloud.dart';
import '../core/fmt.dart';
import '../core/settings.dart';
import 'shared_sleep_screen.dart';
import 'theme.dart';

/// Kopia zapasowa i podgląd snu na rodzinnym koncie Koofr.
class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key});

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  final sync = Cloud.sync;
  bool loading = true;
  bool working = false;
  String? error;

  List<Member> members = [];
  List<ShareLink> links = [];
  Map<String, Map<String, Object?>> consents = {};
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
    Cloud.init().then((_) => _refresh());
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
      wifiOnly = await Cloud.wifiOnly();
      if (sync.connected) members = await sync.members();
      if (sync.ready) {
        links = await sync.links();
        consents = await sync.myConsents();
        backupOn = await sync.backupEnabled();
        lastBackup = await sync.lastBackup();
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => loading = false);
  }

  /// Wykonuje akcję z blokadą przycisków i komunikatem o wyniku.
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kopia i rodzina'),
        actions: [
          if (sync.connected) IconButton(icon: const Icon(Icons.refresh), onPressed: working ? null : _refresh),
        ],
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
                  _ConnectForm(onConnect: (c) => _act(() => sync.connect(c), ok: 'Połączono z Koofr'))
                else if (!sync.ready)
                  ..._joinView()
                else
                  ..._readyView(),
              ],
            ),
    );
  }

  static String _initial(String name) => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  Widget _errorCard(String e) => Card(
        color: const Color(0xFF3A1020),
        child: ListTile(leading: const Icon(Icons.error_outline), title: Text(e)),
      );

  Widget _head(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12, letterSpacing: 1.2, color: C.muted, fontWeight: FontWeight.w700)),
      );

  // ============================================================ wybór osoby

  List<Widget> _joinView() => [
        _head('Kim jesteś?'),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'Jedno konto Koofr służy całej rodzinie. Wybierz siebie z listy albo dodaj nową osobę. '
            'Każda osoba ma własny kod odzyskiwania — ten sam we wszystkich aplikacjach.',
            style: TextStyle(color: C.muted),
          ),
        ),
        Card(
          child: Column(children: [
            for (final m in members)
              ListTile(
                leading: CircleAvatar(child: Text(_initial(m.name))),
                title: Text(m.name),
                subtitle: Text(m.keys.containsKey('rytm-snu') ? 'Używa już Rytmu Snu' : 'Podłączona w innej aplikacji'),
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
          'po zgubieniu telefonu i nie podłączysz kolejnych aplikacji jako ta sama osoba. '
          'Nikt — także Koofr — nie odzyska go za Ciebie.',
      requireConfirm: true,
    );
    if (saved != true) return;
    await _act(() => sync.join(newName: name, code: code), ok: 'Witaj, $name!');
  }

  /// Okno z kodem do skopiowania. Przy [requireConfirm] trzeba zaznaczyć, że kod zapisano.
  Future<bool?> _showCode(
      {required String title, required String text, required String info, bool requireConfirm = false}) {
    var confirmed = false;
    return showDialog<bool>(
      context: context,
      barrierDismissible: !requireConfirm,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: C.surface2, borderRadius: BorderRadius.circular(10)),
              child: SelectableText(text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 15, height: 1.5, color: C.moon)),
            ),
            const SizedBox(height: 8),
            Row(children: [
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Kopiuj'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  _snack('Skopiowano');
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.ios_share, size: 18),
                label: const Text('Udostępnij'),
                onPressed: () => SharePlus.instance.share(ShareParams(text: text, subject: title)),
              ),
            ]),
            Text(info, style: const TextStyle(color: C.muted, fontSize: 13)),
            if (requireConfirm)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: confirmed,
                onChanged: (v) => set(() => confirmed = v ?? false),
                title: const Text('Zapisałem kod'),
              ),
          ]),
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

  // ============================================================ połączone

  Member? get _me => members.where((m) => m.id == sync.userId).firstOrNull;
  List<Member> get _others => members.where((m) => m.id != sync.userId).toList();

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
              subtitle: const Text('Wklejasz go na drugim telefonie zamiast wpisywać e-mail i hasło'),
              onTap: () => _showCode(
                title: 'Kod konfiguracji',
                text: sync.config!.toCode(),
                info: 'Zawiera hasło aplikacji Koofr — przekaż go tylko domownikom. '
                    'Bezpieczniej: utwórz w Koofr osobne hasło aplikacji dla każdego telefonu.',
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
              leading: const Icon(Icons.link_off, color: C.danger),
              title: const Text('Odłącz ten telefon'),
              subtitle: const Text('Kopie na Koofr zostają; zgody udzielone z tego telefonu zostaną cofnięte'),
              onTap: working ? null : _disconnect,
            ),
          ]),
        ),
        _head('Kopia zapasowa'),
        Card(
          child: Column(children: [
            SwitchListTile(
              secondary: const Icon(Icons.cloud_upload_outlined),
              title: const Text('Automatyczna kopia'),
              subtitle: const Text('Raz na dobę, przy otwarciu aplikacji lub po zakończeniu nocy'),
              value: backupOn,
              onChanged: working
                  ? null
                  : (v) => _act(() async {
                        await sync.setBackupEnabled(v);
                        if (v) unawaited(Cloud.autoRun());
                      }),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.wifi),
              title: const Text('Tylko przez Wi-Fi'),
              subtitle: const Text('Dotyczy kopii i wysyłki podglądu wykonywanych automatycznie'),
              value: wifiOnly,
              onChanged: (v) => _act(() => Cloud.setWifiOnly(v), refresh: false).then((_) => _refresh()),
            ),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Zrób kopię teraz'),
              subtitle: Text(lastBackup == null
                  ? 'Jeszcze nie było kopii z tego telefonu'
                  : 'Ostatnia: ${dayLabel(lastBackup!)}, ${hhmm(lastBackup!)}'),
              onTap: working
                  ? null
                  : () => _act(() async {
                        final b = await Cloud.backupNow();
                        return b;
                      }, ok: 'Kopia zapisana na Koofr'),
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Przywróć z kopii'),
              subtitle: const Text('Zastępuje noce i ustawienia na tym telefonie'),
              onTap: working ? null : _pickRestore,
            ),
            const ListTile(
              dense: true,
              leading: Icon(Icons.info_outline, size: 20),
              title: Text('W kopii są noce, wykresy i ustawienia. Nagrania dźwięków zostają tylko na telefonie. '
                  'Zostaje 7 ostatnich dni i po jednej kopii z 4 wcześniejszych tygodni.'),
            ),
          ]),
        ),
        if (Settings.instance.detectFarts) ...[
          _head('Wymiana z moimi aplikacjami'),
          const _ExchangeCard(),
        ],
        _head('Podgląd snu'),
        ValueListenableBuilder<String?>(
          valueListenable: Cloud.lastError,
          builder: (c, e, _) => e == null ? const SizedBox() : _errorCard('Ostatnia automatyczna wysyłka: $e'),
        ),
        Card(
          child: Column(children: [
            if (_others.isEmpty)
              const ListTile(
                leading: Icon(Icons.group_outlined),
                title: Text('Nikt inny jeszcze się nie podłączył'),
                subtitle: Text('Gdy domownicy podłączą swoje aplikacje do tego konta, pojawią się tutaj.'),
              ),
            for (final m in _others)
              ListTile(
                leading: CircleAvatar(child: Text(_initial(m.name))),
                title: Text(m.name),
                subtitle: Text(_summary(m)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _memberSheet(m),
              ),
            if (consents.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.send_outlined),
                title: const Text('Wyślij podgląd teraz'),
                subtitle: const Text('Automatycznie: po każdej nocy i przy otwarciu aplikacji'),
                onTap: working ? null : () => _act(Cloud.publish).then((n) => _snack('Wysłano do osób: ${n ?? 0}')),
              ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Podgląd działa tylko za zgodą obu osób i każda może go w dowolnej chwili wyłączyć. '
            'Dane są szyfrowane na telefonie kluczem osoby oglądającej — nikt inny, także właściciel konta Koofr, ich nie odczyta.',
            style: TextStyle(color: C.muted, fontSize: 12),
          ),
        ),
      ];

  ShareLink? _link(String owner, String viewer) =>
      links.where((l) => l.owner == owner && l.viewer == viewer).firstOrNull;

  String _summary(Member m) {
    if (!m.keys.containsKey('rytm-snu')) return 'Nie używa jeszcze Rytmu Snu';
    final mine = _link(sync.userId!, m.id);
    final theirs = _link(m.id, sync.userId!);
    final parts = <String>[];
    if (mine != null) {
      parts.add(mine.active
          ? 'widzi Twój sen'
          : mine.ownerAgreed
              ? 'czeka na przyjęcie Twojego snu'
              : 'prosi o Twój sen');
    }
    if (theirs != null) {
      parts.add(theirs.active
          ? 'widzisz sen tej osoby'
          : theirs.viewerAgreed
              ? 'czekasz na zgodę'
              : 'chce Ci pokazać swój sen');
    }
    return parts.isEmpty ? 'Brak podglądu' : parts.join(' · ');
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Odłączyć ten telefon?'),
        content: const Text('Kopie na Koofr zostaną. Żeby podłączyć się ponownie, będzie potrzebny Twój kod odzyskiwania.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Odłącz')),
        ],
      ),
    );
    if (ok == true) await _act(sync.disconnect, ok: 'Telefon odłączony');
  }

  // ------------------------------------------------------------ przywracanie

  Future<void> _pickRestore() async {
    final list = await _act(sync.backups, refresh: false);
    if (list == null || !mounted) return;
    if (list.isEmpty) {
      _snack('Na Koofr nie ma jeszcze Twoich kopii.');
      return;
    }
    final b = await showModalBottomSheet<BackupInfo>(
      context: context,
      backgroundColor: C.surface,
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
                title: Text('${dayLabel(b.at)} ${b.at.year}, ${hhmm(b.at)}'),
                subtitle: Text('${(b.size / 1024 / 1024).toStringAsFixed(1)} MB · '
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
        content: Text('Noce i ustawienia z ${dayLabel(b.at)}, ${hhmm(b.at)} zastąpią obecne dane na tym telefonie. '
            'Obecna baza zostanie odłożona na telefonie jako zapas.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Przywróć')),
        ],
      ),
    );
    if (ok != true) return;
    final n = await _act(() => Cloud.restore(b));
    if (n != null) _snack('Przywrócono kopię · nocy: $n');
  }

  // ------------------------------------------------------------ podgląd z jedną osobą

  Future<void> _memberSheet(Member m) async {
    final safety = await sync.safetyNumberWith(m.id);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.surface,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(m.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            if (!m.keys.containsKey('rytm-snu'))
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Ta osoba nie podłączyła jeszcze Rytmu Snu do Koofr. '
                    'Gdy to zrobi, będzie można ustawić podgląd.'),
              )
            else ...[
              const SizedBox(height: 16),
              ..._mineSection(c, m),
              const Divider(height: 28),
              ..._theirsSection(c, m),
              if (safety != null) ...[
                const Divider(height: 28),
                const Text('Kod bezpieczeństwa', style: TextStyle(color: C.muted, fontSize: 12)),
                const SizedBox(height: 4),
                SelectableText(safety, style: const TextStyle(fontFamily: 'monospace', fontSize: 18, color: C.moon)),
                const SizedBox(height: 4),
                const Text('Na telefonie drugiej osoby powinien być identyczny. Jeśli się różni, '
                    'ktoś podmienił klucz — nie włączajcie podglądu.',
                    style: TextStyle(color: C.muted, fontSize: 12)),
              ],
            ],
          ]),
        ),
      ),
    );
  }

  List<Widget> _mineSection(BuildContext sheet, Member m) {
    final l = _link(sync.userId!, m.id);
    final mineHere = consents.containsKey(m.id);
    Future<void> close() async => Navigator.pop(sheet);
    String status;
    final actions = <Widget>[];
    if (l == null) {
      status = 'Nie udostępniasz swojego snu.';
      actions.add(FilledButton.tonal(
        onPressed: () async {
          final scope = await _pickScope(m, ShareScope.defaults());
          if (scope == null) return;
          await close();
          await _act(() async {
            await sync.allowView(m.id, scope);
            await Cloud.publish();
          }, ok: 'Wysłano propozycję — ${m.name} musi ją przyjąć');
        },
        child: const Text('Udostępnij mój sen'),
      ));
    } else if (!l.ownerAgreed) {
      status = '${m.name} prosi o podgląd Twojego snu.';
      actions.addAll([
        FilledButton(
          onPressed: () async {
            final scope = await _pickScope(m, ShareScope.defaults());
            if (scope == null) return;
            await close();
            await _act(() async {
              await sync.allowView(m.id, scope);
              await Cloud.publish();
            }, ok: '${m.name} widzi teraz Twój sen');
          },
          child: const Text('Zgódź się'),
        ),
        OutlinedButton(
          onPressed: () async {
            await close();
            await _act(() => sync.dismissLink(sync.userId!, m.id), ok: 'Odrzucono');
          },
          child: const Text('Odrzuć'),
        ),
      ]);
    } else {
      status = l.active
          ? '${m.name} widzi Twój sen${l.since != null ? ' od ${dayLabel(l.since!)}' : ''}.'
          : 'Czekasz, aż ${m.name} przyjmie podgląd.';
      if (!mineHere) status += '\nZgoda udzielona z innego telefonu — stamtąd są wysyłane dane.';
      actions.addAll([
        if (mineHere)
          OutlinedButton(
            onPressed: () async {
              final scope = await _pickScope(m, {...ShareScope.defaults(), ...l.scope});
              if (scope == null) return;
              await close();
              await _act(() async {
                await sync.allowView(m.id, scope);
                await Cloud.publish();
              }, ok: 'Zmieniono zakres');
            },
            child: const Text('Zmień zakres'),
          ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: C.danger),
          onPressed: () async {
            await close();
            await _act(() => sync.revokeAsOwner(m.id), ok: 'Wyłączono podgląd Twojego snu');
          },
          child: const Text('Wyłącz'),
        ),
      ]);
    }
    return [
      const Text('MÓJ SEN DLA TEJ OSOBY', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: C.muted)),
      const SizedBox(height: 6),
      Text(status),
      if (l != null && l.ownerAgreed && l.scope.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_scopeText(l.scope), style: const TextStyle(color: C.muted, fontSize: 13)),
        ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: actions),
    ];
  }

  List<Widget> _theirsSection(BuildContext sheet, Member m) {
    final l = _link(m.id, sync.userId!);
    Future<void> close() async => Navigator.pop(sheet);
    String status;
    final actions = <Widget>[];
    if (l == null) {
      status = 'Nie widzisz snu tej osoby.';
      actions.add(FilledButton.tonal(
        onPressed: () async {
          await close();
          await _act(() => sync.requestView(m.id), ok: 'Wysłano prośbę do: ${m.name}');
        },
        child: const Text('Poproś o podgląd'),
      ));
    } else if (!l.viewerAgreed) {
      status = '${m.name} chce Ci pokazać swój sen.\n${_scopeText(l.scope)}';
      actions.addAll([
        FilledButton(
          onPressed: () async {
            await close();
            await _act(() => sync.requestView(m.id), ok: 'Przyjęto — dane pojawią się po wysyłce z telefonu ${m.name}');
          },
          child: const Text('Przyjmij'),
        ),
        OutlinedButton(
          onPressed: () async {
            await close();
            await _act(() => sync.dismissLink(m.id, sync.userId!), ok: 'Odrzucono');
          },
          child: const Text('Odrzuć'),
        ),
      ]);
    } else {
      status = l.active ? 'Widzisz sen tej osoby.\n${_scopeText(l.scope)}' : 'Czekasz na zgodę: ${m.name}.';
      actions.addAll([
        if (l.active)
          FilledButton(
            onPressed: () async {
              await close();
              if (!mounted) return;
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SharedSleepScreen(owner: m)));
            },
            child: const Text('Otwórz'),
          ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: C.danger),
          onPressed: () async {
            await close();
            await _act(() => sync.revokeAsViewer(m.id), ok: l.active ? 'Zrezygnowano z podglądu' : 'Wycofano prośbę');
          },
          child: Text(l.active ? 'Zrezygnuj' : 'Wycofaj prośbę'),
        ),
      ]);
    }
    return [
      const Text('SEN TEJ OSOBY DLA MNIE', style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: C.muted)),
      const SizedBox(height: 6),
      Text(status),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: actions),
    ];
  }

  String _scopeText(Map<String, Object?> s) {
    final days = (s[ShareScope.days] as num?)?.toInt();
    final items = [
      for (final k in [
        ShareScope.stages,
        ShareScope.snore,
        ShareScope.breath,
        ShareScope.cpap,
        ShareScope.watch,
        ShareScope.notes,
        ShareScope.farts,
      ])
        if (s[k] == true) ShareScope.label(k).toLowerCase(),
    ];
    return 'Zakres: ${days != null ? 'ostatnie $days dni' : 'noce'}, czas i jakość snu'
        '${items.isEmpty ? '' : ', ${items.join(', ')}'}.';
  }

  Future<Map<String, Object?>?> _pickScope(Member m, Map<String, Object?> initial) {
    final s = {...initial};
    final keys = [
      ShareScope.stages,
      ShareScope.snore,
      ShareScope.breath,
      ShareScope.cpap,
      ShareScope.watch,
      ShareScope.notes,
      // wiatry wyłącznie przy włączonym liczeniu — inaczej żadnego śladu tej funkcji
      if (Settings.instance.detectFarts) ShareScope.farts,
    ];
    if (!Settings.instance.detectFarts) s[ShareScope.farts] = false;
    return showDialog<Map<String, Object?>>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text('Co zobaczy ${m.name}?'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.check),
                title: Text('Czas snu, ocena i proporcje faz — zawsze'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Okres'),
                trailing: DropdownButton<int>(
                  value: (s[ShareScope.days] as num?)?.toInt() ?? 30,
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 7, child: Text('7 dni')),
                    DropdownMenuItem(value: 30, child: Text('30 dni')),
                    DropdownMenuItem(value: 90, child: Text('90 dni')),
                    DropdownMenuItem(value: 365, child: Text('rok')),
                  ],
                  onChanged: (v) => set(() => s[ShareScope.days] = v),
                ),
              ),
              for (final k in keys)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s[k] == true,
                  onChanged: (v) => set(() => s[k] = v ?? false),
                  title: Text(ShareScope.label(k)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Anuluj')),
            FilledButton(onPressed: () => Navigator.pop(c, s), child: const Text('Zgadzam się')),
          ],
        ),
      ),
    );
  }
}

/// Pierwsze połączenie z kontem Koofr.
class _ConnectForm extends StatefulWidget {
  final Future<void> Function(KoofrConfig) onConnect;
  const _ConnectForm({required this.onConnect});

  @override
  State<_ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<_ConnectForm> {
  final email = TextEditingController();
  final pass = TextEditingController();
  final root = TextEditingController(text: 'Rodzina');
  bool hide = true;
  bool busy = false;

  Future<void> _go() async {
    if (email.text.trim().isEmpty || pass.text.trim().isEmpty) return;
    setState(() => busy = true);
    await widget.onConnect(
        KoofrConfig(email: email.text, appPassword: pass.text, root: root.text.trim().isEmpty ? 'Rodzina' : root.text.trim()));
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
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 8),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Kopia zapasowa i podgląd snu domowników na wspólnym, rodzinnym koncie Koofr. '
          'Wszystko jest szyfrowane na telefonie, zanim trafi do Koofr. Domyślnie nic nie jest wysyłane.',
          style: TextStyle(color: C.muted),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
            const Text(
              'Utwórz je na app.koofr.net w ustawieniach konta, w sekcji haseł aplikacji (nie podawaj hasła do konta). '
              'Najlepiej osobne dla każdego telefonu — zgubiony telefon odetniesz jednym kliknięciem.',
              style: TextStyle(color: C.muted, fontSize: 12),
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
            const SizedBox(height: 4),
            TextButton(onPressed: busy ? null : _paste, child: const Text('Mam kod konfiguracji z innego telefonu')),
          ]),
        ),
      ),
    ]);
  }
}

/// Wiatry do Kreski, Doby i Dziennika talerza przez Koofr (tylko przy włączonym liczeniu wiatrów).
class _ExchangeCard extends StatefulWidget {
  const _ExchangeCard();

  @override
  State<_ExchangeCard> createState() => _ExchangeCardState();
}

class _ExchangeCardState extends State<_ExchangeCard> {
  bool? on;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    Cloud.exchangeOn().then((v) {
      if (mounted) setState(() => on = v);
    });
  }

  Future<void> _run() async {
    setState(() => busy = true);
    try {
      await Cloud.exchangeNow(force: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = on;
    if (v == null) return const SizedBox(height: 48);
    return Card(
      child: Column(children: [
        SwitchListTile(
          secondary: const Icon(Icons.swap_horiz),
          title: const Text('Udostępniaj FF moim aplikacjom'),
          subtitle: const Text('Kreska, Doba i Dziennik talerza pobiorą je same przez Koofr, bez eksportu plików. '
              'Widzą je tylko Twoje aplikacje (ten sam kod odzyskiwania).'),
          value: v,
          onChanged: (x) async {
            await Cloud.setExchangeOn(x);
            setState(() => on = x);
            if (x) {
              unawaited(_run());
            } else {
              try {
                await Cloud.sync.removeExchange('rytm-snu');
              } catch (_) {}
            }
          },
        ),
        if (v)
          ValueListenableBuilder<String?>(
            valueListenable: Cloud.lastExchangeMsg,
            builder: (c, last, _) => ListTile(
              leading: busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              title: const Text('Wyślij teraz'),
              subtitle: Text(last == null ? 'Automatycznie po każdej nocy i przy otwarciu aplikacji' : 'Ostatnio: $last'),
              onTap: busy ? null : _run,
            ),
          ),
      ]),
    );
  }
}

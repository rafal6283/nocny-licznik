import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Błąd połączenia z Koofr — komunikat gotowy do pokazania użytkownikowi.
class KoofrException implements Exception {
  final int? status;
  final String message;
  KoofrException(this.message, [this.status]);

  factory KoofrException.http(int status, String what) => KoofrException(
        switch (status) {
          401 => 'Koofr odrzucił logowanie — sprawdź e-mail i hasło aplikacji.',
          403 => 'Brak dostępu do folderu na Koofr.',
          404 => 'Nie znaleziono: $what',
          423 => 'Plik jest zablokowany na Koofr, spróbuj za chwilę.',
          507 => 'Brak wolnego miejsca na koncie Koofr.',
          >= 500 => 'Koofr ma chwilowe problemy ($status), spróbuj później.',
          _ => 'Błąd Koofr $status przy: $what',
        },
        status,
      );

  @override
  String toString() => message;
}

class DavEntry {
  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
  DavEntry(this.name, this.isDir, this.size, this.modified);
  @override
  String toString() => '${isDir ? 'd' : '-'} $name $size';
}

/// Minimalny klient WebDAV (Koofr: https://app.koofr.net/dav/Koofr/).
/// Ścieżki podawane są względem [base], segmenty oddzielone „/”.
class WebDav {
  final Uri base;
  final String _auth;
  final HttpClient _http;
  final _dirs = <String>{};

  static final koofr = Uri.parse('https://app.koofr.net/dav/Koofr/');

  WebDav({required String user, required String password, Uri? base})
      : base = base ?? koofr,
        _auth = 'Basic ${base64.encode(utf8.encode('$user:$password'))}',
        _http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20)
          ..idleTimeout = const Duration(seconds: 15)
          ..userAgent = 'koofr_sync/1.0';

  void close() => _http.close(force: true);

  Uri _uri(String path) {
    final segs = path.split('/').where((s) => s.isNotEmpty).map(Uri.encodeComponent);
    final dir = path.endsWith('/') && segs.isNotEmpty ? '/' : '';
    return base.resolve(segs.join('/') + dir);
  }

  Future<(int, Uint8List)> _send(String method, String path,
      {List<int>? body, Map<String, String>? headers, Duration timeout = const Duration(seconds: 60)}) async {
    try {
      final req = await _http.openUrl(method, _uri(path)).timeout(const Duration(seconds: 25));
      req.headers.set(HttpHeaders.authorizationHeader, _auth);
      headers?.forEach(req.headers.set);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(timeout);
      final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d)).timeout(timeout);
      return (res.statusCode, bytes.takeBytes());
    } on TimeoutException {
      throw KoofrException('Koofr nie odpowiada (przekroczony czas).');
    } on SocketException {
      throw KoofrException('Brak połączenia z internetem.');
    } on HandshakeException {
      throw KoofrException('Nie udało się nawiązać bezpiecznego połączenia z Koofr.');
    } on HttpException catch (e) {
      throw KoofrException('Przerwane połączenie z Koofr: ${e.message}');
    }
  }

  /// Sprawdza logowanie (PROPFIND katalogu głównego).
  Future<void> check() async {
    final (s, _) = await _send('PROPFIND', '', headers: {'Depth': '0'});
    if (s != 207 && s != 200) throw KoofrException.http(s, 'katalog główny');
  }

  /// Zawartość katalogu (bez niego samego). Pusta lista, gdy katalog nie istnieje.
  Future<List<DavEntry>> list(String dir) async {
    final path = dir.endsWith('/') ? dir : '$dir/';
    final (s, body) = await _send('PROPFIND', path, headers: {'Depth': '1', 'Content-Type': 'application/xml'});
    if (s == 404) return [];
    if (s != 207) throw KoofrException.http(s, dir);
    final self = Uri.decodeFull(_uri(path).path);
    return parseMultistatus(utf8.decode(body, allowMalformed: true))
        .where((e) => e.$1 != self && '${e.$1}/' != self && e.$1 != self.substring(0, self.length - 1))
        .map((e) => e.$2)
        .toList();
  }

  /// Odpowiedź PROPFIND → (pełna ścieżka href, wpis). Odporne na różne prefiksy przestrzeni nazw.
  static List<(String, DavEntry)> parseMultistatus(String xml) {
    final out = <(String, DavEntry)>[];
    final resp = RegExp(r'<(?:[\w-]+:)?response\b[^>]*>(.*?)</(?:[\w-]+:)?response>', dotAll: true);
    String? tag(String block, String name) =>
        RegExp('<(?:[\\w-]+:)?$name\\b[^>]*>(.*?)</(?:[\\w-]+:)?$name>', dotAll: true)
            .firstMatch(block)
            ?.group(1)
            ?.trim();
    for (final m in resp.allMatches(xml)) {
      final block = m.group(1)!;
      var href = tag(block, 'href');
      if (href == null) continue;
      href = Uri.decodeFull(href.startsWith('http') ? Uri.parse(href).path : href);
      final isDir = RegExp(r'<(?:[\w-]+:)?collection\b').hasMatch(block);
      final trimmed = href.endsWith('/') ? href.substring(0, href.length - 1) : href;
      final name = trimmed.substring(trimmed.lastIndexOf('/') + 1);
      final size = int.tryParse(tag(block, 'getcontentlength') ?? '') ?? 0;
      DateTime? mod;
      final lm = tag(block, 'getlastmodified');
      if (lm != null) {
        try {
          mod = HttpDate.parse(lm);
        } catch (_) {}
      }
      out.add((trimmed, DavEntry(name, isDir, size, mod)));
    }
    return out;
  }

  /// Plik albo null, gdy go nie ma.
  Future<Uint8List?> get(String path) async {
    final (s, body) = await _send('GET', path, timeout: const Duration(minutes: 5));
    if (s == 404) return null;
    if (s != 200) throw KoofrException.http(s, path);
    return body;
  }

  Future<void> put(String path, List<int> data) async {
    final parent = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    if (parent.isNotEmpty) await ensureDir(parent);
    final (s, _) = await _send('PUT', path,
        body: data, headers: {'Content-Type': 'application/octet-stream'}, timeout: const Duration(minutes: 5));
    if (s != 200 && s != 201 && s != 204) throw KoofrException.http(s, path);
  }

  /// Zapis „atomowy”: najpierw plik tymczasowy, potem przeniesienie na miejsce,
  /// żeby czytający nigdy nie dostał połowy pliku.
  Future<void> putAtomic(String path, List<int> data) async {
    final tmp = '$path.tmp';
    await put(tmp, data);
    try {
      await move(tmp, path);
    } catch (_) {
      await delete(tmp);
      rethrow;
    }
  }

  /// Tworzy katalog z rodzicami. Istniejące katalogi są pamiętane, żeby nie pytać ponownie.
  Future<void> ensureDir(String dir) async {
    final segs = dir.split('/').where((s) => s.isNotEmpty).toList();
    var cur = '';
    for (final seg in segs) {
      cur = cur.isEmpty ? seg : '$cur/$seg';
      if (_dirs.contains(cur)) continue;
      final (s, _) = await _send('MKCOL', '$cur/');
      // 201 utworzony, 405 już istnieje
      if (s != 201 && s != 405 && s != 200) throw KoofrException.http(s, cur);
      _dirs.add(cur);
    }
  }

  Future<void> delete(String path) async {
    final (s, _) = await _send('DELETE', path);
    if (s != 200 && s != 204 && s != 404) throw KoofrException.http(s, path);
    _dirs.removeWhere((d) => d == path || d.startsWith('$path/'));
  }

  Future<void> move(String from, String to) async {
    final (s, _) = await _send('MOVE', from, headers: {'Destination': _uri(to).toString(), 'Overwrite': 'T'});
    if (s != 201 && s != 204 && s != 200) throw KoofrException.http(s, '$from → $to');
  }
}

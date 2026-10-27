import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimalny serwer WebDAV w pamięci (zachowuje się jak Koofr w tym, czego używa pakiet).
class FakeDav {
  final files = <String, Uint8List>{};
  final puts = <String>[];
  final dirs = <String>{''};
  late HttpServer _server;
  final String password;

  FakeDav({this.password = 'haslo'});

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/dav/Koofr/');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  static String _norm(String p) {
    var s = Uri.decodeFull(p);
    const prefix = '/dav/Koofr';
    if (s.startsWith(prefix)) s = s.substring(prefix.length);
    s = s.replaceAll(RegExp(r'^/+|/+$'), '');
    return s;
  }

  String _parent(String p) => p.contains('/') ? p.substring(0, p.lastIndexOf('/')) : '';

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final ok = auth == 'Basic ${base64.encode(utf8.encode('rodzina@example.com:$password'))}';
    final body = await req.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
    if (!ok) {
      res.statusCode = 401;
      await res.close();
      return;
    }
    final path = _norm(req.uri.path);
    switch (req.method) {
      case 'PROPFIND':
        if (!dirs.contains(path) && !files.containsKey(path)) {
          res.statusCode = 404;
          break;
        }
        final depth = req.headers.value('Depth') ?? '1';
        final entries = <String>[path];
        if (depth != '0' && dirs.contains(path)) {
          final pre = path.isEmpty ? '' : '$path/';
          for (final d in dirs) {
            if (d.isNotEmpty && d.startsWith(pre) && !d.substring(pre.length).contains('/')) entries.add(d);
          }
          for (final f in files.keys) {
            if (f.startsWith(pre) && !f.substring(pre.length).contains('/')) entries.add(f);
          }
        }
        final xml = StringBuffer('<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">');
        for (final e in entries) {
          final isDir = dirs.contains(e);
          final href = '/dav/Koofr/${e.split('/').map(Uri.encodeComponent).join('/')}${isDir ? '/' : ''}';
          xml.write('<D:response><D:href>$href</D:href><D:propstat><D:prop>'
              '<D:resourcetype>${isDir ? '<D:collection/>' : ''}</D:resourcetype>'
              '${isDir ? '' : '<D:getcontentlength>${files[e]!.length}</D:getcontentlength>'}'
              '<D:getlastmodified>${HttpDate.format(DateTime.now())}</D:getlastmodified>'
              '</D:prop></D:propstat></D:response>');
        }
        xml.write('</D:multistatus>');
        res.statusCode = 207;
        res.write(xml);
      case 'MKCOL':
        if (dirs.contains(path) || files.containsKey(path)) {
          res.statusCode = 405;
        } else if (!dirs.contains(_parent(path))) {
          res.statusCode = 409;
        } else {
          dirs.add(path);
          res.statusCode = 201;
        }
      case 'PUT':
        if (!dirs.contains(_parent(path))) {
          res.statusCode = 409;
        } else {
          files[path] = body.takeBytes();
          puts.add(path);
          res.statusCode = 201;
        }
      case 'GET':
        final f = files[path];
        if (f == null) {
          res.statusCode = 404;
        } else {
          res.statusCode = 200;
          res.add(f);
        }
      case 'DELETE':
        if (files.remove(path) != null) {
          res.statusCode = 204;
        } else if (dirs.contains(path)) {
          dirs.removeWhere((d) => d == path || d.startsWith('$path/'));
          files.removeWhere((k, _) => k.startsWith('$path/'));
          res.statusCode = 204;
        } else {
          res.statusCode = 404;
        }
      case 'MOVE':
        final dest = _norm(Uri.parse(req.headers.value('Destination')!).path);
        final f = files.remove(path);
        if (f == null) {
          res.statusCode = 404;
        } else {
          files[dest] = f;
          res.statusCode = 201;
        }
      default:
        res.statusCode = 405;
    }
    await res.close();
  }
}

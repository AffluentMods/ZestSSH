import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:zest_native/ftps.dart';

/// An FTPS server in memory behind the native layer's JSON (rust/src/ftps/mod.rs): what the
/// app's FTPS code is tested against without a server or the Rust library. Paths are absolute;
/// a file is its bytes, a folder is a set of names, a link is its target.
const _ab = 'abababababababababababababababababababababababababababababababab';

class FakeFtpsNative implements FtpsNative {
  FakeFtpsNative({this.certificateSha = _ab, this.byAuthority = false, this.hash = false});

  final String certificateSha;
  final bool byAuthority;
  final bool hash;

  final files = <String, List<int>>{};
  final dirs = <String>{'/', '/home', '/home/demo'};
  final links = <String, String>{};
  final modes = <String, int>{};
  final requests = <Map<String, Object?>>[];
  final opened = <int>[];
  final closed = <int>[];
  int moved = 0;
  var _next = 1;

  /// Makes the next op of this name fail with [error] (once).
  final failNext = <String, Map<String, Object?>>{};

  /// Breaks off the next get or put after this many bytes, as a dropped connection does.
  int? breakAfter;

  @override
  int open() {
    opened.add(_next);
    return _next++;
  }

  @override
  void cancel(int handle) {}

  @override
  int progress(int handle) => moved;

  @override
  Future<void> close(int handle) async => closed.add(handle);

  static Map<String, Object?> _err(String kind, String message, [int? code]) => {
    'error': {'kind': kind, 'message': message, 'code': ?code},
  };

  String _parent(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  String _name(String path) => path.substring(path.lastIndexOf('/') + 1);

  Map<String, Object?>? _entry(String path) {
    final name = _name(path);
    if (links.containsKey(path)) {
      return {'name': name, 'dir': false, 'link': true, 'size': 0, 'mtime': 0, 'mode': 511, 'target': links[path]};
    }
    if (dirs.contains(path)) {
      return {'name': name, 'dir': true, 'link': false, 'size': 0, 'mtime': 0, 'mode': modes[path] ?? 493, 'target': null};
    }
    final f = files[path];
    if (f == null) return null;
    return {'name': name, 'dir': false, 'link': false, 'size': f.length, 'mtime': 1700000000, 'mode': modes[path] ?? 420, 'target': null};
  }

  @override
  Future<Map<String, Object?>> call(int handle, Map<String, Object?> r) async {
    requests.add(r);
    final op = r['op'] as String;
    final fail = failNext.remove(op);
    if (fail != null) return {'error': fail};
    final path = r['path'] as String?;
    switch (op) {
      case 'connect':
        final pinned = r['pinned'] as String?;
        final trusted = pinned == certificateSha || (r['allowAuthority'] == true && byAuthority);
        final cert = {'sha256': certificateSha, 'byAuthority': byAuthority, 'der': '30820101'};
        if (!trusted) return {'error': {'kind': 'certificate', 'message': 'not trusted', 'certificate': cert}};
        return {
          'ok': {
            'certificate': cert,
            'home': '/home/demo',
            'welcome': '220 hello',
            'features': {'mlst': true, 'hash': hash},
          },
        };
      case 'list':
        if (!dirs.contains(path)) return _err('reply', 'No such directory', 550);
        final prefix = path == '/' ? '/' : '$path/';
        final children = {
          ...dirs,
          ...files.keys,
          ...links.keys,
        }.where((p) => p != path && p.startsWith(prefix) && !p.substring(prefix.length).contains('/'));
        return {'ok': [for (final c in children.toList()..sort()) _entry(c)]};
      case 'stat':
        return {'ok': _entry(path!)};
      case 'mkdir':
        if (_entry(path!) != null || !dirs.contains(_parent(path))) return _err('reply', 'Create directory operation failed.', 550);
        dirs.add(path);
        return {'ok': null};
      case 'rmdir':
        final prefix = '$path/';
        if (!dirs.contains(path) || [...dirs, ...files.keys, ...links.keys].any((p) => p.startsWith(prefix))) {
          return _err('reply', 'Remove directory operation failed.', 550);
        }
        dirs.remove(path);
        return {'ok': null};
      case 'delete':
        if (files.remove(path) == null && links.remove(path) == null) return _err('reply', 'Delete operation failed.', 550);
        return {'ok': null};
      case 'rename':
        final from = r['from'] as String, to = r['to'] as String;
        if (!files.containsKey(from)) return _err('reply', 'RNFR command failed.', 550);
        files[to] = files.remove(from)!;
        return {'ok': null};
      case 'size':
        final f = files[path];
        return f == null ? _err('reply', 'Could not get file size.', 550) : {'ok': f.length};
      case 'chmod':
        modes[path!] = (r['mode'] as num).toInt();
        return {'ok': null};
      case 'sha256':
        final f = files[path];
        return {'ok': hash && f != null ? sha256.convert(f).toString() : null};
      case 'read':
        final f = files[path];
        if (f == null) return _err('reply', 'Failed to open file.', 550);
        final max = (r['maxBytes'] as num?)?.toInt();
        if (max != null && f.length > max) return _err('too-large', 'too large');
        return {
          'ok': {'data': base64Encode(f)},
        };
      case 'write':
        files[path!] = base64Decode(r['data'] as String);
        return {
          'ok': {'bytes': files[path]!.length},
        };
      case 'get':
        final remote = r['remote'] as String;
        final f = files[remote];
        if (f == null) return _err('reply', 'Failed to open file.', 550);
        final offset = (r['offset'] as num).toInt();
        final out = File(r['local'] as String);
        var rest = f.sublist(offset);
        final cut = breakAfter;
        breakAfter = null;
        if (cut != null && cut < rest.length) {
          out.writeAsBytesSync(rest.sublist(0, cut), mode: offset > 0 ? FileMode.append : FileMode.write);
          return _err('connection', 'connection reset');
        }
        out.writeAsBytesSync(rest, mode: offset > 0 ? FileMode.append : FileMode.write);
        moved = rest.length;
        return {
          'ok': {'bytes': rest.length},
        };
      case 'put':
        final remote = r['remote'] as String;
        final offset = (r['offset'] as num).toInt();
        final bytes = File(r['local'] as String).readAsBytesSync().sublist(offset);
        final cut = breakAfter;
        breakAfter = null;
        final sent = cut != null && cut < bytes.length ? bytes.sublist(0, cut) : bytes;
        files[remote] = [...(offset > 0 ? files[remote]!.sublist(0, offset) : const <int>[]), ...sent];
        if (sent.length < bytes.length) return _err('connection', 'connection reset');
        return {
          'ok': {'bytes': sent.length},
        };
      case 'noop':
      case 'quit':
        return {'ok': null};
      case 'pwd':
        return {'ok': '/home/demo'};
    }
    return _err('request', 'unknown op $op');
  }
}

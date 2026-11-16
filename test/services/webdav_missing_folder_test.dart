import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/backup/backup_destination_manager.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';

/// A WebDAV server as Nextcloud answers: folders made by MKCOL one level at a
/// time (409 where the level above is missing), PROPFIND 404 on a folder
/// that is not there, 401 to a wrong password.
class _Dav {
  _Dav({Set<String>? folders, this.refuseMkcol = false}) : folders = folders ?? {'/dav/'};

  static const password = 'app-token-demo';

  /// Answers every MKCOL 507 Insufficient Storage.
  final bool refuseMkcol;
  final Set<String> folders;
  final Map<String, List<int>> files = {};
  final List<String> calls = [];

  late final client = MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    final auth = request.headers['Authorization'];
    if (auth != 'Basic ${base64Encode(utf8.encode('alice:$password'))}') return http.Response('', 401);
    final folder = path.endsWith('/') ? path : '$path/';
    final parent = folder.substring(0, folder.lastIndexOf('/', folder.length - 2) + 1);
    switch (request.method) {
      case 'PROPFIND':
        return folders.contains(folder) ? http.Response('<d:multistatus xmlns:d="DAV:"/>', 207) : http.Response('', 404);
      case 'MKCOL':
        if (refuseMkcol) return http.Response('', 507);
        if (folders.contains(folder)) return http.Response('', 405);
        if (!folders.contains(parent)) return http.Response('', 409);
        folders.add(folder);
        return http.Response('', 201);
      case 'PUT':
        final dir = path.substring(0, path.lastIndexOf('/') + 1);
        if (!folders.contains(dir)) return http.Response('', 409);
        files[path] = request.bodyBytes;
        return http.Response('', 201);
    }
    return http.Response('', 405);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File backup;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('webdav_folder_');
    backup = File('${temp.path}/zestssh_auto_demo.zest')..writeAsBytesSync([0x5a, 0x45, 0x53, 0x54, 3]);
  });
  tearDown(() => temp.delete(recursive: true));

  WebDavBackupDestination dest(_Dav dav, {String password = 'app-token-demo', String? remotePath}) =>
      WebDavBackupDestination(
        serverUrl: 'https://cloud.example.com/dav',
        username: 'alice',
        password: password,
        remotePath: remotePath,
        client: dav.client,
      );

  Future<Map<String, String?>> copy(WebDavBackupDestination d) async {
    final manager = BackupDestinationManager(prefs: await SharedPreferences.getInstance(), tree: () => null);
    await manager.addDestination(d);
    return manager.backupToAll(backup, 'zestssh_auto_demo.zest');
  }

  test('a copy to a folder that is not there makes each missing level, then the copy', () async {
    final dav = _Dav();
    final d = dest(dav);
    final results = await copy(d);
    expect(results[d.id], isNull, reason: 'copied');
    expect(dav.folders, containsAll(['/dav/ZestSSH/', '/dav/ZestSSH/backups/']));
    expect(dav.files.keys, ['/dav/ZestSSH/backups/zestssh_auto_demo.zest']);
  });

  test('a wrong password still says it is not signed in, and makes nothing', () async {
    final dav = _Dav();
    final d = dest(dav, password: 'wrong');
    final results = await copy(d);
    expect(results[d.id], 'Not authenticated');
    expect(dav.folders, {'/dav/'});
    expect(dav.files, isEmpty);
    expect(dav.calls.where((c) => c.startsWith('MKCOL')), isEmpty);
  });

  test('a folder that is there is checked once and copied to', () async {
    final dav = _Dav(folders: {'/dav/', '/dav/ZestSSH/', '/dav/ZestSSH/backups/'});
    expect(await dest(dav).isAuthenticated(), isTrue);
    expect(dav.calls, ['PROPFIND /dav/ZestSSH/backups/']);
  });

  test('a folder the server will not make says so, with what it answered', () async {
    final d = dest(_Dav(refuseMkcol: true));
    await expectLater(d.isAuthenticated(), throwsA(isA<HttpException>().having((e) => e.message, 'message', contains('404'))));
    final results = await copy(d);
    expect(results[d.id], contains('could not be made'));
  });

  test('an empty Remote path is the default folder, never the root', () {
    final dav = _Dav();
    expect(dest(dav, remotePath: '').remotePath, '/ZestSSH/backups/');
    expect(dest(dav, remotePath: '   ').remotePath, '/ZestSSH/backups/');
    expect(dest(dav).remotePath, '/ZestSSH/backups/');
    expect(dest(dav, remotePath: 'team/backups').remotePath, '/team/backups/');
    expect(dest(dav, remotePath: '/').remotePath, '/', reason: 'a root typed is the root, as asked');
    final saved = WebDavBackupDestination.fromJson(dest(dav, remotePath: '').toJson());
    expect(saved.remotePath, '/ZestSSH/backups/');
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/services/backup/webdav_destination.dart';

/// A WebDAV backup place sends its password with every request, so its form
/// takes only an https:// address. The rule was the form's alone (found
/// in a whitepaper check): a place saved with another address
/// (an older build, a hand-edited setting) sent the password in the clear.
/// Every request now holds the same rule, and nothing is sent otherwise.
void main() {
  late Directory temp;
  late File backup;
  late List<String> sent;
  late MockClient server;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webdav_https_');
    backup = File('${temp.path}/b.zest')..writeAsBytesSync([1, 2, 3]);
    sent = [];
    server = MockClient((request) async {
      sent.add('${request.method} ${request.url}');
      return switch (request.method) {
        'PROPFIND' => http.Response('<d:multistatus xmlns:d="DAV:"/>', 207),
        'MKCOL' => http.Response('', 405),
        'PUT' => http.Response('', 201),
        'GET' => http.Response('zest', 200),
        'DELETE' => http.Response('', 204),
        _ => http.Response('', 405),
      };
    });
  });

  tearDown(() => temp.delete(recursive: true));

  WebDavBackupDestination at(String url) =>
      WebDavBackupDestination(serverUrl: url, username: 'alice', password: 'app-token-demo', client: server);

  for (final url in ['http://nas.lan/dav', 'http://192.168.1.20/dav', 'HTTP://cloud.example.com/dav', 'ftp://x/dav']) {
    test('$url: every request is refused before anything is sent', () async {
      final dav = at(url);
      await expectLater(dav.isAuthenticated(), throwsA(isA<WebDavHttpsRequired>()),
          reason: 'said as what it is, not as a wrong password');
      await expectLater(dav.uploadBackup(backup, 'b.zest'), throwsA(isA<WebDavHttpsRequired>()));
      await expectLater(dav.listBackups(), throwsA(isA<WebDavHttpsRequired>()));
      await expectLater(dav.downloadBackup('b.zest', '${temp.path}/d.zest'), throwsA(isA<WebDavHttpsRequired>()));
      await expectLater(dav.deleteBackup('b.zest'), throwsA(isA<WebDavHttpsRequired>()));
      await dav.authenticate();
      // The password, kept on the copy made when it is read back from secure
      // storage, is held to the same rule.
      await expectLater(dav.withPassword('pw').uploadBackup(backup, 'b.zest'), throwsA(isA<WebDavHttpsRequired>()));
      expect(sent, isEmpty);
    });
  }

  test('an https address goes through as before', () async {
    final dav = at('https://cloud.example.com/remote.php/dav');
    expect(await dav.isAuthenticated(), isTrue);
    await dav.uploadBackup(backup, 'b.zest');
    await dav.withPassword('pw').deleteBackup('b.zest');
    expect(sent, [
      'PROPFIND https://cloud.example.com/remote.php/dav/ZestSSH/backups/',
      'MKCOL https://cloud.example.com/remote.php/dav/ZestSSH/backups/',
      'PUT https://cloud.example.com/remote.php/dav/ZestSSH/backups/b.zest',
      'DELETE https://cloud.example.com/remote.php/dav/ZestSSH/backups/b.zest',
    ]);
  });
}

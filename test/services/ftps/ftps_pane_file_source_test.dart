import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/ftps/ftps_upload_resume.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';

import 'fake_ftps_native.dart';

/// The file browser on an FTPS host (3.4), over a fake native layer: what a
/// listing shows, how a folder goes, and how a transfer is staged, put in
/// place and taken up again where it broke off.
void main() {
  late FakeFtpsNative native;
  late FtpsPaneFileSource fs;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    native = FakeFtpsNative();
    final client = await FtpsClient.connect(
      const FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw'),
      pinnedSha256: native.certificateSha,
      native: native,
    );
    fs = FtpsPaneFileSource(client: client, sourceId: 'session-1');
    tmp = await Directory.systemTemp.createTemp('zest_ftps_test_');
  });
  tearDown(() async {
    await fs.close();
    await tmp.delete(recursive: true);
  });

  test('a listing gives entries with their paths, permissions and hidden flags', () async {
    native.files['/home/demo/notes.txt'] = [1, 2, 3];
    native.files['/home/demo/.profile'] = [4];
    native.dirs.add('/home/demo/logs');
    native.links['/home/demo/latest'] = 'logs';
    expect(await fs.homeDirectory(), '/home/demo');
    final all = await fs.list('/home/demo');
    final byName = {for (final e in all) e.name: e};
    expect(byName.keys, containsAll(['notes.txt', '.profile', 'logs', 'latest']));
    expect(byName['notes.txt']!.path, '/home/demo/notes.txt');
    expect(byName['notes.txt']!.permissions, '-rw-r--r--');
    expect(byName['logs']!.isDirectory, isTrue);
    expect(byName['latest']!.isSymlink, isTrue);
    expect(byName['latest']!.linkTarget, 'logs');
    expect(byName['.profile']!.isHidden, isTrue);
    final shown = await fs.list('/home/demo', includeHidden: false);
    expect(shown.map((e) => e.name), isNot(contains('.profile')));
  });

  test('stat says nothing for what is not there, and a 550 is not an error there', () async {
    expect(await fs.stat('/home/demo/none'), isNull);
    native.failNext['stat'] = {'kind': 'reply', 'message': 'No such file', 'code': 550};
    expect(await fs.stat('/home/demo/none'), isNull);
    expect(await fs.exists('/home/demo'), isTrue);
  });

  test('mkdir makes each folder on the way when asked to', () async {
    await fs.mkdir('/home/demo/a/b/c', recursive: true);
    expect(native.dirs, containsAll(['/home/demo/a', '/home/demo/a/b', '/home/demo/a/b/c']));
  });

  test('a folder is deleted deepest first, and a link in it is removed, never followed', () async {
    native.dirs.addAll(['/home/demo/old', '/home/demo/old/sub', '/home/demo/keep']);
    native.files['/home/demo/old/sub/x.bin'] = [1];
    native.files['/home/demo/keep/precious.txt'] = [9];
    native.links['/home/demo/old/to-keep'] = '/home/demo/keep';
    final gone = <String>[];
    expect(await fs.countEntriesRecursive('/home/demo/old'), 4);
    await fs.deleteDirectoryRecursive('/home/demo/old', onDeleted: gone.add);
    expect(native.dirs, isNot(contains('/home/demo/old')));
    expect(native.files['/home/demo/keep/precious.txt'], [9], reason: 'the link was not followed');
    expect(gone.last, '/home/demo/old');
  });

  test('an upload goes beside the file, is held to its size, then takes its place', () async {
    native.files['/home/demo/site.conf'] = [0];
    final local = File('${tmp.path}/site.conf')..writeAsBytesSync(List.filled(5000, 7));
    final seen = <int>[];
    await fs.uploadFile(local.path, '/home/demo/site.conf', onProgress: (d, t) => seen.add(t), bulk: true);
    expect(native.files['/home/demo/site.conf'], hasLength(5000));
    expect(native.files.containsKey('/home/demo/site.conf.zestpart'), isFalse);
    final puts = native.requests.where((r) => r['op'] == 'put').toList();
    expect(puts.single['remote'], '/home/demo/site.conf.zestpart');
    // A transfer runs on a connection of its own (FTP moves one file at a time on one).
    expect(native.opened, hasLength(2));
    expect(seen.last, 5000);
  });

  test('an upload the connection broke off goes on from what the server has', () async {
    final local = File('${tmp.path}/big.bin')..writeAsBytesSync(List.generate(10000, (i) => i % 251));
    native.breakAfter = 4000;
    await expectLater(fs.uploadFile(local.path, '/home/demo/big.bin'), throwsA(isA<FtpsException>()));
    expect(native.files['/home/demo/big.bin.zestpart'], hasLength(4000), reason: 'kept, to go on from');
    await fs.uploadFile(local.path, '/home/demo/big.bin');
    expect(native.requests.where((r) => r['op'] == 'put').last['offset'], 4000);
    expect(native.files['/home/demo/big.bin'], local.readAsBytesSync());
  });

  Future<FtpsPaneFileSource> afterRestart() async {
    // A new run of the app: a new connection and a new source; only the preferences stay.
    final client = await FtpsClient.connect(
      const FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw'),
      pinnedSha256: native.certificateSha,
      native: native,
    );
    return FtpsPaneFileSource(client: client, sourceId: 'session-2');
  }

  test('an upload the connection broke off goes on after a restart of the app, from the server\'s size', () async {
    final local = File('${tmp.path}/big.bin')..writeAsBytesSync(List.generate(10000, (i) => i % 251));
    native.breakAfter = 6000;
    await expectLater(fs.uploadFile(local.path, '/home/demo/big.bin', bulk: true), throwsA(isA<FtpsException>()));
    final again = await afterRestart();
    addTearDown(again.close);
    await again.uploadFile(local.path, '/home/demo/big.bin', bulk: true);
    final puts = native.requests.where((r) => r['op'] == 'put').toList();
    expect(puts.last['offset'], 6000);
    expect(native.requests.where((r) => r['op'] == 'size'), isNotEmpty, reason: 'the server\'s size, asked first');
    expect(native.files['/home/demo/big.bin'], local.readAsBytesSync());
    expect(native.files.containsKey('/home/demo/big.bin.zestpart'), isFalse);
    // Taken: the next upload of it starts from the start.
    expect((await SharedPreferences.getInstance()).getString(FtpsUploadResume.prefsKey), isNull);
  });

  test('a file that changed since its upload broke off is sent from the start', () async {
    final local = File('${tmp.path}/big.bin')..writeAsBytesSync(List.generate(10000, (i) => i % 251));
    native.breakAfter = 4000;
    await expectLater(fs.uploadFile(local.path, '/home/demo/big.bin'), throwsA(isA<FtpsException>()));
    local.writeAsBytesSync(List.generate(12000, (i) => i % 13));
    final again = await afterRestart();
    addTearDown(again.close);
    await again.uploadFile(local.path, '/home/demo/big.bin');
    expect(native.requests.where((r) => r['op'] == 'put').last['offset'], 0);
    expect(native.files['/home/demo/big.bin'], local.readAsBytesSync());
  });

  test('a server that takes neither REST nor APPE gets the whole file again', () async {
    final local = File('${tmp.path}/big.bin')..writeAsBytesSync(List.generate(10000, (i) => i % 251));
    native.breakAfter = 4000;
    await expectLater(fs.uploadFile(local.path, '/home/demo/big.bin'), throwsA(isA<FtpsException>()));
    native.failNext['put'] = {'kind': 'reply', 'message': 'Command not implemented.', 'code': 502};
    await fs.uploadFile(local.path, '/home/demo/big.bin');
    final puts = native.requests.where((r) => r['op'] == 'put').map((r) => r['offset']).toList();
    expect(puts.sublist(puts.length - 2), [4000, 0]);
    expect(native.files['/home/demo/big.bin'], local.readAsBytesSync());
  });

  test('the store keeps hashes only, and forgets an upload after a week', () async {
    var now = DateTime.utc(2026, 11, 6, 12);
    final store = FtpsUploadResume(now: () => now);
    final key = FtpsUploadResume.keyOf(host: 'files.example.test', port: 21, user: 'demo', stagedPath: '/srv/a.zestpart');
    final modified = DateTime.utc(2026, 11, 1);
    await store.remember(key, localPath: r'C:\Users\demo\a.bin', size: 10, modified: modified);
    final raw = (await SharedPreferences.getInstance()).getString(FtpsUploadResume.prefsKey)!;
    for (final readable in ['files.example.test', 'demo', '/srv/a', 'a.bin']) {
      expect(raw, isNot(contains(readable)));
    }
    now = now.add(const Duration(days: 6));
    expect((await store.take(key))!.isOf(r'C:\Users\demo\a.bin', 10, modified), isTrue);
    await store.remember(key, localPath: r'C:\Users\demo\a.bin', size: 10, modified: modified);
    now = now.add(const Duration(days: 8));
    expect(await store.take(key), isNull);
  });

  test('the store is the open profile\'s: another profile never goes on with its uploads', () async {
    final raw = await SharedPreferences.getInstance();
    final prefs = ProfilePreferences(raw);
    final first = AppDatabase.forTesting(NativeDatabase.memory());
    final second = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(first.close);
    addTearDown(second.close);
    final store = FtpsUploadResume(prefs: () async => prefs);
    final key = FtpsUploadResume.keyOf(host: 'files.example.test', port: 21, user: 'demo', stagedPath: '/srv/a.zestpart');
    final modified = DateTime.utc(2026, 11, 1);

    await prefs.load(first);
    await store.remember(key, localPath: r'C:\Users\demo\a.bin', size: 10, modified: modified);
    expect(raw.containsKey(FtpsUploadResume.prefsKey), isFalse, reason: 'kept in the profile, not the device');

    await prefs.load(second);
    expect(await store.take(key), isNull, reason: 'the same host and file under another profile starts again');

    await prefs.load(first);
    expect((await store.take(key))!.isOf(r'C:\Users\demo\a.bin', 10, modified), isTrue);
  });

  group('a dropped browsing connection (3.4, stage 2)', () {
    Future<FtpsClient> fresh() => FtpsClient.connect(
          const FtpsConnectOptions(host: 'files.example.test', port: 21, username: 'demo', password: 'pw'),
          pinnedSha256: native.certificateSha,
          native: native,
        );

    test('is connected again once on the next action, which then runs', () async {
      var reconnects = 0;
      final first = fs.client;
      final pane = FtpsPaneFileSource(client: first, sourceId: 's', reconnect: () async {
        reconnects++;
        return fresh();
      });
      native.files['/home/demo/a.txt'] = [1];
      native.failNext['list'] = {'kind': 'connection', 'message': 'connection reset'};
      final listed = await pane.list('/home/demo');
      expect(listed.map((e) => e.name), contains('a.txt'));
      expect(reconnects, 1);
      expect(identical(pane.client, first), isFalse, reason: 'the new connection took its place');
      await pane.list('/home/demo');
      expect(reconnects, 1, reason: 'once');
      await pane.close();
    });

    test('where connecting again fails, the first error is said', () async {
      final pane = FtpsPaneFileSource(
          client: fs.client, sourceId: 's', reconnect: () async => throw const FtpsException(FtpsErrorKind.timeout, 'no'));
      native.failNext['stat'] = {'kind': 'closed', 'message': 'this connection is closed'};
      await expectLater(pane.stat('/home/demo'),
          throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.closed)));
    });

    test('a refusal is no dropped connection: nothing is connected again', () async {
      var reconnects = 0;
      final pane = FtpsPaneFileSource(client: fs.client, sourceId: 's', reconnect: () async {
        reconnects++;
        return fresh();
      });
      native.failNext['delete'] = {'kind': 'reply', 'message': 'Permission denied', 'code': 550};
      await expectLater(pane.deleteFile('/home/demo/x'), throwsA(isA<FtpsException>()));
      expect(reconnects, 0);
    });

    test('a transfer connection that dropped is let go: Retry opens a new one', () async {
      final local = File('${tmp.path}/r.bin')..writeAsBytesSync(List.generate(5000, (i) => i % 7));
      native.breakAfter = 1000;
      await expectLater(fs.uploadFile(local.path, '/home/demo/r.bin', bulk: true), throwsA(isA<FtpsException>()));
      final opened = native.opened.length;
      await fs.uploadFile(local.path, '/home/demo/r.bin', bulk: true);
      expect(native.opened.length, opened + 1, reason: 'a new transfer connection');
      expect(native.files['/home/demo/r.bin'], local.readAsBytesSync());
    });
  });

  test('a cancelled upload leaves nothing on the server', () async {
    final local = File('${tmp.path}/c.bin')..writeAsBytesSync([1, 2, 3]);
    native.failNext['put'] = {'kind': 'cancelled', 'message': 'cancelled'};
    final token = TransferCancelToken()..cancel();
    await expectLater(
      fs.uploadFile(local.path, '/home/demo/c.bin', cancelToken: token),
      throwsA(isA<TransferCancelledException>()),
    );
    expect(native.files.keys.where((k) => k.startsWith('/home/demo/c.bin')), isEmpty);
  });

  test('a download is staged in .zestpart, resumes after a break, and is put in place whole', () async {
    final bytes = List.generate(9000, (i) => i % 253);
    native.files['/home/demo/report.pdf'] = bytes;
    final target = '${tmp.path}/report.pdf';
    native.breakAfter = 3000;
    await expectLater(fs.downloadFile('/home/demo/report.pdf', target, bulk: true), throwsA(isA<FtpsException>()));
    expect(File('$target.zestpart').lengthSync(), 3000);
    expect(File(target).existsSync(), isFalse);
    await fs.downloadFile('/home/demo/report.pdf', target, bulk: true);
    expect(native.requests.where((r) => r['op'] == 'get').last['offset'], 3000);
    expect(File(target).readAsBytesSync(), bytes);
    expect(File('$target.zestpart').existsSync(), isFalse);
    expect(File('$target.zestpart.meta').existsSync(), isFalse);
  });

  test('a download larger than allowed is refused before anything is written', () async {
    native.files['/home/demo/huge.iso'] = List.filled(100, 1);
    await expectLater(
      fs.downloadFile('/home/demo/huge.iso', '${tmp.path}/huge.iso', maxBytes: 10),
      throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.tooLarge)),
    );
    expect(native.requests.where((r) => r['op'] == 'get'), isEmpty);
  });

  test('a download the server breaks off with an error is not put in place', () async {
    native.files['/home/demo/short.bin'] = List.filled(50, 1);
    final target = '${tmp.path}/short.bin';
    native.failNext['get'] = {'kind': 'reply', 'message': 'x', 'code': 451};
    await expectLater(fs.downloadFile('/home/demo/short.bin', target), throwsA(isA<FtpsException>()));
    expect(File(target).existsSync(), isFalse);
  });

  test('the editor reads into memory and writes beside the file, then into its place', () async {
    native.files['/home/demo/nginx.conf'] = 'old'.codeUnits;
    expect(String.fromCharCodes(await fs.readBytes('/home/demo/nginx.conf')), 'old');
    await fs.writeBytes('/home/demo/nginx.conf', Uint8List.fromList('new text'.codeUnits));
    expect(String.fromCharCodes(native.files['/home/demo/nginx.conf']!), 'new text');
    expect(native.requests.where((r) => r['op'] == 'write').single['path'], '/home/demo/nginx.conf.zestpart');
    expect(native.requests.any((r) => r['op'] == 'get' || r['op'] == 'put'), isFalse, reason: 'nothing on disk here');
  });

  test('a write the server kept short does not take the file\'s place', () async {
    native.files['/home/demo/app.env'] = 'KEEP'.codeUnits;
    native.failNext['size'] = {'kind': 'reply', 'message': 'x', 'code': 550};
    await expectLater(fs.writeBytes('/home/demo/app.env', Uint8List.fromList([1, 2])), throwsA(anything));
    expect(String.fromCharCodes(native.files['/home/demo/app.env']!), 'KEEP');
  });

  test('chmod goes through SITE CHMOD, and the server SHA-256 only where it has HASH', () async {
    native.files['/home/demo/run.sh'] = [1];
    await fs.chmod('/home/demo/run.sh', 0x1ed);
    expect(native.modes['/home/demo/run.sh'], 0x1ed);
    expect(await fs.sha256('/home/demo/run.sh'), isNull);
  });

  test('verifyTransferSize is what holds an upload to its size', () {
    expect(() => verifyTransferSize(path: '/x', expected: 10, actual: 9), throwsA(isA<SftpIntegrityException>()));
  });
}

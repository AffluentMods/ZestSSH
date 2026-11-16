import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/ftps.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/services/ftps/ftps_upload_resume.dart';
import 'package:zestssh/services/known_hosts_service.dart';

/// An FTPS host's session and file browser (3.4) against a real server: the
/// Rust library, the certificate kept in the known hosts, and the browser's
/// source (list, mkdir, an upload staged and put in place, a download, the
/// editor's read and write, rename, delete), on vsftpd at its defaults, which
/// require TLS session reuse on every data connection.
///
/// Runs only when ZESTSSH_TEST_FTPS_HOST names the server that
/// tool/test_ftps_server.sh starts in WSL (`wsl -u root bash
/// tool/test_ftps_server.sh`, then WSL's own address from `wsl hostname -I`:
/// not 127.0.0.1, whose relay cuts uploads short now and then). Ports:
/// ZESTSSH_TEST_FTPS_PORT (4021, explicit) and ZESTSSH_TEST_FTPS_IMPLICIT_PORT
/// (4990, implicit).
void main() {
  final host = Platform.environment['ZESTSSH_TEST_FTPS_HOST'];
  final skip = host == null ? 'ZESTSSH_TEST_FTPS_HOST is not set (tool/test_ftps_server.sh)' : null;
  final ports = {
    false: int.tryParse(Platform.environment['ZESTSSH_TEST_FTPS_PORT'] ?? '') ?? 4021,
    true: int.tryParse(Platform.environment['ZESTSSH_TEST_FTPS_IMPLICIT_PORT'] ?? '') ?? 4990,
  };

  for (final implicit in [false, true]) {
    test('${implicit ? 'implicit' : 'explicit'} FTPS: the session, its certificate and the file browser', () async {
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final known = KnownHostsService(db.knownHostsDao);
      final tmp = await Directory.systemTemp.createTemp('zest_ftps_it_');
      var asked = 0;
      final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async {
        asked++;
        expect(certificate.byAuthority, isFalse, reason: 'the test server is self-signed');
        return true;
      });
      final options = FtpsConnectOptions(
        host: host!,
        port: ports[implicit]!,
        username: 'zestftps',
        password: 'Zest-Ftps-Test-2026',
        implicitTls: implicit,
      );
      final shell = FtpsShellService(options: options, trust: trust);
      await shell.connect();
      expect(asked, 1);
      expect(await known.pinnedCertificate(host, ports[implicit]!), shell.client!.certificate.sha256);
      final fs = FtpsPaneFileSource(client: shell.client!, sourceId: 'it');
      final dir = '${await fs.homeDirectory()}/zest-app-it-${DateTime.now().microsecondsSinceEpoch}';
      try {
        await fs.mkdir('$dir/sub', recursive: true);
        final bytes = Uint8List.fromList(List.generate(2 * 1024 * 1024 + 5, (i) => Random(i).nextInt(256)));
        final local = File('${tmp.path}/up.bin')..writeAsBytesSync(bytes);
        // Several transfers in a row on the transfer connection: each data connection resumes
        // the session (vsftpd refuses one that does not).
        for (var i = 0; i < 3; i++) {
          await fs.uploadFile(local.path, '$dir/sub/up$i.bin', bulk: true);
        }
        final listed = await fs.list('$dir/sub');
        expect(listed.map((e) => e.name).toSet(), {'up0.bin', 'up1.bin', 'up2.bin'});
        expect(listed.every((e) => e.size == bytes.length), isTrue);

        await fs.downloadFile('$dir/sub/up1.bin', '${tmp.path}/down.bin', bulk: true);
        expect(File('${tmp.path}/down.bin').readAsBytesSync(), bytes);

        await fs.writeBytes('$dir/sub/notes.txt', Uint8List.fromList('first'.codeUnits));
        await fs.writeBytes('$dir/sub/notes.txt', Uint8List.fromList('second, longer'.codeUnits));
        expect(String.fromCharCodes(await fs.readBytes('$dir/sub/notes.txt')), 'second, longer');

        // An upload that broke off before a restart of the app goes on from what the server has
        // (REST then STOR on vsftpd): the first part is in the .zestpart, as a dropped connection
        // leaves it, and a new source (a new run) sends only the rest.
        const had = 700 * 1024;
        final first = File('${tmp.path}/first.bin')..writeAsBytesSync(bytes.sublist(0, had));
        await fs.client.upload(first.path, '$dir/sub/resumed.bin.zestpart');
        await FtpsUploadResume().remember(
          FtpsUploadResume.keyOf(
              host: host, port: ports[implicit]!, user: 'zestftps', stagedPath: '$dir/sub/resumed.bin.zestpart'),
          localPath: local.path,
          size: bytes.length,
          modified: local.statSync().modified,
        );
        final later = FtpsPaneFileSource(client: shell.client!, sourceId: 'it-2');
        final seen = <int>[];
        await later.uploadFile(local.path, '$dir/sub/resumed.bin', bulk: true, onProgress: (done, _) => seen.add(done));
        await later.close();
        if (seen.isNotEmpty) expect(seen.reduce(min), greaterThanOrEqualTo(had), reason: 'only the rest was sent');
        await fs.downloadFile('$dir/sub/resumed.bin', '${tmp.path}/resumed.bin', bulk: true);
        expect(File('${tmp.path}/resumed.bin').readAsBytesSync(), bytes);
        expect(await fs.exists('$dir/sub/resumed.bin.zestpart'), isFalse);

        await fs.rename('$dir/sub/up2.bin', '$dir/sub/moved.bin');
        expect(await fs.exists('$dir/sub/up2.bin'), isFalse);
        expect(await fs.exists('$dir/sub/moved.bin'), isTrue);
      } finally {
        try {
          await fs.deleteDirectoryRecursive(dir);
        } catch (_) {}
        await fs.close();
        await shell.disconnect();
        await db.close();
        await tmp.delete(recursive: true);
      }
      expect(fs.client.isClosed, isTrue);
    }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
  }

  // The host editor's TLS test (3.4): TLS and the certificate's check, then QUIT, with
  // no user name or password sent (vsftpd would log a failed login for a wrong one).
  for (final implicit in [false, true]) {
    test('${implicit ? 'implicit' : 'explicit'} FTPS: the TLS test checks the certificate and signs in to nothing',
        () async {
      final options = FtpsConnectOptions(
          host: host!, port: ports[implicit]!, username: '', password: '', implicitTls: implicit);
      final refused = await FtpsClient.probeTls(options, allowAuthority: true)
          .then<FtpsException?>((_) => null, onError: (Object e) => e as FtpsException);
      expect(refused?.kind, FtpsErrorKind.certificate, reason: 'self-signed: refused, and shown');
      final cert = await FtpsClient.probeTls(options, pinnedSha256: refused!.certificate!.sha256);
      expect(cert.sha256, refused.certificate!.sha256);
    }, skip: skip);
  }

  test('a wrong password says so', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final known = KnownHostsService(db.knownHostsDao);
    final trust = KnownHostsFtpsTrust(known, ({required host, required port, required certificate, previous, previousTrustedAt, teamPin}) async => true);
    final shell = FtpsShellService(
      options: FtpsConnectOptions(host: host!, port: ports[false]!, username: 'zestftps', password: 'wrong'),
      trust: trust,
    );
    await expectLater(shell.connect(), throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.login)));
    await db.close();
  }, skip: skip);
}

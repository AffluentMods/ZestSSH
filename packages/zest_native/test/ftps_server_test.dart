// FtpsClient against a real FTPS server: vsftpd at its defaults (TLS session reuse required on
// every data connection), explicit and implicit, started by the app's tool/test_ftps_server.sh
// (wsl -u root bash tool/test_ftps_server.sh). Skipped unless ZESTSSH_TEST_FTPS_HOST names it (WSL's
// own address, not 127.0.0.1: see that script).
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_native/ftps.dart';

final _host = Platform.environment['ZESTSSH_TEST_FTPS_HOST'];
final _explicitPort = int.tryParse(Platform.environment['ZESTSSH_TEST_FTPS_PORT'] ?? '') ?? 4021;
final _implicitPort = int.tryParse(Platform.environment['ZESTSSH_TEST_FTPS_IMPLICIT_PORT'] ?? '') ?? 4990;
const _user = 'zestftps';
const _password = 'Zest-Ftps-Test-2026';

class _AcceptOnce implements FtpsTrust {
  String? pinned;
  int asked = 0;

  @override
  Future<String?> pinnedFor(String host, int port) async => pinned;

  @override
  Future<bool> ask(FtpsCertificate presented, {required String host, required int port, String? previous}) async {
    asked++;
    return true;
  }

  @override
  Future<void> remember(String host, int port, FtpsCertificate cert) async => pinned = cert.sha256;
}

void main() {
  final skip = _host == null ? 'ZESTSSH_TEST_FTPS_HOST is not set (tool/test_ftps_server.sh)' : null;

  for (final implicit in [false, true]) {
    final port = implicit ? _implicitPort : _explicitPort;
    test('${implicit ? 'implicit' : 'explicit'} FTPS: certificate, list, upload with resume, download, rename, delete', () async {
      final options = FtpsConnectOptions(host: _host!, port: port, username: _user, password: _password, implicitTls: implicit);

      // A self-signed certificate: refused until accepted, then trusted without a question.
      await expectLater(
        FtpsClient.connect(options),
        throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.certificate)),
      );
      final trust = _AcceptOnce();
      final client = await FtpsClient.connectTrusting(options, trust);
      expect(trust.asked, 1);
      final again = await FtpsClient.connectTrusting(options, trust);
      expect(trust.asked, 1);
      await again.close();

      final tmp = await Directory.systemTemp.createTemp('zest_ftps_it_');
      final dir = '${client.home}/zest-it-${DateTime.now().microsecondsSinceEpoch}';
      try {
        await client.mkdir(dir);
        final bytes = Uint8List.fromList(List.generate(3 * 1024 * 1024 + 17, (i) => Random(i).nextInt(256)));
        final local = File('${tmp.path}/up.bin')..writeAsBytesSync(bytes);

        // An upload broken off after its first megabyte, then resumed from what the server has.
        final head = File('${tmp.path}/head.bin')..writeAsBytesSync(bytes.sublist(0, 1024 * 1024));
        await client.upload(head.path, '$dir/up.bin');
        expect(await client.size('$dir/up.bin'), 1024 * 1024);
        final sent = await client.upload(local.path, '$dir/up.bin', offset: 1024 * 1024);
        expect(sent, bytes.length - 1024 * 1024);
        expect(await client.size('$dir/up.bin'), bytes.length);

        final listed = await client.list(dir);
        expect(listed.map((e) => e.name), ['up.bin']);
        expect(listed.single.size, bytes.length);

        // A download broken off, then resumed.
        final part = File('${tmp.path}/down.bin')..writeAsBytesSync(bytes.sublist(0, 500000));
        var last = 0;
        await client.download('$dir/up.bin', part.path, offset: 500000, onProgress: (d) => last = d);
        expect(part.readAsBytesSync(), bytes);
        expect(last, bytes.length);

        await client.rename('$dir/up.bin', '$dir/moved.bin');
        expect(await client.stat('$dir/up.bin'), isNull);
        expect((await client.stat('$dir/moved.bin'))?.size, bytes.length);
        await client.delete('$dir/moved.bin');
        await expectLater(
          client.delete('$dir/moved.bin'),
          throwsA(isA<FtpsException>().having((e) => e.notThere, 'notThere', isTrue)),
        );
      } finally {
        try {
          await client.rmdir(dir);
        } catch (_) {}
        await client.close();
        await tmp.delete(recursive: true);
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('a wrong password says so', () async {
    final trust = _AcceptOnce();
    await expectLater(
      FtpsClient.connectTrusting(
        FtpsConnectOptions(host: _host!, port: _explicitPort, username: _user, password: 'wrong'),
        trust,
      ),
      throwsA(isA<FtpsException>().having((e) => e.kind, 'kind', FtpsErrorKind.login)),
    );
  }, skip: skip);
}

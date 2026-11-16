import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

import '../../helpers/played_sftp_host.dart';

/// What the editor on a computer opens from a host and saves to it, and an
/// image it shows from there, goes between the host and this device's
/// memory (3.0, found while the phone's save was held to tests), through
/// the file pane's own source with the host played by the test, and against
/// a real OpenSSH server (the second one tool/test_sshd.sh starts,
/// 127.0.0.1:2297, with SFTP; those are skipped when it is not running).
///
/// A file pane on a host read a whole file by downloading it to a file in
/// this device's temporary folder and reading that, and wrote one by writing
/// a file there and uploading it: every file opened in the editor, every
/// image looked at and every save left a copy of what it held on this
/// device's disk, in the clear, for as long as it took, and for good where
/// the app was ended meanwhile.
void main() {
  Uint8List bytes(String words) => Uint8List.fromList(utf8.encode(words));

  /// Runs [body] with a folder of the test's in the place of this device's
  /// temporary folder, and gives what [body] gave.
  Future<T> withTemp<T>(Directory temp, Future<T> Function() body) =>
      IOOverrides.runZoned(body, getSystemTempDirectory: () => temp);

  group('a host played by the test', () {
    late Directory temp;
    late PlayedSftpHost host;
    late RemotePaneFileSource source;

    /// The names of everything that was in this device's temporary folder
    /// at any moment at which the host was asked for something.
    late Set<String> onThisDevice;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('zest-app-pane-bytes-test');
      addTearDown(() => temp.delete(recursive: true));
      host = PlayedSftpHost();
      onThisDevice = {};
      host.waitsFor = (request) {
        onThisDevice.addAll(temp.listSync(recursive: true).map((entry) => entry.path));
        return null;
      };
      final sftp = SftpService(host.client);
      await sftp.open();
      addTearDown(sftp.close);
      source = RemotePaneFileSource(service: sftp, sourceId: 'web-01');
    });

    test('a remote file is found with its size, kind and permissions (it was "not there" for every file with a '
        'mode, so a copy onto it never had its size and time to compare, and a folder was not one)', () async {
      host.files['/srv/notes.txt'] = PlayedFile(utf8.encode('twelve bytes'), permissions: 416);
      final file = await source.stat('/srv/notes.txt');
      expect(file, isNotNull);
      expect(file!.size, 12);
      expect(file.isDirectory, isFalse);
      expect(file.permissions, '-rw-r-----');
      final folder = await source.stat('/srv');
      expect(folder?.isDirectory, isTrue);
      expect(folder?.permissions, 'drwxr-xr-x');
      expect(await source.stat('/srv/none.txt'), isNull);
    });

    test('a file is read into memory: nothing of it is on this device while it is read, or afterwards', () async {
      final words = Uint8List.fromList([for (var i = 0; i < 100000; i++) 32 + (i * 7 + i ~/ 95) % 95]);
      host.files['/srv/notes.txt'] = PlayedFile(words);

      final read = await withTemp(temp, () => source.readBytes('/srv/notes.txt', maxBytes: 4 * 1024 * 1024));

      expect(read, words);
      expect(host.asked, contains('read /srv/notes.txt'));
      expect(onThisDevice, isEmpty);
      expect(temp.listSync(), isEmpty);

      // No more of a file than it was asked to take: an editor's limit, or the one for an image.
      await expectLater(
        withTemp(temp, () => source.readBytes('/srv/notes.txt', maxBytes: 50000)),
        throwsA(isA<SftpFileTooLargeException>().having((e) => e.limit, 'limit', 50000)),
      );
    });

    test('what is saved is written from memory: nothing of it is on this device while it is written, or afterwards; '
        'and nothing of a file on this device is handed to the host with it', () async {
      host.files['/srv/conf'] = PlayedFile(bytes('old words'), permissions: 416);

      await withTemp(temp, () => source.writeBytes('/srv/conf', bytes('new words')));
      await withTemp(temp, () => source.writeBytes('/srv/fresh', bytes('first words')));

      expect(utf8.decode(host.files['/srv/conf']!.bytes), 'new words');
      expect(utf8.decode(host.files['/srv/fresh']!.bytes), 'first words');
      expect(host.asked.where((request) => request.startsWith('write ')), hasLength(2));
      expect(onThisDevice, isEmpty);
      expect(temp.listSync(), isEmpty);
      // The time of a file is the host's own, and a new file has what the host gives a new file: nothing is
      // set from a file on this device, which there is none of.
      expect(host.asked.where((request) => request.startsWith('fsetstat ')), isEmpty);
      expect(host.files['/srv/conf']!.permissions, 416);
      expect(host.files['/srv/fresh']!.permissions, 420);
    });
  });

  group('a real server', () {
    final env = Platform.environment;
    final hostName = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
    final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
    final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
    final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
    String? unavailable;

    Future<SSHClient> connect() async {
      final client = SSHClient(
        await SSHSocket.connect(hostName, port, timeout: const Duration(seconds: 5)),
        username: user,
        identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      );
      addTearDown(client.close);
      await client.authenticated.timeout(const Duration(seconds: 20));
      return client;
    }

    Future<String> run(SSHClient client, String command) async =>
        utf8.decode(await client.run(command).timeout(const Duration(seconds: 15))).trim();

    setUpAll(() async {
      try {
        (await Socket.connect(hostName, port, timeout: const Duration(seconds: 2))).destroy();
        if (!File('$dir/client_ed25519').existsSync()) {
          unavailable = 'the test key is not there';
          return;
        }
        final client = SSHClient(
          await SSHSocket.connect(hostName, port),
          username: user,
          identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
        );
        try {
          (await client.sftp()).close();
        } on SSHChannelRequestError {
          unavailable = 'the test sshd at $hostName:$port has no SFTP: start it again with tool/test_sshd.sh';
        } finally {
          client.close();
        }
      } catch (_) {
        unavailable = 'no test sshd at $hostName:$port';
      }
    });

    test('a file of a few megabytes is saved and read again as it was, with nothing of it on this device; a file '
        'that is new is what the host makes a new file', () async {
      if (unavailable != null) return markTestSkipped(unavailable!);
      final client = await connect();
      final remote = '/tmp/zest-app-pane-bytes-test-$pid';
      await run(client, 'mkdir -p $remote; touch $remote/made');
      addTearDown(() async {
        try {
          await run(client, 'rm -rf $remote');
        } catch (_) {}
      });
      final temp = await Directory.systemTemp.createTemp('zest-app-pane-bytes-test');
      addTearDown(() => temp.delete(recursive: true));
      final sftp = SftpService(client);
      await sftp.open();
      addTearDown(sftp.close);
      final source = RemotePaneFileSource(service: sftp, sourceId: 'web-01');
      final picture = Uint8List.fromList([for (var i = 0; i < 3 * 1024 * 1024; i++) (i * 31 + i ~/ 251) % 256]);

      /// What [body] gives, and in [seen] everything that was in this device's temporary folder while it ran,
      /// which is when a copy of what it moves would be there.
      final seen = <String>{};
      Future<T> watched<T>(Future<T> Function() body) async {
        var done = false;
        final outcome = withTemp(temp, body)
            .then<(T?, Object?)>((value) => (value, null), onError: (Object error) => (null, error))
            .whenComplete(() => done = true);
        while (!done) {
          seen.addAll(temp.listSync(recursive: true).map((entry) => entry.path));
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        final (value, error) = await outcome;
        if (error != null) throw error;
        return value as T;
      }

      await watched(() => source.writeBytes('$remote/picture', picture));
      expect(seen, isEmpty);
      expect(await watched(() => source.readBytes('$remote/picture', maxBytes: 32 * 1024 * 1024)), picture);
      expect(seen, isEmpty);

      expect(await run(client, 'stat -c "%a %s" $remote/picture; ls -A $remote | tr "\\n" " "'),
          '${await run(client, 'stat -c %a $remote/made')} ${picture.length}\nmade picture');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';

/// Files whose size the host reports as something other than what they hold
/// (3.0, the SSH core's audit), through the app's own file service against
/// a real OpenSSH server: the second one tool/test_sshd.sh starts
/// (127.0.0.1:2297, with SFTP). Skips itself when it is not running.
///
/// Linux reports no size for what the kernel makes up as it is read
/// (everything under /proc) and a whole page for a few bytes (everything
/// under /sys), and a file that is being written has grown since its size
/// was asked. The first came down empty and was called done; the second
/// could not be downloaded to a file at all ("should be 4096 bytes but 6
/// bytes were transferred"), and neither could the third, where it grew
/// between the two times its size was asked. A device, which has no size
/// either, came down as an empty file and was called done.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  String? unavailable;

  Future<SSHClient> connect() async {
    final client = SSHClient(
      await SSHSocket.connect(host, port, timeout: const Duration(seconds: 5)),
      username: user,
      identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
    );
    addTearDown(client.close);
    await client.authenticated.timeout(const Duration(seconds: 20));
    return client;
  }

  /// What a command prints, byte for byte.
  Future<Uint8List> printed(SSHClient client, String command) => client.run(command).timeout(const Duration(seconds: 15));

  setUpAll(() async {
    try {
      (await Socket.connect(host, port, timeout: const Duration(seconds: 2))).destroy();
      if (!File('$dir/client_ed25519').existsSync()) {
        unavailable = 'the test key is not there';
        return;
      }
      final client = SSHClient(
        await SSHSocket.connect(host, port),
        username: user,
        identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      );
      try {
        (await client.sftp()).close();
      } on SSHChannelRequestError {
        unavailable = 'the test sshd at $host:$port has no SFTP: start it again with tool/test_sshd.sh';
      } finally {
        client.close();
      }
    } catch (_) {
      unavailable = 'no test sshd at $host:$port';
    }
  });

  /// The app's file service on a connection of its own, and a folder on this
  /// device that is removed when the test ends.
  Future<(SSHClient, SftpService, Directory)> opened() async {
    final client = await connect();
    final sftp = SftpService(client);
    await sftp.open();
    addTearDown(sftp.close);
    final local = await Directory.systemTemp.createTemp('zest-app-sftp-size-test');
    addTearDown(() => local.delete(recursive: true));
    return (client, sftp, local);
  }

  List<String> namesIn(Directory folder) => [for (final f in folder.listSync()) f.uri.pathSegments.last]..sort();

  test('a file the host reports no size for comes down whole: into memory, and to a file', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    // The kernel's own name and version: the same at every read.
    const path = '/proc/version';
    final onHost = await printed(client, 'cat $path');
    expect(onHost, isNotEmpty);
    expect((await sftp.stat(path)).size, 0, reason: 'the host reports no size for it');

    // As a file is opened to be looked at or edited.
    final told = <(int, int)>[];
    final inMemory = await sftp.downloadFile(path, onProgress: (transferred, total) => told.add((transferred, total)));
    expect(utf8.decode(inMemory), utf8.decode(onHost));
    // What came, of a whole that is not known; and at the end, that it is all there is.
    expect(told, [(onHost.length, 0), (onHost.length, onHost.length)]);

    // As it is downloaded.
    final file = File('${local.path}/version');
    told.clear();
    await sftp
        .downloadFileToPath(path, file.path, onProgress: (transferred, total) => told.add((transferred, total)))
        .timeout(const Duration(seconds: 30));
    expect(utf8.decode(file.readAsBytesSync()), utf8.decode(onHost));
    expect(told, [(onHost.length, 0), (onHost.length, onHost.length)]);
    expect(namesIn(local), ['version'], reason: 'and nothing half done');
  });

  test('a file of several pages that the host reports no size for comes down whole', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    // What the kernel says of the processors, which the host hands over a page at a time.
    const path = '/proc/cpuinfo';
    final before = await printed(client, 'cat $path');
    final inMemory = await sftp.downloadFile(path);
    final file = File('${local.path}/cpuinfo');
    await sftp.downloadFileToPath(path, file.path).timeout(const Duration(seconds: 30));
    final after = await printed(client, 'cat $path');
    if (before.length <= 8192 || utf8.decode(before) != utf8.decode(after)) {
      return markTestSkipped('$path is too small on this host, or changes from one read to the next');
    }
    expect(utf8.decode(inMemory), utf8.decode(before));
    expect(utf8.decode(file.readAsBytesSync()), utf8.decode(before));
  });

  test('a file the host reports a whole page for comes down as the few bytes it holds', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    // A setting of the loopback interface: a number and a line end.
    const path = '/sys/class/net/lo/mtu';
    final onHost = await printed(client, 'cat $path');
    expect(onHost, isNotEmpty);
    final page = (await sftp.stat(path)).size;
    expect(page, greaterThan(onHost.length), reason: 'the host reports a page for it');

    final told = <(int, int)>[];
    expect(
      utf8.decode(await sftp.downloadFile(path, onProgress: (transferred, total) => told.add((transferred, total)))),
      utf8.decode(onHost),
    );
    // A few bytes of a page, and then: those few bytes are all there is.
    expect(told, [(onHost.length, page), (onHost.length, onHost.length)]);
    final file = File('${local.path}/mtu');
    told.clear();
    await sftp
        .downloadFileToPath(path, file.path, onProgress: (transferred, total) => told.add((transferred, total)))
        .timeout(const Duration(seconds: 30));
    expect(utf8.decode(file.readAsBytesSync()), utf8.decode(onHost));
    expect(told, [(onHost.length, page), (onHost.length, onHost.length)]);
    expect(namesIn(local), ['mtu']);
  });

  test('a file that is being written comes down as far as it went when its size was asked, and the download ends '
      'while the file goes on growing', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    final path = '/tmp/zest-app-sftp-size-test-$pid.log';
    addTearDown(() async {
      try {
        await printed(client, 'rm -f $path $path.go');
      } catch (_) {}
    });
    // Nine megabytes to begin with, and a program that goes on writing to the file for as long as a second file
    // is there (and for no longer than a minute, whatever becomes of this test).
    const start = 9437184;
    await printed(client, 'head -c $start /dev/zero > $path; : > $path.go');
    const line = '0123456789abcdef';
    final writer = client.run("timeout 60 sh -c 'while [ -e $path.go ]; do printf $line >> $path; done'; true");
    Future<int> sizeNow() async => int.parse(utf8.decode(await printed(client, 'stat -c %s $path')).trim());
    final clock = Stopwatch()..start();
    while (await sizeNow() == start) {
      if (clock.elapsed > const Duration(seconds: 10)) fail('the file did not grow');
    }

    /// What came is the file as far as it went when its size was asked: the zeros, and what had been written
    /// after them by then. What was told of it ends with all of it, and the file has grown since.
    Future<void> asItShould(Uint8List came, List<(int, int)> told, String how) async {
      final whenAsked = told.first.$2;
      expect(whenAsked, greaterThan(start), reason: how);
      expect(came.length, whenAsked, reason: '$how: as far as it went when its size was asked');
      expect(came.sublist(0, start).every((byte) => byte == 0), isTrue, reason: how);
      final written = utf8.decode(came.sublist(start));
      expect(written, (line * (written.length ~/ line.length + 1)).substring(0, written.length), reason: how);
      expect(told.every((t) => t.$1 <= t.$2 && t.$2 == whenAsked), isTrue, reason: how);
      expect(told.last, (whenAsked, whenAsked), reason: how);
      expect(await sizeNow(), greaterThan(came.length), reason: '$how: it ended while the file went on growing');
    }

    // Into memory, as a file is opened to be looked at.
    final told = <(int, int)>[];
    final inMemory = await sftp
        .downloadFile(path, onProgress: (transferred, total) => told.add((transferred, total)))
        .timeout(const Duration(seconds: 20));
    await asItShould(inMemory, told, 'into memory');

    // To a file.
    final toFile = <(int, int)>[];
    final file = File('${local.path}/app.log');
    await sftp
        .downloadFileToPath(path, file.path, onProgress: (transferred, total) => toFile.add((transferred, total)))
        .timeout(const Duration(seconds: 20));
    await asItShould(file.readAsBytesSync(), toFile, 'to a file');
    expect(namesIn(local), ['app.log']);

    await printed(client, 'rm -f $path.go');
    await writer.timeout(const Duration(seconds: 30));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a file of no bytes comes down as a file of no bytes', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    final path = '/tmp/zest-app-sftp-size-test-$pid.empty';
    addTearDown(() async {
      try {
        await printed(client, 'rm -f $path');
      } catch (_) {}
    });
    await printed(client, ': > $path');
    final told = <(int, int)>[];
    expect(await sftp.downloadFile(path, onProgress: (transferred, total) => told.add((transferred, total))), isEmpty);
    final file = File('${local.path}/empty');
    await sftp
        .downloadFileToPath(path, file.path, onProgress: (transferred, total) => told.add((transferred, total)))
        .timeout(const Duration(seconds: 30));
    expect(file.readAsBytesSync(), isEmpty);
    expect(told, isEmpty, reason: 'nothing came, and nothing is told of it');
    expect(namesIn(local), ['empty']);
  });

  test('a device or a pipe is no file to download: refused in the app\'s words before it is opened, with nothing '
      'left on this device, and the session goes on', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, local) = await opened();
    final pipe = '/tmp/zest-app-sftp-size-test-$pid.pipe';
    addTearDown(() async {
      try {
        await printed(client, 'rm -f $pipe');
      } catch (_) {}
    });
    await printed(client, 'mkfifo $pipe');

    // A device that never ends, one that holds nothing, and a pipe nobody writes to.
    for (final path in ['/dev/zero', '/dev/null', pipe]) {
      Object? failure;
      try {
        // (No more than a megabyte in any case: a test that fails here must not fill this device.)
        await sftp.downloadFile(path, maxBytes: 1024 * 1024).timeout(const Duration(seconds: 10));
      } catch (e) {
        failure = e;
      }
      expect(failure, isA<SftpNotAFileException>().having((e) => e.remotePath, 'path', path), reason: path);
      failure = null;
      try {
        await sftp
            .downloadFileToPath(path, '${local.path}/down', maxBytes: 1024 * 1024)
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        failure = e;
      }
      expect(failure, isA<SftpNotAFileException>(), reason: path);
      expect(namesIn(local), isEmpty, reason: '$path: nothing was begun on this device');
      expect(
        sftpErrorMessage(failure!, name: 'zero', op: SftpOp.download, l10n: en),
        'There is nothing to download of "zero": on the server it is a device, a pipe or a socket, not a file.',
      );
    }

    // Nothing of them was opened on the host: the session answers as before. (Opening a pipe waits for whoever
    // writes to it, and the host answers nothing else on the session meanwhile.)
    expect(utf8.decode(await sftp.downloadFile('/proc/version').timeout(const Duration(seconds: 20))),
        startsWith('Linux'));
    expect((await sftp.listDirectory('/tmp').timeout(const Duration(seconds: 20))).map((e) => e.path), contains(pipe));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('how many bytes a download asks for, and what it takes for a file', () {
    // The size the host reported, from where the download starts.
    expect(bytesToAskFor(size: 100, offset: 0), 100);
    expect(bytesToAskFor(size: 100, offset: 40), 60);
    expect(bytesToAskFor(size: 100, offset: 100), 0, reason: 'all of it is here already');
    // No size reported: to where the host says the file ends.
    expect(bytesToAskFor(size: 0, offset: 0), isNull);

    SftpFileAttrs kind(int type) => SftpFileAttrs(size: 0, mode: SftpFileMode.value(type | 420));
    // A file, a folder, a link, and what says nothing of its kind pass.
    for (final passes in [kind(0x8000), kind(0x4000), kind(0xA000), SftpFileAttrs(size: 0)]) {
      expect(() => mustBeAFile(passes, '/it'), returnsNormally, reason: '${passes.mode}');
    }
    // A character device, a block device, a pipe and a socket do not.
    for (final refused in [kind(0x2000), kind(0x6000), kind(0x1000), kind(0xC000)]) {
      expect(() => mustBeAFile(refused, '/it'), throwsA(isA<SftpNotAFileException>()), reason: '${refused.mode}');
    }
    // Said in every language the app speaks, with the name in it.
    for (final locale in AppLocalizations.supportedLocales) {
      final said = sftpErrorMessage(const SftpNotAFileException('/dev/zero'),
          name: 'zero', op: SftpOp.download, l10n: lookupAppLocalizations(locale));
      expect(said, contains('zero'), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(said, isNot(contains('There is nothing to download')), reason: '$locale');
      }
    }
  });
}

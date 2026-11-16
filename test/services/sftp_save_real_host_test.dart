import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';

/// A file that is saved from the editor on a phone (3.0, the SSH core's
/// audit), through the app's own file service against a real OpenSSH server:
/// the second one tool/test_sshd.sh starts (127.0.0.1:2297, with SFTP).
/// Skips itself when it is not running.
///
/// The editor on a phone hands the file service the text it holds, and the
/// file service wrote it into the file itself: the file was cut to nothing
/// when it was opened, and written from its beginning. A connection that
/// dropped in the middle of that left the file with part of the new text,
/// and the text it had held was gone. An upload, and a save from the editor
/// on a computer, is written beside the file and put in its place when it
/// is whole.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  String? unavailable;
  var folders = 0;

  /// A connection; with [onRequest], every SFTP request it makes is handed there as it leaves.
  Future<SSHClient> connect({void Function(String request)? onRequest}) async {
    final client = SSHClient(
      await SSHSocket.connect(host, port, timeout: const Duration(seconds: 5)),
      username: user,
      identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      printTrace: onRequest == null
          ? null
          : (line) {
              final at = line?.indexOf(': Sftp') ?? -1;
              if (line != null && line.startsWith('->') && at > 0) onRequest(line.substring(at + 2));
            },
    );
    addTearDown(client.close);
    await client.authenticated.timeout(const Duration(seconds: 20));
    return client;
  }

  Future<String> run(SSHClient client, String command) async =>
      utf8.decode(await client.run(command).timeout(const Duration(seconds: 15))).trim();

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

  /// A connection to look at the host with, and a folder of this test's
  /// there, which is removed at the end.
  Future<(SSHClient, String)> folderOnHost() async {
    final client = await connect();
    final remote = '/tmp/zest-app-sftp-save-test-$pid-${folders++}';
    await run(client, 'mkdir -p $remote');
    addTearDown(() async {
      try {
        await run(client, 'chmod -R u+rwx $remote; rm -rf $remote');
      } catch (_) {}
    });
    return (client, remote);
  }

  /// The app's file service on a connection of its own.
  Future<SftpService> fileService(SSHClient client) async {
    final sftp = SftpService(client);
    await sftp.open();
    addTearDown(sftp.close);
    return sftp;
  }

  /// [length] bytes that are text, and that differ from place to place, so
  /// that a piece in the wrong place shows.
  Uint8List text(int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = i % 97 == 96 ? 10 : 97 + (i * 31 + i ~/ 97) % 26;
    }
    return bytes;
  }

  test('a save that the connection drops in the middle of leaves the file as it was; what was on its way stays '
      'beside it until the next save, which takes its place', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (looking, remote) = await folderOnHost();
    await run(looking, "yes 'old words' | head -n 1000 > $remote/notes.txt; chmod 640 $remote/notes.txt");
    final before = await run(looking, 'cksum < $remote/notes.txt');

    // The connection that saves is cut as soon as the first piece of the new text has left.
    late final SSHClient saving;
    var cut = false;
    saving = await connect(onRequest: (request) {
      if (cut || !request.startsWith('SftpWritePacket')) return;
      cut = true;
      Timer.run(saving.close);
    });
    final sftp = await fileService(saving);
    // What the host runs for that connection: the connection itself, and its file session.
    final session = await run(saving, 'echo \$PPID');
    final theirs = '$session ${await run(looking, 'pgrep -P $session | tr "\\n" " "; true')}';
    Object? failure;
    try {
      await sftp.uploadFile('$remote/notes.txt', text(3 * 1024 * 1024)).timeout(const Duration(seconds: 30));
    } catch (e) {
      failure = e;
    }
    expect(cut, isTrue, reason: 'some of it was on its way');
    expect(failure, isNotNull, reason: 'and whoever saved is told that it was not saved');
    await saving.done.timeout(const Duration(seconds: 10)).catchError((Object _) {});

    // What the host has, once it is done with the connection that dropped.
    var held = '';
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 10)) {
      final there = await run(looking, 'for p in $theirs; do kill -0 \$p 2>/dev/null && echo \$p; done; true');
      held = await run(looking, 'cksum < $remote/notes.txt; stat -c "%a %s" $remote/notes.txt');
      if (there.isEmpty) break;
    }
    expect(held, '$before\n640 10000', reason: 'every one of the old words, and nothing of the new text');
    expect(await run(looking, 'ls -A $remote'), 'notes.txt\nnotes.txt.zestpart');
    expect(int.parse(await run(looking, 'stat -c %s $remote/notes.txt.zestpart')), lessThan(3 * 1024 * 1024));
    expect(await run(looking, 'stat -c %a $remote/notes.txt.zestpart'), '640',
        reason: 'and what is beside it is readable by nobody that the file is not');

    // The next save, on a connection that holds.
    final again = await fileService(await connect());
    final words = text(3 * 1024 * 1024);
    await again.uploadFile('$remote/notes.txt', words);
    expect(await run(looking, 'ls -A $remote; stat -c "%a %s" $remote/notes.txt'), 'notes.txt\n640 ${words.length}');
    expect(await again.downloadFile('$remote/notes.txt'), words);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a setting that the kernel of the host makes up as it is read, which can only be written where it is and '
      'has no size, is saved', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final looking = await connect();
    final sftp = await fileService(await connect());
    // A program of this account's on the host, and how readily the host ends it when its memory runs out: a
    // number that its account may raise, in a file that the kernel makes up. It is gone with the program.
    final program = await run(looking, 'nohup sleep 120 </dev/null >/dev/null 2>&1 & echo \$!');
    addTearDown(() async {
      try {
        await run(looking, 'kill $program');
      } catch (_) {}
    });
    final setting = '/proc/$program/oom_score_adj';
    final was = int.parse(utf8.decode(await sftp.downloadFile(setting)).trim());
    if (was > 900) return markTestSkipped('the setting is as high as it goes');

    await sftp.uploadFile(setting, Uint8List.fromList(utf8.encode('${was + 100}\n')));

    expect(utf8.decode(await sftp.downloadFile(setting)), '${was + 100}\n');

    // And as the editor on a computer saves it, from a file on this device.
    final local = await Directory.systemTemp.createTemp('zest-app-sftp-save-test');
    addTearDown(() => local.delete(recursive: true));
    final file = File('${local.path}/setting')..writeAsStringSync('${was + 50}\n');
    await sftp.uploadFileFromPath(file.path, setting);
    expect(utf8.decode(await sftp.downloadFile(setting)), '${was + 50}\n');
  });

  test('a save keeps what the file was: its permissions, and the link it is reached by; a file that is new is what '
      'the host makes a new file', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (looking, remote) = await folderOnHost();
    await run(looking, "mkdir $remote/real; printf 'old key' > $remote/real/key; chmod 600 $remote/real/key; "
        'ln -s real/key $remote/key; touch $remote/made');
    final sftp = await fileService(await connect());

    await sftp.uploadFile('$remote/key', Uint8List.fromList(utf8.encode('new key')));
    await sftp.uploadFile('$remote/fresh', Uint8List.fromList(utf8.encode('words')));

    expect(await run(looking, 'readlink $remote/key; cat $remote/real/key; echo; stat -c %a $remote/real/key'),
        'real/key\nnew key\n600');
    expect(await run(looking, 'cat $remote/fresh; echo; stat -c %a $remote/fresh'),
        'words\n${await run(looking, 'stat -c %a $remote/made')}');
    expect(await run(looking, 'ls -A $remote $remote/real | tr "\\n" " "'), '$remote: fresh key made real  $remote/real: key');
  });
}

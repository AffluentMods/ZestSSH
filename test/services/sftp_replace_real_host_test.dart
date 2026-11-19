import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';

/// A file on the host that is replaced by an upload, or saved from the
/// editor on a computer, stays what it was (3.0, the SSH core's audit),
/// through the app's own file service against a real OpenSSH server: the
/// second one tool/test_sshd.sh starts (127.0.0.1:2297, with SFTP). Skips
/// itself when it is not running.
///
/// An upload is written beside the file and put in its place when it is
/// whole, so that nothing is lost where it breaks off. What was put in its
/// place was a new file: with the permissions of a new file (a key that
/// only its owner could read came back readable by everyone, a script was
/// no program any more), in the place of the link the file was reached by,
/// and not at all where the folder may not be written to. And to put it
/// there, the file that was there was removed first.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  String? unavailable;
  var folders = 0;

  /// A connection; with [asked], every SFTP request it makes is noted there.
  Future<SSHClient> connect({List<String>? asked}) async {
    final client = SSHClient(
      await SSHSocket.connect(host, port, timeout: const Duration(seconds: 5)),
      username: user,
      identities: SSHKeyPair.fromPem(File('$dir/client_ed25519').readAsStringSync()),
      printTrace: asked == null
          ? null
          : (line) {
              final at = line?.indexOf(': Sftp') ?? -1;
              if (line != null && line.startsWith('->') && at > 0) asked.add(line.substring(at + 2));
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

  tearDown(() {
    SftpService.debugOneStepRename = true;
    SftpService.debugUnixPermissions = null;
  });

  /// The app's file service on a connection of its own, a folder of this
  /// test's on the host, and one on this device; both removed at the end.
  Future<(SSHClient, SftpService, String, Directory)> opened({List<String>? asked}) async {
    final client = await connect(asked: asked);
    final sftp = SftpService(client);
    await sftp.open();
    addTearDown(sftp.close);
    final remote = '/tmp/zest-app-sftp-replace-test-$pid-${folders++}';
    await run(client, 'mkdir -p $remote');
    final local = await Directory.systemTemp.createTemp('zest-app-sftp-replace-test');
    addTearDown(() async {
      try {
        await run(client, 'chmod -R u+rwx $remote; rm -rf $remote');
      } catch (_) {}
      await local.delete(recursive: true);
    });
    return (client, sftp, remote, local);
  }

  File withContent(Directory folder, String name, String content) =>
      File('${folder.path}/$name')..writeAsBytesSync(Uint8List.fromList(utf8.encode(content)));

  test('a file that is replaced keeps its permissions: what only its owner may read stays that, and a script stays '
      'a program', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    await run(client, "printf 'old key' > $remote/key; chmod 600 $remote/key; "
        "printf 'old script' > $remote/run.sh; chmod 775 $remote/run.sh; "
        "printf 'old tool' > $remote/tool; chmod 1755 $remote/tool");

    await sftp.uploadFileFromPath(withContent(local, 'key', 'new key').path, '$remote/key');
    await sftp.uploadFileFromPath(withContent(local, 'run.sh', 'new script').path, '$remote/run.sh');
    await sftp.uploadFileFromPath(withContent(local, 'tool', 'new tool').path, '$remote/tool');

    expect(await run(client, 'cat $remote/key; echo; stat -c %a $remote/key'), 'new key\n600');
    // (More than a new file is given on this host, where group and others get no writing by themselves.)
    expect(await run(client, 'cat $remote/run.sh; echo; stat -c %a $remote/run.sh'), 'new script\n775');
    // Who may read, write and run it, and no more: what else a file was marked with is not handed on to new
    // content. (The mark here is the one a host leaves on a file that is written to; the one that makes a
    // program run as its owner it takes off by itself.)
    expect(await run(client, 'cat $remote/tool; echo; stat -c %a $remote/tool'), 'new tool\n755');
    expect(await run(client, 'ls -A $remote'), 'key\nrun.sh\ntool', reason: 'and nothing half done beside them');

    // From a system whose files have permissions of their own (this one may have none): a new file on the host
    // gets them, and one that replaces another still has that one's.
    SftpService.debugUnixPermissions = true;
    final fresh = withContent(local, 'fresh', 'words');
    final sent = (await fresh.stat()).mode & 511;
    await sftp.uploadFileFromPath(fresh.path, '$remote/fresh');
    expect(int.parse(await run(client, 'stat -c %a $remote/fresh'), radix: 8), sent);
    expect(sent, isNot(384), reason: 'this file is not one that only its owner may read');
    await sftp.uploadFileFromPath(fresh.path, '$remote/key');
    expect(await run(client, 'cat $remote/key; echo; stat -c %a $remote/key'), 'words\n600');
  });

  test('what is written beside a file is never readable by more people than the file it replaces', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final asked = <String>[];
    final (client, sftp, remote, local) = await opened(asked: asked);
    await run(client, "printf 'old key' > $remote/key; chmod 600 $remote/key");
    // Large enough to be looked at while it is on its way.
    final large = File('${local.path}/key')..writeAsBytesSync(Uint8List(24 * 1024 * 1024));

    asked.clear();
    final uploading = sftp.uploadFileFromPath(large.path, '$remote/key');
    var seen = '';
    final clock = Stopwatch()..start();
    while (seen.isEmpty && clock.elapsed < const Duration(seconds: 20)) {
      seen = await run(client, 'stat -c %a $remote/key.zestpart 2>/dev/null; true');
    }
    await uploading.timeout(const Duration(seconds: 60));
    expect(seen, '600', reason: 'while it was being written');
    expect(await run(client, 'stat -c "%a %s" $remote/key; ls -A $remote'), '600 ${24 * 1024 * 1024}\nkey');
    // It is made that way, and not made as any new file and narrowed a moment later: whoever opens a file
    // while everyone may read it goes on reading it. (The host makes a file as it is asked to: the SSH
    // package's own test of that is against this server.)
    final made = asked.where((request) => request.startsWith('SftpOpenPacket') && request.contains('key.zestpart'));
    expect(made, hasLength(1));
    expect(made.single, contains('SftpFileMode(600)'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a file that is reached by a link is replaced where it is: the link stays a link', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    await run(client, "mkdir $remote/available $remote/enabled; printf 'old' > $remote/available/site; "
        'chmod 640 $remote/available/site; ln -s ../available/site $remote/enabled/site');

    await sftp.uploadFileFromPath(withContent(local, 'site', 'new').path, '$remote/enabled/site');

    expect(await run(client, 'readlink $remote/enabled/site'), '../available/site', reason: 'still the link it was');
    expect(await run(client, 'cat $remote/available/site; echo; stat -c %a $remote/available/site'), 'new\n640',
        reason: 'and the file it leads to has the new words, and its permissions');
    expect(await run(client, 'ls -A $remote/available $remote/enabled | tr "\\n" " "'),
        '$remote/available: site  $remote/enabled: site');

    // A link that leads nowhere: the upload takes its place, as it did.
    await run(client, 'ln -s nowhere $remote/dangling');
    await sftp.uploadFileFromPath(withContent(local, 'dangling', 'words').path, '$remote/dangling');
    expect(await run(client, 'cat $remote/dangling; test -L $remote/dangling || echo " a file"'), 'words a file');

    // A link that leads to what is no file, a pipe here and a folder (a unit that is switched off is a link to a
    // device): the upload takes the place of the link, and what the link led to is not touched.
    await run(client, 'mkfifo $remote/pipe; ln -s pipe $remote/unit; mkdir $remote/folder; ln -s folder $remote/name');
    await sftp.uploadFileFromPath(withContent(local, 'unit', 'a unit').path, '$remote/unit');
    expect(await run(client, 'test -p $remote/pipe && echo "still a pipe"'), 'still a pipe');
    expect(await run(client, 'cat $remote/unit; test -L $remote/unit || echo " a file"'), 'a unit a file');
    await sftp.uploadFileFromPath(withContent(local, 'name', 'a name').path, '$remote/name');
    expect(await run(client, 'test -d $remote/folder && echo "still a folder"'), 'still a folder');
    expect(await run(client, 'cat $remote/name; test -L $remote/name || echo " a file"'), 'a name a file');
    expect(await run(client, 'ls -A $remote | tr "\\n" " "'), 'available dangling enabled folder name pipe unit');
  });

  test('a file in a folder that may not be written to is written where it is, where the file itself may be',
      () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    await run(client, "mkdir $remote/locked; printf 'old' > $remote/locked/conf; chmod 640 $remote/locked/conf; "
        'chmod 555 $remote/locked');
    final before = await run(client, 'stat -c %i $remote/locked/conf');

    await sftp.uploadFileFromPath(withContent(local, 'conf', 'new words').path, '$remote/locked/conf');

    expect(await run(client, 'cat $remote/locked/conf; echo; stat -c %a $remote/locked/conf'), 'new words\n640');
    expect(await run(client, 'stat -c %i $remote/locked/conf'), before, reason: 'the same file, with new words in it');
    expect(await run(client, 'ls -A $remote/locked'), 'conf');

    // A file that is not there yet cannot be made in such a folder: said as the host says it.
    Object? failure;
    try {
      await sftp.uploadFileFromPath(withContent(local, 'other', 'x').path, '$remote/locked/other');
    } catch (e) {
      failure = e;
    }
    expect(failure, isA<SftpStatusError>().having((e) => e.code, 'code', SftpStatusCode.permissionDenied));
  });

  test('a file of another group than a new file would have is written where it is, and stays in its group; one that '
      'may not be written itself is replaced after all', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    // A second group of the account's, where it has one: the group a team shares a folder by.
    final groups = (await run(client, 'id -Gn')).split(' ');
    if (groups.length < 2) return markTestSkipped('the account on the host has one group only');
    final shared = groups[1];
    await run(client, "printf 'old' > $remote/page; chgrp $shared $remote/page; chmod 664 $remote/page; "
        "printf 'old' > $remote/sealed; chgrp $shared $remote/sealed; chmod 444 $remote/sealed");
    final before = await run(client, 'stat -c %i $remote/page');

    await sftp.uploadFileFromPath(withContent(local, 'page', 'new words').path, '$remote/page');
    expect(await run(client, 'cat $remote/page; echo; stat -c "%G %a" $remote/page'), 'new words\n$shared 664');
    expect(await run(client, 'stat -c %i $remote/page'), before, reason: 'the same file');

    // It may not be written, and its folder may: replaced, as it always was, with its permissions.
    await sftp.uploadFileFromPath(withContent(local, 'sealed', 'new words').path, '$remote/sealed');
    expect(await run(client, 'cat $remote/sealed; echo; stat -c %a $remote/sealed'), 'new words\n444');
    expect(await run(client, 'ls -A $remote'), 'page\nsealed', reason: 'and nothing half done beside them');
  });

  test('a file is put in the place of another in one step, with nothing removed for it; on a host that cannot, the '
      'file is moved aside and removed only once the new one is in its place', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final asked = <String>[];
    final (client, sftp, remote, local) = await opened(asked: asked);
    await run(client, "printf 'old' > $remote/site");

    asked.clear();
    await sftp.uploadFileFromPath(withContent(local, 'site', 'new').path, '$remote/site');
    expect(await run(client, 'cat $remote/site; ls -A $remote'), 'newsite');
    expect(asked.where((request) => request.startsWith('SftpRemovePacket')), isEmpty,
        reason: 'the file that was there is never removed: $asked');
    expect(asked.where((request) => request.startsWith('SftpRenamePacket')), isEmpty,
        reason: 'the rename that a taken name refuses is not tried');
    expect(asked.where((request) => request.startsWith('SftpExtendedPacket')), hasLength(1), reason: 'one step');

    // A host without that step (OpenSSH's own rename refuses a name that is taken): the file
    // that is there is moved aside, under a name of this upload's own, the new one renamed onto
    // its name, and the one moved aside removed after. The file itself is never removed; nothing
    // is left beside it, and a file of the person's under the old fixed name is not touched.
    SftpService.debugOneStepRename = false;
    await run(client, "printf 'mine' > $remote/site.zestold");
    asked.clear();
    await sftp.uploadFileFromPath(withContent(local, 'site', 'newer').path, '$remote/site');
    expect(await run(client, 'cat $remote/site; echo; cat $remote/site.zestold; echo; ls -A $remote'),
        'newer\nmine\nsite\nsite.zestold');
    expect(asked.where((request) => request.startsWith('SftpExtendedPacket')), isEmpty);
    final removed = [for (final r in asked) if (r.startsWith('SftpRemovePacket')) r];
    expect(removed, hasLength(1), reason: 'only the one this upload moved aside: $asked');
    expect(RegExp(r'/site\.zestold-[0-9a-f]{8}\)$').hasMatch(removed.single), isTrue, reason: '$removed');
    expect([for (final r in asked) if (r.startsWith('SftpRenamePacket')) r], hasLength(3),
        reason: 'refused onto the name, the file aside, the upload onto the name: $asked');
  });

  test('an upload that is stopped half way leaves the file it was to replace as it was; where it could only be '
      'written where it is, that is said', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    await run(client, "printf 'old' > $remote/site; chmod 640 $remote/site; mkdir $remote/locked; "
        "printf 'old' > $remote/locked/conf; chmod 555 $remote/locked");
    final large = File('${local.path}/large')..writeAsBytesSync(Uint8List(24 * 1024 * 1024));

    /// An upload of [large] to [path] that its person stops as soon as some of it is on its way.
    Future<Object?> stopped(String path) async {
      final token = TransferCancelToken();
      Object? failure;
      try {
        await sftp
            .uploadFileFromPath(large.path, path, cancelToken: token, onProgress: (sent, total) => token.cancel())
            .timeout(const Duration(seconds: 60));
      } catch (e) {
        failure = e;
      }
      return failure;
    }

    // Beside the file: nothing of it is left, and the file is as it was.
    expect(await stopped('$remote/site'), isA<TransferCancelledException>());
    expect(await run(client, 'cat $remote/site; echo; stat -c %a $remote/site; ls -A $remote'), 'old\n640\nlocked\nsite');

    // Where it is: the file holds part of the new content now, and whoever asked is told so.
    final failure = await stopped('$remote/locked/conf');
    expect(
      failure,
      isA<SftpWrittenInPlaceException>()
          .having((e) => e.remotePath, 'path', '$remote/locked/conf')
          .having((e) => e.cause, 'cause', isA<TransferCancelledException>()),
    );
    expect(await run(client, 'cat $remote/locked/conf | head -c 3'), isNot('old'));
    expect(
      sftpErrorMessage(failure!, name: 'conf', op: SftpOp.upload, l10n: en),
      'Cancelled. On the server, "conf" could only be written where it is, so what it holds there now is part of the '
      'new content. Save or upload it again.',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a file that is not there yet is made, as before; and what is said of a file written where it is, in every '
      'language', () async {
    if (unavailable != null) return markTestSkipped(unavailable!);
    final (client, sftp, remote, local) = await opened();
    await sftp.uploadFileFromPath(withContent(local, 'notes.txt', 'first words').path, '$remote/notes.txt');
    expect(await run(client, 'cat $remote/notes.txt'), 'first words');
    expect(await run(client, 'ls -A $remote'), 'notes.txt');

    const broken = SftpWrittenInPlaceException('/srv/conf', SocketException('Connection reset by peer'));
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final said = sftpErrorMessage(broken, name: 'conf', op: SftpOp.upload, l10n: l10n);
      expect(said, startsWith('${l10n.sftpErrConnectionLost} '), reason: '$locale: what broke it off comes first');
      expect(said, contains('conf'), reason: '$locale');
      if (locale.languageCode != 'en') expect(said, isNot(contains('could only be written')), reason: '$locale');
    }
  });
}

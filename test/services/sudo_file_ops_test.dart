import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/sudo_runner.dart';
import 'package:zestssh/utils/file_manager.dart' show debugRestrictFileToOwner;

/// Retry with sudo (3.4): what runs on the host
/// for each file action done again as root, how sudo is given the password
/// (on its standard input, never on a command line or in a log), and how
/// each way sudo can refuse is told apart, with its code.
void main() {
  const password = 'hunter2-Secret';

  group('the commands', () {
    test('each action runs the command that does it in a terminal, every path in single quotes', () {
      expect(
        SudoFileOps.program(const SudoMove('/etc/a.conf', '/etc/b.conf')),
        "sh -c '${SudoFileOps.noClobber}exec mv -- \"\$1\" \"\$2\"' sh '/etc/a.conf' '/etc/b.conf'",
      );
      expect(
        SudoFileOps.program(const SudoCopy('/srv/a', '/srv/b')),
        "sh -c '${SudoFileOps.notALink}exec cp -p -- \"\$1\" \"\$2\"' sh '/srv/a' '/srv/b'",
      );
      expect(
        SudoFileOps.program(const SudoCopy('/srv/site', '/var/www/site', folder: true)),
        "sh -c '${SudoFileOps.noClobber}exec cp -rp -- \"\$1\" \"\$2\"' sh '/srv/site' '/var/www/site'",
      );
      expect(SudoFileOps.program(const SudoDelete('/var/log/old.log')), "rm -- '/var/log/old.log'");
      expect(SudoFileOps.program(const SudoDelete('/var/cache/app', folder: true)), "rm -r -- '/var/cache/app'");
      expect(SudoFileOps.program(const SudoMkdir('/opt/new')), "mkdir -- '/opt/new'");
      expect(
        SudoFileOps.program(
          const SudoUpload('C:/Users/demo/site.conf', '/etc/nginx/site.conf'),
          temp: '/tmp/.zestssh-edit-ab',
        ),
        "sh -c '${SudoFileOps.uploadScript}' sh '/tmp/.zestssh-edit-ab' '/etc/nginx/site.conf'",
      );
      expect(SudoFileOps.program(const SudoDownload('/etc/shadow', 'C:/Users/demo/shadow')), "cat -- '/etc/shadow'");
    });

    test('the scripts stand in single quotes, and read their paths as arguments', () {
      for (final script in [SudoFileOps.noClobber, SudoFileOps.uploadScript, SudoFileOps.notALink]) {
        expect(script, isNot(contains("'")));
        expect(script, isNot(contains('!')), reason: 'history expansion in some shells');
      }
      expect(SudoFileOps.noClobber, contains(r'[ -e "$2" ]'));
    });

    test('a write as root over a file is never made through a symbolic link, checked in the same command', () {
      expect(SudoFileOps.notALink, contains(r'[ -h "$2" ]'));
      expect(SudoFileOps.uploadScript, startsWith(SudoFileOps.notALink));
      expect(SudoFileOps.program(const SudoCopy('/srv/a', '/srv/b')), contains(SudoFileOps.notALink));
      expect(
        SftpService.rootWriteProgram('/tmp/.zestssh-edit-ab', '/etc/nginx/nginx.conf'),
        "sh -c '${SudoFileOps.uploadScript}' sh '/tmp/.zestssh-edit-ab' '/etc/nginx/nginx.conf'",
      );
    });

    test('what the dialog shows is the command, without sudo and quotes', () {
      expect(const SudoMove('/a', '/b').shown, 'mv /a /b');
      expect(const SudoCopy('/a', '/b').shown, 'cp -p /a /b');
      expect(const SudoCopy('/a', '/b', folder: true).shown, 'cp -rp /a /b');
      expect(const SudoDelete('/a').shown, 'rm /a');
      expect(const SudoDelete('/a', folder: true).shown, 'rm -r /a');
      expect(const SudoMkdir('/a').shown, 'mkdir /a');
      expect(const SudoUpload('/home/me/site.conf', '/etc/site.conf').shown, 'cp site.conf /etc/site.conf');
      expect(const SudoDownload('/etc/shadow', '/home/me/shadow').shown, 'cat /etc/shadow');
    });

    test('a path a shell other than sh could read as a command, or a Windows host, is never run', () async {
      final host = _Host();
      final ops = _ops(host);
      for (final op in [
        const SudoMove('/srv/big & calc', '/srv/b'),
        const SudoDelete("/srv/it's"),
        const SudoMkdir('-rf'),
        const SudoDelete('/C:/Users/demo/a.txt'),
      ]) {
        expect(op.runnable, isFalse, reason: op.shown);
        await expectLater(ops.run(op, password), throwsA(isA<SftpNameNotInCommandException>()));
      }
      expect(host.commands, isEmpty, reason: 'nothing was sent');
    });
  });

  group('sudo', () {
    test('is asked every time, reads the password on its standard input, prints no prompt, speaks English', () async {
      final host = _Host();
      await _ops(host).run(const SudoMkdir('/opt/new'), password);
      expect(host.commands.single, "env LC_ALL=C sudo -k -S -p '' -- mkdir -- '/opt/new'");
      expect(host.stdins.single, '$password\n', reason: 'one line, on standard input');
    });

    test('the password is on no command line and in no log line, whatever happens', () async {
      final logged = <String>[];
      final sub = Logger.root.onRecord.listen((r) => logged.add('${r.message} ${r.error ?? ''}'));
      addTearDown(sub.cancel);
      final host = _Host();
      final ops = _ops(host);
      await ops.run(const SudoMove('/etc/a', '/etc/b'), password);
      await ops.run(const SudoCopy('/etc/a', '/etc/b', folder: true), password);
      await ops.run(const SudoDelete('/etc/a', folder: true), password);
      final file = await _tempFile('upload me');
      await ops.run(SudoUpload(file.path, '/etc/c'), password);
      host.answer = (_) => (exitCode: 1, stderr: _b('Sorry, try again.\nsudo: 1 incorrect password attempt\n'));
      await expectLater(ops.run(const SudoMkdir('/opt/x'), password), throwsA(isA<SudoPasswordException>()));
      host.answer = (_) => (exitCode: 1, stderr: _b('mv: cannot move: Read-only file system'));
      await expectLater(ops.run(const SudoMove('/a', '/b'), password), throwsA(isA<SudoFailedException>()));
      expect(host.commands, hasLength(6));
      for (final c in host.commands) {
        expect(c, isNot(contains(password)));
      }
      expect(logged, isNotEmpty, reason: 'it says what it runs');
      for (final l in logged) {
        expect(l, isNot(contains(password)));
      }
    });

    test('a password with a line end in it is never sent, as sudo would give the rest to the program', () async {
      final host = _Host();
      await expectLater(
        _ops(host).run(const SudoMkdir('/opt/x'), 'abc\nrm -rf /'),
        throwsA(isA<SudoPasswordException>()),
      );
      expect(host.commands, isEmpty);
    });

    test('each refusal is told apart and has its own code', () {
      Exception r(String said, [int code = 1]) => SudoRunner.refusal(said, exitCode: code);
      expect(
        r('Sorry, try again.\nsudo: no password was provided\nsudo: 1 incorrect password attempt'),
        isA<SudoPasswordException>(),
      );
      expect(r('sudo: sorry, you must have a tty to run sudo'), isA<SudoNeedsTerminalException>());
      expect(r('sudo: a terminal is required to read the password'), isA<SudoNeedsTerminalException>());
      expect(r('deploy is not in the sudoers file.  This incident will be reported.'), isA<SudoNotAllowedException>());
      expect(r("env: 'sudo': No such file or directory", 127), isA<SudoUnavailableException>());
      expect(r('bash: sudo: command not found', 127), isA<SudoUnavailableException>());
      expect(r('sh: 1: sudo: not found'), isA<SudoUnavailableException>());
      final failed = r("rm: cannot remove '/x': Read-only file system");
      expect(failed, isA<SudoFailedException>());
      expect((failed as SudoFailedException).said, contains('Read-only file system'));

      final codes = {
        const SudoPasswordException().code,
        const SudoNotAllowedException('').code,
        const SudoUnavailableException('').code,
        const SudoNeedsTerminalException().code,
        const SudoTimeoutException().code,
      };
      expect(codes, hasLength(5));
      for (final c in codes) {
        expect(ErrorCodes.all, contains(c));
        expect(c.code, startsWith('ZS-16'));
      }
    });

    test('a host that does not answer is given up on, and says so', () async {
      final host = _Host()..throws = const SudoTimeoutException();
      await expectLater(
        _ops(host).run(const SudoDelete('/srv/x', folder: true), password),
        throwsA(isA<SudoTimeoutException>()),
      );
      expect(host.idles.single, const Duration(minutes: 10), reason: 'a whole folder may take a while');
      final one = _Host();
      await _ops(one).run(const SudoDelete('/srv/x'), password);
      expect(one.idles.single, const Duration(minutes: 2));
    });
  });

  group('an upload', () {
    test('goes to a file of its own in /tmp, sudo copies it into place, and the file in /tmp is removed', () async {
      final host = _Host();
      final file = await _tempFile('server { listen 80; }');
      await _ops(host).run(SudoUpload(file.path, '/etc/nginx/site.conf'), password);
      expect(host.putFrom, [file.path]);
      expect(host.commands.single, contains("sh '/tmp/.zestssh-edit-1' '/etc/nginx/site.conf'"));
      expect(host.removed, ['/tmp/.zestssh-edit-1']);
    });

    test('the file in /tmp is removed when sudo refuses too', () async {
      final host = _Host()..answer = (_) => (exitCode: 1, stderr: _b('Sorry, try again.'));
      final file = await _tempFile('x');
      await expectLater(
        _ops(host).run(SudoUpload(file.path, '/etc/x'), password),
        throwsA(isA<SudoPasswordException>()),
      );
      expect(host.removed, ['/tmp/.zestssh-edit-1']);
    });
  });

  group('a download', () {
    test('writes what cat printed, and the file takes its name once all of it came', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_dl_');
      addTearDown(() => dir.delete(recursive: true));
      final host = _Host()..stdout = utf8.encode('root:x:0:0\n');
      final local = '${dir.path}${Platform.pathSeparator}passwd';
      await _ops(host).run(SudoDownload('/etc/passwd', local), password);
      expect(File(local).readAsStringSync(), 'root:x:0:0\n');
      expect(File('$local.zestpart').existsSync(), isFalse);
    });

    test('the file is this account\'s alone before a byte of it is written', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_dl_');
      addTearDown(() => dir.delete(recursive: true));
      final restricted = <(String, int)>[];
      debugRestrictFileToOwner = (f) async {
        restricted.add((f.path, f.lengthSync()));
        return true;
      };
      addTearDown(() => debugRestrictFileToOwner = null);
      final host = _Host()..stdout = utf8.encode('root:x:0:0\n');
      final local = '${dir.path}${Platform.pathSeparator}shadow';
      await _ops(host).run(SudoDownload('/etc/shadow', local), password);
      expect(restricted, [('$local.zestpart', 0)]);
      expect(File(local).readAsStringSync(), 'root:x:0:0\n');
    });

    test('leaves nothing behind where sudo refused', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_dl_');
      addTearDown(() => dir.delete(recursive: true));
      final host = _Host()..answer = (_) => (exitCode: 1, stderr: _b('sudo: 3 incorrect password attempts'));
      final local = '${dir.path}${Platform.pathSeparator}shadow';
      await expectLater(
        _ops(host).run(SudoDownload('/etc/shadow', local), password),
        throwsA(isA<SudoPasswordException>()),
      );
      expect(dir.listSync(), isEmpty);
    });
  });

  // The commands, run by a real sh where this computer has one (the host's
  // sudo left out): the quotes hold, a move never replaces what is there, an
  // upload keeps a file that is there and gives a new one mode 644.
  group('in a real sh', () {
    final sh = _findSh();

    // (Git's sh on Windows makes real symbolic links only when told to.)
    Future<ProcessResult> run(Directory dir, String program) =>
        Process.run(sh!, ['-c', program], workingDirectory: dir.path, environment: {'MSYS': 'winsymlinks:nativestrict'});

    test(
      'a move does not replace what is there, and moves where nothing is',
      () async {
        final dir = await Directory.systemTemp.createTemp('zestssh_sudo_sh_');
        addTearDown(() => dir.delete(recursive: true));
        File('${dir.path}/a b').writeAsStringSync('a');
        File('${dir.path}/taken').writeAsStringSync('keep');
        var r = await run(dir, SudoFileOps.program(const SudoMove('a b', 'taken')));
        expect(r.exitCode, isNot(0));
        expect('${r.stderr}', contains('File exists'));
        expect(File('${dir.path}/taken').readAsStringSync(), 'keep');
        r = await run(dir, SudoFileOps.program(const SudoMove('a b', "it's new")));
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(File("${dir.path}/it's new").readAsStringSync(), 'a');
      },
      skip: sh == null ? 'no sh on this computer' : false,
    );

    test('an upload writes into a file that is there, and refuses a folder', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_sh_');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/tmpfile').writeAsStringSync('new text');
      File('${dir.path}/conf').writeAsStringSync('old');
      Directory('${dir.path}/folder').createSync();
      var r = await run(dir, SudoFileOps.program(const SudoUpload('x', 'conf'), temp: 'tmpfile'));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(File('${dir.path}/conf').readAsStringSync(), 'new text');
      r = await run(dir, SudoFileOps.program(const SudoUpload('x', 'folder'), temp: 'tmpfile'));
      expect(r.exitCode, isNot(0));
      expect('${r.stderr}', contains('Is a directory'));
      r = await run(dir, SudoFileOps.program(const SudoUpload('x', 'fresh'), temp: 'tmpfile'));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(File('${dir.path}/fresh').readAsStringSync(), 'new text');
      // Save as root is the same command.
      r = await run(dir, SftpService.rootWriteProgram('tmpfile', 'conf2'));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(File('${dir.path}/conf2').readAsStringSync(), 'new text');
      // Nothing is left beside the files, and a part left by an earlier try
      // is not in the way.
      File('${dir.path}/conf.zestpart').writeAsStringSync('left over');
      r = await run(dir, SudoFileOps.program(const SudoUpload('x', 'conf'), temp: 'tmpfile'));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(dir.listSync().map((e) => e.uri.pathSegments.last).where((n) => n.contains('.zestpart')), isEmpty);
    }, skip: sh == null ? 'no sh on this computer' : false);

    // A write that stops halfway (a full disk, a quota) must leave the file
    // as it was: the upload and Save as root wrote onto the file itself with
    // `cp`, which empties it first (found in a review). The stop
    // is played by a `cp` and a `cat` that empty what they are to write and
    // fail, put first on the PATH.
    test('a write as root that stops halfway leaves the file as it was, and no part beside it', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_sh_');
      addTearDown(() => dir.delete(recursive: true));
      final bin = Directory('${dir.path}/bin')..createSync();
      // cp: empties its last argument, then fails. cat: lets through nothing.
      File('${bin.path}/cp').writeAsStringSync('#!/bin/sh\nfor a in "\$@"; do last=\$a; done\n: > "\$last"\nexit 1\n');
      File('${bin.path}/cat').writeAsStringSync('#!/bin/sh\nexit 1\n');
      await run(dir, 'chmod +x bin/cp bin/cat');
      File('${dir.path}/tmpfile').writeAsStringSync('new text');
      for (final program in [
        SudoFileOps.program(const SudoUpload('x', 'sshd_config'), temp: 'tmpfile'),
        SftpService.rootWriteProgram('tmpfile', 'sshd_config'),
      ]) {
        File('${dir.path}/sshd_config').writeAsStringSync('PermitRootLogin no');
        final r = await run(dir, 'PATH="\$PWD/bin:\$PATH"; export PATH; $program');
        expect(r.exitCode, isNot(0), reason: program);
        expect(File('${dir.path}/sshd_config').readAsStringSync(), 'PermitRootLogin no',
            reason: 'the file was emptied by a write that did not finish');
        expect(dir.listSync().map((e) => e.uri.pathSegments.last).where((n) => n.contains('.zestpart')), isEmpty,
            reason: 'no part is left beside it');
      }
    }, skip: sh == null ? 'no sh on this computer' : false);

    // The part beside the file had a name anyone could tell beforehand
    // (`<file>.zestpart`) and was written as root, by name, right after an
    // `rm` of that name. In a folder others may write (the sticky /tmp among
    // them) a symbolic link put there between the two sent root's write
    // wherever it led. Played by an `rm` that, having removed a `.zestpart`,
    // puts a link to `victim` in its place. The part has a name of its own
    // now, made as it is created (mktemp), so there is no name to wait for.
    test('a symbolic link put where the part was expected is never written through', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_sh_');
      addTearDown(() => dir.delete(recursive: true));
      await run(dir, 'ln -s victim link');
      if ((await run(dir, '[ -h link ]')).exitCode != 0) {
        markTestSkipped('this sh makes no symbolic links');
        return;
      }
      final bin = Directory('${dir.path}/bin')..createSync();
      File('${bin.path}/rm').writeAsStringSync(
          '#!/bin/sh\ncommand -p rm "\$@"\nfor a in "\$@"; do case \$a in *.zestpart) ln -s victim "\$a";; esac; done\n');
      await run(dir, 'chmod +x bin/rm');
      File('${dir.path}/tmpfile').writeAsStringSync('new text');
      for (final program in [
        SudoFileOps.program(const SudoUpload('x', 'conf'), temp: 'tmpfile'),
        SftpService.rootWriteProgram('tmpfile', 'conf'),
        // And where there was no file yet.
        SudoFileOps.program(const SudoUpload('x', 'fresh'), temp: 'tmpfile'),
      ]) {
        File('${dir.path}/victim').writeAsStringSync('not yours to write');
        File('${dir.path}/conf').writeAsStringSync('old');
        final r = await run(dir, 'PATH="\$PWD/bin:\$PATH"; export PATH; $program');
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect(File('${dir.path}/victim').readAsStringSync(), 'not yours to write', reason: program);
        final written = program.contains('fresh') ? 'fresh' : 'conf';
        expect(FileSystemEntity.isLinkSync('${dir.path}/$written'), isFalse, reason: 'the file is a file, not the link');
        expect(File('${dir.path}/$written').readAsStringSync(), 'new text');
        await run(dir, 'command -p rm -f fresh conf.zestpart fresh.zestpart');
      }
    }, skip: sh == null ? 'no sh on this computer' : false);

    test('an upload, a copy and Save as root refuse a symbolic link, one that leads nowhere included', () async {
      final dir = await Directory.systemTemp.createTemp('zestssh_sudo_sh_');
      addTearDown(() => dir.delete(recursive: true));
      File('${dir.path}/tmpfile').writeAsStringSync('new text');
      await run(dir, 'ln -s victim link');
      if ((await run(dir, '[ -h link ]')).exitCode != 0) {
        markTestSkipped('this sh makes no symbolic links');
        return;
      }
      for (final program in [
        SudoFileOps.program(const SudoUpload('x', 'link'), temp: 'tmpfile'),
        SudoFileOps.program(const SudoCopy('tmpfile', 'link')),
        SftpService.rootWriteProgram('tmpfile', 'link'),
      ]) {
        final r = await run(dir, program);
        expect(r.exitCode, isNot(0), reason: program);
        expect('${r.stderr}', contains('Is a symbolic link'));
        expect(File('${dir.path}/victim').existsSync(), isFalse, reason: 'nothing written where it leads');
      }
    }, skip: sh == null ? 'no sh on this computer' : false);
  });
}

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

Future<File> _tempFile(String text) async {
  final dir = await Directory.systemTemp.createTemp('zestssh_sudo_up_');
  addTearDown(() => dir.delete(recursive: true));
  return File('${dir.path}${Platform.pathSeparator}site.conf')..writeAsStringSync(text);
}

String? _findSh() {
  for (final c in ['/bin/sh', r'C:\Program Files\Git\usr\bin\sh.exe', r'C:\Program Files\Git\bin\sh.exe']) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

SudoFileOps _ops(_Host host) => SudoFileOps(
  runner: SudoRunner(host.exec),
  putTemp: (local) async {
    host.putFrom.add(local);
    return '/tmp/.zestssh-edit-${host.putFrom.length}';
  },
  removeTemp: (temp) async => host.removed.add(temp),
);

/// A host's exec channel: what was run, what went in, and what it answers.
class _Host {
  final commands = <String>[];
  final stdins = <String>[];
  final idles = <Duration>[];
  final putFrom = <String>[];
  final removed = <String>[];
  List<int> stdout = const [];
  Object? throws;
  SudoExecResult Function(String command)? answer;

  Future<SudoExecResult> exec(
    String command, {
    required Uint8List stdin,
    StreamConsumer<List<int>>? stdoutTo,
    required Duration idle,
  }) async {
    commands.add(command);
    stdins.add(utf8.decode(stdin));
    idles.add(idle);
    if (throws != null) throw throws!;
    final result = answer?.call(command) ?? (exitCode: 0, stderr: Uint8List(0));
    if (stdoutTo != null) await Stream<List<int>>.value(result.exitCode == 0 ? stdout : const []).pipe(stdoutTo);
    return result;
  }
}

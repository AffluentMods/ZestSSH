import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/utils/command_text.dart';

/// Records the commands a service sends, and runs none.
class _Recorder implements SSHClient {
  final commands = <String>[];

  @override
  Future<Uint8List> runCapped(String command, {required int maxBytes, required Duration timeout}) async {
    commands.add(command);
    return Uint8List.fromList('${'ab' * 32}  file\n'.codeUnits);
  }

  @override
  Future<SSHSession> execute(String command, {SSHPtyConfig? pty, SSHX11Config? x11, Map<String, String>? environment}) async {
    commands.add(command);
    throw const _Sent();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sent implements Exception {
  const _Sent();
}

/// A name a server lists reaches a command line on the server only where no
/// shell can read it as part of a command (found in a security
/// review).
///
/// A name went in single quotes with POSIX escaping, which holds for sh,
/// bash, zsh, dash and ksh and for no other shell: cmd.exe (Windows'
/// OpenSSH, as it comes) has no single quotes, so `&` in them runs what
/// follows; PowerShell ends the string at a quote and runs what follows `;`;
/// fish reads `\'` inside single quotes as a quote. A 5 MB file named
/// `big & <cmd> & rem .bin` on a Windows host ran `<cmd>` as the person who
/// downloaded it, at the checksum after the download; a folder of such a name
/// did with Open terminal here. Now such a name goes into no command: the
/// checksum says it could not be had, following the file says why, and the
/// folder is not typed.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  // What a name can hold and still stand in quotes for every shell.
  const fine = [
    '/home/deploy/release-2024.tar.gz',
    '/srv/my app/logs',
    '/srv/Photos (2024)/[draft] #3',
    '/srv/a+b@c,d:e=f~g',
    '/srv/café/日本語/Документы/한국어/हिन्दी/عربي',
    '/srv/caf\u0065\u0301',
    '/srv/\u{1F600} notes',
    '/C:/Users/demo/file.bin',
  ];

  // What a shell other than a POSIX one could read as part of a command.
  const hostile = [
    "/srv/it's here",
    '/srv/big & echo ZEST_POC & rem .bin',
    '/srv/a | b',
    '/srv/a; b',
    '/srv/a > b',
    '/srv/a < b',
    '/srv/a ^ b',
    '/srv/100%PATH%',
    '/srv/wow!',
    r'/srv/$HOME',
    '/srv/`id`',
    '/srv/a"b',
    r'/srv/a\b',
    r"/srv/\'; touch pwned; #",
    '/srv/a*b',
    '/srv/a?b',
    // Curly quotes are quotes to PowerShell; other dashes, its hyphen.
    '/srv/a\u2018b',
    '/srv/a\u2019; calc; #',
    '/srv/a\u201cb',
    '/srv/a\u201eb',
    '/srv/a\u2013b',
    '/srv/a\u2014b',
    // Spaces other than the space, controls, formatting, modifier letters.
    '/srv/a\u00a0b',
    '/srv/a\u3000b',
    '/srv/a\nb',
    '/srv/a\x15b',
    '/srv/a\u202eb',
    '/srv/a\u200db',
    '/srv/a\u02bcb',
    // Fullwidth forms that look like operators.
    '/srv/a\uff06b',
    '/srv/a\uff07b',
    // Taken for an option.
    '-rf',
    '',
  ];

  group('what may stand in a command line', () {
    test('a name of letters of any script, digits, symbols, spaces and plain punctuation', () {
      for (final name in fine) {
        expect(CommandText.standsInAnyShell(name), isTrue, reason: name);
      }
      expect(CommandText.cdInto('/srv/Photos (2024)'), "cd '/srv/Photos (2024)'");
    });

    test('nothing a shell other than a POSIX one could read as part of a command', () {
      for (final name in hostile) {
        expect(CommandText.standsInAnyShell(name), isFalse, reason: name);
        expect(CommandText.cdInto(name), isNull, reason: name);
      }
    });
  });

  group('the checksum of a remote file', () {
    test('a name no shell can misread is checked on the host', () async {
      final client = _Recorder();
      final hash = await SftpService(client).sha256Remote('/srv/my app/big file (1).bin');
      expect(hash, 'ab' * 32);
      expect(client.commands.single, "sha256sum '/srv/my app/big file (1).bin' 2>/dev/null || "
          "shasum -a 256 '/srv/my app/big file (1).bin' 2>/dev/null");
    });

    test('any other is not sent to the host, and the check says it could not be had', () async {
      for (final name in hostile) {
        final client = _Recorder();
        expect(await SftpService(client).sha256Remote(name), isNull, reason: name);
        expect(client.commands, isEmpty, reason: name);
      }
    });

    test("nor is a Windows host's, which has no sha256sum", () async {
      for (final path in ['/C:/share/big.bin', '/d:/x', '/C:']) {
        final client = _Recorder();
        expect(await SftpService(client).sha256Remote(path), isNull, reason: path);
        expect(client.commands, isEmpty, reason: path);
      }
      expect(isWindowsDrivePath('/srv/C:/x'), isFalse);
      expect(isWindowsDrivePath('/Cx:/x'), isFalse);
    });
  });

  group('following a remote file', () {
    test('a name no shell can misread is followed', () async {
      final client = _Recorder();
      await expectLater(SftpService(client).tailFile('/var/log/app (1).log'), throwsA(isA<_Sent>()));
      expect(client.commands.single, endsWith(" sh '/var/log/app (1).log'"));
    });

    test('any other is not, nothing is sent, and the person is told why', () async {
      for (final name in hostile) {
        final client = _Recorder();
        Object? thrown;
        try {
          await SftpService(client).tailFile(name);
        } catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SftpNameNotInCommandException>(), reason: name);
        expect(client.commands, isEmpty, reason: name);
        expect(sftpErrorMessage(thrown!), en.remoteNameNotInCommand);
        if (name.isNotEmpty) expect('$thrown', isNot(contains(name)), reason: 'the name stays out of what is copied');
      }
    });
  });

  // The proof, on the shells a Windows host runs: what may stand in a command
  // line is read as it is, and what the review's names did is not sent.
  group('on this computer\'s shells', () {
    const everyPlainCharacter = 'Az09 ._/+@,:=~#()[]-';

    test('cmd.exe and PowerShell read a name that may stand there as it is', () async {
      expect(CommandText.standsInAnyShell(everyPlainCharacter), isTrue);
      final q = CommandText.quoted(everyPlainCharacter);
      final cmd = await Process.run('cmd.exe', ['/d', '/c', 'echo $q& echo ZEST_END']);
      expect('${cmd.stdout}'.split(RegExp(r'\r?\n')).first, q, reason: 'cmd.exe has no quotes: they are text');
      final ps = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', 'Write-Output $q']);
      expect('${ps.stdout}'.trim(), everyPlainCharacter);
    }, skip: !Platform.isWindows);

    test("the names a review found ran their command through cmd.exe and PowerShell, and are not sent now", () async {
      const viaCmd = '/C:/share/big & echo ZEST_POC_INJECTED & rem .bin';
      final old = "'${viaCmd.replaceAll("'", r"'\''")}'";
      final ran = await Process.run('cmd.exe', ['/d', '/c', 'sha256sum $old 2>nul']);
      expect('${ran.stdout}', contains('ZEST_POC_INJECTED'), reason: 'what quoting alone did');
      expect(CommandText.cdInto(viaCmd), isNull);
      final client = _Recorder();
      expect(await SftpService(client).sha256Remote(viaCmd), isNull);
      expect(client.commands, isEmpty);

      const viaPowerShell = "/C:/share/a'; Write-Output ZEST_POC_INJECTED; #";
      final oldPs = "cd '${viaPowerShell.replaceAll("'", r"'\''")}'";
      final psRan = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', oldPs]);
      expect('${psRan.stdout}', contains('ZEST_POC_INJECTED'), reason: 'what quoting alone did');
      expect(CommandText.cdInto(viaPowerShell), isNull);
    }, skip: !Platform.isWindows);
  });
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';

/// The SFTP app-service layer had no test coverage at all: the protocol
/// under `packages/zest_ssh_core` is well tested, but the glue that decides
/// what a hostile server's filename becomes on disk, whether a partial
/// transfer may be resumed, and whether a "finished" transfer actually moved
/// every byte was not. Those are exactly the decisions that corrupt or
/// overwrite user data when they go wrong, so they live in pure functions
/// and are exercised here.
void main() {
  group('safeChildName - names Windows, older ones too, takes for a device', () {
    test('a space before the first dot makes no other name', () {
      for (final name in ['CON .txt', 'NUL .tar.gz', 'COM1 .log', 'aux  .c', 'PRN   .x']) {
        expect(safeChildName(name, forWindows: true), '_$name');
      }
    });

    test('the superscript digits, and 0', () {
      for (final name in ['COM¹', 'COM².txt', 'com³', 'LPT¹', 'lpt².txt', 'LPT³', 'COM0', 'LPT0', 'com0.log']) {
        expect(safeChildName(name, forWindows: true), '_$name');
      }
    });

    test("the console's own names", () {
      for (final name in ['CONIN\$', 'CONOUT\$', 'conin\$.txt', 'conout\$.log']) {
        expect(safeChildName(name, forWindows: true), '_$name');
      }
    });

    test('names that only start the same are themselves', () {
      for (final name in ['CONSOLE.txt', 'COM10', 'LPT.txt', 'NULL', 'COMPANY.pdf', 'con-fig', 'CONIN', 'aux.c.bak2'.replaceFirst('aux', 'auxiliary')]) {
        expect(safeChildName(name, forWindows: true), name);
      }
    });

    test('on any other system they are names like any', () {
      for (final name in ['CON .txt', 'COM¹', 'CONIN\$', 'COM0']) {
        expect(safeChildName(name, forWindows: false), name);
      }
    });
  });

  group('safeChildName - hostile server-supplied names', () {
    test('a normal name passes through untouched', () {
      expect(safeChildName('report.pdf', forWindows: false), 'report.pdf');
      expect(safeChildName('report.pdf', forWindows: true), 'report.pdf');
    });

    test('POSIX absolute path is reduced to its leaf', () {
      // Without this, package:path's join() DISCARDS the destination
      // directory and the "download" writes to /etc/cron.d instead.
      expect(safeChildName('/etc/cron.d/evil', forWindows: false), 'evil');
    });

    test('Windows absolute path is reduced to its leaf', () {
      expect(
        safeChildName(r'C:\Windows\System32\evil.dll', forWindows: false),
        'evil.dll',
      );
    });

    test('backslashes are stripped even on POSIX hosts', () {
      // The same downloaded name can later be written on a Windows peer, so
      // a POSIX host must not accept a backslash as part of one component.
      expect(safeChildName(r'a\b', forWindows: false), 'b');
    });

    test('parent-directory traversal cannot survive', () {
      expect(safeChildName('../../etc/passwd', forWindows: false), 'passwd');
      expect(safeChildName('..', forWindows: false), 'file');
      expect(safeChildName('.', forWindows: false), 'file');
    });

    test('NUL and control characters are removed', () {
      // NUL truncates the path at the syscall boundary on POSIX.
      expect(safeChildName('evil\x00.txt', forWindows: false), 'evil.txt');
      expect(safeChildName('a\x1fb', forWindows: false), 'ab');
    });

    test('unicode direction overrides are removed', () {
      // U+202E renders "gpj.exe" as "exe.jpg" in the file list.
      final spoofed = 'photo\u202egpj.exe';
      final safe = safeChildName(spoofed, forWindows: false);
      expect(safe.contains('\u202e'), isFalse);
      expect(safe, 'photogpj.exe');
    });

    test('direction marks and characters that take no room are removed; the joiners a script spells with stay '
        '(found in a security review)', () {
      expect(safeChildName('re\u200eport\u200f.\u061cpdf\u200b\u2060\ufeff', forWindows: false), 'report.pdf');
      // Two names that looked the same are one name.
      expect(safeChildName('notes\u200b.txt', forWindows: false), safeChildName('notes.txt', forWindows: false));
      // Persian spells with U+200C, an emoji family with U+200D.
      expect(safeChildName('\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645.txt', forWindows: false), contains('\u200c'));
      expect(safeChildName('a\u200db', forWindows: false), 'a\u200db');
    });

    test('a long name is cut between two characters, never inside one', () {
      // 199 letters, then a character of two UTF-16 units across the 200th.
      final name = '${'a' * 199}\u{1F600}${'b' * 50}';
      final safe = safeChildName(name, forWindows: false);
      expect(safe.length, lessThanOrEqualTo(maxComponentLength));
      expect(safe.codeUnits.any((c) => c >= 0xD800 && c <= 0xDFFF), isFalse, reason: 'no half of a character is left');
      expect(safe, 'a' * 199);
    });

    test('a long name in a script of three bytes a character fits the 255 bytes a name may have, with the ending a '
        'download adds while it runs', () {
      final name = '${'\u6587' * 180}.tar.gz';
      final safe = safeChildName(name, forWindows: false);
      expect(utf8.encode(safe).length, lessThanOrEqualTo(maxComponentBytes));
      expect(utf8.encode('$safe.zestpart.meta').length, lessThanOrEqualTo(255));
      expect(safe.endsWith('.gz'), isTrue);
      expect(safe.startsWith('\u6587' * 70), isTrue);
    });

    test('a name of any length from a server is worked on only at its end', () {
      final safe = safeChildName('${'x' * 200000}.log', forWindows: false);
      expect(safe.length, maxComponentLength);
      expect(safe.endsWith('.log'), isTrue);
    });

    test('empty or whitespace-only names become a placeholder', () {
      expect(safeChildName('', forWindows: false), 'file');
      expect(safeChildName('   ', forWindows: false), 'file');
    });

    test('over-long names are truncated but keep their extension', () {
      final long = '${'a' * 500}.tar.gz';
      final safe = safeChildName(long, forWindows: false);
      expect(safe.length, lessThanOrEqualTo(maxComponentLength));
      expect(safe.endsWith('.gz'), isTrue);
    });

    test('over-long extensionless names are simply truncated', () {
      final safe = safeChildName('b' * 500, forWindows: false);
      expect(safe.length, maxComponentLength);
    });

    group('Windows-specific rules', () {
      test('NTFS alternate data stream separator is neutralised', () {
        // "notes.txt:hidden" writes a stream the file listing never shows.
        expect(safeChildName('notes.txt:hidden', forWindows: true),
            'notes.txt_hidden');
      });

      test('reserved device names are prefixed', () {
        for (final name in ['CON', 'con', 'NUL', 'com1', 'LPT9']) {
          final safe = safeChildName(name, forWindows: true);
          expect(safe, '_$name',
              reason: '$name is a Win32 device, not a file');
        }
      });

      test('reserved names are still reserved with an extension', () {
        expect(safeChildName('CON.txt', forWindows: true), '_CON.txt');
      });

      test('trailing dots and spaces are stripped', () {
        // Win32 strips these silently, so "evil " and "evil" collide and an
        // overwrite check on one can be defeated by the other.
        expect(safeChildName('evil ', forWindows: true), 'evil');
        expect(safeChildName('evil.', forWindows: true), 'evil');
        expect(safeChildName('evil. . ', forWindows: true), 'evil');
      });

      test('other illegal Win32 characters are replaced', () {
        expect(safeChildName('a<b>c|d?e*f"g', forWindows: true),
            'a_b_c_d_e_f_g');
      });

      test('POSIX hosts keep names that are only reserved on Windows', () {
        // aux.c is a real file in plenty of C projects.
        expect(safeChildName('aux.c', forWindows: false), 'aux.c');
      });
    });
  });

  group('SftpPartialMeta', () {
    test('round-trips through encode/decode', () {
      const meta = SftpPartialMeta(
        remotePath: '/srv/data/big.iso',
        remoteSize: 4096,
        remoteMtime: 1735689600,
      );
      final decoded = SftpPartialMeta.decode(meta.encode());
      expect(decoded, isNotNull);
      expect(decoded!.remotePath, '/srv/data/big.iso');
      expect(decoded.remoteSize, 4096);
      expect(decoded.remoteMtime, 1735689600);
    });

    test('survives a missing mtime', () {
      const meta =
          SftpPartialMeta(remotePath: '/a/b', remoteSize: 10, remoteMtime: null);
      final decoded = SftpPartialMeta.decode(meta.encode());
      expect(decoded!.remoteMtime, isNull);
      expect(decoded.remoteSize, 10);
    });

    test('malformed sidecars decode to null rather than throwing', () {
      // A bad sidecar must degrade to "start over", never to a bogus resume.
      expect(SftpPartialMeta.decode(null), isNull);
      expect(SftpPartialMeta.decode(''), isNull);
      expect(SftpPartialMeta.decode('not json'), isNull);
      expect(SftpPartialMeta.decode('[]'), isNull);
      expect(SftpPartialMeta.decode('{"remote":"","size":1}'), isNull);
      expect(SftpPartialMeta.decode('{"size":1}'), isNull);
      expect(SftpPartialMeta.decode('{"remote":"/a"}'), isNull);
      expect(SftpPartialMeta.decode('{"remote":"/a","size":-1}'), isNull);
      expect(SftpPartialMeta.decode('{"remote":"/a","size":"10"}'), isNull);
    });
  });

  group('decideResume', () {
    const meta = SftpPartialMeta(
      remotePath: '/srv/big.iso',
      remoteSize: 1000,
      remoteMtime: 111,
      source: 'sftp:aaaa',
    );

    ResumeDecision call({
      bool allowResume = true,
      bool partialExists = true,
      int partialLength = 400,
      SftpPartialMeta? sidecar = meta,
      String remotePath = '/srv/big.iso',
      int remoteSize = 1000,
      int? remoteMtime = 111,
      String? source = 'sftp:aaaa',
    }) =>
        decideResume(
          allowResume: allowResume,
          partialExists: partialExists,
          partialLength: partialLength,
          meta: sidecar,
          remotePath: remotePath,
          remoteSize: remoteSize,
          remoteMtime: remoteMtime,
          source: source,
        );

    test('the same path and size on another server starts fresh', () {
      final d = call(source: 'sftp:bbbb');
      expect(d.isResume, isFalse);
      expect(d.discardPartial, isTrue);
      expect(d.reason, contains('another server'));
    });

    test('the same address reached as FTPS is another server than as SFTP', () {
      expect(call(source: 'ftps:aaaa').isResume, isFalse);
    });

    test('a note from before the server was written down starts fresh, and so does a server that cannot be told',
        () {
      const old = SftpPartialMeta(remotePath: '/srv/big.iso', remoteSize: 1000, remoteMtime: 111);
      expect(call(sidecar: old).isResume, isFalse);
      expect(call(sidecar: SftpPartialMeta.decode(old.encode())).isResume, isFalse);
      expect(call(source: null).isResume, isFalse);
    });

    test('the server is written into the note and read back, as a hash and never by name', () {
      final source = transferSource('sftp', [1, 2, 3, 0, ...'deploy'.codeUnits]);
      expect(source, matches(RegExp(r'^sftp:[0-9a-f]{32}$')));
      expect(source, isNot(transferSource('sftp', [1, 2, 4, 0, ...'deploy'.codeUnits])));
      expect(source, isNot(transferSource('sftp', [1, 2, 3, 0, ...'alex'.codeUnits])));
      final note = SftpPartialMeta(remotePath: '/srv/big.iso', remoteSize: 1000, source: source).encode();
      expect(note, isNot(contains('deploy')));
      expect(SftpPartialMeta.decode(note)!.source, source);
    });

    test('resumes when everything matches', () {
      final d = call();
      expect(d.isResume, isTrue);
      expect(d.startOffset, 400);
      expect(d.discardPartial, isFalse);
    });

    test('starts fresh when there is no partial', () {
      final d = call(partialExists: false, partialLength: 0);
      expect(d.isResume, isFalse);
      expect(d.startOffset, 0);
    });

    test('starts fresh when the partial is empty', () {
      expect(call(partialLength: 0).isResume, isFalse);
    });

    test('starts fresh when resume is disabled', () {
      final d = call(allowResume: false);
      expect(d.isResume, isFalse);
      expect(d.discardPartial, isTrue);
    });

    test('starts fresh when the sidecar is missing', () {
      // No provenance means we cannot prove the bytes belong to this file.
      expect(call(sidecar: null).isResume, isFalse);
    });

    test('starts fresh when the partial belongs to a different file', () {
      expect(call(remotePath: '/srv/other.iso').isResume, isFalse);
    });

    test('starts fresh when the remote size changed', () {
      // The file was replaced - appending would splice two different files.
      expect(call(remoteSize: 2000).isResume, isFalse);
    });

    test('starts fresh when the remote mtime changed', () {
      expect(call(remoteMtime: 999).isResume, isFalse);
    });

    test('resumes when either side omits the mtime', () {
      // Plenty of servers omit mtime; treating absent as "changed" would
      // disable resume everywhere.
      expect(call(remoteMtime: null).isResume, isTrue);
      expect(
        call(
          sidecar: const SftpPartialMeta(
            remotePath: '/srv/big.iso',
            remoteSize: 1000,
            source: 'sftp:aaaa',
          ),
        ).isResume,
        isTrue,
      );
    });

    test('starts fresh when the remote size is unknown', () {
      expect(call(remoteSize: 0).isResume, isFalse);
    });

    test('starts fresh when the partial is larger than the source', () {
      // Corrupt or stale staging file.
      expect(call(partialLength: 5000).isResume, isFalse);
    });

    test('reports completion when the partial already covers the file', () {
      final d = call(partialLength: 1000);
      expect(d.startOffset, 1000);
      expect(d.discardPartial, isFalse);
      expect(d.reason, contains('complete'));
    });
  });

  group('verifyTransferSize', () {
    test('accepts an exact match', () {
      expect(
        () => verifyTransferSize(path: '/a', expected: 100, actual: 100),
        returnsNormally,
      );
    });

    test('rejects a short transfer', () {
      // The dangerous case: a truncated file that renames cleanly onto the
      // destination looks like success to the user and to later size checks.
      expect(
        () => verifyTransferSize(path: '/a', expected: 100, actual: 99),
        throwsA(isA<SftpIntegrityException>()),
      );
    });

    test('rejects an over-long transfer', () {
      expect(
        () => verifyTransferSize(path: '/a', expected: 100, actual: 101),
        throwsA(isA<SftpIntegrityException>()),
      );
    });

    test('skips verification when the source size is unknown', () {
      // Character devices, /proc entries and some object stores report 0.
      expect(
        () => verifyTransferSize(path: '/a', expected: 0, actual: 4096),
        returnsNormally,
      );
    });

    test('the exception says which file, and the two numbers; what became of the destination is not its to say', () {
      final e = SftpIntegrityException(
        path: '/srv/big.iso',
        expected: 100,
        actual: 40,
      );
      expect(e.toString(), 'SftpIntegrityException: "/srv/big.iso" should be 100 bytes but 40 bytes were transferred.');
      // (It said that the destination was left unchanged, which a file that was written where it is was not.)
    });
  });
}

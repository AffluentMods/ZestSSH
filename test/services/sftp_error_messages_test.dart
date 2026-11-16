import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart' show SftpFileTooLargeException, SftpWrittenInPlaceException;
import 'package:zestssh/services/sftp_transfer_safety.dart' show SftpIntegrityException;
import 'package:zestssh/services/transfer_cancel_token.dart';

/// The SFTP UI used to surface failures as a raw `e.toString()`
/// ("SftpStatusError: Failure(code 4)"), which tells a user nothing. These
/// assertions pin the mapping so a regression shows up as a failing test
/// rather than as an unreadable toast. They are said in the app's language
/// (3.0: they were English only).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final de = lookupAppLocalizations(const Locale('de'));

  String say(Object error, {String? name, SftpOp op = SftpOp.generic}) =>
      sftpErrorMessage(error, name: name, op: op, l10n: en);

  SftpStatusError status(int code, [String message = '']) => SftpStatusError(code, message);

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  test('a folder past what a listing takes is said as that, with the number, in the language of the app', () {
    final error = SftpListingTooLongError('/srv/endless', 1000000);
    expect(say(error, name: 'endless', op: SftpOp.list),
        'This folder lists more than 1,000,000 items, more than ZestSSH takes of one folder. Use a terminal to work in it.');
    expect(sftpErrorMessage(error, name: 'endless', op: SftpOp.list, l10n: de), contains('1.000.000'));
  });

  group('protocol status codes', () {
    test('no-such-file names the missing item', () {
      expect(say(status(SftpStatusCode.noSuchFile, 'No such file'), name: 'notes.txt', op: SftpOp.download),
          'The server no longer has "notes.txt".');
    });

    test('no-such-file on upload blames the destination folder', () {
      expect(say(status(SftpStatusCode.noSuchFile, 'No such file'), name: 'notes.txt', op: SftpOp.upload),
          'The destination folder no longer exists: it may have been moved or deleted on the server.');
    });

    test('permission-denied says what could not be done, for every operation', () {
      final denied = status(SftpStatusCode.permissionDenied, 'Permission denied');
      expect({for (final op in SftpOp.values) op: say(denied, name: 'secrets', op: op)}, {
        SftpOp.list: "Permission denied: your account can't open \"secrets\" on the server.",
        SftpOp.download: "Permission denied: your account can't read \"secrets\" on the server.",
        SftpOp.upload: "Permission denied: your account can't write \"secrets\" on the server.",
        SftpOp.delete: "Permission denied: your account can't delete \"secrets\" on the server.",
        SftpOp.rename: "Permission denied: your account can't rename \"secrets\" on the server.",
        SftpOp.mkdir: "Permission denied: your account can't create \"secrets\" on the server.",
        SftpOp.chmod: "Permission denied: your account can't change the permissions of \"secrets\" on the server.",
        SftpOp.generic: "Permission denied: your account can't access \"secrets\" on the server.",
      });
    });

    test('generic failure surfaces the server text when it says something', () {
      expect(say(status(SftpStatusCode.failure, 'Disk quota exceeded.'), name: 'big.iso', op: SftpOp.upload),
          'The server refused the operation: Disk quota exceeded');
    });

    test('generic failure falls back to op-specific advice when silent', () {
      final silent = status(SftpStatusCode.failure);
      expect(say(silent, name: 'logs', op: SftpOp.delete),
          "The server refused to delete \"logs\". If it's a folder, it may not be empty.");
      expect(say(silent, op: SftpOp.upload), 'The server refused the upload. The disk may be full or over quota.');
      expect(say(silent, op: SftpOp.rename),
          'The server refused the rename. A file with that name may already exist.');
      expect(say(silent, name: 'logs', op: SftpOp.chmod), 'The server refused the operation on "logs".');
    });

    test('a message the server garbled, a lost connection, an operation it lacks', () {
      expect(say(status(SftpStatusCode.badMessage, 'x')), "The server sent an answer ZestSSH couldn't understand.");
      for (final code in [SftpStatusCode.noConnection, SftpStatusCode.connectionLost]) {
        expect(say(status(code, 'x')), 'The connection to the server was lost.');
      }
      expect(say(status(SftpStatusCode.opUnsupported, 'nope')), "This server doesn't support that operation.");
    });

    test('an unknown status code still produces something actionable', () {
      expect(say(status(99, 'weird failure')), 'The server reported an error: weird failure');
      expect(say(status(99)), 'The server reported an error (code 99).');
    });
  });

  group('other SFTP errors', () {
    test('aborted session', () {
      expect(say(SftpAbortError('Connection closed')), 'The SFTP session closed before the operation finished.');
    });

    test('unsupported extension', () {
      expect(say(SftpExtensionUnsupportedError('statvfs@openssh.com')), "This server doesn't support that operation.");
    });

    test('any other SFTP error says what it said, or that the operation failed', () {
      expect(say(SftpError('Directory not empty.')), 'Directory not empty');
      expect(say(SftpError('  ')), 'The SFTP operation failed.');
    });

    test('an error of any other kind says what it said', () {
      expect(say(const FormatException('bad input')), 'bad input');
    });

    test('cancellation is not phrased as a failure', () {
      expect(say(const TransferCancelledException()), 'Cancelled.');
    });

    test('a file too large for the editor', () {
      expect(say(const SftpFileTooLargeException('/srv/app/huge.log', 900000000, 52428800), name: 'huge.log'),
          'This file is too large to open in the editor. Download it instead.');
    });

    test('a file written where it is: what broke it off ends as a sentence, before what that leaves is said', () {
      String said(Object cause, [AppLocalizations? t]) => sftpErrorMessage(
          SftpWrittenInPlaceException('/srv/app/conf', cause),
          name: 'conf', op: SftpOp.upload, l10n: t ?? en);
      const leaves = 'On the server, "conf" could only be written where it is, so what it holds there now is part of '
          'the new content. Save or upload it again.';
      // What a server or a system said ends in no full stop: one is put behind it. (The two ran together.)
      expect(said(status(SftpStatusCode.failure, 'Disk quota exceeded')),
          'The server refused the operation: Disk quota exceeded. $leaves');
      expect(said(const FileSystemException('', '', OSError('The device is not ready', 21))),
          'Local file error: The device is not ready. $leaves');
      // A sentence that ends as one is left as it is, in languages that end theirs with another mark as well.
      expect(said(const TransferCancelledException()), 'Cancelled. $leaves');
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        expect(said(const TransferCancelledException(), t),
            '${t.sftpErrCancelled} ${t.sftpErrWrittenInPlace(t.sftpErrNamed('conf'))}', reason: '$locale');
        expect(said(status(SftpStatusCode.failure, 'Disk quota exceeded'), t),
            '${t.sftpErrRefusedBecause('Disk quota exceeded')}. ${t.sftpErrWrittenInPlace(t.sftpErrNamed('conf'))}',
            reason: '$locale');
      }
    });

    test('another number of bytes at the far end than were sent: how many, and what that left', () {
      const short = SftpIntegrityException(path: '/srv/app/conf', expected: 4096, actual: 1024);
      // (It said its own name, the path, and that the destination was left unchanged, in English.)
      expect(say(short, name: 'conf', op: SftpOp.upload),
          '4096 bytes were sent and 1024 arrived. What arrived was not kept, and anything it was to replace is untouched.');
      // Written where it is, what it left is the file with part of the new content: that is said, and not that
      // nothing was touched.
      expect(
        say(const SftpWrittenInPlaceException('/srv/app/conf', short), name: 'conf', op: SftpOp.upload),
        '4096 bytes were sent and 1024 arrived. On the server, "conf" could only be written where it is, so what it '
        'holds there now is part of the new content. Save or upload it again.',
      );
    });
  });

  group('local filesystem errors', () {
    test('disk full is called out specifically', () {
      for (final code in [28, 112]) {
        expect(say(FileSystemException('write failed', '/tmp/x', OSError('No space left on device', code))),
            'Not enough free space on this device to finish the transfer.');
      }
    });

    test('access denied is called out specifically', () {
      for (final code in [13, 1, 5]) {
        expect(say(FileSystemException('open failed', '/tmp/x', OSError('Permission denied', code)), name: 'x'),
            'Your system denied access to "x".');
      }
      expect(say(const PathAccessException('/tmp/x', OSError('Access is denied', 5)), name: 'x'),
          "Your system denied access to \"x\". Check that the file isn't read-only or open in another program.");
      expect(say(const PathNotFoundException('/tmp/x', OSError('Not found', 2)), name: 'x'),
          'This device no longer has "x".');
    });

    test('a generic filesystem error still surfaces the OS text', () {
      expect(say(const FileSystemException('failed', '/tmp/x', OSError('Too many open files', 24))),
          'Local file error: Too many open files');
      expect(say(const FileSystemException('read failed')), 'Local file error: read failed');
      expect(say(const FileSystemException('')), 'Local file error.');
    });

    test('our own path-traversal rejection is explained', () {
      expect(say(ArgumentError('Path traversal detected in local path: ../../etc')),
          'That path is not allowed: Path traversal detected in local path: ../../etc');
      expect(say(ArgumentError()), 'That path is not allowed.');
    });
  });

  group('message hygiene', () {
    test('an unnamed target still reads as a sentence', () {
      final msg = say(status(SftpStatusCode.noSuchFile, 'gone'));
      expect(msg, 'The server no longer has the item.');
      expect(say(status(SftpStatusCode.noSuchFile, 'gone'), name: ''), msg);
    });

    test('redundant exception labels are stripped from server text', () {
      expect(say(status(SftpStatusCode.failure, 'SftpError: Directory not empty')),
          'The server refused the operation: Directory not empty');
    });

    test('"Instance of ..." is never shown to the user', () {
      final msg = say(_Opaque());
      expect(msg, isNot(contains('Instance of')));
      expect(msg, 'The operation failed.');
    });
  });

  group('the language', () {
    test('is the app\'s own when none is given', () {
      L10nGlobal.update(de);
      expect(sftpErrorMessage(status(SftpStatusCode.noSuchFile), name: 'notes.txt'),
          'Auf dem Server gibt es „notes.txt“ nicht mehr.');
      expect(sftpErrorMessage(status(SftpStatusCode.noSuchFile)), 'Auf dem Server gibt es das Element nicht mehr.');
    });

    test('is the one given, and what the server said stays as it said it', () {
      final fr = lookupAppLocalizations(const Locale('fr'));
      expect(sftpErrorMessage(status(SftpStatusCode.permissionDenied), name: 'secrets', op: SftpOp.delete, l10n: fr),
          'Autorisation refusée : votre compte ne peut pas supprimer « secrets » sur le serveur.');
      expect(sftpErrorMessage(status(SftpStatusCode.failure, 'Disk quota exceeded'), l10n: de),
          'Der Server hat den Vorgang abgelehnt: Disk quota exceeded');
    });

    test('every message is said in every language the app speaks', () {
      final errors = <(Object, SftpOp)>[
        for (final code in [
          SftpStatusCode.noSuchFile,
          SftpStatusCode.permissionDenied,
          SftpStatusCode.failure,
          SftpStatusCode.badMessage,
          SftpStatusCode.connectionLost,
          SftpStatusCode.opUnsupported,
          99,
        ])
          for (final op in SftpOp.values) (status(code), op),
        (SftpAbortError('x'), SftpOp.generic),
        (const TransferCancelledException(), SftpOp.generic),
        (const SftpFileTooLargeException('/srv/app/huge.log', 900000000, 52428800), SftpOp.generic),
        (const SftpIntegrityException(path: '/srv/app/conf', expected: 4096, actual: 1024), SftpOp.generic),
        (
          const SftpWrittenInPlaceException(
              '/srv/app/conf', SftpIntegrityException(path: '/srv/app/conf', expected: 4096, actual: 1024)),
          SftpOp.generic,
        ),
        (const FileSystemException('', '', OSError('', 28)), SftpOp.generic),
        (const FileSystemException('', '', OSError('', 13)), SftpOp.generic),
        (const FileSystemException(''), SftpOp.generic),
        (const PathAccessException('', OSError('', 5)), SftpOp.generic),
        (const PathNotFoundException('', OSError('', 2)), SftpOp.generic),
        (ArgumentError(), SftpOp.generic),
        (_Opaque(), SftpOp.generic),
      ];
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        for (final (error, op) in errors) {
          for (final name in [null, 'notes.txt']) {
            final msg = sftpErrorMessage(error, name: name, op: op, l10n: t);
            expect(msg.trim(), isNotEmpty, reason: '$locale $error $op');
            if (locale.languageCode != 'en') {
              expect(msg, isNot(sftpErrorMessage(error, name: name, op: op, l10n: en)),
                  reason: '$locale says $error the English way');
            }
            if (name != null && msg.contains('notes')) expect(msg, contains('notes.txt'));
          }
        }
      }
    });
  });
}

/// An exception whose toString() is useless - the fallback path must not
/// leak "Instance of '_Opaque'" into the UI.
class _Opaque implements Exception {}

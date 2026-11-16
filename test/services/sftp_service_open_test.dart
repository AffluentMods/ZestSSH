import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';

import '../helpers/played_sftp_host.dart';

/// Whether a file service is open (3.0, the SSH core's audit: what a file
/// pane does after its connection dropped and came back), through the app's
/// own file service with the host played by the test.
///
/// It said that it was open from the moment it had been opened until the
/// app closed it, whatever had become of its session meanwhile. Everything
/// that asks before it uses one (the list of hosts a file pane can show, a
/// pane that is handed one, a screen that opens one for a session that has
/// one already) took a service whose connection had dropped for one that
/// works, and went on using it after the session had been connected again
/// on a connection of its own.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final lost = SSHSocketError(const SocketException('Connection reset by peer'));

  PlayedSftpHost hostWithNotes() => PlayedSftpHost()..files['/srv/notes.txt'] = PlayedFile('notes'.codeUnits);

  /// Lets what ended reach whoever listens for it.
  Future<void> aMoment() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('it is open while its session is: no longer once the connection has dropped, and what it is asked then '
      'fails with what the connection ended with', () async {
    final host = hostWithNotes();
    final connection = host.connect();
    final sftp = SftpService(connection.client);
    addTearDown(sftp.close);
    expect(sftp.isOpen, isFalse, reason: 'not opened yet');
    await sftp.open();
    expect(sftp.isOpen, isTrue);
    expect((await sftp.stat('/srv/notes.txt')).size, 5);

    connection.drop(lost);
    await aMoment();
    expect(sftp.isOpen, isFalse);
    await expectLater(sftp.stat('/srv/notes.txt'), throwsA(same(lost)));
    await expectLater(sftp.listDirectory('/srv'), throwsA(same(lost)));
    expect(sftpErrorMessage(lost, name: 'srv', op: SftpOp.list, l10n: en), en.sftpErrConnectionLost);

    // Opened again on the connection that dropped: it cannot be, and says what the connection ended with.
    await expectLater(sftp.open(), throwsA(same(lost)));
    expect(sftp.isOpen, isFalse);

    // On the connection that took its place, a service of its own is open.
    final again = SftpService(host.connect().client);
    addTearDown(again.close);
    await again.open();
    expect(again.isOpen, isTrue);
    expect((await again.stat('/srv/notes.txt')).size, 5);
    expect(sftp.isOpen, isFalse);
  });

  test('the host ends the file session and the connection goes on: it is no longer open, and is again once it has '
      'been opened again', () async {
    final host = hostWithNotes();
    final connection = host.connect();
    final sftp = SftpService(connection.client);
    addTearDown(sftp.close);
    await sftp.open();
    connection.endSessions();
    await aMoment();
    expect(sftp.isOpen, isFalse);
    await expectLater(sftp.stat('/srv/notes.txt'), throwsA(isA<SftpAbortError>()));

    await sftp.open();
    expect(sftp.isOpen, isTrue);
    expect((await sftp.stat('/srv/notes.txt')).size, 5);
    // The session that ended is not taken for the one that was opened after it, however late it is heard of.
    await aMoment();
    expect(sftp.isOpen, isTrue);
  });

  test('closed by the app it is not open, and open again when it is opened again', () async {
    final host = hostWithNotes();
    final sftp = SftpService(host.connect().client);
    await sftp.open();
    await sftp.close();
    expect(sftp.isOpen, isFalse);
    expect(() => sftp.stat('/srv/notes.txt'), throwsStateError);
    await aMoment();

    await sftp.open();
    expect(sftp.isOpen, isTrue);
    expect((await sftp.stat('/srv/notes.txt')).size, 5);
    await sftp.close();
  });
}

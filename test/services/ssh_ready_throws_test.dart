import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_failing_socket.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A connection that goes at the moment its host key is approved, as the
/// app's own SSH service meets it (3.0, from the SSH core's audit).
///
/// Once a host's key is approved the SSH core sends its NEWKEYS and tells
/// the app that the connection is ready. What was thrown there (a socket
/// that had gone, of which nothing had said so yet) went nowhere: the
/// connection stayed open, and the app waited the fifteen seconds it gives
/// a sign-in and then said that the sign-in had timed out.
///
/// The host is played by the test, on a socket whose writes fail from the
/// app's NEWKEYS on.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('the try ends at once and says what happened: not when the time for a sign-in is up, as a sign-in that '
      'timed out', () async {
    final server = PlayedServer();
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      // The app writes its version, its proposal and its start of the exchange; the fourth write is its NEWKEYS.
      tunnelSocket: WritesFail(server.socket, from: 4),
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    final clock = Stopwatch()..start();
    Object? failure;
    final tried = ssh.connect().then<void>((_) {}, onError: (Object error) {
      failure = error;
    });
    // The played host waits for the app's NEWKEYS, which does not come.
    await server.exchangeKeys().then((_) {}, onError: (Object _) {});
    await tried.timeout(const Duration(seconds: 40));
    expect(failure, isNotNull, reason: 'the connection was made');
    // Fifteen seconds is what a sign-in is given.
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
    final said = connectionFailureText(failure!);
    expect(said, contains('The connection could not be made ready once its host key was approved'));
    expect(said, contains(WritesFail.said));
    expect(ConnectionError.translate(said, host: 'web-01.example.com').type,
        isNot(ConnectionErrorType.signInTimedOut));
  });
}

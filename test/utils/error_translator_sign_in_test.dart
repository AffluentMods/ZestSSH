import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, jumpHostFailureText;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What is said of a sign-in that did not happen, by what stopped it (3.0,
/// found while the errors of tasks were put into words).
///
/// There was one sentence for all of it, "The server closed the connection
/// before completing login.", under "Authentication Failed" and a tip to
/// check the sign-in details: for a server that refused the key or the
/// password and closed nothing, for a sign-in that this app gave up waiting
/// for, for a network that dropped while it was under way, and for a server
/// so old that the two found no way of encrypting in common, for which the
/// app has a sentence that names the setting to turn on.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  ConnectionError said(Object e, {String? username = 'deploy', String? host = 'web-01'}) =>
      ConnectionError.translate(connectionFailureText(e), host: host, port: 22, username: username);

  SSHAuthAbortError cutOff([SSHError? reason]) => SSHAuthAbortError('Connection closed before authentication', reason);

  test('a sign-in that the server refused is said as that', () {
    for (final refused in [
      SSHAuthFailError('All authentication methods failed'),
      SSHAuthFailError('Max authentication attempts (20) exceeded'),
    ]) {
      final shown = said(refused);
      expect(shown.type, ConnectionErrorType.authFailed);
      expect(shown.title, 'Authentication failed');
      expect(shown.description, 'The server refused the sign-in: it accepted nothing that was offered. (deploy@web-01)');
      expect(shown.tip, en.errAuthFailedTip);
      expect(shown.rawError, '$refused');
    }
    // Who it was signed in as and where, as far as that is known.
    final refused = SSHAuthFailError('All authentication methods failed');
    expect(said(refused, username: null).description,
        'The server refused the sign-in: it accepted nothing that was offered. (web-01)');
    for (final user in ['deploy', null]) {
      expect(said(refused, username: user, host: null).description,
          'The server refused the sign-in: it accepted nothing that was offered.');
    }
  });

  test('a connection that the server closed before the sign-in was over is said as that, as it was', () {
    for (final closed in [
      cutOff(),
      // A message that ends the connection, with no words in it.
      cutOff(SSHDisconnectError(11, '', authentic: true)),
    ]) {
      final shown = said(closed);
      expect(shown.type, ConnectionErrorType.authFailed);
      expect(shown.title, 'Authentication failed');
      expect(shown.description, 'The server closed the connection before completing login. (web-01)');
      expect(shown.tip, en.errAuthFailedTip);
    }
    expect(said(cutOff(), host: null).description, 'The server closed the connection before completing login.');
  });

  test('a sign-in that was not finished in time is said as that', () {
    final late = TimeoutException('Authentication timed out', const Duration(seconds: 15));
    final shown = said(late);
    expect(shown.title, 'Sign-in timed out');
    expect(shown.description, 'web-01 did not finish the sign-in in time.');
    expect(
      shown.tip,
      'The connection was accepted, and then nothing more came. Check that the port is the one the SSH server '
      'listens on. A very busy server can also take this long.',
    );
    expect(shown.type.name, 'signInTimedOut', reason: 'it was reached, and it refused nothing');
    expect(shown.rawError, 'TimeoutException after 0:00:15.000000: Authentication timed out');
    expect(said(late, host: null).description, '${en.errFallbackServerCapitalized} did not finish the sign-in in time.');
    // A connection that could not be made in time is another thing, as it was.
    final unreached = said(TimeoutException('Connection timed out', const Duration(seconds: 10)));
    expect((unreached.type, unreached.description), (ConnectionErrorType.timeout, en.errTimeoutDesc('web-01')));
  });

  test('a sign-in that ended with its connection says what ended the connection, where that is known', () {
    final dropped = said(cutOff(SSHSocketError(const SocketException('Connection reset by peer'))));
    expect(dropped.type, ConnectionErrorType.networkError);
    expect(dropped.description, en.errNetworkErrorDesc('web-01'));
    expect(dropped.rawError, 'SSHSocketError(SocketException: Connection reset by peer)');

    // A server that is none, or speaks another version.
    final noServer = said(cutOff(SSHHandshakeError('Invalid version: SSH-1.5-old')));
    expect(noServer.type, ConnectionErrorType.sshProtocol);
    expect(noServer.description, en.errSshProtocolDesc('web-01'));
    expect(noServer.rawError, contains('Invalid version: SSH-1.5-old'));

    // A host's key that was not accepted is none of these: it is said for itself
    // (test/providers/host_key_not_accepted_said_test.dart).
    final key = said(cutOff(SSHHostkeyError('Hostkey verification failed')));
    expect(key.type, ConnectionErrorType.saidByApp);
    expect(key.description, en.connHostKeyNotAcceptedPlain);
  });

  test('a server so old that nothing is found in common says so, with what to turn on', () {
    final kinds = {
      'No matching key exchange algorithm': en.errAlgoTypeKeyExchange,
      'No matching host key algorithm': en.errAlgoTypeHostKey,
      'No matching client cipher algorithm': en.errAlgoTypeCipher,
      'No matching server cipher algorithm': en.errAlgoTypeCipher,
      'No matching client MAC algorithm': en.errAlgoTypeMac,
      'No matching server MAC algorithm': en.errAlgoTypeMac,
    };
    expect(kinds.values.toSet(), hasLength(4));
    kinds.forEach((thrown, kind) {
      // As a session has it, cut off in its sign-in; and bare.
      for (final failure in [cutOff(SSHHandshakeError(thrown)), SSHHandshakeError(thrown)]) {
        final shown = said(failure);
        expect(shown.type, ConnectionErrorType.algorithmMismatch, reason: thrown);
        expect(shown.title, 'Algorithm mismatch', reason: thrown);
        expect(shown.description, en.errAlgorithmMismatchDesc(kind, 'web-01'), reason: thrown);
        expect(shown.tip, contains(en.connectionEditCompatibilityMode), reason: thrown);
        expect(shown.rawError, 'SSHHandshakeError($thrown)');
      }
    });
    // (A host's key that was not accepted is said for itself, and never as an algorithm.)
    final unaccepted = said(SSHHostkeyError('Hostkey verification failed'));
    expect((unaccepted.type, unaccepted.description), (ConnectionErrorType.saidByApp, en.connHostKeyNotAcceptedPlain));
  });

  test('of a jump host on the way too, under its own name and address', () {
    String at(Object cause) => jumpHostFailureText(
        en,
        JumpHostFailure(
            label: 'vpn-gateway', host: '192.168.10.23', port: 22, username: 'deploy', stage: JumpStage.signIn, cause: cause));
    expect(
      at(SSHAuthFailError('All authentication methods failed')),
      en.jumpHostNoSignIn(
          'vpn-gateway', 'The server refused the sign-in: it accepted nothing that was offered. (deploy@192.168.10.23)'),
    );
    expect(at(TimeoutException('Authentication timed out', const Duration(seconds: 15))),
        en.jumpHostNoSignIn('vpn-gateway', '192.168.10.23 did not finish the sign-in in time.'));
    expect(at(cutOff(SSHHandshakeError('No matching key exchange algorithm'))),
        en.jumpHostNoSignIn('vpn-gateway', en.errAlgorithmMismatchDesc(en.errAlgoTypeKeyExchange, '192.168.10.23')));
  });

  test('in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      final refused = said(SSHAuthFailError('All authentication methods failed'));
      final closed = said(cutOff());
      final late = said(TimeoutException('Authentication timed out'));
      expect({refused.description, closed.description, late.description}, hasLength(3), reason: '$locale');
      expect(refused.description, '${l10n.errSignInRefusedDesc} (deploy@web-01)', reason: '$locale');
      expect(late.description, l10n.errSignInTimedOutDesc('web-01'), reason: '$locale');
      expect(late.description, contains('web-01'), reason: '$locale');
      expect((late.title, late.tip), (l10n.errSignInTimedOutTitle, l10n.errSignInTimedOutTip), reason: '$locale');
      expect(late.tip, contains('SSH'), reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(l10n.errSignInRefusedDesc, isNot(en.errSignInRefusedDesc), reason: '$locale');
      expect(l10n.errSignInTimedOutTitle, isNot(en.errSignInTimedOutTitle), reason: '$locale');
      expect(l10n.errSignInTimedOutDesc('web-01'), isNot(en.errSignInTimedOutDesc('web-01')), reason: '$locale');
      expect(l10n.errSignInTimedOutTip, isNot(en.errSignInTimedOutTip), reason: '$locale');
    }
  });
}

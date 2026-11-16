import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, noSessionText;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// A host that signs someone in and then starts no session (3.0, from the
/// SSH core's audit): what the SSH library throws where the shell is asked
/// for is taken for what it is, and said in the app's own words. It was
/// shown as the library wrote it ("Failed to start pty"), under "an
/// unexpected error", or as an error of the SSH protocol.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  test('what the library throws where a shell is asked for, as what the host did not give', () {
    final cases = <(Object, NoSessionKind)>[
      (SSHChannelRequestError('Failed to start pty'), NoSessionKind.terminal),
      (SSHChannelRequestError('Failed to start shell'), NoSessionKind.shell),
      (SSHChannelOpenError(1, 'administratively prohibited'), NoSessionKind.session),
      (SSHChannelOpenError(2, 'open failed'), NoSessionKind.session),
      (SSHChannelOpenError(4, 'resource shortage'), NoSessionKind.session),
      // Anything else that was asked for the session and refused, and a
      // channel the host closed without answering.
      (SSHChannelRequestError('Failed to request x11 forwarding'), NoSessionKind.other),
      (SSHChannelRequestError('Failed to set environment variable: LANG'), NoSessionKind.other),
      (SSHChannelRequestError('The channel closed before the request was answered'), NoSessionKind.other),
      // The connection closing under the question, with no error of its own.
      (SSHStateError('Connection closed before the request was answered'), NoSessionKind.closed),
      (SSHStateError('Connection closed while waiting for channel open'), NoSessionKind.closed),
      (SSHStateError('Transport is closed'), NoSessionKind.closed),
    ];
    for (final (error, kind) in cases) {
      final noSession = SshNoSessionException.of(error);
      expect(noSession, isNotNull, reason: '$error');
      expect(noSession!.kind, kind, reason: '$error');
      expect(noSession.cause, same(error), reason: 'what the library said is kept for the report');
      expect('$noSession', 'No session after sign-in (${kind.name}): $error');
    }
  });

  test('what is something else stays what it is', () {
    for (final error in <Object>[
      // A network that broke says so itself.
      SSHSocketError(const SocketException('Connection reset by peer')),
      const SocketException('Connection reset by peer'),
      TimeoutException('no answer'),
      // Another state of the connection than its having closed.
      SSHStateError('Unexpected reply to the request'),
      SSHPacketError('Malformed packet'),
      SSHAuthFailError('All authentication methods failed'),
      StateError('anything else'),
    ]) {
      expect(SshNoSessionException.of(error), isNull, reason: '$error');
      expect(connectionFailureText(error), '$error', reason: 'the library speaking, put into words as ever');
    }
  });

  test('each is said in the app\'s own words, shown as they are, with what the library said left to the report',
      () {
    final words = {
      NoSessionKind.terminal: en.connNoTerminal,
      NoSessionKind.shell: en.connNoShell,
      NoSessionKind.session: en.connNoSession,
      NoSessionKind.other: en.connNoSessionOther,
      NoSessionKind.closed: en.connNoSessionClosed,
    };
    expect(words.keys, unorderedEquals(NoSessionKind.values));
    expect(words.values.toSet(), hasLength(NoSessionKind.values.length), reason: 'each its own sentence');
    for (final MapEntry(key: kind, value: said) in words.entries) {
      expect(noSessionText(en, kind), said);
      final kept = connectionFailureText(SshNoSessionException(kind, SSHChannelRequestError('Failed to start pty')));
      expect(kept, '$kSaidByApp$said', reason: kind.name);
      expect(kept, isNot(contains('Failed to start pty')));
      final shown = ConnectionError.translate(kept, host: 'web-01', port: 22, username: 'deploy');
      expect(shown.type, ConnectionErrorType.saidByApp, reason: kind.name);
      expect(shown.title, en.errConnectionFailedTitle);
      expect(shown.description, said);
      expect(said, startsWith('The host signed you in, but '), reason: 'it says first that the sign-in went through');
    }
    // What the library's own text was shown as.
    expect(ConnectionError.translate('SSHChannelRequestError(Failed to start pty)', host: 'web-01').type,
        ConnectionErrorType.unknown);
    expect(
        ConnectionError.translate('SSHStateError(Connection closed before the request was answered)', host: 'web-01')
            .type,
        ConnectionErrorType.sshProtocol);
  });

  test('a host that stopped answering while a connection to it was being made is said as one that could not be '
      'reached in time', () {
    final quiet = SSHNoAnswerError(const Duration(seconds: 45), 3);
    expect('$quiet', 'SSHNoAnswerError(Nothing came from the server for 45 seconds: 3 keep-alives went unanswered)');
    expect(SshNoSessionException.of(quiet), isNull, reason: 'the host refused nothing');
    final shown = ConnectionError.translate(connectionFailureText(quiet), host: 'web-01', port: 22);
    expect(shown.type, ConnectionErrorType.timeout);
    expect(shown.title, en.errTimeoutTitle);
    expect(shown.tip, en.errTimeoutTip);
  });

  test('in every language the app speaks', () {
    for (final locale in AppLocalizations.supportedLocales) {
      if (locale.languageCode == 'en') continue;
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      final said = <String>{};
      for (final kind in NoSessionKind.values) {
        final text = noSessionText(l10n, kind);
        expect(text, isNot(noSessionText(en, kind)), reason: '$locale ${kind.name}');
        expect(connectionFailureText(SshNoSessionException(kind, StateError('x'))), '$kSaidByApp$text',
            reason: 'in the language the app speaks now');
        said.add(text);
      }
      expect(said, hasLength(NoSessionKind.values.length), reason: '$locale');
      // The option a key is marked with is the same word everywhere.
      expect(noSessionText(l10n, NoSessionKind.terminal), contains('no-pty'), reason: '$locale');
    }
  });
}

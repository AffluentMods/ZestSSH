import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played host puts where none belongs, and what the app asks
// first, are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_ignore.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_service.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome, monitorExecFailure;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/editor_test_said.dart';

/// A host that breaks the order of the strict key exchange, as the app's
/// own SSH service meets it (3.0, from the SSH core's audit).
///
/// Where a host and the app both name the strict key exchange, the first
/// exchange of a connection carries the messages of that exchange and
/// nothing else, and the host's proposal is the first packet it sends: a
/// packet put in before the keys are in force is what an attack on the
/// count of packets is made of (Terrapin). The SSH core ends such a
/// connection. The app said of it "An error occurred during the SSH
/// handshake", with a word about SSH versions, and tried again where it
/// tries again: each try one more connection that ended before sign-in.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);
  final ignore = SSH_Message_Ignore(Uint8List(4)).encode();
  const notFirst = 'Strict KEX violation: the server\'s key exchange proposal was not the first packet it sent '
      '(possible Terrapin attack).';

  setUp(() => L10nGlobal.update(en));

  /// The app's own service on a played host that names the strict exchange,
  /// or does not, and puts [first] before its proposal and [beforeNewKeys]
  /// between its answer and its NEWKEYS: what the try ended with (null
  /// where the app went on to ask for its sign-in), whether it sent a
  /// sign-in, and the connection's log.
  Future<({Object? failure, bool signInSent, List<String> log})> dialled({
    required bool strict,
    List<Uint8List> first = const [],
    List<Uint8List> beforeNewKeys = const [],
  }) async {
    final server = PlayedServer(strict: strict);
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    final tried = ssh.connect().timeout(patience).then<void>((_) {}, onError: (Object error) {
      failure = error;
    });
    // Where the app ends the connection, the played host waits for what does not come. Where the exchange was
    // taken, the app asks for the service it signs in with.
    final wentOn = await server
        .exchangeKeys(first: first, beforeNewKeys: beforeNewKeys)
        .then((_) => server.next(SSH_Message_Service_Request.messageId))
        .then((_) => true, onError: (Object _) => false);
    if (wentOn) return (failure: null, signInSent: true, log: log);
    await tried;
    // What ends the connection is written a moment after the try has ended.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final sent = server.takeSent().map((packet) => packet[0]);
    return (
      failure: failure,
      signInSent: sent.contains(SSH_Message_Userauth_Request.messageId) ||
          sent.contains(SSH_Message_Service_Request.messageId),
      log: log,
    );
  }

  test('the sentence, word for word', () {
    expect(
      en.connStrictOrderBroken,
      'Something came in the key exchange with the host that does not belong there, and the host and this app had '
      'agreed to take nothing of the kind (the strict key exchange). The connection was not made, and nothing was '
      'sent to the host. An attack on the connection looks like this (the one known as Terrapin), and so does an SSH '
      'server, or a proxy in front of it, that does not keep to the order. If it happens on one network only, do '
      'not use that network for this.',
    );
  });

  test('a host that names the strict exchange and sends something before its proposal: not connected to, said as '
      'that, nothing of a sign-in sent, and not tried again', () async {
    final outcome = await dialled(strict: true, first: [ignore]);
    expect(outcome.failure, isNotNull, reason: 'the connection was made');
    expect(outcome.signInSent, isFalse);
    final said = connectionFailureText(outcome.failure!);
    expect(said, saidByApp(en.connStrictOrderBroken));
    // As whatever shows a failed connection shows it: the app's own sentence, and no tip about anything else.
    final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
    expect((shown.type, shown.description), (ConnectionErrorType.saidByApp, en.connStrictOrderBroken));
    expect(reconnectCannotHelp(outcome.failure!), isTrue, reason: 'the next try would end the same way');
    // The connection's log has what the SSH core found.
    expect(outcome.log.where((line) => line.contains(notFirst)), isNotEmpty);
  });

  test('the same host sends something that is no message of the exchange before its NEWKEYS: the same', () async {
    final outcome = await dialled(strict: true, beforeNewKeys: [ignore]);
    expect(outcome.failure, isNotNull, reason: 'the connection was made');
    expect(outcome.signInSent, isFalse);
    expect(connectionFailureText(outcome.failure!), saidByApp(en.connStrictOrderBroken));
    expect(reconnectCannotHelp(outcome.failure!), isTrue);
    expect(outcome.log.where((line) => line.contains('unexpected message id 2 during the initial key exchange')),
        isNotEmpty);
  });

  test('a host that names no strict exchange and sends the same before its proposal: the app goes on, as the '
      'protocol has it', () async {
    final outcome = await dialled(strict: false, first: [ignore]);
    expect(outcome.failure, isNull);
  });

  test('the order of the strict exchange broken is said so by itself and as what ended a sign-in, and Server '
      'Monitor does not dial such a host again; another failure of a key exchange is what it was', () {
    final broken = SSHHandshakeError(notFirst, strictOrderBroken: true);
    for (final failure in <Object>[broken, SSHAuthAbortError('Connection closed before authentication', broken)]) {
      expect(connectionFailureText(failure), saidByApp(en.connStrictOrderBroken));
      expect(reconnectCannotHelp(failure), isTrue);
      expect(monitorExecFailure(failure, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.endsTheSame);
    }
    final nothingInCommon = SSHHandshakeError('No matching key exchange algorithm');
    for (final failure in <Object>[
      nothingInCommon,
      SSHAuthAbortError('Connection closed before authentication', nothingInCommon),
    ]) {
      final said = connectionFailureText(failure);
      expect(said, isNot(startsWith(saidByApp(''))));
      expect(said, contains('No matching key exchange algorithm'));
      expect(reconnectCannotHelp(failure), isFalse);
      expect(monitorExecFailure(failure, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.error);
    }
  });

  test('a connection test that was cut off by it says the same, and keeps what the SSH core found for its '
      'details', () {
    SSHAuthAbortError cutOff(SSHError reason) => SSHAuthAbortError('Connection closed before authentication', reason);
    final broken = SSHHandshakeError(notFirst, strictOrderBroken: true);
    expect(editorTestSaid(en, cutOff(broken)), en.connStrictOrderBroken);
    expect(editorTestCutOffBy(en, cutOff(broken)), 'SSHHandshakeError($notFirst)');
    // Another failure of a key exchange: said as a failed connection says it (an error in the handshake), with
    // what was found behind it. (It was "Auth aborted: Connection closed before authentication".)
    final outOfTurn = SSHHandshakeError('The server sent NEWKEYS without an answer to a key exchange.');
    expect(editorTestSaid(en, cutOff(outOfTurn), host: 'web-01.example.com'),
        '${en.errSshProtocolDesc('web-01.example.com')}\n\n${en.errSshProtocolTip}');
    expect(editorTestCutOffBy(en, cutOff(outOfTurn)),
        'SSHHandshakeError(The server sent NEWKEYS without an answer to a key exchange.)');
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final sentence = lookupAppLocalizations(locale).connStrictOrderBroken;
      expect(sentence, contains('Terrapin'), reason: '$locale');
      expect(sentence, isNot(contains('{')), reason: '$locale');
      if (locale.languageCode != 'en') expect(sentence, isNot(en.connStrictOrderBroken), reason: '$locale');
    }
  });
}

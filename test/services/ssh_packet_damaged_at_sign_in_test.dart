import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// What a host answers a sign-in with is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_service.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/editor_test_said.dart';

/// A packet that does not pass its check while a host is being signed in
/// to, as the app's own SSH service meets it (3.0, from the SSH core's
/// audit).
///
/// From the moment both sides have their keys, every packet carries a check
/// value. One that does not pass was changed or damaged on the way, or the
/// two sides do not protect their packets the same way: the SSH core uses
/// nothing of it and ends the connection. The app said of that "An error
/// occurred during the SSH handshake" with a word about SSH versions and
/// the host's sshd_config, which sends its person to the wrong place when a
/// network is what failed.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);
  const didNotPass = 'A packet from the other side did not pass its check: it was changed or damaged on the way, or '
      'the two sides do not protect their packets the same way';
  const noSuchLength = 'A packet from the other side has a length that no packet has: it was changed or damaged on '
      'the way, or the two sides do not protect their packets the same way';

  setUp(() => L10nGlobal.update(en));

  /// The app's own service on a played host under [suite] whose answer at
  /// [moment] of the sign-in comes with [change] made to it: what the try
  /// ended with, whether the app sent a sign-in after that answer, and the
  /// connection's log.
  Future<({Object failure, bool signInSentAfter, List<String> log})> damaged(
    PlayedSuite suite,
    _Moment moment,
    void Function(Uint8List packet) change,
  ) async {
    final server = PlayedServer(suite: suite);
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
    final tried = ssh.connect().timeout(patience).then((_) {}, onError: (Object error) {
      failure = error;
    });
    await server.exchangeKeys();
    await server.next(SSH_Message_Service_Request.messageId);
    final accept = SSH_Message_Service_Accept('ssh-userauth').encode();
    if (moment == _Moment.beforeTheSignIn) {
      server.sendChanged([accept], (packets) => change(packets.single));
    } else {
      server.send([accept]);
      await server.next(SSH_Message_Userauth_Request.messageId);
      // Whatever else it had sent by now is no matter of what follows.
      server.takeSent();
      server.sendChanged([SSH_Message_Userauth_Success().encode()], (packets) => change(packets.single));
    }
    await tried;
    expect(failure, isNotNull, reason: 'the connection was made');
    // What ends the connection is written a moment after the try has ended.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final after = server.takeSent().any((packet) => packet[0] == SSH_Message_Userauth_Request.messageId);
    return (failure: failure!, signInSentAfter: after, log: log);
  }

  void lastByte(Uint8List packet) => packet[packet.length - 1] ^= 0x01;

  void expectSaidAsDamaged(({Object failure, bool signInSentAfter, List<String> log}) outcome, String theCoreSays) {
    // Nothing of a packet that did not pass is gone on with: no sign-in follows it, and none a second time.
    expect(outcome.signInSentAfter, isFalse);
    final said = connectionFailureText(outcome.failure);
    expect(said, saidByApp(en.connPacketDamaged));
    // As whatever shows a failed connection shows it: the app's own sentence, and no tip about anything else.
    final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, en.connPacketDamaged);
    // The next try may get through: it is tried again where the app tries again.
    expect(reconnectCannotHelp(outcome.failure), isFalse);
    // The connection's log has what the SSH core found, in its own words, as a line of the session's (the trace of
    // a connection that is being made has it too).
    expect(outcome.log.where((line) => line.startsWith('ssh_session: A packet ')), ['ssh_session: $theCoreSays']);
  }

  test('the sentence, word for word', () {
    expect(
      en.connPacketDamaged,
      'What came from the host did not pass its check, so nothing of it was used and the connection was not made. '
      'Either it was changed or damaged on the way, or the host\'s SSH server and this app do not protect what they '
      'send the same way. Try again. If it happens every time, and on another network as well, it is the host\'s '
      'SSH server and this app that do not work together.',
    );
  });

  for (final suite in [PlayedSuite.chacha, PlayedSuite.ctrEtm]) {
    test('the answer to the first thing the app asks under keys comes changed, under $suite: said as that, with '
        'no sign-in sent, and worth the next try', () async {
      expectSaidAsDamaged(await damaged(suite, _Moment.beforeTheSignIn, lastByte), didNotPass);
    });

    test('the answer to the sign-in comes changed, under $suite: said as that, and not as a sign-in the host '
        'took or refused', () async {
      expectSaidAsDamaged(await damaged(suite, _Moment.atTheSignIn, lastByte), didNotPass);
    });
  }

  test('a packet whose length was changed on the way, where the length is read before the check: the same '
      'sentence', () async {
    expectSaidAsDamaged(await damaged(PlayedSuite.ctr, _Moment.atTheSignIn, (packet) => packet[0] ^= 0x40), noSuchLength);
  });

  test('a packet that did not pass its check is said so by itself and as what ended a sign-in; a packet the host '
      'itself sent wrongly is an error of the SSH protocol, as it was', () {
    final changed = SSHPacketError(didNotPass, damaged: true);
    for (final failure in <Object>[changed, SSHAuthAbortError('Connection closed before authentication', changed)]) {
      expect(connectionFailureText(failure), saidByApp(en.connPacketDamaged));
      expect(reconnectCannotHelp(failure), isFalse);
    }
    final wrong = SSHPacketError('Malformed packet: no length');
    for (final failure in <Object>[wrong, SSHAuthAbortError('Connection closed before authentication', wrong)]) {
      final said = connectionFailureText(failure);
      expect(said, isNot(startsWith(saidByApp(''))));
      expect(said, contains('Malformed packet: no length'));
      expect(ConnectionError.translate(said, host: 'web-01.example.com').type, ConnectionErrorType.sshProtocol);
    }
  });

  test('a connection test that was cut off by such a packet says the same, and keeps what the SSH core found for '
      'its details', () {
    SSHAuthAbortError cutOff(SSHError reason) => SSHAuthAbortError('Connection closed before authentication', reason);
    final changed = SSHPacketError(didNotPass, damaged: true);
    expect(editorTestSaid(en, cutOff(changed)), en.connPacketDamaged);
    expect(editorTestCutOffBy(en, cutOff(changed)), 'SSHPacketError($didNotPass)');
    // A packet the host itself sent wrongly: said as a failed connection says it (an error in the handshake),
    // with what was found behind it. (It was "Auth aborted: Connection closed before authentication".)
    final wrong = SSHPacketError('Malformed packet: no length');
    expect(editorTestSaid(en, cutOff(wrong), host: 'web-01.example.com'),
        '${en.errSshProtocolDesc('web-01.example.com')}\n\n${en.errSshProtocolTip}');
    expect(editorTestCutOffBy(en, cutOff(wrong)), 'SSHPacketError(Malformed packet: no length)');
  });

  test('every language says it its own way', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final sentence = lookupAppLocalizations(locale).connPacketDamaged;
      expect(sentence.trim(), isNotEmpty, reason: '$locale');
      expect(sentence, isNot(contains('{')), reason: '$locale');
      if (locale.languageCode != 'en') expect(sentence, isNot(en.connPacketDamaged), reason: '$locale');
    }
  });
}

/// When the played host's answer comes changed.
enum _Moment {
  /// Its answer to the service the app asks for: the first packet the app
  /// reads under keys, before it has sent anything of a sign-in.
  beforeTheSignIn,

  /// Its answer to the sign-in.
  atTheSignIn,
}

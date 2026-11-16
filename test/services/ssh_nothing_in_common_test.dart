import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The proposal of a key exchange is not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_kex.dart';
import 'package:zestssh/features/monitoring/monitor_state_ui.dart' show failedCheckSaid;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome, monitorExecFailure;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart' show connectionTestFailed;
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/editor_test_said.dart';

/// A host that the app has no algorithm of one kind in common with (3.0;
/// the SSH core's audit: the tip to turn Compatibility mode on where it is
/// on, and a key exchange with nothing in common that was tried again).
///
/// Such a connection ended with "No matching cipher algorithm" and no word
/// of what either side had offered. Whatever showed it said that this
/// happens with older servers, and to turn Compatibility mode on: also
/// where the connection had been made with the mode, and also of a server
/// that offers nothing the mode has. Nothing in the app said what the
/// server does offer. (A server that speaks AES-GCM only was one of those
/// until the app offered AES-GCM: test/services/ssh_gcm_offered_test.dart.)
/// A session that had dropped tried such a host ten times, and Server
/// Monitor dialled it again by its timer for as long as it was monitored:
/// each one a connection that ended before its sign-in, in the host's log.
///
/// The SSH core's error says what each side offered now, and the app keeps
/// it with the failure: the tip to turn the mode on is given where the
/// mode adds something the server offers, and where it does not, what the
/// server offers is said, and that no setting changes it. Such a host is
/// not tried again by itself.
///
/// The host is played by the test: its proposal for the key exchange is
/// the test's, and nothing after it is looked at.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);
  const host = 'web-01.example.com';
  // What the app offers with the mode off, and what the mode adds, as its service has them.
  const ciphersOffered =
      'chacha20-poly1305@openssh.com,aes256-ctr,aes128-ctr,aes256-gcm@openssh.com,aes128-gcm@openssh.com';
  const ciphersOfTheMode = 'aes128-cbc,aes192-cbc,aes256-cbc';
  // Where the switch is, as a computer is told.
  const place = 'Auth / Show advanced options';

  setUp(() {
    L10nGlobal.update(en);
    Redactor.instance
      ..clearNames()
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = false;
    ReportScrub.clearFolders();
  });

  tearDown(() => Redactor.instance.clearNames());

  /// A server's proposal for the key exchange: what it is not told is
  /// something the app has in both modes.
  Uint8List proposal({List<String>? kex, List<String>? hostKeys, List<String>? ciphers, List<String>? macs}) =>
      SSH_Message_KexInit(
        kexAlgorithms: [...(kex ?? const ['curve25519-sha256']), 'ext-info-s', 'kex-strict-s-v00@openssh.com'],
        serverHostKeyAlgorithms: hostKeys ?? const ['ssh-ed25519'],
        encryptionClientToServer: ciphers ?? const ['aes256-ctr'],
        encryptionServerToClient: ciphers ?? const ['aes256-ctr'],
        macClientToServer: macs ?? const ['hmac-sha2-256'],
        macServerToClient: macs ?? const ['hmac-sha2-256'],
        compressionClientToServer: const ['none'],
        compressionServerToClient: const ['none'],
        firstKexPacketFollows: false,
      ).encode();

  /// The app's own service on a host that proposes [offered], with
  /// Compatibility mode on or off: what the try ended with.
  Future<Object> tried(Uint8List offered, {required bool compatibility}) async {
    final server = PlayedServer();
    final ssh = SshService(
      host: host,
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      compatibilityMode: compatibility,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    // (What the played server sends after the proposal of the test is not looked at: it waits in vain.)
    unawaited(server.exchangeKeys(first: [offered]).then((_) {}, onError: (Object _) {}));
    Object? failure;
    await ssh.connect().timeout(patience).then((_) {}, onError: (Object error) {
      failure = error;
    });
    expect(failure, isNotNull, reason: 'it connected');
    return failure!;
  }

  ConnectionError shownOf(String said) =>
      ConnectionError.translate(said, host: host, port: 22, username: 'deploy', onAComputer: true);

  /// A key exchange that ended with nothing in common, as what cut a
  /// sign-in off: made by hand, for what needs no connection.
  SSHAuthAbortError cutOff(String found, {required List<String> offered, required List<String> theirs}) =>
      SSHAuthAbortError(
        'Connection closed before authentication',
        SSHHandshakeError(found, offered: offered, otherSideOffered: theirs),
      );

  test('a host that offers only ciphers the app has in neither mode: said with what the host offers and that no '
      'setting changes it, with the mode off and with it on; kept with what each side offered; not tried again',
      () async {
    for (final compatibility in [false, true]) {
      final why = 'Compatibility mode: $compatibility';
      final failure = await tried(proposal(ciphers: ['3des-cbc', 'arcfour256']),
          compatibility: compatibility);
      expect(failure, isA<SSHAuthAbortError>(), reason: why);
      final said = connectionFailureText(failure);
      expect(
        said,
        'SSHHandshakeError(No matching client cipher algorithm) '
        '[ZestSSH offered: ${compatibility ? '$ciphersOffered,$ciphersOfTheMode' : ciphersOffered}] '
        '[the server offers: 3des-cbc,arcfour256] [Compatibility mode adds: ]',
        reason: why,
      );
      final shown = shownOf(said);
      expect(shown.type, ConnectionErrorType.algorithmMismatch, reason: why);
      expect(shown.title, en.errAlgorithmMismatchTitle, reason: why);
      expect(shown.description, en.errAlgorithmNoneInCommonDesc('cipher', host, '3des-cbc, arcfour256'),
          reason: why);
      expect(shown.tip, en.errAlgorithmNoneInCommonTip, reason: why);
      expect(shown.rawError, said, reason: why);
      expect(reconnectCannotHelp(failure), isTrue, reason: '$why: the next try offers the same');
    }
    expect(
      en.errAlgorithmNoneInCommonDesc('cipher', host, '3des-cbc, arcfour256'),
      'Could not agree on a cipher algorithm with web-01.example.com. The server offers only 3des-cbc, '
      'arcfour256, and ZestSSH has none of them.',
    );
    expect(
      en.errAlgorithmNoneInCommonTip,
      'No setting in ZestSSH changes this: it has none of what this server offers, with Compatibility mode or '
      'without. The server has to offer something ZestSSH has: whoever runs it can add a newer algorithm to its '
      'SSH settings, or update its SSH server. The details of this error list what ZestSSH offers.',
    );
  });

  test('a host that offers something the app has in Compatibility mode only, with the mode off: the tip to turn it '
      'on, as before, kept with what the mode adds; and not tried again as it is', () async {
    final failure = await tried(proposal(ciphers: ['aes256-cbc', '3des-cbc', 'aes128-cbc']), compatibility: false);
    final said = connectionFailureText(failure);
    expect(
      said,
      'SSHHandshakeError(No matching client cipher algorithm) [ZestSSH offered: $ciphersOffered] '
      '[the server offers: aes256-cbc,3des-cbc,aes128-cbc] [Compatibility mode adds: aes128-cbc,aes256-cbc]',
    );
    final shown = shownOf(said);
    expect(shown.type, ConnectionErrorType.algorithmMismatch);
    expect(shown.description, en.errAlgorithmMismatchDesc('cipher', host));
    expect(shown.tip, en.errAlgorithmMismatchTip(place));
    // As it is saved, the next try ends the same way: its person has to turn the mode on.
    expect(reconnectCannotHelp(failure), isTrue);
  });

  test('each other kind of algorithm: what the host offers where the mode has nothing for it, and the tip where '
      'the mode adds something the host offers', () async {
    for (final (offered, kind, names, modeAdds) in [
      (proposal(kex: ['diffie-hellman-group1-sha1']), 'key exchange', 'diffie-hellman-group1-sha1', ''),
      (
        proposal(kex: ['diffie-hellman-group1-sha1', 'diffie-hellman-group14-sha1']),
        'key exchange',
        'diffie-hellman-group1-sha1,diffie-hellman-group14-sha1',
        'diffie-hellman-group14-sha1',
      ),
      (proposal(hostKeys: ['ssh-dss']), 'host key', 'ssh-dss', ''),
      (proposal(hostKeys: ['ssh-dss', 'ssh-rsa']), 'host key', 'ssh-dss,ssh-rsa', 'ssh-rsa'),
      (proposal(macs: ['hmac-ripemd160', 'umac-64@openssh.com']), 'MAC', 'hmac-ripemd160,umac-64@openssh.com', ''),
      (proposal(macs: ['hmac-md5', 'hmac-ripemd160']), 'MAC', 'hmac-md5,hmac-ripemd160', 'hmac-md5'),
    ]) {
      final failure = await tried(offered, compatibility: false);
      final said = connectionFailureText(failure);
      expect(said, endsWith(' [the server offers: $names] [Compatibility mode adds: $modeAdds]'), reason: names);
      // (The two marks a proposal carries among its key exchanges are no key exchanges.)
      expect(said, isNot(contains('kex-strict-s')), reason: names);
      expect(said, isNot(contains('ext-info-s')), reason: names);
      final shown = shownOf(said);
      expect(shown.type, ConnectionErrorType.algorithmMismatch, reason: names);
      if (modeAdds.isEmpty) {
        expect(shown.description, en.errAlgorithmNoneInCommonDesc(kind, host, names.replaceAll(',', ', ')),
            reason: names);
        expect(shown.tip, en.errAlgorithmNoneInCommonTip, reason: names);
      } else {
        expect(shown.description, en.errAlgorithmMismatchDesc(kind, host), reason: names);
        expect(shown.tip, en.errAlgorithmMismatchTip(place), reason: names);
      }
      expect(reconnectCannotHelp(failure), isTrue, reason: names);
    }
  });

  test('what Compatibility mode adds is what it has, was not offered and the host offers: nothing where the '
      'connection was made with it', () {
    final withMode = SshService.buildAlgorithms(compatibility: true);
    final without = SshService.buildAlgorithms(compatibility: false);
    List<String> names(List<dynamic> algorithms) => [for (final algorithm in algorithms) algorithm.name as String];
    String adds(List<String> offered, List<String> theirs) {
      final said =
          nothingInCommonText(SSHHandshakeError('No matching x algorithm', offered: offered, otherSideOffered: theirs));
      return algorithmsOfferedOf(said)!.modeAdds.join(',');
    }

    // Each kind, offered without the mode, by a host that offers everything the mode has of it and a made-up one.
    expect(adds(names(without.cipher), [...names(withMode.cipher), 'made-up']), 'aes128-cbc,aes192-cbc,aes256-cbc');
    expect(adds(names(without.kex), ['made-up', ...names(withMode.kex)]),
        'diffie-hellman-group14-sha1,diffie-hellman-group-exchange-sha1');
    expect(adds(names(without.hostkey), names(withMode.hostkey)), 'ssh-rsa');
    expect(adds(names(without.mac), names(withMode.mac)), 'hmac-md5');
    // Offered with the mode: it has no more to add, whatever the host offers.
    for (final kind in [withMode.cipher, withMode.kex, withMode.hostkey, withMode.mac]) {
      expect(adds(names(kind), [...names(kind), 'made-up']), '');
    }
    // A host that offers nothing the mode has.
    expect(adds(names(without.cipher), ['3des-cbc', 'arcfour256']), '');
    // An error that was made with no word of what this side offered: as if it had offered nothing.
    final bare = nothingInCommonText(SSHHandshakeError('No matching cipher algorithm', otherSideOffered: ['aes256-cbc']));
    expect(bare, 'SSHHandshakeError(No matching cipher algorithm) [ZestSSH offered: ] [the server offers: aes256-cbc] '
        '[Compatibility mode adds: aes256-cbc]');
  });

  test('of what a server names, only what a name can be is kept, forty names at most, and then it is said that '
      'there were more', () {
    final kept = withAlgorithmsOffered(
      'SSHHandshakeError(No matching cipher algorithm)',
      offered: ['aes256-ctr'],
      serverOffers: [
        '3des-cbc',
        'has a space',
        'ends-a-mark]',
        '[tried:',
        'café-cbc',
        '',
        'a' * 64,
        'b' * 65,
        'rijndael-cbc@lysator.liu.se',
      ],
      modeAdds: const [],
    );
    expect(algorithmsOfferedOf(kept)!.serverOffers, ['3des-cbc', 'a' * 64, 'rijndael-cbc@lysator.liu.se']);
    expect(shownOf(kept).description,
        en.errAlgorithmNoneInCommonDesc('cipher', host, '3des-cbc, ${'a' * 64}, rijndael-cbc@lysator.liu.se'));

    // Forty are kept as they came; of more, forty and a sign that there were more.
    List<String> made(int count) => [for (var i = 1; i <= count; i++) 'made-up-$i'];
    final forty = algorithmsOfferedOf(withAlgorithmsOffered('x', offered: made(40), serverOffers: made(40), modeAdds: made(40)))!;
    expect(forty.serverOffers, made(40));
    expect(forty.offered, made(40));
    expect(forty.modeAdds, made(40));
    final more = algorithmsOfferedOf(withAlgorithmsOffered('x', offered: made(41), serverOffers: made(45), modeAdds: made(41)))!;
    expect(more.serverOffers, [...made(40), '...']);
    expect(more.offered, [...made(40), '...']);
    expect(more.modeAdds, [...made(40), '...']);
    expect(mostAlgorithmsKept, 40);

    // A host that names nothing a name can be: what it offers cannot be said, and that the mode has nothing can.
    final nothing = withAlgorithmsOffered('SSHHandshakeError(No matching server MAC algorithm)',
        offered: ['hmac-sha2-256'], serverOffers: ['not a name', ''], modeAdds: const []);
    expect(nothing, endsWith(' [the server offers: ] [Compatibility mode adds: ]'));
    expect(shownOf(nothing).description, en.errAlgorithmMismatchDesc('MAC', host));
    expect(shownOf(nothing).tip, en.errAlgorithmNoneInCommonTip);
  });

  test('no name of a server\'s making is taken for the words of an error: the kind of algorithm, and what kind of '
      'failure it is, are read from what the error says by itself', () {
    // Names that are words of other failures, and of other kinds of algorithm.
    const words = [
      'sshkeydecrypterror',
      'authentication',
      'refused',
      'timeout',
      'socketexception',
      'host-key',
      'hmac-sha2-256',
      'cipher',
      'sshauthfailerror',
    ];
    final kept = withAlgorithmsOffered('SSHHandshakeError(No matching key exchange algorithm)',
        offered: ['curve25519-sha256'], serverOffers: words, modeAdds: const []);
    final shown = shownOf(kept);
    expect(shown.type, ConnectionErrorType.algorithmMismatch);
    expect(shown.description, en.errAlgorithmNoneInCommonDesc('key exchange', host, words.join(', ')));
    expect(algorithmKindNotInCommon(en, kept), 'key exchange');

    // So of a sign-in that a server refused: a way it names is no word of the error. (A server that named one
    // of its ways "sshkeydecrypterror" had its refusal shown as a key that needs its passphrase.)
    final refused = withSignInWays('SSHAuthFailError(All authentication methods failed)', ['password'], words);
    final shownRefused = shownOf(refused);
    expect(shownRefused.type, ConnectionErrorType.authPasswordFailed);
    expect(shownRefused.title, isNot(en.errKeyPassphraseRequiredTitle));
    expect(shownRefused.description, contains('sshkeydecrypterror'));

    // What an error says by itself: without what was put at its end for whoever shows it.
    expect(saidByItself(kept), 'SSHHandshakeError(No matching key exchange algorithm)');
    expect(saidByItself(refused), 'SSHAuthFailError(All authentication methods failed)');
    final passedOver = withSignInWays(
      withKeysPassedOver('SSHAuthFailError(All authentication methods failed)', ['ssh-rsa'], ['rsa-sha2-512']),
      ['publickey'],
      ['publickey'],
    );
    expect(passedOver, contains(' [keys passed over: ssh-rsa] [signatures the server takes: rsa-sha2-512] [tried: '));
    expect(saidByItself(passedOver), 'SSHAuthFailError(All authentication methods failed)');
    // (Only what stands at the end was put there: the same words further in are the error's own.)
    expect(
      saidByItself('It said [keys passed over: a] [signatures the server takes: b] and more [tried: p] '
          '[the server takes: q]'),
      'It said [keys passed over: a] [signatures the server takes: b] and more',
    );
    // A text with nothing at its end is all its own, brackets and all.
    for (final own in [
      'SocketException: Connection refused',
      'It said [tried: publickey] and went on',
      'Bad state [ZestSSH offered: a] [the server offers: b] [Compatibility mode adds: c] and more',
      '',
    ]) {
      expect(saidByItself(own), own);
    }
  });

  test('a text that says nothing of what each side offered is given the tip, as before: whether the mode has '
      'anything for the server is not known of it', () {
    const bare = 'SSHHandshakeError(No matching client cipher algorithm)';
    expect(algorithmsOfferedOf(bare), isNull);
    expect(shownOf(bare).description, en.errAlgorithmMismatchDesc('cipher', host));
    expect(shownOf(bare).tip, en.errAlgorithmMismatchTip(place));
    // And an error that carries no lists is kept as it prints itself, and is tried again as before.
    final unknown = SSHAuthAbortError('Connection closed before authentication', SSHHandshakeError(bare));
    expect(connectionFailureText(unknown), 'SSHHandshakeError($bare)');
    expect(reconnectCannotHelp(unknown), isFalse);
    expect(reconnectCannotHelp(SSHHandshakeError(bare)), isFalse);
    // With what each side offered it is not tried again, as what cut a sign-in off and by itself.
    final known = SSHHandshakeError(bare, offered: const ['aes256-ctr'], otherSideOffered: const ['3des-cbc']);
    expect(reconnectCannotHelp(known), isTrue);
    expect(reconnectCannotHelp(SSHAuthAbortError('Connection closed before authentication', known)), isTrue);
    expect(connectionFailureText(known), connectionFailureText(SSHAuthAbortError('Cut off', known)));
    expect(connectionFailureText(known), startsWith('$known [ZestSSH offered: aes256-ctr] '));
  });

  test('at a jump host, in the host editor\'s test and in Server Monitor: the same words, and not tried again',
      () async {
    final failure = await tried(proposal(ciphers: ['3des-cbc', 'arcfour256']), compatibility: true);
    const names = '3des-cbc, arcfour256';

    // A jump host on the way: its own sentence, with what a host is told of the same failure.
    final atJump =
        JumpHostFailure(label: 'auth-gateway', host: '192.0.2.10', port: 22, stage: JumpStage.signIn, cause: failure);
    expect(
      connectionFailureText(atJump),
      saidByApp(en.jumpHostNoSignIn('auth-gateway', en.errAlgorithmNoneInCommonDesc('cipher', '192.0.2.10', names))),
    );
    expect(reconnectCannotHelp(atJump), isTrue);

    // The host editor's test: both paragraphs, and the report with what each side offered behind what cut the
    // sign-in off.
    final desc = en.errAlgorithmNoneInCommonDesc('cipher', host, names);
    expect(editorTestSaid(en, failure, host: host), '$desc\n\n${en.errAlgorithmNoneInCommonTip}');
    final report = connectionTestFailed(en, failure, host: host).report!;
    expect(
      report,
      contains('  What cut it off: SSHHandshakeError(No matching client cipher algorithm) '
          '[ZestSSH offered: $ciphersOffered,$ciphersOfTheMode] [the server offers: 3des-cbc,arcfour256] '
          '[Compatibility mode adds: ]'),
    );
    expect(report, contains('  Kind: algorithmMismatch'));
    expect(editorTestCutOffBy(en, failure), startsWith('SSHHandshakeError(No matching client cipher algorithm) ['));

    // Server Monitor: what no timer changes, with the same sentence under the host.
    final told = monitorExecFailure(failure, hostKeyNeedsReview: false);
    expect((told.outcome, told.failedWith), (MonitorExecOutcome.endsTheSame, failure));
    expect(monitorExecFailure(atJump, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.endsTheSame);
    expect(failedCheckSaid(failure, host: 'web-01', port: 22),
        en.errAlgorithmNoneInCommonDesc('cipher', 'web-01', names));
  });

  test('a report of the error itself, and of another end of a handshake, as each is', () {
    final nothing = SSHHandshakeError('No matching host key algorithm',
        offered: const ['ssh-ed25519'], otherSideOffered: const ['ssh-dss', 'ssh-rsa']);
    final direct = ErrorReport.build(what: 'It failed', where: 'A test', error: nothing);
    expect(
      direct,
      contains('Error: SSHHandshakeError(No matching host key algorithm) [ZestSSH offered: ssh-ed25519] '
          '[the server offers: ssh-dss,ssh-rsa] [Compatibility mode adds: ssh-rsa]'),
    );
    // What cut a sign-in off, under the error of the sign-in, which is said as it is.
    final cut = ErrorReport.build(
      what: 'It failed',
      where: 'A test',
      error: cutOff('No matching host key algorithm', offered: ['ssh-ed25519'], theirs: ['ssh-dss']),
    );
    expect(cut, contains('Error: SSHAuthAbortError(Connection closed before authentication)\n'
        '  What cut it off: SSHHandshakeError(No matching host key algorithm) [ZestSSH offered: ssh-ed25519] '
        '[the server offers: ssh-dss] [Compatibility mode adds: ]'));
    // Another end of a handshake has nothing of the kind behind it.
    final other = ErrorReport.build(what: 'It failed', where: 'A test', error: SSHHandshakeError('It was cut short'));
    expect(other, contains('Error: SSHHandshakeError(It was cut short)\n'));
    expect(other, isNot(contains('ZestSSH offered')));
    expect(ErrorReport.build(what: 'It failed', where: 'A test', error: 'a text [the server offers: x]'),
        contains('Error: a text [the server offers: x]\n'));
  });

  test('every language says both, the first with the kind, the host and what it offers', () {
    final said = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final desc = l10n.errAlgorithmNoneInCommonDesc('<kind>', host, '3des-cbc, blowfish-cbc');
      for (final part in ['<kind>', host, '3des-cbc, blowfish-cbc']) {
        expect(desc, contains(part), reason: '$locale');
      }
      expect(desc, isNot(contains('{')), reason: '$locale');
      expect(l10n.errAlgorithmNoneInCommonTip, contains('ZestSSH'), reason: '$locale');
      expect(said.add(desc), isTrue, reason: '$locale says it as another language');
      expect(said.add(l10n.errAlgorithmNoneInCommonTip), isTrue, reason: '$locale says it as another language');
      // No setting changes it: nothing sends its reader to the switch of the mode.
      expect(l10n.errAlgorithmNoneInCommonTip, isNot(contains(l10n.connectionEditShowAdvanced)), reason: '$locale');
    }
  });
}

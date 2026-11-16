import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The groups of the RFCs are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/kex/kex_dh.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

import '../../packages/zest_ssh_core/test/src/played_group_exchange.dart';
import '../helpers/editor_test_said.dart';

/// A host that names a group too short for the key exchange, as the app's
/// own SSH service meets it (3.0, from the SSH core's audit).
///
/// Where a host has no key exchange in common with the app but a group
/// exchange, the host names the group, and everything the session carries
/// is as safe as that group. The SSH core took a group of 1024 bits, which
/// can be broken by whoever has the means. It takes none under 2048 bits
/// now, so such a host is no longer connected to: the app has to say why,
/// and what would mend it, where it said "An error occurred during the SSH
/// handshake" with a word about SSH versions.
///
/// The host is played by the test.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 10);

  setUp(() => L10nGlobal.update(en));

  // The groups of RFC 2409 (1024 bits) and RFC 3526 (2048 bits).
  final group1 = SSHKexDH.group1();
  final group14 = SSHKexDH.group14();

  /// The app's own service on a host that offers a group exchange and
  /// nothing else, and names the group of [p] and [g]: the shortest group
  /// the app had asked for, whether it went on with the exchange, what the
  /// try ended with where it did not, and the connection's log.
  Future<({int shortestAskedFor, int askedForByChoice, bool wentOn, Object? failure, List<String> log})> named(
    BigInt p,
    BigInt g, {
    bool compatibility = false,
  }) async {
    final server = PlayedGroupExchange();
    final log = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      compatibilityMode: compatibility,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: server.socket,
      onLog: log.add,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    final tried = ssh.connect().timeout(patience).then((_) {}, onError: (Object error) {
      failure = error;
    });
    final asked = await server.request();
    final publicValue = await server.name(p, g);
    // Where the app ended the connection, its try has ended with why.
    if (publicValue == null) await tried;
    return (
      shortestAskedFor: asked.shortest,
      askedForByChoice: asked.preferred,
      wentOn: publicValue != null,
      failure: failure,
      log: log,
    );
  }

  // Where the place of the Compatibility mode switch is said: as a computer is told it, which the tests run on.
  const place = 'Auth / Show advanced options';

  /// The group error that [failure] is, or that ended its sign-in.
  SSHKexGroupError groupError(Object failure) =>
      failure is SSHAuthAbortError ? failure.reason! as SSHKexGroupError : failure as SSHKexGroupError;

  test('a host that names a group of 1024 bits, without Compatibility mode: not connected to, said as a host that '
      'offers only an outdated key exchange, with both lengths and the switch that connects to it, and not tried '
      'again', () async {
    final outcome = await named(group1.p, group1.g);
    expect(outcome.shortestAskedFor, 2048);
    expect(outcome.wentOn, isFalse);
    expect(outcome.failure, isNotNull);
    expect(compatibilityModeTakesGroup(groupError(outcome.failure!)), isTrue);
    final said = connectionFailureText(outcome.failure!);
    expect(said, saidByApp(en.connKexGroupOutdated(1024, 2048, place)));
    expect(
      en.connKexGroupOutdated(1024, 2048, place),
      'This host offers only an outdated key exchange (a group of 1024 bits; none under 2048 bits is taken), so no '
      'connection was made. Nothing was sent to it. Update its SSH server if you can. For an old server that cannot '
      'be updated, Compatibility mode (under "Auth / Show advanced options") in this host\'s settings connects to '
      'it. Not recommended: whoever records the session and breaks such a group can read it.',
    );
    // Short enough that a notification keeps all of it with the line a monitored host that is not tried again
    // has after it (a notification's body is cut at 500 characters).
    expect('${en.connKexGroupOutdated(1024, 2048, place)} ${en.zestMonitorTipNotTriedAgain}'.length,
        lessThanOrEqualTo(500));
    // As whatever shows a failed connection shows it: the app's own sentence, under the code and with the Copy
    // details that every failed connection has.
    final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, en.connKexGroupOutdated(1024, 2048, place));
    expect(reconnectCannotHelp(outcome.failure!), isTrue, reason: 'the next try would be named the same group');
    // The connection's log has what the SSH core found.
    expect(outcome.log.where((line) => line.contains('of 1024 bits, and none under 2048 bits is taken')), isNotEmpty);
  });

  test('a host that names a group of 1024 bits, with Compatibility mode: the app asks for 1024 bits at the least '
      'and goes on with the exchange, and its log says how long the group is', () async {
    final outcome = await named(group1.p, group1.g, compatibility: true);
    expect(outcome.shortestAskedFor, 1024);
    expect(outcome.askedForByChoice, 3072, reason: 'a host with longer groups still names one of 3072 bits');
    expect(outcome.wentOn, isTrue);
    expect(outcome.failure, isNull);
    expect(outcome.log, contains('debug: SSHTransport: the server named a group of 1024 bits for the key exchange'));
  });

  test('a group shorter than Compatibility mode takes: said as a group too short, with the mode or without it, and '
      'nothing of the mode, which would not connect to it', () async {
    final odd768 = (BigInt.one << 767) | (BigInt.one << 384) | BigInt.one;
    for (final compatibility in [false, true]) {
      final why = 'Compatibility Mode: $compatibility';
      final outcome = await named(odd768, BigInt.two, compatibility: compatibility);
      final least = compatibility ? 1024 : 2048;
      expect(outcome.shortestAskedFor, least, reason: why);
      expect(outcome.wentOn, isFalse, reason: why);
      final said = connectionFailureText(outcome.failure!);
      expect(said, saidByApp(en.connKexGroupTooShort(768, least)), reason: why);
      expect(said, isNot(contains(en.connectionEditCompatibilityMode)), reason: why);
    }
    expect(
      en.connKexGroupTooShort(1024, 2048),
      'The host chose a key exchange group of 1024 bits, and nothing under 2048 bits is taken, so the connection '
      'was not made. Nothing was sent to the host. What a session carries under a group that short can be read '
      'later by whoever records it and has the means to break the group. The host\'s SSH server has to offer '
      'longer groups, or a newer key exchange.',
    );
  });

  test('which refused groups Compatibility mode would take: one as long as it takes, refused without it', () {
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 1024, shortestTaken: 2048)), isTrue);
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 1536, shortestTaken: 2048)), isTrue);
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 1023, shortestTaken: 2048)), isFalse);
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 768, shortestTaken: 1024)), isFalse);
    // Refused for another reason than its length: the mode changes nothing of it.
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 2048, shortestTaken: 2048)), isFalse);
    expect(compatibilityModeTakesGroup(SSHKexGroupError('x', bits: 8193, shortestTaken: 2048)), isFalse);
  });

  test('a host that names a group of 2048 bits: the app goes on with the exchange, and its log says how long the '
      'group is', () async {
    final outcome = await named(group14.p, group14.g);
    expect(outcome.shortestAskedFor, 2048);
    // What the app asks for by choice: a host that has longer groups too names one of 3072 bits, and not its
    // shortest. (It asked for 2048, and got the weakest group such a host has.)
    expect(outcome.askedForByChoice, 3072);
    expect(outcome.wentOn, isTrue);
    expect(outcome.failure, isNull);
    expect(outcome.log, contains('debug: SSHTransport: the server named a group of 2048 bits for the key exchange'));
  });

  test('a host that names a group that is none (a generator of one): not connected to, said as an error of the '
      'SSH protocol with what was found in its details, and not tried again', () async {
    final outcome = await named(group14.p, BigInt.one);
    expect(outcome.wentOn, isFalse);
    expect(outcome.failure, isNotNull);
    final said = connectionFailureText(outcome.failure!);
    final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.sshProtocol);
    expect(shown.rawError, contains('with a generator that is none'));
    expect(shown.description, isNot(contains('1024')));
    expect(reconnectCannotHelp(outcome.failure!), isTrue, reason: 'the next try would be named the same group');
  });

  test('a group that was refused is one, also as what ended a sign-in and at a jump host; nothing else is', () {
    final tooShort = SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048);
    final noGroup = SSHKexGroupError('with a generator that is none', bits: 2048, shortestTaken: 2048);
    for (final failure in <Object>[tooShort, SSHAuthAbortError('Connection closed before authentication', tooShort)]) {
      expect(connectionFailureText(failure), saidByApp(en.connKexGroupOutdated(1024, 2048, place)));
      expect(reconnectCannotHelp(failure), isTrue);
    }
    for (final failure in <Object>[noGroup, SSHAuthAbortError('Connection closed before authentication', noGroup)]) {
      expect(connectionFailureText(failure), isNot(startsWith(saidByApp(''))));
      expect(connectionFailureText(failure), contains('with a generator that is none'));
      expect(reconnectCannotHelp(failure), isTrue);
    }
    // A key exchange that failed for something else that its error says no more of is tried again, as it was.
    // (One that found nothing in common says what each side offered, and is not:
    // test/services/ssh_nothing_in_common_test.dart.)
    expect(reconnectCannotHelp(SSHHandshakeError('No matching key exchange algorithm')), isFalse);
    expect(reconnectCannotHelp(SSHStateError('Transport is closed')), isFalse);
  });

  test('a connection test that was cut off by such a group says the same, and keeps what the SSH core found for '
      'its details', () {
    SSHAuthAbortError cutOff(SSHError reason) => SSHAuthAbortError('Connection closed before authentication', reason);
    final tooShort = SSHKexGroupError(
      'The server named a group for the key exchange of 1024 bits, and none under 2048 bits is taken',
      bits: 1024,
      shortestTaken: 2048,
    );
    expect(editorTestSaid(en, cutOff(tooShort)), en.connKexGroupOutdated(1024, 2048, place));
    expect(editorTestCutOffBy(en, cutOff(tooShort)), '$tooShort');
    // A group that is none for another reason: said as a failed connection says it (an error in the handshake),
    // with what was found behind it. (It was "Auth aborted: Connection closed before authentication".)
    final noGroup = SSHKexGroupError('with a generator that is none', bits: 2048, shortestTaken: 2048);
    expect(editorTestSaid(en, cutOff(noGroup), host: 'web-01.example.com'),
        '${en.errSshProtocolDesc('web-01.example.com')}\n\n${en.errSshProtocolTip}');
    expect(editorTestCutOffBy(en, cutOff(noGroup)), 'SSHKexGroupError(with a generator that is none)');
  });

  test('every language says it its own way, with both lengths; the outdated key exchange with the name of the '
      'switch and the place it is given, once', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final sentence = l10n.connKexGroupTooShort(1024, 2048);
      expect(sentence, contains('1024'), reason: '$locale');
      expect(sentence, contains('2048'), reason: '$locale');
      expect(sentence, isNot(contains('{')), reason: '$locale');
      final outdated = l10n.connKexGroupOutdated(1024, 2048, 'PLACE');
      expect(outdated, contains('1024'), reason: '$locale');
      expect(outdated, contains('2048'), reason: '$locale');
      expect('PLACE'.allMatches(outdated), hasLength(1), reason: '$locale');
      expect(outdated, contains(l10n.connectionEditCompatibilityMode), reason: '$locale');
      expect(outdated, isNot(contains('{')), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(sentence, isNot(en.connKexGroupTooShort(1024, 2048)), reason: '$locale');
        expect(outdated, isNot(en.connKexGroupOutdated(1024, 2048, 'PLACE')), reason: '$locale');
      }
    }
  });
}

import 'dart:io' show SocketException;

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show CrateClosedOffline;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart' show SshPromptCancelled;
import 'package:zestssh/services/ssh_connection_factory.dart' show NotSilentlyPollableException;
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/utils/error_translator.dart';

/// What is said of a jump host that failed on the way to a host (3.0, from
/// the SSH core's audit): which jump host it was, what it failed at, and
/// why, in the words the same failure of a host has, with the jump host's
/// own address in them. It was said as the host's own failure, with the
/// host's address: "db-primary is not accepting connections" of a jump host
/// that was down.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  JumpHostFailure at(JumpStage stage, Object cause, {String? onward}) => JumpHostFailure(
        label: 'bastion',
        host: '192.0.2.10',
        port: 2222,
        username: 'deploy',
        stage: stage,
        cause: cause,
        onward: onward,
      );

  const refused = SocketException('Connection refused');

  test('each thing a jump host fails at has its sentence, with why, for the jump host\'s own address', () {
    final why = ConnectionError.translate('$refused', host: '192.0.2.10', port: 2222, username: 'deploy').description;
    expect(why, contains('192.0.2.10'));
    expect(why, contains('2222'));
    expect(jumpHostFailureText(en, at(JumpStage.reach, refused)), 'The jump host bastion could not be reached. $why');

    final wrongKey = SSHAuthFailError('All authentication methods failed');
    final noSignIn = ConnectionError.translate('$wrongKey', host: '192.0.2.10', port: 2222, username: 'deploy').description;
    expect(jumpHostFailureText(en, at(JumpStage.signIn, wrongKey)),
        'Signing in to the jump host bastion did not work. $noSignIn');

    // What the app said itself of the details (a key that is not on this device) is said as it is.
    final gone = SSHAuthFailedException(en.connKeyNotOnDevice('ops key'));
    expect(
      jumpHostFailureText(en, at(JumpStage.details, gone)),
      'The sign-in details of the jump host bastion could not be used. The private key of "ops key" is not on this '
      'device: it was removed, or its import did not finish. Open the key and import its private key again.',
    );

    final timeout = SSHStateError('Connection closed while waiting for channel open');
    final whyNot = ConnectionError.translate('$timeout', host: '192.0.2.10', port: 2222, username: 'deploy').description;
    expect(jumpHostFailureText(en, at(JumpStage.onward, timeout, onward: 'db-primary')),
        'The jump host bastion did not open the way to db-primary. $whyNot');
  });

  test('a jump host that will not pass connections on, and one that could not reach the next itself', () {
    expect(
      jumpHostFailureText(en, at(JumpStage.onward, SSHChannelOpenError(1, 'open failed'), onward: 'db-primary')),
      'The jump host bastion does not pass connections on to db-primary: forwarding is turned off there, or not '
      'allowed for this account or key.',
    );
    // What it said of the next host is its own words, shown as text and nothing else.
    final esc = String.fromCharCode(0x1b);
    expect(
      jumpHostFailureText(
          en, at(JumpStage.onward, SSHChannelOpenError(2, 'connect failed:\r\nNo route$esc[2J to host'), onward: 'db-primary')),
      'The jump host bastion could not reach db-primary itself. What it said: connect failed: No route [2J to host',
    );
    // With no words of its own, or for another reason: that it did not open the way, and why as the library says.
    for (final cause in [SSHChannelOpenError(2, ''), SSHChannelOpenError(4, 'resource shortage')]) {
      expect(jumpHostFailureText(en, at(JumpStage.onward, cause, onward: 'db-primary')),
          startsWith('The jump host bastion did not open the way to db-primary. '));
    }
    // The same answer to something that is no way on is not taken for one.
    expect(jumpHostFailureText(en, at(JumpStage.signIn, SSHChannelOpenError(1, 'open failed'))),
        startsWith('Signing in to the jump host bastion did not work. '));
  });

  test('a jump host that ended the connection itself, saying why: its words, said as the jump host\'s, by whose they '
      'are', () {
    SSHAuthAbortError cutOff(String words, {required bool authentic}) => SSHAuthAbortError(
        'Connection closed before authentication', SSHDisconnectError(2, words, authentic: authentic));
    final esc = String.fromCharCode(0x1b);
    // Under keys whose host key was approved: the jump host's own words, shown as text and nothing else.
    expect(
      jumpHostFailureText(en, at(JumpStage.signIn, cutOff('Too many\r\nauthentication$esc[2J failures', authentic: true))),
      'The jump host bastion ended the connection. Its reason: Too many authentication [2J failures',
    );
    // Before that, they can be anybody's on the way.
    expect(
      jumpHostFailureText(en, at(JumpStage.signIn, cutOff('Too many authentication failures', authentic: false))),
      'The connection to the jump host bastion was ended before its key was checked. The reason that was sent, '
      'which may not be the jump host\'s own: Too many authentication failures',
    );
    // Whatever it was doing when it ended the connection: while it was to open the way on as well.
    expect(
      jumpHostFailureText(
          en, at(JumpStage.onward, SSHDisconnectError(11, 'Idle timeout', authentic: true), onward: 'db-primary')),
      'The jump host bastion ended the connection. Its reason: Idle timeout',
    );
    // With no words, there is nothing of its own to say: what it failed at, and why as the app has it.
    expect(jumpHostFailureText(en, at(JumpStage.signIn, cutOff(' \r\n', authentic: true))),
        startsWith('Signing in to the jump host bastion did not work. '));
    // And a host that ends the connection is still said as the host.
    expect(hostEndedText(en, cutOff('Too many authentication failures', authentic: true)),
        'The host ended the connection. Its reason: Too many authentication failures');
  });

  test('it is kept and shown as the app\'s own sentence, and what a jump host failed with counts as it would for '
      'the host', () {
    final failure = at(JumpStage.reach, refused);
    final kept = connectionFailureText(failure);
    expect(kept, '$kSaidByApp${jumpHostFailureText(en, failure)}');
    // Shown for the host the session is for: the words are the jump host's all the same.
    final shown = ConnectionError.translate(kept, host: '192.0.2.31', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, isNot(contains('192.0.2.31')));
    expect(shown.description, contains('192.0.2.10'));
    expect('$failure', 'Jump host bastion (reach): $refused');

    // Connecting again cannot help where it could not for the host itself.
    expect(reconnectCannotHelp(at(JumpStage.signIn, SSHAuthFailError('All authentication methods failed'))), isTrue);
    expect(reconnectCannotHelp(at(JumpStage.signIn, SSHHostkeyError('Hostkey verification failed'))), isTrue);
    expect(reconnectCannotHelp(at(JumpStage.reach, refused)), isFalse);
    expect(reconnectCannotHelp(SSHAuthFailError('All authentication methods failed')), isTrue);
    expect(reconnectCannotHelp(refused), isFalse);
  });

  test('what is no failure of a jump host passes as it is; anything else is that jump host\'s, with what it was doing',
      () {
    Object of(Object error) => jumpHostFailureOf(
          error,
          label: 'bastion',
          host: '192.0.2.10',
          port: 2222,
          username: 'deploy',
          stage: JumpStage.signIn,
          onward: 'db-primary',
        );
    final further = at(JumpStage.reach, refused);
    for (final passes in <Object>[
      // A jump host further out, which has its name already.
      further,
      // The person cancelling.
      ConnectionCancelledException(),
      const SshPromptCancelled(),
      // What the app refuses by itself.
      const OrchardAccessRefused('Not on this network.'),
      const CrateClosedOffline(crateId: 'c-ops', hours: 24, message: 'Closed on this device.'),
      // Nobody there to give it its sign-in details, where the app connects by itself (Server Monitor).
      NotSilentlyPollableException('bastion'),
    ]) {
      expect(of(passes), same(passes), reason: '$passes');
    }
    final wrapped = of(refused);
    expect(
      wrapped,
      isA<JumpHostFailure>()
          .having((f) => f.label, 'label', 'bastion')
          .having((f) => f.host, 'host', '192.0.2.10')
          .having((f) => f.port, 'port', 2222)
          .having((f) => f.username, 'username', 'deploy')
          .having((f) => f.stage, 'stage', JumpStage.signIn)
          .having((f) => f.cause, 'cause', same(refused))
          .having((f) => f.onward, 'onward', 'db-primary'),
    );
  });

  test('in every language the app speaks, with the names in it', () {
    final failures = [
      at(JumpStage.details, const SSHAuthFailedException('no key')),
      at(JumpStage.reach, refused),
      at(JumpStage.signIn, SSHAuthFailError('All authentication methods failed')),
      at(JumpStage.onward, SSHStateError('Transport is closed'), onward: 'db-primary'),
      at(JumpStage.onward, SSHChannelOpenError(1, 'open failed'), onward: 'db-primary'),
      at(JumpStage.onward, SSHChannelOpenError(2, 'Connection refused'), onward: 'db-primary'),
      at(JumpStage.signIn, SSHAuthAbortError('closed', SSHDisconnectError(2, 'Connection refused', authentic: true))),
      at(JumpStage.signIn, SSHAuthAbortError('closed', SSHDisconnectError(2, 'Connection refused', authentic: false))),
    ];
    final english = [for (final f in failures) jumpHostFailureText(en, f)];
    expect(english.toSet(), hasLength(failures.length), reason: 'each its own sentence');
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      for (var i = 0; i < failures.length; i++) {
        final said = jumpHostFailureText(l10n, failures[i]);
        expect(said, contains('bastion'), reason: '$locale $i');
        if (failures[i].onward != null) expect(said, contains('db-primary'), reason: '$locale $i');
        if (locale.languageCode != 'en') expect(said, isNot(english[i]), reason: '$locale $i');
      }
      // What the jump host said is in the three that quote it.
      for (final quoting in failures.skip(5)) {
        expect(jumpHostFailureText(l10n, quoting), contains('Connection refused'), reason: '$locale $quoting');
      }
    }
  });
}

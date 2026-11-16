import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show ConnectionCancelledException;
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

/// A key's own password, tried after the key (3.0, accounts per host), in
/// the app's SSH session: fetched only once a host has not taken the key
/// and asks for a password, as the way "password" or as a real password
/// prompt of its questions; never where the key is taken, and not for a
/// question that is not a password (a one-time code goes to the person). A
/// fetch that refuses (an Orchard's rule, the person cancelling) ends the
/// sign-in as that, and nothing more is sent.
///
/// The host is played by the test, and keeps what it is asked and sent.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const patience = Duration(seconds: 15);
  const saved = 'correct-horse-battery';

  setUp(() => L10nGlobal.update(en));
  tearDown(() => AuthDeadline.debugPatience = null);

  final key = SSHKeyPair.fromPem(
          File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync())
      .single;

  /// The app's own service signs in to a played host with [key], and with
  /// [passwordAfterKey] where one is given. The host takes the ways [ways];
  /// it says yes to the key where [takesKey], and to [saved] as a password
  /// or as the answer to a real password prompt. Its keyboard-interactive
  /// questions are [rounds], one request each, in order; whoever is asked
  /// the rest answers with [answers].
  ///
  /// How the try ended (null: connected), and what the host saw, in order:
  /// `key?` (asked about the key), `key!` (signed with it), `password:<it>`,
  /// `questions` (asked for its questions) and `answers:<them>`.
  Future<({Object? failure, List<String> seen, List<String> asked})> signIn({
    required List<String> ways,
    bool takesKey = false,
    Future<String?> Function()? passwordAfterKey,
    List<List<(String, bool)>> rounds = const [],
    List<String> answers = const [],
  }) async {
    final server = PlayedServer();
    final asked = <String>[];
    final ssh = SshService(
      host: 'web-01.example.com',
      port: 22,
      username: 'deploy',
      keyPairs: [key],
      passwordAfterKey: passwordAfterKey,
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      onServerQuestion: (question) async {
        asked.addAll(question.prompts.map((p) => p.text));
        return answers;
      },
      tunnelSocket: server.socket,
    );
    addTearDown(ssh.disconnect);
    Object? failure;
    var ended = false;
    final tried = ssh.connect().timeout(patience).then<void>((_) {
      ended = true;
    }, onError: (Object error) {
      failure = error;
      ended = true;
    });
    await server.greet();
    final host = PlayedSignIn(ways: ways, takesKey: takesKey, password: saved, rounds: rounds);
    if (await host.play(server, over: () => ended)) await PlayedSignIn.openShell(server);
    await tried;
    return (failure: failure, seen: host.seen, asked: asked);
  }

  /// A fetch that counts how often it was called and answers [password].
  ({Future<String?> Function() fetch, int Function() calls}) counted(String? password) {
    var calls = 0;
    return (
      fetch: () async {
        calls++;
        return password;
      },
      calls: () => calls,
    );
  }

  test('a host that does not take the key and takes passwords: the key first, then the password saved with it, '
      'fetched once', () async {
    final later = counted(saved);
    final outcome = await signIn(ways: ['publickey', 'password'], passwordAfterKey: later.fetch);
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'password:$saved']);
    expect(later.calls(), 1);
  });

  test('a host that takes the key: the password is never fetched, nor sent', () async {
    final later = counted(saved);
    final outcome = await signIn(ways: ['publickey', 'password'], takesKey: true, passwordAfterKey: later.fetch);
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'key!']);
    expect(later.calls(), 0);
  });

  test('a host that asks for it as a password prompt of its questions: it is the answer, fetched once', () async {
    final later = counted(saved);
    final outcome = await signIn(
      ways: ['publickey', 'keyboard-interactive'],
      passwordAfterKey: later.fetch,
      rounds: [
        [('Password: ', false)],
      ],
    );
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'questions', 'answers:$saved']);
    expect(later.calls(), 1);
    expect(outcome.asked, isEmpty, reason: 'nothing was left for the person');
  });

  test('a one-time code is no password: the person is asked, and the password is not fetched for it', () async {
    final later = counted(saved);
    final outcome = await signIn(
      ways: ['publickey', 'keyboard-interactive'],
      passwordAfterKey: later.fetch,
      rounds: [
        [('Verification code: ', false)],
        [('Password: ', false)],
      ],
      answers: ['123456'],
    );
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'questions', 'answers:123456', 'answers:$saved']);
    expect(outcome.asked, ['Verification code:']);
    expect(later.calls(), 1, reason: 'fetched for the password prompt, after the code');
  });

  test('both ways: the password is fetched once, for the way "password" and then for the prompt', () async {
    final later = counted('not-it');
    final outcome = await signIn(
      ways: ['publickey', 'password', 'keyboard-interactive'],
      passwordAfterKey: later.fetch,
      rounds: [
        [('Password: ', false)],
      ],
    );
    expect(outcome.failure, isA<SSHAuthFailError>());
    expect(outcome.seen, ['key?', 'password:not-it', 'questions', 'answers:not-it']);
    expect(later.calls(), 1);
  });

  test('a fetch that refuses ends the sign-in as that, and nothing more is sent', () async {
    final refused = OrchardAccessRefused(en.orchardPasswordNotConfirmed);
    final outcome = await signIn(
      ways: ['publickey', 'password', 'keyboard-interactive'],
      passwordAfterKey: () async => throw refused,
      rounds: [
        [('Password: ', false)],
      ],
    );
    expect(outcome.failure, same(refused));
    expect(outcome.seen, ['key?']);
  });

  test('the person cancelling where it was asked for is a cancel', () async {
    final outcome = await signIn(
      ways: ['publickey', 'keyboard-interactive'],
      passwordAfterKey: () async => throw ConnectionCancelledException(),
      rounds: [
        [('Password: ', false)],
      ],
    );
    expect(outcome.failure, isA<ConnectionCancelledException>());
    expect(outcome.seen, ['key?', 'questions']);
  });

  test('without a password saved with the key, none is sent: the host refuses', () async {
    final outcome = await signIn(ways: ['publickey', 'password']);
    expect(outcome.failure, isA<SSHAuthFailError>());
    expect(outcome.seen, ['key?']);
  });

  group('the answerer', () {
    test('a password saved with a key is something to answer with, also with nobody to ask', () async {
      var calls = 0;
      final answerer = KeyboardInteractiveAnswerer(passwordAfterKey: () async {
        calls++;
        return saved;
      });
      expect(answerer.canAnswer, isTrue);
      expect(answerer.handler, isNotNull);
      expect(await answerer.answer('', '', [(text: 'Verification code:', echo: false)]), ['']);
      expect(calls, 0, reason: 'no password prompt');
      expect(await answerer.answer('', '', [(text: 'Password:', echo: false)]), [saved]);
      expect(await answerer.answer('', '', [(text: 'Password:', echo: false)]), [''], reason: 'once');
      expect(calls, 1);
      expect(KeyboardInteractiveAnswerer().canAnswer, isFalse);
    });

    test('what stopped the fetch is kept, and the fetch is not made again', () async {
      var calls = 0;
      final refused = OrchardAccessRefused(en.orchardPasswordWrongHost);
      final answerer = KeyboardInteractiveAnswerer(passwordAfterKey: () async {
        calls++;
        throw refused;
      });
      expect(answerer.passwordAfterKeyStopped, isNull);
      await expectLater(answerer.passwordAfterKey(), throwsA(same(refused)));
      await expectLater(answerer.passwordAfterKey(), throwsA(same(refused)));
      expect(answerer.passwordAfterKeyStopped, same(refused));
      expect(calls, 1);
    });

    test('sent as the way "password", it is said in the log; none, nothing is said', () async {
      final lines = <String>[];
      expect(await sendPasswordAfterKey(KeyboardInteractiveAnswerer(passwordAfterKey: () async => saved), lines.add),
          saved);
      expect(lines, ['ssh_auth: The key was not taken; sending the password saved with it']);
      lines.clear();
      expect(await sendPasswordAfterKey(KeyboardInteractiveAnswerer(passwordAfterKey: () async => null), lines.add),
          isNull);
      expect(lines, isEmpty);
    });
  });
}

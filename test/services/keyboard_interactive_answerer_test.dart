import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/services/ssh_auth_prompts.dart';

/// The rules every ZestSSH connection answers a server's keyboard-interactive
/// questions by (3.0): the saved password only for a real password
/// prompt and only once, every other question to the person as the server's
/// own words, empty answers when nobody is there, and a sign-in clock that
/// stops while the person answers.
void main() {
  const pw = 'hunter2';
  ({String text, bool echo}) prompt(String text, {bool echo = false}) =>
      (text: text, echo: echo);

  group('someone is watching', () {
    late List<ServerQuestion> asked;
    List<String>? reply;

    KeyboardInteractiveAnswerer answerer({String? password = pw}) {
      asked = [];
      return KeyboardInteractiveAnswerer(
        password: password,
        ask: (question) async {
          asked.add(question);
          return reply;
        },
      );
    }

    test('the saved password answers the password prompt, the person the '
        'code', () async {
      reply = ['123456'];
      final a = answerer();
      final answers = await a.answer('', '', [
        prompt('Password:'),
        prompt('Verification code:'),
      ]);
      expect(answers, [pw, '123456']);
      expect(asked, hasLength(1));
      expect(asked.single.prompts.map((p) => p.text), ['Verification code:']);
      expect(asked.single.prompts.single.echo, isFalse);
    });

    test('the password goes once; a second password prompt asks the person',
        () async {
      reply = ['typed-by-person'];
      final a = answerer();
      expect(await a.answer('', '', [prompt('Password:')]), [pw]);
      expect(asked, isEmpty);
      expect(await a.answer('', '', [prompt('Password:')]),
          ['typed-by-person']);
      expect(asked.single.round, 2);
    });

    test('with no saved password, even a password prompt goes to the person',
        () async {
      reply = ['secret'];
      final a = answerer(password: null);
      expect(await a.answer('', '', [prompt('Password:')]), ['secret']);
      expect(asked.single.prompts.single.text, 'Password:');
    });

    test('a 2FA prompt never receives the saved password', () async {
      reply = ['654321'];
      final a = answerer();
      for (final text in [
        'Verification code:',
        'passcode:',
        'One-time password (OATH) for `alice\':',
        'Enter PASSCODE:',
      ]) {
        final answers = await a.answer('', '', [prompt(text)]);
        expect(answers, ['654321'], reason: text);
      }
    });

    test('an echoed question stays visible', () async {
      reply = ['1'];
      final a = answerer();
      await a.answer('', '', [prompt('Passcode or option (1-3):', echo: true)]);
      expect(asked.single.prompts.single.echo, isTrue);
    });

    test('a message with nothing to answer is acknowledged without asking',
        () async {
      var active = 0;
      final a = KeyboardInteractiveAnswerer(
        password: pw,
        ask: (_) async => fail('nothing to ask'),
        onServerActive: () => active++,
      );
      expect(
          await a.answer('Duo', 'Pushed a login request to your phone.', []),
          isEmpty);
      expect(active, 1);
    });

    test('cancelling ends the sign-in and is recorded', () async {
      reply = null;
      final a = answerer();
      await expectLater(a.answer('', '', [prompt('Verification code:')]),
          throwsA(isA<SshPromptCancelled>()));
      expect(a.cancelled, isTrue);
    });

    test('a reply of the wrong length counts as a cancel, not a guess',
        () async {
      reply = ['a', 'b'];
      final a = answerer();
      await expectLater(a.answer('', '', [prompt('Verification code:')]),
          throwsA(isA<SshPromptCancelled>()));
    });

    test('the person sees only the server\'s words: never the saved '
        'password, nothing filled in', () async {
      reply = ['x'];
      final a = answerer();
      await a.answer('Name', 'Instruction', [
        prompt('Password:'),
        prompt('Code:'),
      ]);
      final q = asked.single;
      final shown = [q.name, q.instruction, for (final p in q.prompts) p.text];
      expect(shown.join('|'), isNot(contains(pw)));
      expect(q.name, 'Name');
      expect(q.instruction, 'Instruction');
    });

    test('server text is cleaned: no controls, direction overrides or '
        'invisible characters, and capped', () async {
      reply = ['x'];
      final a = answerer();
      await a.answer(
        'Na\u202Eme\x1b[31m',
        'line1\r\nline2\x07\u200B\n',
        [prompt('Co\u202Ede:\n${'x' * 400}')],
      );
      final q = asked.single;
      expect(q.name, 'Name[31m');
      expect(q.instruction, 'line1\nline2');
      final text = q.prompts.single.text;
      expect(text, startsWith('Code: xxx'));
      expect(text.runes.length, kServerPromptMax + 1, reason: '+ ellipsis');
      expect(text, endsWith('\u2026'));
    });
  });

  group('nobody is watching (background connections)', () {
    test('only the saved password is sent; everything else is empty', () {
      final a = KeyboardInteractiveAnswerer(password: pw);
      expect(
          a.answerUnattended([prompt('Password:'), prompt('Verification code:')]),
          [pw, '']);
    });

    test('the password goes once here too, so a wrong one is not repeated '
        'into a lockout', () {
      final a = KeyboardInteractiveAnswerer(password: pw);
      expect(a.answerUnattended([prompt('Password:')]), [pw]);
      expect(a.answerUnattended([prompt('Password:')]), ['']);
    });

    test('answer() with no asker follows the same rule', () async {
      final a = KeyboardInteractiveAnswerer(password: pw);
      expect(await a.answer('', '', [prompt('Verification code:')]), ['']);
      expect(a.cancelled, isFalse);
    });

    test('with no password and nobody to ask, keyboard-interactive is not '
        'offered at all', () {
      final none = KeyboardInteractiveAnswerer();
      expect(none.canAnswer, isFalse);
      expect(none.handler, isNull);
      expect(KeyboardInteractiveAnswerer(password: pw).handler, isNotNull);
      expect(KeyboardInteractiveAnswerer(ask: (_) async => null).handler,
          isNotNull);
    });
  });

  group('cleanServerText', () {
    test('keeps line breaks only where asked', () {
      expect(cleanServerText('a\nb', maxLength: 10), 'a b');
      expect(cleanServerText('a\nb', maxLength: 10, multiline: true), 'a\nb');
    });

    test('drops C1 controls, bidi isolates and the byte-order mark', () {
      expect(
          cleanServerText('\u0085a\u2066b\u2069\uFEFFc\u00AD', maxLength: 10),
          'abc');
    });
  });

  group('AuthDeadline', () {
    Object? outcome;

    void watch(AuthDeadline deadline, Future<void> auth) {
      outcome = null;
      deadline
          .wait(auth, onTimeout: () => TimeoutException('late'))
          .then<void>((_) {
        outcome = 'done';
      }, onError: (Object e) {
        outcome = e;
      });
    }

    testWidgets('times out after the limit of silence', (tester) async {
      final auth = Completer<void>();
      watch(AuthDeadline(), auth.future);
      await tester.pump(const Duration(seconds: 14));
      expect(outcome, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(outcome, isA<TimeoutException>());
    });

    testWidgets('the clock stops while the person answers and restarts in '
        'full', (tester) async {
      final deadline = AuthDeadline();
      final auth = Completer<void>();
      final person = Completer<String>();
      watch(deadline, auth.future);
      await tester.pump(const Duration(seconds: 10));
      unawaited(deadline.whileAsking(() => person.future));
      await tester.pump(const Duration(minutes: 2));
      expect(outcome, isNull, reason: 'no timeout while asking');
      person.complete('123456');
      await tester.pump(const Duration(seconds: 14));
      expect(outcome, isNull, reason: 'a full 15 seconds after the answer');
      await tester.pump(const Duration(seconds: 2));
      expect(outcome, isA<TimeoutException>());
    });

    testWidgets('a server that has started asking gets longer to reply',
        (tester) async {
      final deadline = AuthDeadline();
      final auth = Completer<void>();
      watch(deadline, auth.future);
      deadline.relax(kServerQuestionPatience);
      await tester.pump(const Duration(seconds: 100));
      expect(outcome, isNull);
      await tester.pump(const Duration(seconds: 21));
      expect(outcome, isA<TimeoutException>());
    });

    testWidgets('one that words nothing of its own fails as a sign-in that timed out, with how long the server '
        'was given', (tester) async {
      Object? failed;
      void wait(AuthDeadline deadline) {
        failed = null;
        deadline.wait(Completer<void>().future).then<void>((_) {}, onError: (Object e) {
          failed = e;
        });
      }

      wait(AuthDeadline());
      await tester.pump(const Duration(seconds: 16));
      expect(failed, isA<SignInTimedOut>());
      expect((failed! as SignInTimedOut).duration, const Duration(seconds: 15));
      expect('$failed', 'TimeoutException after 0:00:15.000000: Authentication timed out');

      // One that has started asking: the longer time it was given.
      final asked = AuthDeadline()..relax(kServerQuestionPatience);
      wait(asked);
      await tester.pump(kServerQuestionPatience + const Duration(seconds: 1));
      expect((failed! as SignInTimedOut).duration, kServerQuestionPatience);

      // A limit of its own.
      wait(AuthDeadline(const Duration(seconds: 2)));
      await tester.pump(const Duration(seconds: 3));
      expect((failed! as SignInTimedOut).duration, const Duration(seconds: 2));

      // What a test gives a server where no limit is given; a limit that is given stays.
      AuthDeadline.debugPatience = const Duration(seconds: 4);
      addTearDown(() => AuthDeadline.debugPatience = null);
      wait(AuthDeadline());
      await tester.pump(const Duration(seconds: 3));
      expect(failed, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect((failed! as SignInTimedOut).duration, const Duration(seconds: 4));
      wait(AuthDeadline(const Duration(seconds: 8)));
      await tester.pump(const Duration(seconds: 7));
      expect(failed, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect((failed! as SignInTimedOut).duration, const Duration(seconds: 8));
    });

    testWidgets('the clock stops while a key signs, and starts again in full when it has', (tester) async {
      final deadline = AuthDeadline();
      final auth = Completer<void>();
      watch(deadline, auth.future);
      final key = _PlayedKey();
      final keys = signingOffTheClock([key], deadline);
      expect(keys, hasLength(1));
      // What a server is told of the key, and what it signs at once, is the key's own.
      final given = keys.single;
      expect((given.name, given.type, given.toPem()), ('the name', 'the type', 'the key'));
      expect(given.toPublicKey(), same(key.public));
      expect(given.sign(Uint8List(4)), same(key.signature));
      await tester.pump(const Duration(seconds: 10));
      expect(outcome, isNull);

      // A hardware key that waits to be touched.
      SSHSignature? signed;
      unawaited(given.signAsync(Uint8List(4)).then((signature) => signed = signature));
      await tester.pump(const Duration(minutes: 2));
      expect(outcome, isNull, reason: 'no timeout while the key signs');
      expect(signed, isNull);
      key.touched.complete();
      await tester.pump();
      expect(signed, same(key.signature));
      await tester.pump(const Duration(seconds: 14));
      expect(outcome, isNull, reason: 'a full 15 seconds after it has signed');
      await tester.pump(const Duration(seconds: 2));
      expect(outcome, isA<TimeoutException>());

      // A sign-in with no keys has none.
      expect(signingOffTheClock(null, AuthDeadline()), isEmpty);
      expect(signingOffTheClock(const [], AuthDeadline()), isEmpty);
    });

    testWidgets('a key that fails to sign fails as it did, and the clock goes on', (tester) async {
      final deadline = AuthDeadline();
      watch(deadline, Completer<void>().future);
      final key = _PlayedKey();
      Object? failed;
      unawaited(signingOffTheClock([key], deadline).single.signAsync(Uint8List(4)).then<void>((_) {},
          onError: (Object e) {
        failed = e;
      }));
      await tester.pump(const Duration(seconds: 30));
      key.touched.completeError(StateError('the agent did not sign'));
      await tester.pump();
      expect(failed, isA<StateError>());
      expect(outcome, isNull);
      await tester.pump(const Duration(seconds: 16));
      expect(outcome, isA<TimeoutException>());
    });

    testWidgets('one that words the failure for itself fails with that', (tester) async {
      Object? failed;
      AuthDeadline().wait(Completer<void>().future, onTimeout: () => const FormatException('worded here')).then<void>(
          (_) {}, onError: (Object e) {
        failed = e;
      });
      await tester.pump(const Duration(seconds: 16));
      expect(failed, isA<FormatException>());
    });

    testWidgets('finishing in time wins and leaves no timer behind',
        (tester) async {
      final auth = Completer<void>();
      watch(AuthDeadline(), auth.future);
      auth.complete();
      await tester.pump();
      expect(outcome, 'done');
      await tester.pump(const Duration(minutes: 5));
      expect(outcome, 'done');
    });

    testWidgets('a failed sign-in keeps its own error', (tester) async {
      final auth = Completer<void>();
      watch(AuthDeadline(), auth.future);
      auth.completeError(StateError('rejected'));
      await tester.pump();
      expect(outcome, isA<StateError>());
    });
  });
}

/// A key that signs when it is touched, as a key on a hardware key does.
class _PlayedKey extends SSHKeyPair {
  final public = _Public();
  final signature = _Signature();

  /// Completes when its person has touched it.
  final touched = Completer<void>();

  @override
  String get name => 'the name';

  @override
  String get type => 'the type';

  @override
  core_hk.SSHHostKey toPublicKey() => public;

  @override
  SSHSignature sign(Uint8List data) => signature;

  @override
  Future<SSHSignature> signAsync(Uint8List data) async {
    await touched.future;
    return signature;
  }

  @override
  String toPem() => 'the key';
}

class _Public implements core_hk.SSHHostKey {
  @override
  Uint8List encode() => Uint8List(0);
}

class _Signature implements SSHSignature {
  @override
  Uint8List encode() => Uint8List(0);
}

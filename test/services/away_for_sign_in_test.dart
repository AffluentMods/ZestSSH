import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/away_for_sign_in.dart';

/// Time away for a sign-in this app opened does not count toward Auto-lock
/// (found in a security review): leaving for a code, a mail link or a company's page
/// locked the app behind the person. Every other absence counts as before.
void main() {
  test('nothing waiting: time away counts', () {
    final now = DateTime.now();
    expect(AwayForSignIn.covers(now.subtract(const Duration(minutes: 5)), now), isFalse);
  });

  test('left while a sign-in waits: covered', () async {
    final done = Completer<void>();
    final flow = AwayForSignIn.during(() => done.future);
    final left = DateTime.now().add(const Duration(seconds: 1));
    expect(AwayForSignIn.covers(left, left.add(const Duration(minutes: 5))), isTrue);
    done.complete();
    await flow;
    expect(AwayForSignIn.covers(left, left.add(const Duration(minutes: 5))), isFalse, reason: 'it ended');
  });

  test('left before the sign-in began: not covered', () async {
    final left = DateTime.now().subtract(const Duration(minutes: 1));
    final done = Completer<void>();
    final flow = AwayForSignIn.during(() => done.future);
    expect(AwayForSignIn.covers(left, DateTime.now()), isFalse);
    done.complete();
    await flow;
  });

  test('past its longest wait, time away counts again', () async {
    final done = Completer<void>();
    // Read first: the wait begins at or after it, whatever the machine is doing.
    final now = DateTime.now();
    final flow = AwayForSignIn.during(() => done.future);
    addTearDown(() {
      if (!done.isCompleted) done.complete();
    });
    expect(AwayForSignIn.covers(now.add(const Duration(seconds: 1)), now.add(AwayForSignIn.longest)), isTrue);
    expect(
        AwayForSignIn.covers(
            now.add(const Duration(seconds: 1)), now.add(AwayForSignIn.longest + const Duration(minutes: 1))),
        isFalse);
    done.complete();
    await flow;
  });

  test('two at once: covered until the last ends, and an error ends it too', () async {
    final first = Completer<void>();
    final flow = AwayForSignIn.during(() => first.future);
    final failed = AwayForSignIn.during<void>(() async => throw StateError('no'));
    await expectLater(failed, throwsStateError);
    final left = DateTime.now().add(const Duration(seconds: 1));
    expect(AwayForSignIn.covers(left, left), isTrue, reason: 'the first still waits');
    first.complete();
    await flow;
    expect(AwayForSignIn.covers(left, left), isFalse);
  });
}

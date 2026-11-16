import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/account/account_deletion_flow.dart' show FreshSignIn;
import 'package:zestssh/services/account/sync_reset_api.dart';
import 'package:zestssh/services/account/sync_reset_flow.dart';

/// A server that answers a reset with [answer], or refuses with [refusal].
class _Api extends Fake implements SyncResetApi {
  _Api(this.done, {this.answer = const SyncResetResult(hadData: true, keptDays: 30), this.refusal});

  final List<String> done;
  final SyncResetResult answer;
  final SyncResetException? refusal;

  @override
  Future<SyncResetResult> reset({required String token, required String confirmUid}) async {
    done.add('reset $token for $confirmUid');
    final refused = refusal;
    if (refused != null) throw refused;
    return answer;
  }
}

/// Resetting cloud sync, step by step (3.0): nothing is changed until the
/// server said yes, no sync cycle runs while the copy goes, and this device
/// forgets the keys of the copy only once it is gone.
void main() {
  const fresh = FreshSignIn(token: 'fresh-token', uid: 'uid-1', email: 'you@example.com');

  late List<String> done;
  late List<SyncResetStage> stages;

  SyncResetFlow flow({
    FreshSignIn? signIn = fresh,
    Object? signInFails,
    bool sameAccount = true,
    SyncResetException? refusal,
    SyncResetResult answer = const SyncResetResult(hadData: true, keptDays: 30),
    Completer<void>? cycleRunning,
  }) {
    return SyncResetFlow(
      isSameAccount: (f) {
        done.add('same account? ${f.uid}');
        return sameAccount;
      },
      signInAgain: () async {
        done.add('sign in');
        if (signInFails != null) throw signInFails;
        return signIn;
      },
      suspendSync: () async {
        done.add('hold sync');
        // A cycle already running is waited for.
        if (cycleRunning != null) await cycleRunning.future;
        done.add('sync held');
      },
      resumeSync: () => done.add('lift the hold'),
      api: _Api(done, answer: answer, refusal: refusal),
      disconnectHere: () async => done.add('sync off here'),
    );
  }

  setUp(() {
    done = [];
    stages = [];
  });

  test('in order: sign in again, hold sync, ask the server, turn sync off here, lift the hold', () async {
    final outcome = await flow().run(onStage: stages.add);

    expect(done, [
      'sign in',
      'same account? uid-1',
      'hold sync',
      'sync held',
      'reset fresh-token for uid-1',
      'sync off here',
      'lift the hold',
    ]);
    expect(stages, [
      SyncResetStage.signingIn,
      SyncResetStage.stoppingSync,
      SyncResetStage.resetting,
      SyncResetStage.turningOffHere,
    ]);
    expect(outcome, isA<SyncResetDone>());
    outcome as SyncResetDone;
    expect(outcome.hadData, isTrue);
    expect(outcome.keptDays, 30);
  });

  test('what the server did is passed on: nothing was there, and no number it did not give', () async {
    final outcome = await flow(answer: const SyncResetResult(hadData: false, keptDays: 0)).run();
    outcome as SyncResetDone;
    expect(outcome.hadData, isFalse);
    expect(outcome.keptDays, 0);
  });

  test('the server is not asked while a sync cycle is still running', () async {
    final cycle = Completer<void>();
    final run = flow(cycleRunning: cycle).run();
    await pumpEventQueue();
    expect(done, ['sign in', 'same account? uid-1', 'hold sync'], reason: 'waiting for the cycle');
    cycle.complete();
    await run;
    expect(done.indexOf('sync held'), lessThan(done.indexOf('reset fresh-token for uid-1')));
  });

  test('backing out of the sign-in changes nothing', () async {
    final outcome = await flow(signIn: null).run(onStage: stages.add);
    expect(outcome, isA<SyncResetCancelled>());
    expect(done, ['sign in'], reason: 'sync was never held, the server never asked');
    expect(stages, [SyncResetStage.signingIn]);
  });

  test('a sign-in that fails changes nothing, and says what was thrown', () async {
    final outcome = await flow(signInFails: StateError('the browser did not come back')).run();
    outcome as SyncResetFailed;
    expect(outcome.code, 'sign-in-failed');
    expect(outcome.detail, contains('the browser did not come back'));
    expect(outcome.cause, isNull, reason: 'the server was not asked: nothing of its stopped this');
    expect(done, ['sign in']);
  });

  test('what stopped the request is carried to the screen: what was caught, where nothing answered', () async {
    const caught = FormatException('what was caught');
    final outcome = await flow(refusal: const SyncResetException('network', 'no answer', cause: caught)).run();
    outcome as SyncResetFailed;
    expect(outcome.code, 'network');
    expect(outcome.detail, 'no answer');
    expect(outcome.cause, same(caught));
  });

  test('a sign-in to another account changes nothing', () async {
    final outcome = await flow(sameAccount: false).run();
    expect(outcome, isA<SyncResetWrongAccount>());
    expect(done, ['sign in', 'same account? uid-1'], reason: 'neither held nor asked');
  });

  test('the server refuses: sync runs again, and this device keeps its keys', () async {
    final outcome = await flow(
      refusal: const SyncResetException('recent-sign-in-required', 'HTTP 403: Sign in again to reset cloud sync'),
    ).run(onStage: stages.add);

    outcome as SyncResetFailed;
    expect(outcome.code, 'recent-sign-in-required');
    expect(outcome.detail, 'HTTP 403: Sign in again to reset cloud sync');
    expect(outcome.cause, 'HTTP 403: Sign in again to reset cloud sync', reason: 'the answer, where there was one');
    expect(done, [
      'sign in',
      'same account? uid-1',
      'hold sync',
      'sync held',
      'reset fresh-token for uid-1',
      'lift the hold',
    ]);
    expect(done, isNot(contains('sync off here')), reason: 'the cloud copy is still there: its keys are kept');
    expect(stages.last, SyncResetStage.resetting);
  });

  test('the keys are forgotten before the hold is lifted: no cycle runs with them', () async {
    await flow().run();
    expect(done.indexOf('sync off here'), lessThan(done.indexOf('lift the hold')));
    expect(done.where((d) => d == 'lift the hold'), hasLength(1));
  });
}

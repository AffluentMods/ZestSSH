import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Which keys are the account's is asked of the server at most every ten
/// minutes and one question at a time; keys that are not ready yet are asked
/// about again next time, and a failure is never kept.
///
/// When the server cannot be asked, what it said last stands, or, with
/// nothing said yet in this run, the keys this device holds as confirmed
/// (3.0). Until this was held, ten minutes into an outage
/// of ZestSSH Cloud every use of the keys failed: a certificate the device
/// held and that was still good could not be used to log in.
void main() {
  late AccountKeys keys;
  setUpAll(() async => keys = await AccountKeys.generate());

  test('asks once for callers at the same time, then reuses the answer', () async {
    var asked = 0;
    final answer = Completer<CrateAuthor?>();
    var now = DateTime(2026, 9, 23, 12);
    final source = OrchardAuthorSource(() {
      asked++;
      return answer.future;
    }, clock: () => now);

    final first = source();
    final second = source();
    answer.complete(CrateAuthor(uid: 'u1', keys: keys));
    expect((await first)!.uid, 'u1');
    expect((await second)!.uid, 'u1');
    expect(asked, 1);

    now = now.add(const Duration(minutes: 9));
    await source();
    expect(asked, 1, reason: 'within ten minutes the answer stands');
  });

  test('asks again after ten minutes', () async {
    var asked = 0;
    var now = DateTime(2026, 9, 23, 12);
    final source = OrchardAuthorSource(() async {
      asked++;
      return CrateAuthor(uid: 'u1', keys: keys);
    }, clock: () => now);
    await source();
    now = now.add(const Duration(minutes: 11));
    await source();
    expect(asked, 2);
  });

  test('keys that are not ready are asked about again right away', () async {
    var asked = 0;
    final source = OrchardAuthorSource(() async {
      asked++;
      return asked == 1 ? null : CrateAuthor(uid: 'u1', keys: keys);
    });
    expect(await source(), isNull);
    expect((await source())!.uid, 'u1');
    expect(asked, 2);
  });

  test('a failure is not kept', () async {
    var asked = 0;
    final source = OrchardAuthorSource(() async {
      asked++;
      if (asked == 1) throw StateError('offline');
      return CrateAuthor(uid: 'u1', keys: keys);
    });
    await expectLater(source(), throwsStateError);
    expect((await source())!.uid, 'u1');
  });

  group('the server cannot be asked', () {
    late DateTime now;
    late int asked;
    late bool down;
    late CrateAuthor? Function() answer;

    setUp(() {
      now = DateTime(2026, 10, 8, 12);
      asked = 0;
      down = false;
      answer = () => CrateAuthor(uid: 'u1', keys: keys);
    });

    OrchardAuthorSource source({Future<CrateAuthor?> Function()? lastConfirmed}) => OrchardAuthorSource(
          () async {
            asked++;
            if (down) throw StateError('Account keys: no answer');
            return answer();
          },
          clock: () => now,
          lastConfirmed: lastConfirmed,
        );

    test('what it said last stands, long after the ten minutes', () async {
      final who = source();
      expect((await who())!.uid, 'u1');
      down = true;
      now = now.add(const Duration(minutes: 11));
      expect((await who())!.uid, 'u1', reason: 'eleven minutes on, and the server down');
      now = now.add(const Duration(hours: 30));
      expect((await who())!.uid, 'u1', reason: 'a day on');
    });

    test('it is left alone for a minute after it could not be asked, then asked again', () async {
      final who = source();
      await who();
      down = true;
      now = now.add(const Duration(minutes: 11));
      await who();
      expect(asked, 2);
      // Every use of the keys in that minute gets the answer at once.
      now = now.add(const Duration(seconds: 59));
      await who();
      await who();
      expect(asked, 2, reason: 'a server that is down must not make every use wait for a connection to give up');
      now = now.add(const Duration(seconds: 1));
      await who();
      expect(asked, 3, reason: 'a minute on, it is asked again');
    });

    test('when it answers again, its answer stands, whatever it is', () async {
      final who = source();
      await who();
      down = true;
      now = now.add(const Duration(minutes: 11));
      expect(await who(), isNotNull);

      // It is back, and says the keys are not this account's any more.
      down = false;
      answer = () => null;
      now = now.add(const Duration(minutes: 2));
      expect(await who(), isNull, reason: 'an answer is not a failure: nothing stands in for it');

      // Down again right after: nothing is known now, so nothing stands.
      down = true;
      await expectLater(who(), throwsStateError);
    });

    test('with nothing said yet in this run, the keys the device holds as confirmed stand in', () async {
      down = true;
      var looked = 0;
      final who = source(lastConfirmed: () async {
        looked++;
        return CrateAuthor(uid: 'u1', keys: keys);
      });
      expect((await who())!.uid, 'u1', reason: 'the app was started while the server was down');
      expect(looked, 1);
      // And they are not read again at every use.
      await who();
      expect(looked, 1);
      expect(asked, 1);

      // Back: the server's answer is the one that counts from then on.
      down = false;
      now = now.add(const Duration(minutes: 2));
      await who();
      expect(asked, 2);
      now = now.add(const Duration(minutes: 9));
      await who();
      expect(asked, 2, reason: 'and it stands for ten minutes, like any answer');
    });

    test('a device that holds no confirmed keys has nothing to stand in: the failure is thrown', () async {
      down = true;
      await expectLater(source(lastConfirmed: () async => null)(), throwsStateError);
      await expectLater(source()(), throwsStateError);
    });

    test('after the keys were replaced nothing stands in until the server has answered', () async {
      var looked = 0;
      final who = source(lastConfirmed: () async {
        looked++;
        return CrateAuthor(uid: 'u1', keys: keys);
      });
      await who();
      // This device learned that the account's keys were replaced.
      who.forget();
      down = true;
      await expectLater(who(), throwsStateError, reason: 'neither the old answer nor what the device holds');
      expect(looked, 0, reason: 'what the device holds may be the very keys that were replaced');

      // Once the server has answered, its answer is what stands.
      down = false;
      await who();
      down = true;
      now = now.add(const Duration(minutes: 11));
      expect((await who())!.uid, 'u1');
      expect(looked, 0);
    });

    test('the keys were replaced before this run had asked anything: what the device holds does not stand in',
        () async {
      // The app was started, and the first thing it learned (from an Orchard
      // that refused these keys) is that the account has others now.
      var looked = 0;
      final who = source(lastConfirmed: () async {
        looked++;
        return CrateAuthor(uid: 'u1', keys: keys);
      });
      who.forget();
      down = true;
      await expectLater(who(), throwsStateError);
      expect(looked, 0, reason: 'they may be the very keys that were replaced');
    });

    test('the server said the keys are not ready here, then cannot be asked: nothing stands in for that answer',
        () async {
      var looked = 0;
      final who = source(lastConfirmed: () async {
        looked++;
        return CrateAuthor(uid: 'u1', keys: keys);
      });
      answer = () => null;
      expect(await who(), isNull);
      down = true;
      await expectLater(who(), throwsStateError);
      expect(looked, 0, reason: 'its last word was that these are not the keys: what the device holds is not asked');
    });

    test('callers at the same time share the one question, and its outcome', () async {
      final who = source();
      await who();
      down = true;
      now = now.add(const Duration(minutes: 11));
      final answers = await Future.wait([who(), who(), who()]);
      expect(answers.map((a) => a!.uid), ['u1', 'u1', 'u1']);
      expect(asked, 2);
    });
  });
}

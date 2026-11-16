import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/rules/reauth_warning.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A team's "Sign-in lasts" rule warns before it bites: in the
/// last tenth of the span, at least a quarter of an hour and at most a day, once for
/// each moment it stops counting, and the notice comes down once it is no longer so.
void main() {
  const hour = 3600;
  final en = lookupAppLocalizations(const Locale('en'));

  test('the last tenth of the span, at least 15 minutes, at most a day', () {
    expect(reauthWarningBefore(hour), const Duration(minutes: 15));
    expect(reauthWarningBefore(4 * hour), const Duration(minutes: 24));
    expect(reauthWarningBefore(8 * hour), const Duration(minutes: 48));
    expect(reauthWarningBefore(5 * 24 * hour), const Duration(hours: 12));
    expect(reauthWarningBefore(30 * 24 * hour), const Duration(days: 1));
  });

  group('the watch', () {
    late int now;
    late int? signedIn;
    late List<String> said;
    late ReauthWatch watch;
    const team = (id: 't1', name: 'Northwind', seconds: 8 * hour, signInOnly: false);

    setUp(() {
      now = 1000000;
      signedIn = now;
      said = [];
      watch = ReauthWatch(
        signedInAt: () async => signedIn,
        tell: (t, ends) => said.add('tell ${t.id} ${ends - 1000000}'),
        takeDown: (id) => said.add('down $id'),
        now: () => DateTime.fromMillisecondsSinceEpoch(now * 1000),
      );
    });

    test('quiet until the last tenth, and said once', () async {
      await watch.check(const [team]);
      now += 7 * hour;
      await watch.check(const [team]);
      expect(said, isEmpty);
      now += 13 * 60; // 7 h 13 min: 47 minutes left, within the last 48.
      await watch.check(const [team]);
      expect(said, ['tell t1 ${8 * hour}']);
      now += 60;
      await watch.check(const [team]);
      expect(said.length, 1, reason: 'said once for that moment');
    });

    test('signed in again: taken down, and the new moment counts from then', () async {
      now += 7 * hour + 30 * 60;
      await watch.check(const [team]);
      expect(said.length, 1);
      signedIn = now;
      await watch.check(const [team]);
      expect(said.last, 'down t1');
      now += 7 * hour + 30 * 60;
      await watch.check(const [team]);
      expect(said.last, startsWith('tell t1'));
    });

    test('a passkey\'s confirmation moves the moment, unless the team requires company sign-in', () async {
      var confirmed = now;
      final tapped = ReauthWatch(
        signedInAt: () async => signedIn,
        confirmedAt: () async => confirmed,
        tell: (t, ends) => said.add('tell ${t.id} ${ends - 1000000}'),
        takeDown: (id) => said.add('down $id'),
        now: () => DateTime.fromMillisecondsSinceEpoch(now * 1000),
      );
      const company = (id: 't2', name: 'Acme', seconds: 8 * hour, signInOnly: true);
      now += 7 * hour + 30 * 60;
      await tapped.check(const [team, company]);
      expect(said, ['tell t1 ${8 * hour}', 'tell t2 ${8 * hour}']);
      said.clear();
      // A tap: the one team's moment moves, and its notice comes down; the other's stays.
      confirmed = now;
      await tapped.check(const [team, company]);
      expect(said, ['down t1']);
    });

    test('past the moment: taken down, the team\'s banner says it from there', () async {
      now += 7 * hour + 30 * 60;
      await watch.check(const [team]);
      now += hour;
      await watch.check(const [team]);
      expect(said.last, 'down t1');
    });

    test('no rule, or no way to tell when the account signed in: nothing is said', () async {
      now += 7 * hour + 30 * 60;
      await watch.check(const [(id: 't2', name: 'Open', seconds: 0, signInOnly: false)]);
      signedIn = null;
      await watch.check(const [team]);
      expect(said, isEmpty);
    });

    test('a team left, or the account signed out: what was told comes down', () async {
      now += 7 * hour + 30 * 60;
      await watch.check(const [team]);
      await watch.check(const []);
      expect(said.last, 'down t1');
      await watch.check(const [team]);
      watch.forget();
      expect(said.last, 'down t1');
    });
  });

  test('the notice says when, how long a sign-in lasts, and offers to sign in', () {
    var signedInAgain = false;
    final n = reauthSoonNotice(
      orchardId: 't1',
      team: 'Northwind',
      windowSeconds: 8 * hour,
      ends: 1000000,
      l10n: en,
      onSignIn: () => signedInAgain = true,
      now: DateTime.fromMillisecondsSinceEpoch(1000000 * 1000 - hour * 1000),
    );
    expect(n.id, reauthSoonNoticeId('t1'));
    expect(n.title, en.orchardReauthSoonTitle('Northwind'));
    expect(n.body, contains('8 hours'));
    expect(n.actionLabel, en.orchardReauthSoonAction);
    n.onAction!();
    expect(signedInAgain, isTrue);
  });
}

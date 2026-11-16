import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/reveal_gate.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/redactor.dart';

/// A Crate that asks again (3.0) before its secrets leave the
/// device, not only before they are shown: a share with the key's password
/// or private key asks the person first, and so does a session about to
/// send a saved password to a host this account may change. A session has
/// no screen of its own, so the app asks for it over whatever screen is up;
/// sessions asking together share one answer; with nothing to ask on, the
/// answer is no.

const _orchard = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _askCrate = '77777777-7777-4777-8777-777777777777';
const _plainCrate = '88888888-8888-4888-8888-888888888888';

/// The device's own check: what the person answers, and what they were told.
class _FakeAuth extends Fake implements LocalAuthentication {
  bool answer = false;
  var asked = 0;
  String? reason;

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticate) {
      asked++;
      reason = invocation.namedArguments[#localizedReason] as String?;
      return Future<bool>.value(answer);
    }
    return super.noSuchMethod(invocation);
  }
}

/// A session's own [Ref], as the connect flow has one.
final _sessionRef = Provider<Ref>((ref) => ref);

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> frames(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  // A new scope each time: overrides made with overrideWith are not
  // updated in place.
  Widget app(Widget home, {List<Override> overrides = const [], GlobalKey<NavigatorState>? navigator}) =>
      ProviderScope(
        key: UniqueKey(),
        overrides: overrides,
        child: MaterialApp(
          navigatorKey: navigator,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: home),
        ),
      );

  group('a share with secrets', () {
    const summary = OrchardSummary(
      id: _orchard,
      name: 'Acme',
      role: 'owner',
      defaultCrateId: _plainCrate,
      crates: [
        CrateSummary(id: _askCrate, name: 'Prod', level: 'manage', switches: CrateSwitches.all, confirmReveal: true),
        CrateSummary(id: _plainCrate, name: 'Dev', level: 'manage', switches: CrateSwitches.all),
      ],
    );

    /// Runs [mayShareSecretsOf] for [key] with [space] on screen; its answer.
    Future<bool?> share(WidgetTester tester, _FakeAuth auth, String key, {Space space = const OrchardSpace(_orchard)}) async {
      late BuildContext context;
      late WidgetRef widgetRef;
      await tester.pumpWidget(app(
        Consumer(builder: (c, ref, _) {
          context = c;
          widgetRef = ref;
          ref.watch(itemCratesProvider('key'));
          return const Text('hosts');
        }),
        overrides: [
          activeSpaceProvider.overrideWith((ref) => space),
          orchardSummariesProvider.overrideWith((ref) async => [summary]),
          activeOrchardProvider.overrideWithValue(const AsyncData(summary)),
          itemCratesProvider('key').overrideWith((ref) => Stream.value({'k-ask': _askCrate, 'k-plain': _plainCrate})),
          localAuthProvider.overrideWithValue(auth),
        ],
      ));
      await frames(tester);
      bool? answer;
      unawaited(mayShareSecretsOf(context, widgetRef, key).then((v) => answer = v));
      await frames(tester);
      await tester.pump(const Duration(seconds: 5));
      return answer;
    }

    testWidgets('from a Crate that asks again: only once the person confirms it is them', (tester) async {
      final auth = _FakeAuth();
      expect(await share(tester, auth, 'k-ask'), isFalse, reason: 'declined: nothing is shared');
      expect(auth.asked, 1);
      expect(auth.reason, l10n.orchardSendReason, reason: 'worded for a secret leaving, not being shown');

      auth.answer = true;
      expect(await share(tester, auth, 'k-ask'), isTrue);
      expect(auth.asked, 2);
    });

    testWidgets('from a Crate that does not ask again, or from your Tree: at once', (tester) async {
      final auth = _FakeAuth();
      expect(await share(tester, auth, 'k-plain'), isTrue);
      expect(await share(tester, auth, 'k-ask', space: const TreeSpace()), isTrue);
      expect(auth.asked, 0);
    });
  });

  group('a session sending a password', () {
    /// The app's root with [auth], answering sessions over its navigator
    /// (or over nothing, with [noScreen]); returns the session's [Ref].
    Future<Ref> start(WidgetTester tester, _FakeAuth auth, {bool noScreen = false}) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(
        Consumer(builder: (context, ref, _) {
          answerConfirmItIsYouRequests(ref, () => noScreen ? null : navigator.currentContext);
          return const Text('app');
        }),
        overrides: [localAuthProvider.overrideWithValue(auth)],
        navigator: navigator,
      ));
      return ProviderScope.containerOf(tester.element(find.text('app'))).read(_sessionRef);
    }

    testWidgets('waits for the person, asked over the screen that is up; sessions asking together share the answer',
        (tester) async {
      final auth = _FakeAuth()..answer = true;
      final session = await start(tester, auth);
      final answers = <bool>[];
      unawaited(askConfirmItIsYou(session).then(answers.add));
      unawaited(askConfirmItIsYou(session).then(answers.add));
      await frames(tester);
      expect(answers, [true, true]);
      expect(auth.asked, 1, reason: 'one question for hosts opened together');
      expect(auth.reason, l10n.orchardSendReason);

      // The next connection asks again.
      auth.answer = false;
      unawaited(askConfirmItIsYou(session).then(answers.add));
      await frames(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(answers, [true, true, false]);
      expect(auth.asked, 2);
    });

    testWidgets('the question names where the password goes; another place is asked on its own', (tester) async {
      final auth = _FakeAuth()..answer = true;
      final session = await start(tester, auth);
      final answers = <String>[];
      unawaited(askConfirmItIsYou(session, destination: 'db1.example.com:22').then((v) => answers.add('db1 $v')));
      unawaited(askConfirmItIsYou(session, destination: 'db1.example.com:22').then((v) => answers.add('db1 $v')));
      unawaited(askConfirmItIsYou(session, destination: 'other.example:2222').then((v) => answers.add('other $v')));
      await frames(tester);
      await frames(tester);
      expect(answers, ['db1 true', 'db1 true', 'other true']);
      expect(auth.asked, 2, reason: 'the same place shares one question, another place gets its own');
      expect(auth.reason, l10n.orchardSendToReason('other.example:2222'));
    });

    testWidgets('while recording, the question does not show the address', (tester) async {
      final auth = _FakeAuth()..answer = true;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(app(
        Consumer(builder: (context, ref, _) {
          answerConfirmItIsYouRequests(ref, () => navigator.currentContext);
          return const Text('app');
        }),
        overrides: [localAuthProvider.overrideWithValue(auth)],
        navigator: navigator,
      ));
      // Recording mode on, as the app seeds it.
      Redactor.instance
        ..enabled = true
        ..level = RedactLevel.layout;
      addTearDown(() => Redactor.instance.enabled = false);
      final session = ProviderScope.containerOf(tester.element(find.text('app'))).read(_sessionRef);
      unawaited(askConfirmItIsYou(session, destination: 'secret-db.example.com:22'));
      await frames(tester);
      expect(auth.asked, 1);
      expect(auth.reason, isNot(contains('secret-db')));
    });

    testWidgets('nobody answering in time counts as no, and the question closes', (tester) async {
      final auth = _FakeAuth()..answer = true;
      // Nothing on screen answers sessions here.
      await tester.pumpWidget(app(const Text('app'), overrides: [localAuthProvider.overrideWithValue(auth)]));
      final container = ProviderScope.containerOf(tester.element(find.text('app')));
      final session = container.read(_sessionRef);
      bool? answer;
      unawaited(askConfirmItIsYou(session).then((v) => answer = v));
      await tester.pump(kConfirmItIsYouTimeout - const Duration(seconds: 1));
      expect(answer, isNull, reason: 'still waiting for the person');
      expect(container.read(confirmItIsYouRequestProvider)?.isOpen, isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(answer, isFalse);
      expect(container.read(confirmItIsYouRequestProvider), isNull, reason: 'the question is closed');
      expect(auth.asked, 0);
    });

    testWidgets('with no screen to ask on, the answer is no', (tester) async {
      final auth = _FakeAuth()..answer = true;
      final session = await start(tester, auth, noScreen: true);
      bool? answer;
      unawaited(askConfirmItIsYou(session).then((v) => answer = v));
      await frames(tester);
      expect(answer, isFalse);
      expect(auth.asked, 0);
    });
  });
}

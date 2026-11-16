// A session to a watched Crate's host, on screen (3.0;
// watch_ui.dart): whom to ask to watch, what the tab says while it waits for
// one of them, and what it says while nobody is watching. Each is shown
// with a real watch (session_watch.dart) over the test doubles of a share
// (sharing_ui_fakes.dart). How a watched session runs is tested end to end
// in test/features/orchards/watch. And, while ZestSSH Cloud cannot be
// reached: the question that asks for the reason, the way on for a held
// session, and the line of a session that goes on with nobody watching.

import 'dart:async';
import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';
import 'sharing_ui_fakes.dart';

const _host = WatchedHost(
  orchardId: '22222222-2222-4222-8222-222222222222',
  crateId: '33333333-3333-4333-8333-333333333333',
  crateName: 'Production',
);

/// A screen whose button runs [open] with a context under the navigator.
class _Opener extends StatelessWidget {
  const _Opener(this.open);

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(key: const ValueKey('open'), onPressed: () => open(context), child: const Text('open')),
      );
}

class _Health extends ConnectionHealthNotifier {}

/// The gate, answering as the test says and keeping what it was asked.
class _Gate extends WatchGate {
  _Gate(super.ref);

  WatchRequest? request;

  /// Each time more people were asked: the session, then who.
  final asked = <String>[];
  Object? failAsk;

  @override
  Future<WatchRequest?> requestFor(String sessionId, {required String hostLabel}) async => request;

  @override
  Future<void> askMore(String sessionId, Set<String> uids) async {
    asked.add('$sessionId: ${(uids.toList()..sort()).join(', ')}');
    final failure = failAsk;
    failAsk = null;
    if (failure != null) throw failure;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late ProviderContainer container;

  /// What ZestSSH Cloud answers when the app asks how it is (a status, or
  /// what is thrown).
  Object cloudAnswer = 200;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    SessionWatches.reset();
  });

  tearDown(() {
    SessionWatches.reset();
    SessionShares.reset();
    Redactor.instance
      ..clearNames()
      ..enabled = false;
  });

  _Gate gate() => container.read(watchGateProvider) as _Gate;
  FakeSessions sessions() => container.read(activeSessionsProvider.notifier) as FakeSessions;

  /// ZestSSH Cloud is asked how it is, and the screens hear the answer.
  Future<CloudReachState> cloudIs(WidgetTester tester, Object answer) async {
    cloudAnswer = answer;
    final state = await container.read(cloudReachProvider).checkNow();
    await tester.pump();
    await tester.pump();
    return state;
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    Widget? child,
    void Function(BuildContext context)? open,
    Size size = const Size(1100, 760),
    Object? cloud,
  }) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    cloudAnswer = cloud ?? 200;
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      watchGateProvider.overrideWith(_Gate.new),
      // How ZestSSH Cloud stands: asked when a test says so, never by
      // itself (its own timer is one that does nothing).
      cloudReachProvider.overrideWith((ref) {
        final reach = CloudReachService(
          check: () async {
            final a = cloudAnswer;
            if (a is int) return a;
            throw a;
          },
          timer: (wait, then) => Timer(Duration.zero, () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: child ?? _Opener(open!)),
      ),
    ));
    await tester.pump();
    (container.read(activeSessionsProvider.notifier) as FakeSessions)
        .show({'s1': connectedSession('s1', 'Web 1')});
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Ends the test with nothing waiting (a watch keeps timers, a toast one).
  Future<void> finish(WidgetTester tester) async {
    SessionWatches.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await settle(tester);
  }

  bool picked(WidgetTester tester, String uid) => tester
      .widgetList<Icon>(find.descendant(of: find.byKey(ValueKey('watch-person-$uid')), matching: find.byType(Icon)))
      .any((i) => i.icon == LucideIcons.checkSquare);

  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
        for (final r in tester.widgetList<RichText>(find.byType(RichText))) r.text.toPlainText(),
      ];

  String? lastNotice() {
    final history = container.read(notificationCenterProvider).history;
    return history.isEmpty ? null : history.first.title;
  }

  /// A watch of s1 that counts nobody as watching (its record names
  /// nobody), with waits long enough never to end by themselves here.
  SessionWatch watchOf({String sessionId = 's1'}) {
    final watch = SessionWatch(
      sessionId: sessionId,
      host: _host,
      record: () async => OrchardRecord(_host.orchardId),
      recheck: const Duration(hours: 1),
      grace: const Duration(seconds: 65),
    );
    SessionWatches.add(watch);
    return watch;
  }

  WatchRequest request(List<ShareCandidate> people, {Set<String> alreadyAsked = const {}}) => WatchRequest(
        sessionId: 's1',
        host: _host,
        crateName: 'Production',
        hostLabel: 'Web 1',
        people: people,
        alreadyAsked: alreadyAsked,
      );

  final managers = [
    candidate('uid-kit', 'kit@example.com', level: CrateLevel.manage),
    candidate('uid-max', 'max@example.com', level: CrateLevel.manage),
    candidate('uid-sam', 'sam@example.com', level: CrateLevel.manage, keysChanged: true),
    candidate('uid-lee', null, level: CrateLevel.manage, noKeys: true),
  ];

  group('ask someone to watch', () {
    testWidgets('everyone else who manages the Crate, what asking means, and who was picked', (tester) async {
      Set<String>? answer;
      var answered = 0;
      await pumpApp(tester, open: (c) async {
        answer = await showWatchAsk(c, request(managers));
        answered++;
      });
      await tapKey(tester, 'open');
      expect(find.text(l10n.watchAskTitle), findsOneWidget);
      expect(find.text(l10n.watchAskSub('Web 1', 'Production')), findsOneWidget);
      expect(find.text(l10n.watchAskNote), findsOneWidget);
      expect(find.text(l10n.watchAskManages('Production')), findsNWidgets(2));
      // Keys that changed, or that this device never saw: compare first.
      expect(find.text(l10n.sharePersonKeyChanged), findsNWidgets(2));
      expect(find.text('uid-lee'), findsOneWidget, reason: 'no address known: the id');
      expect([for (final p in managers) picked(tester, p.uid)], everyElement(isFalse),
          reason: 'with more than one person to ask, nobody is picked beforehand');

      // Nobody picked: nothing is asked. Someone whose keys changed cannot
      // be picked at all.
      await tapText(tester, l10n.watchAskButton);
      await tapKey(tester, 'watch-person-uid-sam');
      await tapKey(tester, 'watch-person-uid-lee');
      expect((picked(tester, 'uid-sam'), picked(tester, 'uid-lee')), (false, false));
      await tapText(tester, l10n.watchAskButton);
      expect(answered, 0);
      expect(find.byType(WatchAskDialog), findsOneWidget);

      await tapKey(tester, 'watch-person-uid-kit');
      await tapKey(tester, 'watch-person-uid-max');
      await tapKey(tester, 'watch-person-uid-max');
      expect((picked(tester, 'uid-kit'), picked(tester, 'uid-max')), (true, false), reason: 'a second tap unpicks');
      await tapText(tester, l10n.watchAskButton);
      expect(answered, 1);
      expect(answer, {'uid-kit'});
      expect(find.byType(WatchAskDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('one person to ask is picked already; giving up answers nothing', (tester) async {
      Set<String>? answer = {'not answered'};
      await pumpApp(tester, open: (c) async => answer = await showWatchAsk(c, request(managers.sublist(1))));
      await tapKey(tester, 'open');
      expect(picked(tester, 'uid-max'), isTrue);
      await tapText(tester, l10n.cancel);
      expect(answer, isNull);
      expect(find.byType(WatchAskDialog), findsNothing);

      // The same, asked: one press.
      await tapKey(tester, 'open');
      await tapText(tester, l10n.watchAskButton);
      expect(answer, {'uid-max'});
      await finish(tester);
    });

    testWidgets('someone asked already is shown as asked, and not asked twice', (tester) async {
      Set<String>? answer;
      await pumpApp(tester,
          open: (c) async => answer = await showWatchAsk(c, request(managers, alreadyAsked: {'uid-kit', 'uid-sam'})));
      await tapKey(tester, 'open');
      expect(find.text(l10n.watchAskAlready), findsNWidgets(2));
      expect(find.text(l10n.sharePersonKeyChanged), findsOneWidget, reason: 'lee; sam is said to be asked already');
      expect((picked(tester, 'uid-kit'), picked(tester, 'uid-max')), (true, true),
          reason: 'kit is asked, and max is the one person left to ask');
      await tapKey(tester, 'watch-person-uid-kit');
      expect(picked(tester, 'uid-kit'), isTrue, reason: 'asked already: not something to change here');
      await tapText(tester, l10n.watchAskButton);
      expect(answer, {'uid-max'});
      await finish(tester);
    });

    testWidgets('while recording, no host name and nobody\'s address is on screen', (tester) async {
      SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
      prefs = await SharedPreferences.getInstance();
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['Web 1']);
      await pumpApp(tester, open: (c) => showWatchAsk(c, request(managers)));
      await tapKey(tester, 'open');
      final all = rendered(tester).join('\n');
      for (final secret in ['kit@example.com', 'max@example.com', 'sam@example.com', 'Web 1']) {
        expect(all, isNot(contains(secret)));
      }
      await finish(tester);
    });
  });

  group('a session waiting for someone to watch', () {
    final names = {'uid-kit': 'kit@example.com', 'uid-max': 'max@example.com', 'uid-noa': 'noa@example.com'};

    testWidgets('who was asked and where each stands; giving up ends the wait', (tester) async {
      final watch = watchOf();
      await pumpApp(tester, child: const WatchWaitingPanel(sessionId: 's1'));
      // Whom to ask is still being chosen: it only says what it waits for.
      expect(find.text(l10n.watchWaitingTitle), findsOneWidget);
      expect(find.text(l10n.watchWaitingBody), findsNothing);
      expect(find.byKey(const ValueKey('watch-cancel-s1')), findsNothing);

      final share = FakeShare(guests: [
        guest('uid-kit', ShareGuestState.invited, canEnd: true),
        guest('uid-max', ShareGuestState.declined, canEnd: true),
        // Invited to the same live view, not asked to watch.
        guest('uid-noa', ShareGuestState.watching),
      ]);
      SessionShares.add('s1', share, names: names);
      watch.askedPeople();
      await settle(tester);
      expect(find.text(l10n.watchWaitingBody), findsOneWidget);
      String stateOf(String uid) => tester
          .widgetList<Text>(find.descendant(of: find.byKey(ValueKey('watch-asked-$uid')), matching: find.byType(Text)))
          .last
          .data!;
      expect((stateOf('uid-kit'), stateOf('uid-max')), (l10n.shareStateInvited, l10n.shareStateDeclined));
      expect(find.text('kit@example.com'), findsOneWidget);
      expect(find.byKey(const ValueKey('watch-asked-uid-noa')), findsNothing);
      // kit's device is connecting: the tab follows.
      share.show([guest('uid-kit', ShareGuestState.connected, canEnd: true)]);
      await settle(tester);
      expect(stateOf('uid-kit'), l10n.shareStateConnecting);
      expect(find.byKey(const ValueKey('watch-asked-uid-max')), findsNothing);

      await tapKey(tester, 'watch-cancel-s1');
      expect(watch.phase, SessionWatchPhase.over);
      expect(await watch.firstWatcher, WatchGivenUp.cancelled);
      expect(find.text(l10n.watchWaitingTitle), findsNothing);
      await finish(tester);
    });

    testWidgets('asking someone else: who manages the Crate is asked for, and the pick is passed on', (tester) async {
      final watch = watchOf();
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]),
          names: names);
      watch.askedPeople();
      await pumpApp(tester, child: const WatchWaitingPanel(sessionId: 's1'));
      gate().request = request(managers, alreadyAsked: {'uid-kit'});
      await tapKey(tester, 'watch-ask-other-s1');
      expect(find.byType(WatchAskDialog), findsOneWidget);
      expect(find.text(l10n.watchAskAlready), findsOneWidget);
      await tapText(tester, l10n.watchAskButton);
      expect(gate().asked, ['s1: uid-max']);
      expect(find.byType(WatchAskDialog), findsNothing);

      // Given up in the dialog: nobody is asked. Not reached: it says so.
      await tapKey(tester, 'watch-ask-other-s1');
      await tapText(tester, l10n.cancel);
      expect(gate().asked, hasLength(1));
      gate().failAsk = StateError('offline');
      await tapKey(tester, 'watch-ask-other-s1');
      await tapText(tester, l10n.watchAskButton);
      expect(lastNotice(), l10n.shareFailedOffline);
      // ZestSSH Cloud gave no answer: said as that, with its code.
      gate().failAsk = const SocketException('Connection refused');
      await tapKey(tester, 'watch-ask-other-s1');
      await tapText(tester, l10n.watchAskButton);
      // (A long notice is kept as its first sentence and the rest.)
      final notice = container.read(notificationCenterProvider).history.first;
      expect([notice.title, if (notice.body != null) notice.body].join(' '),
          '${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)');
      // The session went meanwhile: there is nothing to ask for.
      gate().request = null;
      await tapKey(tester, 'watch-ask-other-s1');
      expect(find.byType(WatchAskDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('with ZestSSH Cloud away and nobody asked, the tab does not say it waits for someone', (tester) async {
      final watch = watchOf();
      await pumpApp(tester, child: const WatchWaitingPanel(sessionId: 's1'));
      expect(find.text(l10n.watchWaitingTitle), findsOneWidget);
      await cloudIs(tester, const SocketException('Connection refused'));
      expect(find.text(l10n.watchWaitingTitle), findsNothing);
      expect(find.byKey(const ValueKey('watch-waiting-s1')), findsNothing);
      // The service answers again: it waits for someone to be asked.
      await cloudIs(tester, 200);
      expect(find.text(l10n.watchWaitingTitle), findsOneWidget);
      // Someone was asked while the service was there, and it went away
      // afterwards: that wait is still what the tab shows.
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]),
          names: names);
      watch.askedPeople();
      await cloudIs(tester, const SocketException('Connection refused'));
      expect(watch.phase, SessionWatchPhase.waiting);
      expect(find.byKey(const ValueKey('watch-waiting-s1')), findsOneWidget);
      expect(find.text(l10n.watchWaitingBody), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a session that is not watched, or is being watched, shows nothing', (tester) async {
      await pumpApp(
        tester,
        child: const Column(children: [
          WatchWaitingPanel(sessionId: 's1'),
          WatchHeldBanner(sessionId: 's1'),
        ]),
      );
      expect(find.text(l10n.watchWaitingTitle), findsNothing);
      expect(find.byKey(const ValueKey('watch-held-s1')), findsNothing);

      // Watched: someone invited to end it is there, and manages the Crate.
      final record = OrchardRecord(_host.orchardId);
      record.crates[_host.crateId] = RecordCrate(id: _host.crateId, ownersOnly: false, allow: {}, watched: true);
      record.roles['managers'] = RecordRole(
          id: 'managers',
          rank: 100,
          nameEnc: '',
          nameGeneration: 1,
          can: {},
          crates: {_host.crateId: levelSwitches(CrateLevel.manage)});
      record.members['uid-kit'] = RecordMember(uid: 'uid-kit', role: 'managers', keys: {}, since: 1);
      final watch = SessionWatch(
          sessionId: 's1', host: _host, record: () async => record, recheck: const Duration(hours: 1));
      SessionWatches.add(watch);
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.watching, canEnd: true)]));
      watch.askedPeople();
      watch.connected();
      await settle(tester);
      expect(watch.phase, SessionWatchPhase.watched);
      expect(find.text(l10n.watchWaitingTitle), findsNothing);
      expect(find.byKey(const ValueKey('watch-held-s1')), findsNothing);
      await finish(tester);
    });
  });

  group('the reason for going on with nobody watching', () {
    const refused = SocketException('Connection refused');

    UnwatchedRequest why({bool held = false}) =>
        UnwatchedRequest(sessionId: 's1', host: _host, crateName: 'Production', hostLabel: 'Web 1', held: held);

    Finder field() =>
        find.descendant(of: find.byKey(const ValueKey('unwatched-ask-reason')), matching: find.byType(EditableText));

    testWidgets('why nobody can be asked, what is reported and to whom, and no way on without a reason',
        (tester) async {
      String? answer = 'not answered';
      var answered = 0;
      await pumpApp(tester, open: (c) async {
        answer = await showUnwatchedAsk(c, why());
        answered++;
      });
      await tapKey(tester, 'open');
      expect(find.byType(UnwatchedAskDialog), findsOneWidget);
      expect(find.text(l10n.unwatchedAskTitle), findsOneWidget);
      expect(find.text(l10n.unwatchedAskSub('Production', 'Web 1')), findsOneWidget);
      expect(find.text(l10n.unwatchedAskBody('Production')), findsOneWidget);
      expect(find.text(l10n.unwatchedAskReason), findsOneWidget);
      // Room to write a sentence or two and read it whole.
      final reasonField = tester.widget<TextField>(
          find.descendant(of: find.byKey(const ValueKey('unwatched-ask-reason')), matching: find.byType(TextField)));
      expect((reasonField.minLines, reasonField.maxLines), (3, 6));
      expect(find.byKey(const ValueKey('unwatched-ask-cloud')), findsNothing,
          reason: 'nothing is known to be in the way of the service: nothing is said of it');

      // No reason, or one of blanks: the way on does nothing.
      await tapText(tester, l10n.unwatchedAskConnect);
      await tester.enterText(field(), '   ');
      await settle(tester);
      await tapText(tester, l10n.unwatchedAskConnect);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(answered, 0);
      expect(find.byType(UnwatchedAskDialog), findsOneWidget);

      // A reason: answered with it as a report carries it.
      await tester.enterText(field(), '  restoring   the database ');
      await settle(tester);
      await tapText(tester, l10n.unwatchedAskConnect);
      expect((answered, answer), (1, 'restoring the database'));
      expect(find.byType(UnwatchedAskDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('for a held session it asks whether it goes on; Enter takes the reason; giving up answers nothing',
        (tester) async {
      String? answer = 'not answered';
      await pumpApp(tester, open: (c) async => answer = await showUnwatchedAsk(c, why(held: true)));
      await tapKey(tester, 'open');
      expect(find.text(l10n.unwatchedAskTitleHeld), findsOneWidget);
      expect(find.text(l10n.unwatchedAskTitle), findsNothing);
      expect(find.text(l10n.unwatchedAskGoOn), findsOneWidget);
      expect(find.text(l10n.unwatchedAskConnect), findsNothing);
      await tester.enterText(field(), 'the migration is half done');
      await settle(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(answer, 'the migration is half done');
      expect(find.byType(UnwatchedAskDialog), findsNothing);

      await tapKey(tester, 'open');
      await tester.enterText(field(), 'written, and then given up');
      await settle(tester);
      await tapText(tester, l10n.cancel);
      expect(answer, isNull);
      expect(find.byType(UnwatchedAskDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('how ZestSSH Cloud stands is said with its code, as it changes; a reason is no longer than a report '
        'takes', (tester) async {
      await pumpApp(tester, open: (c) => showUnwatchedAsk(c, why()));
      final state = await cloudIs(tester, refused);
      expect(state.reach, CloudReach.notResponding);
      await tapKey(tester, 'open');
      final said = cloudFailureOfReach(state)!.message(l10n);
      expect(said, contains('ZS-1101'));
      // What is going on, its code apart where it can be read out, and the
      // details to copy.
      final note = find.byKey(const ValueKey('unwatched-ask-cloud'));
      expect(find.descendant(of: note, matching: find.text(ErrorCodes.withoutCode(said).$1)), findsOneWidget);
      expect(find.descendant(of: note, matching: find.text('ZS-1101')), findsOneWidget);
      expect(find.descendant(of: note, matching: find.byType(CopyDetailsButton)), findsOneWidget);
      expect(find.descendant(of: note, matching: find.byIcon(LucideIcons.cloudOff)), findsOneWidget);
      // The service answers with a fault of its own: said as that.
      final fault = await cloudIs(tester, 503);
      expect(fault.reach, CloudReach.fault);
      expect(find.text(ErrorCodes.withoutCode(cloudFailureOfReach(fault)!.message(l10n)).$1), findsOneWidget);
      expect(find.text(ErrorCodes.withoutCode(said).$1), findsNothing);
      // It answers again: nothing is said of it any more.
      await cloudIs(tester, 200);
      expect(find.byKey(const ValueKey('unwatched-ask-cloud')), findsNothing);

      await tester.enterText(field(), 'a' * 400);
      await settle(tester);
      expect(tester.widget<EditableText>(field()).controller.text, hasLength(300));
      await finish(tester);
    });

    testWidgets('while recording, no host name is on screen', (tester) async {
      SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
      prefs = await SharedPreferences.getInstance();
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['Web 1']);
      await pumpApp(tester, open: (c) => showUnwatchedAsk(c, why()));
      await tapKey(tester, 'open');
      expect(find.byType(UnwatchedAskDialog), findsOneWidget);
      expect(rendered(tester).join(' '), isNot(contains('Web 1')));
      await finish(tester);
    });
  });

  testWidgets('tmux control mode in a watched session says why it is not there', (tester) async {
    final tmux = FakeTmux()..noConnection();
    var left = 0;
    await pumpApp(tester, child: TmuxSessionView(host: tmux, onLeave: () => left++));
    // A session with no connection, as ever.
    expect(find.text(l10n.tmuxUiNeedsLiveSession), findsOneWidget);
    expect(find.text(l10n.tmuxWatchedUnavailable), findsNothing);
    await finish(tester);

    // A watched one: it has a connection, which it keeps to itself.
    watchOf();
    await pumpApp(tester, child: TmuxSessionView(host: tmux, onLeave: () => left++));
    expect(find.text(l10n.tmuxWatchedUnavailable), findsOneWidget);
    expect(find.text(l10n.tmuxUiNeedsLiveSession), findsNothing);
    await tapText(tester, l10n.tmuxBackToShell);
    expect(left, 1);
    await finish(tester);
  });

  testWidgets('on a computer, the session\'s own tab says it waits for someone to watch, and that typing is held',
      (tester) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      watchGateProvider.overrideWith(_Gate.new),
    ]);
    addTearDown(container.dispose);
    final sessions = container.read(activeSessionsProvider.notifier) as FakeSessions;
    final tabs = container.read(workTabsProvider.notifier);
    // Connecting: it has no terminal yet, and waits for someone to watch.
    sessions.show({'s1': SessionState.connecting('c-s1', connectionLabel: 'Web 1', host: '10.50.0.21', port: 22)});
    tabs.setActiveTab(tabs.tabContaining('s1')!.id);
    container.read(v3ActiveSessionTabProvider.notifier).state = 's1';
    container.read(paneTreeProvider.notifier).initSinglePane('s1');
    final watch = watchOf();
    SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]),
        names: {'uid-kit': 'kit@example.com'});
    watch.askedPeople();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: DesktopTerminalArea(
            onConnectTo: (_) {},
            onToggleSftp: (_) {},
            onApplyLayout: (_) {},
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(find.byKey(const ValueKey('watch-waiting-s1')), findsOneWidget);
    expect(find.text(l10n.watchWaitingTitle), findsOneWidget);
    expect(find.text('kit@example.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-held-s1')), findsNothing);

    // Connected, with nobody watching: the line over the terminal.
    sessions.show({'s1': connectedSession('s1', 'Web 1')});
    watch.connected();
    await settle(tester);
    expect(watch.phase, SessionWatchPhase.held);
    expect(find.byKey(const ValueKey('watch-held-s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('watch-waiting-s1')), findsNothing);
    await finish(tester);
  });

  group('a watched session nobody is watching', () {
    testWidgets('it says typing is held and when it closes, counting down, with the way to ask someone',
        (tester) async {
      final watch = watchOf();
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]));
      watch.askedPeople();
      watch.connected();
      await pumpApp(tester, child: const WatchHeldBanner(sessionId: 's1'));
      await settle(tester);
      expect(watch.phase, SessionWatchPhase.held);
      final banner = find.byKey(const ValueKey('watch-held-s1'));
      expect(banner, findsOneWidget);
      String said() =>
          tester.widgetList<Text>(find.descendant(of: banner, matching: find.byType(Text))).first.data!;
      // (A minute and five seconds are left, or a second or two fewer by
      // the time it is drawn.)
      expect([l10n.watchHeldBanner('1:05'), l10n.watchHeldBanner('1:04'), l10n.watchHeldBanner('1:03')],
          contains(said()));
      expect(said(), contains('Typing is held'));

      gate().request = WatchRequest(
          sessionId: 's1', host: _host, crateName: 'Production', hostLabel: 'Web 1', people: managers.sublist(1));
      await tapKey(tester, 'watch-held-ask-s1');
      expect(find.byType(WatchAskDialog), findsOneWidget);
      await tapText(tester, l10n.watchAskButton);
      expect(gate().asked, ['s1: uid-max']);

      // The session closed: the line goes with its watch.
      SessionWatches.end('s1');
      await settle(tester);
      expect(banner, findsNothing);
      await finish(tester);
    });

    /// A held session of s1 on screen, with its line.
    Future<SessionWatch> held(WidgetTester tester, {Size size = const Size(1100, 760)}) async {
      // The line is on screen before there is anything to say (and has
      // heard how the service stands): what it does when a session becomes
      // held is its own doing.
      await pumpApp(tester, child: const WatchHeldBanner(sessionId: 's1'), size: size);
      await settle(tester);
      expect(sessions().askedMayGoOn, isEmpty);
      final watch = watchOf();
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]));
      watch.askedPeople();
      watch.connected();
      await settle(tester);
      expect(watch.phase, SessionWatchPhase.held);
      return watch;
    }

    final goOn = find.byKey(const ValueKey('watch-held-go-on-s1'));

    testWidgets('whoever may go on with nobody watching is offered it: looked at when it is held, every little while, '
        'and when the service changes; and told when it cannot be done', (tester) async {
      await held(tester);
      // Looked at once when it is held: this person may not, so nothing is
      // offered beside asking someone else.
      expect(sessions().askedMayGoOn, ['s1']);
      expect(goOn, findsNothing);
      expect(find.byKey(const ValueKey('watch-held-ask-s1')), findsOneWidget);

      // They may (ZestSSH Cloud went away): seen at the next look, which is
      // every quarter of a minute, and no sooner.
      sessions().mayGoOn = true;
      await tester.pump(const Duration(seconds: 10));
      expect(sessions().askedMayGoOn, hasLength(1));
      expect(goOn, findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      expect(sessions().askedMayGoOn, hasLength(2));
      expect(goOn, findsOneWidget);
      expect(find.descendant(of: goOn, matching: find.text(l10n.unwatchedAskGoOn)), findsOneWidget);
      // On a computer the ways on are beside what it says.
      expect(tester.getRect(goOn).top, lessThan(tester.getRect(find.textContaining('Typing is held')).bottom));
      expect(tester.getRect(goOn).right,
          lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('watch-held-ask-s1'))).left));
      // Not looked at again before another quarter of a minute is over.
      await tester.pump(const Duration(seconds: 5));
      expect(sessions().askedMayGoOn, hasLength(2));

      // Pressed: the session is let go on (which asks why, and keeps what
      // is reported: the gate's to do). While that is at work it cannot be
      // pressed again; afterwards the line looks at once how things stand.
      sessions().goOnWaits = Completer<void>();
      await tapKey(tester, 'watch-held-go-on-s1');
      expect(sessions().wentOn, ['s1']);
      expect(tester.widget<ButtonStyleButton>(goOn).onPressed, isNull);
      await tester.tap(goOn, warnIfMissed: false);
      await settle(tester);
      expect(sessions().wentOn, ['s1']);
      expect(sessions().askedMayGoOn, hasLength(2));
      sessions().goOnWaits!.complete();
      sessions().goOnWaits = null;
      await settle(tester);
      expect(tester.widget<ButtonStyleButton>(goOn).onPressed, isNotNull);
      expect(sessions().askedMayGoOn, hasLength(3));
      // They gave up: nothing is said.
      sessions().failGoOn = const SessionWatchCancelled();
      await tapKey(tester, 'watch-held-go-on-s1');
      expect(lastNotice(), isNull);
      expect(sessions().wentOn, hasLength(2));
      // It may not after all: said in the words it was refused with.
      sessions().failGoOn = const OrchardAccessRefused('ZestSSH Cloud can be reached again (as the gate says it)');
      await tapKey(tester, 'watch-held-go-on-s1');
      expect(lastNotice(), 'ZestSSH Cloud can be reached again (as the gate says it)');
      // Anything else: the app's own words for what went wrong, and what
      // failed for Copy details (it was in the sentence, as the program
      // writes it).
      await tester.pump(const Duration(seconds: 6));
      sessions().failGoOn = StateError('the database is closed');
      await tapKey(tester, 'watch-held-go-on-s1');
      expect(lastNotice(), l10n.orchardErrorNotDone);
      expect(container.read(notificationCenterProvider).history.first.details, contains('the database is closed'));

      // How the service stands changed: looked at again at once.
      final looks = sessions().askedMayGoOn.length;
      sessions().mayGoOn = false;
      await cloudIs(tester, 200);
      await tester.pump();
      expect(sessions().askedMayGoOn.length, looks + 1);
      expect(goOn, findsNothing);
      await finish(tester);
    });

    testWidgets('while its person is asked why, it says typing is held and no time; a session that goes on with '
        'nobody watching says that, for as long as it does', (tester) async {
      final watch = await held(tester);
      final banner = find.byKey(const ValueKey('watch-held-s1'));
      final unwatched = find.byKey(const ValueKey('watch-unwatched-s1'));
      expect(find.descendant(of: banner, matching: find.text(l10n.watchHeldBannerAsked)), findsNothing);

      // Asked: nothing closes it meanwhile, and the line says no time.
      watch.holdOpen();
      await settle(tester);
      expect(find.descendant(of: banner, matching: find.text(l10n.watchHeldBannerAsked)), findsOneWidget);
      expect(find.byKey(const ValueKey('watch-held-ask-s1')), findsOneWidget);
      // They gave up: it counts down again.
      watch.closeAfterGrace();
      await settle(tester);
      expect(find.descendant(of: banner, matching: find.text(l10n.watchHeldBannerAsked)), findsNothing);
      expect(banner, findsOneWidget);

      // Let go on: its own line, and nothing to press.
      expect(watch.goUnwatched(), isTrue);
      await settle(tester);
      expect(banner, findsNothing);
      expect(find.descendant(of: unwatched, matching: find.text(l10n.watchUnwatchedBanner)), findsOneWidget);
      expect(find.descendant(of: unwatched, matching: find.byType(TextButton)), findsNothing);
      // The line looks no more whether it may go on: it does. Not as time
      // passes, and not when the service changes.
      final looks = sessions().askedMayGoOn.length;
      await tester.pump(const Duration(seconds: 40));
      await cloudIs(tester, const SocketException('Connection refused'));
      expect(sessions().askedMayGoOn.length, looks);
      SessionWatches.end('s1');
      await settle(tester);
      expect(unwatched, findsNothing);

      // One let go on before it connects says nothing yet: there is no
      // session to say it of.
      final next = watchOf();
      expect(next.goUnwatched(), isTrue);
      await settle(tester);
      expect(unwatched, findsNothing);
      next.connected();
      await settle(tester);
      expect(unwatched, findsOneWidget);

      // A session held anew is looked at anew, at once.
      SessionWatches.end('s1');
      SessionShares.reset();
      await settle(tester);
      final again = watchOf();
      SessionShares.add('s1', FakeShare(guests: [guest('uid-kit', ShareGuestState.invited, canEnd: true)]));
      again.askedPeople();
      again.connected();
      await settle(tester);
      expect(again.phase, SessionWatchPhase.held);
      expect(banner, findsOneWidget);
      expect(sessions().askedMayGoOn.length, looks + 1);
      await finish(tester);
    });

    testWidgets('on a phone the ways on are under what it says, and nothing is cut off', (tester) async {
      await held(tester, size: const Size(360, 720));
      sessions().mayGoOn = true;
      await tester.pump(const Duration(seconds: 16));
      await tester.pump();
      expect(goOn, findsOneWidget);
      final text = tester.getRect(find.textContaining('Typing is held'));
      final go = tester.getRect(goOn);
      final ask = tester.getRect(find.byKey(const ValueKey('watch-held-ask-s1')));
      expect(go.top, greaterThanOrEqualTo(text.bottom), reason: 'under what it says');
      expect((go.left >= 0, ask.right <= 360), (true, true));
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });
}

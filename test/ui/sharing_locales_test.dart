// Every session sharing screen, in every language the app ships, with the
// shipped font (the test font draws each glyph as a square, far wider than
// real text): nothing overflows in a pop-up on a computer or in a sheet on
// a small phone. A layout that does not fit throws, which fails the test.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart' show crateLevelLabel;
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/screens/sharing/share_view_screen.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

import '../visual/shots_util.dart';
import 'sharing_ui_fakes.dart';

const _live = '11111111-1111-4111-8111-000000000001';
const _tmux = '11111111-1111-4111-8111-000000000002';
const _changed = '11111111-1111-4111-8111-000000000003';
const _toWatch = '11111111-1111-4111-8111-000000000004';
const _toEnd = '11111111-1111-4111-8111-000000000005';

const _watchedHost = WatchedHost(
  orchardId: '22222222-2222-4222-8222-222222222222',
  crateId: '33333333-3333-4333-8333-333333333333',
  crateName: 'Production (Frankfurt)',
);

/// Long addresses, as real ones are.
const _names = {
  'uid-sam': 'samantha.fairweather@example-engineering.com',
  'uid-kit': 'kit@example.com',
  'uid-noa': 'noa.lindqvist@example.com',
  'uid-lee': 'lee@example.com',
  'uid-eve': 'eve@example.com',
  'uid-max': 'maximilian@example.com',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeTmux tmux;
  late ProviderContainer container;
  late IncomingShare liveShare;
  late IncomingShare tmuxShare;
  late IncomingShare changedShare;
  late IncomingShare watchShare;
  late IncomingShare endShare;
  void Function(BuildContext context) opener = (_) {};

  setUpAll(() async {
    final dana = await AccountKeys.generate();
    final sam = await AccountKeys.generate();
    const from = 'danielle.okonkwo-reyes@example-engineering.com';
    liveShare = await incomingShare(shareId: _live, mode: ShareMode.live, from: dana, to: sam, fromEmail: from);
    tmuxShare = await incomingShare(shareId: _tmux, mode: ShareMode.tmux, from: dana, to: sam, fromEmail: from);
    changedShare = await incomingShare(
        shareId: _changed, mode: ShareMode.live, from: dana, to: sam, fromEmail: from, keysChanged: true);
    watchShare = await incomingShare(
        shareId: _toWatch,
        mode: ShareMode.live,
        from: dana,
        to: sam,
        fromEmail: from,
        crateName: 'Production (Frankfurt)',
        mayEnd: true,
        watched: true);
    endShare = await incomingShare(
        shareId: _toEnd, mode: ShareMode.live, from: dana, to: sam, fromEmail: from, mayEnd: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    ShareViews.reset();
    SessionWatches.reset();
    tmux = FakeTmux();
  });

  tearDown(() {
    SessionWatches.reset();
    SessionShares.reset();
    ShareViews.reset();
  });

  FakeSharing sharing() => container.read(sessionSharingProvider) as FakeSharing;

  /// The app at [size] in [locale]: a screen with the shared session's chip
  /// and strip and a button that runs [opener]; the live view has its route.
  Future<void> pumpApp(WidgetTester tester, Locale locale, Size size) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      tmuxHostProvider.overrideWith((ref, sessionId) => tmux),
      sessionSharingProvider.overrideWith(FakeSharing.new),
      shareInvitationsProvider.overrideWith(FakeInvitations.new),
      shareJoiningProvider.overrideWith(FakeJoining.new),
      shareTmuxJoinsProvider.overrideWithValue(FakeTmuxJoins()),
      // ZestSSH Cloud does not answer, once the test asks how it is.
      cloudReachProvider.overrideWith((ref) {
        final reach = CloudReachService(
          check: () async => throw const SocketException('Connection refused'),
          timer: (wait, then) => Timer(Duration.zero, () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: Column(
            children: [
              const Row(children: [Expanded(child: SizedBox()), SessionShareChip(sessionId: 's1')]),
              const SessionShareStrip(sessionId: 's1', always: true),
              // A watched session: what its tab says while nobody
              // watches, and while it waits for someone to.
              const WatchHeldBanner(sessionId: 's1'),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: WatchWaitingPanel(sessionId: 's1'),
              ),
              Expanded(
                child: Center(
                  child: Builder(
                    builder: (context) => TextButton(
                        key: const ValueKey('open'), onPressed: () => opener(context), child: const Text('open')),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      GoRoute(
        path: Routes.shareView,
        builder: (context, state) =>
            ShareViewScreen(shareId: state.extra is String ? state.extra as String : '', onLeave: () => context.pop()),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        routerConfig: router,
      ),
    ));
    await tester.pump();
    (container.read(activeSessionsProvider.notifier) as FakeSessions)
        .show({'s1': connectedSession('s1', 'Hypervisor Node3 (rack B, row 4)')});
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> open(WidgetTester tester, void Function(BuildContext context) what) async {
    opener = what;
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
  }

  /// Taps [target], scrolled into view first: on a small phone a sheet is
  /// taller than what shows of it.
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await settle(tester);
  }

  /// Closes whatever pop-up or sheet is in front.
  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Navigator).first), rootNavigator: true).pop();
    await settle(tester);
  }

  /// Back, as a person goes: a question asked in a dialog's place (the dialog
  /// rules, 3.4) goes, and the dialog it was asked in is there again.
  Future<void> back(WidgetTester tester) async {
    await Navigator.of(tester.element(find.byType(Navigator).first), rootNavigator: true).maybePop();
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    SessionWatches.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  final everyone = [
    candidate('uid-kit', _names['uid-kit']),
    candidate('uid-noa', _names['uid-noa'], level: CrateLevel.connect),
    candidate('uid-sam', _names['uid-sam'], keysChanged: true),
    candidate('uid-lee', null, noKeys: true),
    candidate('uid-max', _names['uid-max'], level: CrateLevel.manage),
  ];

  /// Every screen and every state with words of its own.
  Future<void> everyScreen(WidgetTester tester, AppLocalizations l10n) async {
    Future<void> shareDialog(ShareContext context) => open(
          tester,
          (c) => showZestModal<void>(
            context: c,
            size: ZestModalSize.large,
            child: ShareSessionDialog(sessionId: 's1', shareContext: context),
          ),
        );

    // Share this session: both ways possible, every note showing.
    await shareDialog(shareContext(everyone,
        withoutAccess: ['eve@example.com', 'someone.else@example.com'],
        sessionLogs: true,
        crateName: 'Production (Frankfurt)'));
    expect(find.text(l10n.shareChipTmux), findsOneWidget);
    expect(find.text(l10n.shareUiRecommended), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('share-mode-live')));
    await tap(tester, find.byKey(const ValueKey('share-person-uid-kit')));
    // Someone picked may end the session: the chip, and the line it changes.
    await tap(tester, find.byKey(const ValueKey('share-person-uid-max')));
    expect(find.text(l10n.shareCanEnd), findsNWidgets(2));
    await tap(
        tester,
        find.descendant(
            of: find.byKey(const ValueKey('share-person-uid-max')),
            matching: find.byKey(const ValueKey('share-can-end'))));
    expect(
        find.text(l10n.sharePersonLevel('Production (Frankfurt)', crateLevelLabel(CrateLevel.manage, l10n))),
        findsOneWidget);
    // A refusal, with the longest message.
    sharing().failStart = const ShareStartFailed(ShareStartProblem.notReady);
    await tap(tester, find.text(l10n.shareStartLive).last);
    expect(find.text(l10n.shareFailedNotReady), findsOneWidget);
    await close(tester);

    // A session of a watched Crate: a live view only, with why.
    await shareDialog(shareContext(everyone, watched: true, crateName: 'Production (Frankfurt)'));
    expect(find.text(l10n.shareTmuxWatched), findsOneWidget);
    await close(tester);

    // Asking someone to watch: everyone who manages the Crate, one of them
    // asked already and one whose keys changed.
    await open(
        tester,
        (c) => showWatchAsk(
            c,
            WatchRequest(
              sessionId: 's1',
              host: _watchedHost,
              crateName: 'Production (Frankfurt)',
              hostLabel: 'Hypervisor Node3 (rack B, row 4)',
              people: [
                candidate('uid-sam', _names['uid-sam'], level: CrateLevel.manage),
                candidate('uid-max', _names['uid-max'], level: CrateLevel.manage),
                candidate('uid-noa', _names['uid-noa'], level: CrateLevel.manage, keysChanged: true),
                candidate('uid-kit', _names['uid-kit'], level: CrateLevel.manage),
              ],
              alreadyAsked: const {'uid-kit'},
            )));
    // (In some languages the title and the button are the same words.)
    expect(find.text(l10n.watchAskTitle), findsWidgets);
    expect(find.text(l10n.watchAskNote), findsOneWidget);
    expect(find.text(l10n.watchAskAlready), findsOneWidget);
    await close(tester);

    // The tab while it waits for one of them, and while nobody watches.
    final watch = SessionWatch(
      sessionId: 's1',
      host: _watchedHost,
      record: () async => OrchardRecord(_watchedHost.orchardId),
      recheck: const Duration(hours: 1),
    );
    SessionWatches.add(watch);
    SessionShares.add(
        's1',
        FakeShare()
          ..show([
            guest('uid-sam', ShareGuestState.invited, canEnd: true),
            guest('uid-max', ShareGuestState.declined, canEnd: true),
            guest('uid-kit', ShareGuestState.connected, canEnd: true),
          ]),
        names: _names);
    watch.askedPeople();
    await settle(tester);
    expect(find.text(l10n.watchWaitingBody), findsOneWidget);
    expect(find.text(l10n.watchAskOther), findsOneWidget);
    watch.connected();
    await settle(tester);
    expect(find.byKey(const ValueKey('watch-held-s1')), findsOneWidget);
    // While ZestSSH Cloud cannot be reached: the way on beside asking
    // someone else, the question that asks why (for a held session and
    // before a connection, with how the service stands), the line while
    // its person is asked, and the line of a session that goes on.
    (container.read(activeSessionsProvider.notifier) as FakeSessions).mayGoOn = true;
    await container.read(cloudReachProvider).checkNow();
    await tester.pump();
    await settle(tester);
    expect(find.text(l10n.unwatchedAskGoOn), findsOneWidget);
    for (final held in [true, false]) {
      await open(
          tester,
          (c) => showUnwatchedAsk(
              c,
              UnwatchedRequest(
                sessionId: 's1',
                host: _watchedHost,
                crateName: 'Production (Frankfurt)',
                hostLabel: 'Hypervisor Node3 (rack B, row 4)',
                held: held,
              )));
      expect(find.text(held ? l10n.unwatchedAskTitleHeld : l10n.unwatchedAskTitle), findsOneWidget);
      expect(find.text(l10n.unwatchedAskBody('Production (Frankfurt)')), findsOneWidget);
      expect(find.byKey(const ValueKey('unwatched-ask-cloud')), findsOneWidget);
      await close(tester);
    }
    watch.holdOpen();
    await settle(tester);
    expect(find.text(l10n.watchHeldBannerAsked), findsOneWidget);
    watch.closeAfterGrace();
    expect(watch.goUnwatched(), isTrue);
    await settle(tester);
    expect(find.text(l10n.watchUnwatchedBanner), findsOneWidget);
    SessionWatches.reset();
    SessionShares.reset();
    await settle(tester);

    // Neither way possible, each with its reason.
    tmux.attachedTo('my session');
    await shareDialog(shareContext(everyone));
    expect(find.text(l10n.shareTmuxBadName), findsOneWidget);
    expect(find.text(l10n.shareLiveInTmux), findsOneWidget);
    await close(tester);
    tmux = FakeTmux();
    await shareDialog(shareContext(const [], synced: false));
    expect(find.text(l10n.shareTmuxNeedsSync), findsOneWidget);
    expect(find.text(l10n.shareNobody('Production')), findsOneWidget);
    await close(tester);

    // A session that cannot be shared.
    sharing().availability = (null, ShareUnavailable.notInCrate);
    await open(tester, (c) => showShareSession(c, 's1'));
    expect(find.text(l10n.shareNotInCrateBody), findsOneWidget);
    await close(tester);
    sharing().availability = (null, ShareUnavailable.notReady);
    await open(tester, (c) => showShareSession(c, 's1'));
    expect(find.text(l10n.shareNotReadyBody), findsOneWidget);
    await close(tester);

    // A live view being shared: the chip, the strip with someone typing and
    // with someone asking, and who is there in every state.
    final share = FakeShare()
      ..show([
        guest('uid-sam', ShareGuestState.watching, asks: true),
        guest('uid-kit', ShareGuestState.typing),
        guest('uid-noa', ShareGuestState.watching, canType: false),
        guest('uid-lee', ShareGuestState.invited),
        guest('uid-eve', ShareGuestState.declined),
        guest('uid-max', ShareGuestState.connected),
      ], holder: 'uid-kit');
    SessionShares.add('s1', share, names: _names);
    await settle(tester);
    expect(find.text(l10n.shareTypingBanner(_names['uid-kit']!)), findsOneWidget);
    await open(tester, (c) => showShareParticipants(c, 's1'));
    expect(find.text(l10n.shareStateTyping), findsOneWidget);
    // More people than fit: the list scrolls rather than overflow.
    share.show([
      for (var i = 0; i < 8; i++) guest('uid-g$i', ShareGuestState.watching, asks: i == 0, canEnd: i == 1),
    ], lineOpen: false);
    await settle(tester);
    expect(find.text(l10n.shareReconnecting), findsOneWidget);
    expect(find.text(l10n.shareStateWatchingCanEnd), findsOneWidget);
    await tap(tester, find.text(l10n.shareStop).last);
    expect(find.text(l10n.shareStopConfirmLive), findsOneWidget);
    await back(tester);
    await close(tester);
    share.show([guest('uid-sam', ShareGuestState.watching, asks: true)]);
    await settle(tester);
    expect(find.text(l10n.shareAskingBanner(_names['uid-sam']!)), findsOneWidget);

    // A shared tmux session, and the pop-up of one that ended meanwhile.
    tmux.attachedTo('release-2026-10');
    SessionShares.add(
        's1',
        FakeShare(mode: ShareMode.tmux, tmuxSession: 'release-2026-10', keyboardRequests: false)
          ..show([
            guest('uid-sam', ShareGuestState.connected, canType: false),
            guest('uid-kit', ShareGuestState.invited, canType: false),
          ]),
        names: _names);
    await settle(tester);
    await open(tester, (c) => showShareParticipants(c, 's1'));
    expect(find.text(l10n.sharePopTmuxTitle('release-2026-10')), findsOneWidget);
    await tap(tester, find.text(l10n.shareStop).last);
    expect(find.text(l10n.shareStopConfirmTmux), findsOneWidget);
    await back(tester);
    SessionShares.sessionClosed('s1');
    await settle(tester);
    expect(find.text(l10n.shareEndedBody), findsOneWidget);
    await close(tester);

    // Shared with you: empty, then every kind of invitation, then one that
    // is being watched.
    final invitations = container.read(shareInvitationsProvider.notifier) as FakeInvitations;
    await open(tester, showShareInvitations);
    expect(find.text(l10n.shareInvitesEmpty), findsOneWidget);
    invitations.show([liveShare, tmuxShare, changedShare, watchShare, endShare]);
    await settle(tester);
    expect(find.text(l10n.shareInviteLiveHow), findsNWidgets(2));
    // Asked to watch a session of a watched Crate, and invited to end one.
    expect(find.text(l10n.shareInviteWatchHow('Production (Frankfurt)')), findsOneWidget);
    expect(find.text(l10n.shareInviteLiveHowCanEnd), findsOneWidget);
    final view = FakeView()..terminal.resize(132, 43);
    ShareViews.add(liveShare, view);
    view.show(ShareViewPhase.watching);
    await settle(tester);
    expect(find.text(l10n.shareWatchingNow.toUpperCase()), findsOneWidget);

    // The live view itself, in every state it has words for.
    await tap(tester, find.byKey(const ValueKey('share-open-$_live')));
    expect(find.byType(ShareViewScreen), findsOneWidget);
    for (final keyboard in ShareKeyboard.values) {
      view.show(ShareViewPhase.watching, keyboard: keyboard);
      await settle(tester);
    }
    view.show(ShareViewPhase.watching, asking: true);
    await settle(tester);
    expect(find.text(l10n.shareViewAsked), findsOneWidget);
    // Someone invited to end the session: the line that says so, and the
    // question before it ends.
    view
      ..canAsk = false
      ..canEnd = true
      ..show(ShareViewPhase.watching);
    await settle(tester);
    expect(find.text(l10n.shareViewEnd), findsOneWidget);
    await tap(tester, find.byKey(const ValueKey('share-view-end')));
    expect(find.text(l10n.shareViewEndBody), findsOneWidget);
    await close(tester);
    expect(find.text(l10n.shareViewEndBody), findsNothing);
    view
      ..canAsk = true
      ..canEnd = false;
    for (final phase in [ShareViewPhase.connecting, ShareViewPhase.waitingForHost, ShareViewPhase.joining]) {
      view.show(phase);
      await settle(tester);
    }
    for (final end in ShareViewEnd.values) {
      view.show(ShareViewPhase.ended, end: end);
      await settle(tester);
    }
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('the sharing screens fit on a computer in ${locale.languageCode}', (tester) async {
      await pumpApp(tester, locale, const Size(900, 720));
      await everyScreen(tester, lookupAppLocalizations(locale));
      await finish(tester);
    });

    testWidgets('the sharing screens fit on a small phone in ${locale.languageCode}', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpApp(tester, locale, const Size(360, 640));
        await everyScreen(tester, lookupAppLocalizations(locale));
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}

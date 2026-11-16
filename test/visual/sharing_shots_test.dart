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
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/screens/sharing/share_view_screen.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

import '../ui/sharing_ui_fakes.dart';
import 'shots_util.dart';

/// Pictures of session sharing (3.0), with the real fonts:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/sharing_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up.

const _live = '11111111-1111-4111-8111-000000000001';
const _tmux = '11111111-1111-4111-8111-000000000002';
const _changed = '11111111-1111-4111-8111-000000000003';
const _toWatch = '11111111-1111-4111-8111-000000000004';

const _watchedHost = WatchedHost(
  orchardId: '22222222-2222-4222-8222-222222222222',
  crateId: '33333333-3333-4333-8333-333333333333',
  crateName: 'Production',
);

const _names = {
  'uid-sam': 'sam@example.com',
  'uid-kit': 'kit@example.com',
  'uid-noa': 'noa@example.com',
  'uid-jordan': 'jordan@example.com',
  'uid-priya': 'priya@example.com',
};

void main() {
  late SharedPreferences prefs;
  late ProviderContainer container;
  late FakeTmux tmux;
  late IncomingShare liveShare;
  late IncomingShare tmuxShare;
  late IncomingShare changedShare;
  late IncomingShare watchShare;
  void Function(BuildContext context) opener = (_) {};

  setUpAll(() async {
    final alex = await AccountKeys.generate();
    final sam = await AccountKeys.generate();
    liveShare = await incomingShare(shareId: _live, mode: ShareMode.live, from: alex, to: sam);
    tmuxShare = await incomingShare(
        shareId: _tmux, mode: ShareMode.tmux, from: alex, to: sam, fromEmail: 'kit@example.com', hostLabel: 'log-store');
    changedShare = await incomingShare(
        shareId: _changed, mode: ShareMode.live, from: alex, to: sam, fromEmail: 'noa@example.com', keysChanged: true);
    watchShare = await incomingShare(
        shareId: _toWatch, mode: ShareMode.live, from: alex, to: sam, hostLabel: 'db-primary', mayEnd: true, watched: true);
  });

  /// The app at [size] with [themeId]: a session's header line (its chip),
  /// the strip under it and a stand-in for the terminal; the live view has
  /// its route. A phone has no chip: its strip is there the whole time the
  /// session is shared, as in the app (terminal_screen.dart). Returns the key
  /// the pictures are taken from.
  Future<GlobalKey> start(WidgetTester tester, String themeId, Size size, {bool phone = false}) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues({'app_theme_id': themeId});
    prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    ShareViews.reset();
    SessionWatches.reset();
    tmux = FakeTmux();
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    final key = GlobalKey();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      tmuxHostProvider.overrideWith((ref, sessionId) => tmux),
      sessionSharingProvider.overrideWith(FakeSharing.new),
      shareInvitationsProvider.overrideWith(FakeInvitations.new),
      shareJoiningProvider.overrideWith(FakeJoining.new),
      shareTmuxJoinsProvider.overrideWithValue(FakeTmuxJoins()),
      // ZestSSH Cloud does not answer, once a picture asks how it is.
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
          backgroundColor: AppColors.v3Background,
          body: Column(
            children: [
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                color: AppColors.v3Surface,
                child: Row(children: [
                  Text('Web 1',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                  if (!phone) const SessionShareChip(sessionId: 's1'),
                  const Spacer(),
                  Builder(
                    builder: (context) => TextButton(
                        key: const ValueKey('open'), onPressed: () => opener(context), child: const Text('')),
                  ),
                ]),
              ),
              SessionShareStrip(sessionId: 's1', always: phone),
              const WatchHeldBanner(sessionId: 's1'),
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: WatchWaitingPanel(sessionId: 's1'),
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
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: theme.toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          routerConfig: router,
        ),
      ),
    ));
    await tester.pump();
    (container.read(activeSessionsProvider.notifier) as FakeSessions).show({'s1': connectedSession('s1', 'Web 1')});
    await tester.pump();
    return key;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> open(WidgetTester tester, void Function(BuildContext context) what) async {
    opener = what;
    await tester.tap(find.byKey(const ValueKey('open')));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.byType(Navigator).first), rootNavigator: true).pop();
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    SessionWatches.reset();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
    plainShadows();
  }

  final everyone = [
    candidate('uid-kit', 'kit@example.com', level: CrateLevel.edit),
    candidate('uid-noa', 'noa@example.com', level: CrateLevel.connect),
    candidate('uid-sam', 'sam@example.com'),
    candidate('uid-jordan', 'jordan@example.com', keysChanged: true),
  ];

  FakeView watching() {
    final view = FakeView();
    view.terminal
      ..resize(96, 26)
      ..write('\x1b[1;32mdeploy@web1\x1b[0m:\x1b[1;34m~/app\x1b[0m\$ tail -f /var/log/app/current.log\r\n'
          '09:14:02 \x1b[32mINFO\x1b[0m  listening on :8080\r\n'
          '09:14:07 \x1b[32mINFO\x1b[0m  GET /health 200 3ms\r\n'
          '09:14:19 \x1b[33mWARN\x1b[0m  slow query: 412ms (orders by customer)\r\n'
          '09:14:21 \x1b[32mINFO\x1b[0m  GET /orders?customer=1042 200 431ms\r\n'
          '09:14:30 \x1b[31mERROR\x1b[0m upstream timed out: payments (attempt 2 of 3)\r\n'
          '09:14:31 \x1b[32mINFO\x1b[0m  retrying in 2s\r\n');
    view.show(ShareViewPhase.watching);
    return view;
  }

  Future<void> everyPicture(WidgetTester tester, GlobalKey key, String tag) async {
    void Function(BuildContext) dialog(ShareContext context) => (c) => showZestModal<void>(
          context: c,
          size: ZestModalSize.large,
          child: ShareSessionDialog(sessionId: 's1', shareContext: context),
        );

    // Share this session.
    await open(tester, dialog(shareContext(everyone, withoutAccess: ['priya@example.com'], sessionLogs: true)));
    await tester.tap(find.byKey(const ValueKey('share-person-uid-kit')), warnIfMissed: false);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_1_share_tmux');
    await tester.ensureVisible(find.byKey(const ValueKey('share-mode-live')));
    await tester.tap(find.byKey(const ValueKey('share-mode-live')));
    await settle(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('share-person-uid-noa')));
    await tester.tap(find.byKey(const ValueKey('share-person-uid-noa')));
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_2_share_live');
    // kit may end the session.
    final kitEnds = find.descendant(
        of: find.byKey(const ValueKey('share-person-uid-kit')), matching: find.byKey(const ValueKey('share-can-end')));
    // Brought into the middle of the body, not to its edge, so that the
    // picture shows the rows around it whole.
    await tester.runAsync(() => Scrollable.ensureVisible(tester.element(kitEnds), alignment: 0.5));
    await settle(tester);
    await tester.tap(kitEnds);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_12_share_live_can_end');
    await close(tester);

    // A session to a watched Crate's host: whom to ask, the tab while
    // it waits for one of them, and while nobody is watching.
    await open(
        tester,
        (c) => showWatchAsk(
            c,
            WatchRequest(
              sessionId: 's1',
              host: _watchedHost,
              crateName: 'Production',
              hostLabel: 'web-01',
              people: [
                candidate('uid-kit', 'kit@example.com', level: CrateLevel.manage),
                candidate('uid-sam', 'sam@example.com', level: CrateLevel.manage),
                candidate('uid-jordan', 'jordan@example.com', level: CrateLevel.manage, keysChanged: true),
              ],
            )));
    await tester.tap(find.byKey(const ValueKey('watch-person-uid-kit')), warnIfMissed: false);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_16_watch_ask');
    await close(tester);
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
            guest('uid-kit', ShareGuestState.invited, canEnd: true),
            guest('uid-sam', ShareGuestState.connected, canEnd: true),
          ]),
        names: _names);
    watch.askedPeople();
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_17_watch_waiting');
    watch.connected();
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_18_watch_held');

    // While ZestSSH Cloud cannot be reached (the outage work): whoever may
    // go on with nobody watching is offered it, and asked why; the line
    // while they are asked; and the line of a session that goes on so.
    (container.read(activeSessionsProvider.notifier) as FakeSessions).mayGoOn = true;
    await container.read(cloudReachProvider).checkNow();
    await tester.pump();
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_20_watch_held_may_go_on');
    Finder reason() =>
        find.descendant(of: find.byKey(const ValueKey('unwatched-ask-reason')), matching: find.byType(EditableText));
    await open(
        tester,
        (c) => showUnwatchedAsk(
            c,
            const UnwatchedRequest(
                sessionId: 's1', host: _watchedHost, crateName: 'Production', hostLabel: 'web-01', held: true)));
    await saveShot(tester, key, 'sharing_${tag}_21_unwatched_ask_held_empty');
    await tester.enterText(reason(), 'The migration is half done and cannot be left as it is');
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_22_unwatched_ask_held');
    await close(tester);
    watch.holdOpen();
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_23_watch_held_asked');
    watch.closeAfterGrace();
    watch.goUnwatched();
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_24_watch_unwatched');
    SessionWatches.reset();
    SessionShares.reset();
    await settle(tester);
    // Before a connection: the same question, as one that connects.
    await open(
        tester,
        (c) => showUnwatchedAsk(
            c, const UnwatchedRequest(sessionId: 's1', host: _watchedHost, crateName: 'Production', hostLabel: 'web-01')));
    await tester.enterText(reason(), 'Restoring the database from last night');
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_25_unwatched_ask_connect');
    await close(tester);

    // A live view being shared: the chip, the strip, and who is there.
    final share = FakeShare()
      ..show([
        guest('uid-kit', ShareGuestState.typing),
        guest('uid-sam', ShareGuestState.watching, asks: true),
        guest('uid-noa', ShareGuestState.watching, canType: false),
        guest('uid-jordan', ShareGuestState.invited),
        guest('uid-priya', ShareGuestState.declined),
      ], holder: 'uid-kit');
    SessionShares.add('s1', share, names: _names);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_3_chip_and_strip');
    await open(tester, (c) => showShareParticipants(c, 's1'));
    await saveShot(tester, key, 'sharing_${tag}_4_participants');
    await close(tester);
    share.show([guest('uid-sam', ShareGuestState.watching, asks: true), guest('uid-noa', ShareGuestState.watching)]);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_5_asking');
    // One of those watching may end the session.
    share.show([
      guest('uid-kit', ShareGuestState.watching, canEnd: true),
      guest('uid-sam', ShareGuestState.watching),
      guest('uid-noa', ShareGuestState.watching, canType: false),
    ]);
    await open(tester, (c) => showShareParticipants(c, 's1'));
    await saveShot(tester, key, 'sharing_${tag}_13_participants_can_end');
    await close(tester);
    SessionShares.reset();
    await settle(tester);

    // Shared with you.
    final invitations = container.read(shareInvitationsProvider.notifier) as FakeInvitations;
    invitations.show([watchShare]);
    await open(tester, showShareInvitations);
    await saveShot(tester, key, 'sharing_${tag}_19_asked_to_watch');
    await close(tester);
    invitations.show([liveShare, tmuxShare, changedShare]);
    await open(tester, showShareInvitations);
    await saveShot(tester, key, 'sharing_${tag}_6_invitations');
    final view = watching();
    ShareViews.add(liveShare, view);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_7_invitations_watching');

    // The live view.
    await tester.ensureVisible(find.byKey(const ValueKey('share-open-$_live')));
    await tester.tap(find.byKey(const ValueKey('share-open-$_live')));
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_8_view_watching');
    view.show(ShareViewPhase.watching, keyboard: ShareKeyboard.you);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_9_view_typing');
    view.show(ShareViewPhase.waitingForHost);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_10_view_waiting');
    view.show(ShareViewPhase.ended, end: ShareViewEnd.stopped);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_11_view_ended');

    // The view of someone invited to end the session, and the question.
    view
      ..canAsk = false
      ..canEnd = true
      ..show(ShareViewPhase.watching);
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_14_view_can_end');
    await tester.tap(find.byKey(const ValueKey('share-view-end')));
    await settle(tester);
    await saveShot(tester, key, 'sharing_${tag}_15_view_end_question');
    await close(tester);
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';

    testWidgets('on a computer ($tag)', (tester) async {
      // A computer's platform, so that the theme's buttons and fields have
      // a computer's sizes (a test runs as Android unless told otherwise).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final key = await start(tester, themeId, const Size(1100, 760));
        await everyPicture(tester, key, tag);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('on a phone (dark)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final key = await start(tester, 'graphite', const Size(390, 844), phone: true);
      await everyPicture(tester, key, 'phone');
      await finish(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, skip: !shotsEnabled);
}

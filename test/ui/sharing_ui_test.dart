// The session sharing screens (3.0): "Share this session", who is in a
// share and the keyboard, the chip and the strip a shared session shows, a
// live view of someone else's session, and "Shared with you". Each is shown
// with test doubles of the share, the view and the app's sharing services
// (sharing_ui_fakes.dart), so every state can be put on screen and what the
// screen asks for can be read back. The real ones are tested end to end in
// test/features/sharing.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart' show crateLevelLabel;
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/sharing/share_session_dialog.dart';
import 'package:zestssh/ui/screens/sharing/share_view_screen.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';
import 'sharing_ui_fakes.dart';

const _live = '11111111-1111-4111-8111-000000000001';
const _tmux = '11111111-1111-4111-8111-000000000002';
const _changed = '11111111-1111-4111-8111-000000000003';

/// A screen whose button runs [open] with a context under the navigator.
class _Opener extends StatelessWidget {
  const _Opener(this.open);

  final void Function(BuildContext context) open;

  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(key: const ValueKey('open'), onPressed: () => open(context), child: const Text('open')),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late FakeTmux tmux;
  late FakeTmuxJoins tmuxJoins;
  late ProviderContainer container;
  late IncomingShare liveShare;
  late IncomingShare tmuxShare;
  late IncomingShare changedShare;
  final left = <String>[];

  setUpAll(() async {
    final dana = await AccountKeys.generate();
    final sam = await AccountKeys.generate();
    liveShare = await incomingShare(shareId: _live, mode: ShareMode.live, from: dana, to: sam);
    tmuxShare = await incomingShare(shareId: _tmux, mode: ShareMode.tmux, from: dana, to: sam);
    changedShare =
        await incomingShare(shareId: _changed, mode: ShareMode.live, from: dana, to: sam, keysChanged: true);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    ShareViews.reset();
    tmux = FakeTmux();
    tmuxJoins = FakeTmuxJoins();
    left.clear();
  });

  tearDown(() {
    SessionShares.reset();
    ShareViews.reset();
    Redactor.instance
      ..clearNames()
      ..enabled = false;
  });

  FakeSharing sharing() => container.read(sessionSharingProvider) as FakeSharing;
  FakeInvitations invitations() => container.read(shareInvitationsProvider.notifier) as FakeInvitations;
  FakeJoining joining() => container.read(shareJoiningProvider) as FakeJoining;
  FakeSessions sessions() => container.read(activeSessionsProvider.notifier) as FakeSessions;

  /// The app with one screen: [child], or a button that runs [open]. The
  /// live view and a terminal have routes, as in the app.
  Future<void> pumpApp(
    WidgetTester tester, {
    Widget? child,
    void Function(BuildContext context)? open,
    Size size = const Size(1100, 760),
    Locale locale = const Locale('en'),
  }) async {
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
      shareTmuxJoinsProvider.overrideWithValue(tmuxJoins),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (context, _) => Scaffold(body: child ?? _Opener(open!))),
      GoRoute(
        path: Routes.shareView,
        builder: (context, state) => ShareViewScreen(
          shareId: state.extra is String ? state.extra as String : '',
          onLeave: () {
            left.add('view');
            context.pop();
          },
        ),
      ),
      GoRoute(
        path: '/terminal/:id',
        builder: (context, state) => Scaffold(body: Text('terminal of ${state.pathParameters['id']}')),
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
    sessions().show({'s1': connectedSession('s1', 'Web 1')});
    await tester.pump();
  }

  /// Lets pop-ups open and close, and what was started run.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// Ends the test with nothing waiting (a toast keeps a timer).
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    // Brought into view first, as a person scrolls to it: a dialog's body
    // scrolls where it is taller than the window.
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await settle(tester);
  }

  Future<void> openDialog(WidgetTester tester, ShareContext context) async {
    await pumpApp(
      tester,
      open: (c) => showZestModal<void>(
        context: c,
        size: ZestModalSize.large,
        child: ShareSessionDialog(sessionId: 's1', shareContext: context),
      ),
    );
    await tapKey(tester, 'open');
  }

  bool picked(WidgetTester tester, String uid) => tester
      .widgetList<Icon>(find.descendant(of: find.byKey(ValueKey('share-person-$uid')), matching: find.byType(Icon)))
      .any((i) => i.icon == LucideIcons.checkSquare);

  bool modeOn(WidgetTester tester, String key) => tester
      .widgetList<Icon>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(Icon)))
      .any((i) => i.icon == LucideIcons.circleDot);

  /// Everything the screen would paint or announce.
  List<String> rendered(WidgetTester tester) => [
        for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
        for (final r in tester.widgetList<RichText>(find.byType(RichText))) r.text.toPlainText(),
        for (final tip in tester.widgetList<Tooltip>(find.byType(Tooltip))) tip.message ?? '',
      ];

  String level(CrateLevel l) => crateLevelLabel(l, l10n);

  /// What the app last said in a notice (on a computer a toast goes to the
  /// notification center, which is not part of these screens).
  String? lastNotice() {
    final history = container.read(notificationCenterProvider).history;
    if (history.isEmpty) return null;
    final latest = history.first;
    return [latest.title, if (latest.body != null) latest.body!].join(' ');
  }

  final everyone = [
    candidate('uid-kit', 'kit@example.com'),
    candidate('uid-noa', 'noa@example.com', level: CrateLevel.connect),
    candidate('uid-sam', 'sam@example.com', keysChanged: true),
    candidate('uid-lee', null, noKeys: true),
  ];

  group('share this session', () {
    testWidgets('who can be invited, what each may do there, and who cannot join', (tester) async {
      await openDialog(tester, shareContext(everyone, withoutAccess: ['eve@example.com'], sessionLogs: true));
      expect(find.text(l10n.shareTitle('Web 1')), findsOneWidget);
      expect(find.text(l10n.shareUiSubtitle('Production')), findsOneWidget);
      // The recommended way first; a new tmux session would start.
      expect(modeOn(tester, 'share-mode-tmux'), isTrue);
      expect(find.text(l10n.shareTmuxNewSession), findsOneWidget);
      expect(find.text(l10n.shareStartTmux), findsOneWidget);
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.use))), findsOneWidget);
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.connect))), findsOneWidget,
          reason: 'in a shared tmux session everyone types with their own sign-in');
      expect(find.byKey(const ValueKey('share-keyboard')), findsNothing);

      // A live view: someone at the lowest level watches and never types.
      await tapKey(tester, 'share-mode-live');
      expect(modeOn(tester, 'share-mode-live'), isTrue);
      expect(find.text(l10n.sharePersonLevelWatchOnly('Production', level(CrateLevel.connect))), findsOneWidget);
      expect(find.byKey(const ValueKey('share-keyboard')), findsOneWidget);
      // Keys that changed, or that this device never saw: compare first.
      expect(find.text(l10n.sharePersonKeyChanged), findsNWidgets(2));
      expect(find.text('uid-lee'), findsOneWidget, reason: 'no address known: the id');
      expect(find.text(l10n.shareCantJoin('eve@example.com', 'Production')), findsOneWidget);
      expect(find.text(l10n.shareLogsNote('Production')), findsOneWidget);

      // Nobody picked: nothing starts. Someone whose keys changed cannot be
      // picked at all.
      await tapText(tester, l10n.shareStartLive);
      await tapKey(tester, 'share-person-uid-sam');
      await tapKey(tester, 'share-person-uid-lee');
      expect((picked(tester, 'uid-sam'), picked(tester, 'uid-lee')), (false, false));
      await tapText(tester, l10n.shareStartLive);
      expect(sharing().started, isEmpty);

      await tapKey(tester, 'share-person-uid-kit');
      await tapKey(tester, 'share-person-uid-noa');
      await tapKey(tester, 'share-person-uid-noa');
      expect((picked(tester, 'uid-kit'), picked(tester, 'uid-noa')), (true, false), reason: 'a second tap unpicks');
      await tapKey(tester, 'share-person-uid-noa');
      await tapText(tester, l10n.shareStartLive);
      final started = sharing().started.single;
      expect((started.sessionId, started.mode, started.keyboardRequests, started.tmuxSession),
          ('s1', ShareMode.live, true, ''));
      expect(started.people, {'uid-kit', 'uid-noa'});
      expect(find.byType(ShareSessionDialog), findsNothing, reason: 'it closes once sharing has started');
      expect(lastNotice(), l10n.shareStarted);
      expect(tmux.created, isEmpty);
      await finish(tester);
    });

    testWidgets('a live view without keyboard requests, when that is switched off', (tester) async {
      await openDialog(tester, shareContext(everyone));
      await tapKey(tester, 'share-mode-live');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('share-keyboard')), matching: find.byType(ZestSwitch)));
      await settle(tester);
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartLive);
      expect(sharing().started.single.keyboardRequests, isFalse);
      await finish(tester);
    });

    testWidgets('in a live view, someone picked can be the one who may end the session', (tester) async {
      await openDialog(tester, shareContext(everyone));
      Finder endChip(String uid) => find.descendant(
          of: find.byKey(ValueKey('share-person-$uid')), matching: find.byKey(const ValueKey('share-can-end')));
      // On is a ticked box beside its words.
      bool ends(String uid) =>
          find.descendant(of: endChip(uid), matching: find.byIcon(LucideIcons.checkSquare)).evaluate().isNotEmpty;
      Future<void> tapChip(String uid) async {
        await tester.ensureVisible(endChip(uid));
        await tester.pump();
        await tester.tap(endChip(uid));
        await settle(tester);
      }

      // In a shared tmux session nobody ends it for the others: everyone
      // there signs in to the host by themselves.
      await tapKey(tester, 'share-person-uid-kit');
      expect(find.byKey(const ValueKey('share-can-end')), findsNothing);

      // A live view: only for someone picked, and not on by itself.
      await tapKey(tester, 'share-mode-live');
      expect(endChip('uid-kit'), findsOneWidget);
      expect(endChip('uid-noa'), findsNothing);
      expect(ends('uid-kit'), isFalse);
      expect(find.text(l10n.shareCanEnd), findsOneWidget);
      expect(rendered(tester), contains(l10n.shareCanEndHelp), reason: 'what it means is one hover away');
      await tapKey(tester, 'share-person-uid-noa');
      expect(endChip('uid-noa'), findsOneWidget);

      await tapChip('uid-kit');
      expect((ends('uid-kit'), ends('uid-noa')), (true, false));
      expect(picked(tester, 'uid-kit'), isTrue, reason: 'choosing their part does not unpick them');
      // The box says it: the line under the name does not say it again.
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.use))), findsOneWidget);
      expect(find.text('Production: ${level(CrateLevel.use)}, can watch and end the session'), findsNothing);
      expect(find.text(l10n.sharePersonLevelWatchOnly('Production', level(CrateLevel.connect))), findsOneWidget);
      // A second tap takes it back; a third gives it again.
      await tapChip('uid-kit');
      expect(ends('uid-kit'), isFalse);
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.use))), findsOneWidget);
      await tapChip('uid-kit');
      await tapChip('uid-noa');
      expect((ends('uid-kit'), ends('uid-noa')), (true, true));
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.connect))), findsOneWidget,
          reason: 'one who ends the session watches: not said as watch only beside the box');

      // The other way of sharing has no such part; back in a live view,
      // what was chosen is still there.
      await tapKey(tester, 'share-mode-tmux');
      expect(find.byKey(const ValueKey('share-can-end')), findsNothing);
      expect(find.text(l10n.sharePersonLevel('Production', level(CrateLevel.use))), findsOneWidget);
      await tapKey(tester, 'share-mode-live');
      expect((ends('uid-kit'), ends('uid-noa')), (true, true));

      // Someone unpicked is not one who ends it, whatever was chosen.
      await tapKey(tester, 'share-person-uid-noa');
      expect(endChip('uid-noa'), findsNothing);
      await tapText(tester, l10n.shareStartLive);
      final started = sharing().started.single;
      expect((started.sessionId, started.mode, started.keyboardRequests), ('s1', ShareMode.live, true));
      expect(started.people, {'uid-kit'});
      expect(started.enders, {'uid-kit'});
      expect(SessionShares.of('s1')!.guests.map((g) => (g.uid, g.canType, g.canEnd)), [('uid-kit', false, true)]);
      await finish(tester);
    });

    testWidgets('a shared tmux session started after someone was picked to end a live view has nobody who ends it',
        (tester) async {
      await openDialog(tester, shareContext(everyone));
      await tapKey(tester, 'share-mode-live');
      await tapKey(tester, 'share-person-uid-kit');
      await tester.tap(find.byKey(const ValueKey('share-can-end')));
      await settle(tester);
      await tapKey(tester, 'share-mode-tmux');
      await tapText(tester, l10n.shareStartTmux);
      final started = sharing().started.single;
      expect((started.mode, started.people.single), (ShareMode.tmux, 'uid-kit'));
      expect(started.enders, isEmpty);
      await finish(tester);
    });

    testWidgets('a session of a watched Crate: only a live view, and someone who manages the Crate is invited as one '
        'who can end it', (tester) async {
      final people = [
        candidate('uid-kit', 'kit@example.com', level: CrateLevel.manage),
        candidate('uid-noa', 'noa@example.com', level: CrateLevel.connect),
        candidate('uid-sam', 'sam@example.com'),
      ];
      await openDialog(tester, shareContext(people, watched: true));
      Finder endChip(String uid) => find.descendant(
          of: find.byKey(ValueKey('share-person-$uid')), matching: find.byKey(const ValueKey('share-can-end')));
      // On is a ticked box beside its words.
      bool ends(String uid) =>
          find.descendant(of: endChip(uid), matching: find.byIcon(LucideIcons.checkSquare)).evaluate().isNotEmpty;

      // A shared tmux session would have everyone sign in by themselves,
      // unwatched: not offered, with why.
      expect(find.text(l10n.shareTmuxWatched), findsOneWidget);
      expect(modeOn(tester, 'share-mode-live'), isTrue);
      await tapKey(tester, 'share-mode-tmux');
      expect(modeOn(tester, 'share-mode-tmux'), isFalse);

      await tapKey(tester, 'share-person-uid-kit');
      await tapKey(tester, 'share-person-uid-sam');
      expect((ends('uid-kit'), ends('uid-sam')), (true, false),
          reason: 'who manages the Crate watches; anyone else is invited as ever');
      await tapText(tester, l10n.shareStartLive);
      final started = sharing().started.single;
      expect(started.mode, ShareMode.live);
      expect(started.people, {'uid-kit', 'uid-sam'});
      expect(started.enders, {'uid-kit'});
      await finish(tester);

      // In a Crate that is not watched, nobody is that by itself.
      SessionShares.reset();
      await openDialog(tester, shareContext(people));
      await tapKey(tester, 'share-mode-live');
      await tapKey(tester, 'share-person-uid-kit');
      expect(ends('uid-kit'), isFalse);
      expect(find.text(l10n.shareTmuxWatched), findsNothing);
      await finish(tester);
    });

    testWidgets('nobody else can open the Crate: it says so', (tester) async {
      await openDialog(tester, shareContext(const [], withoutAccess: ['eve@example.com']));
      expect(find.text(l10n.shareNobody('Production')), findsOneWidget);
      await tapText(tester, l10n.shareStartTmux);
      expect(sharing().started, isEmpty);
      expect(tmux.created, isEmpty);
      await finish(tester);
    });

    testWidgets('a shared tmux session: a new one gets a name of its own, the one this tab is in is used as it is',
        (tester) async {
      await openDialog(tester, shareContext(everyone));
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartTmux);
      final name = tmux.created.single;
      expect(kShareTmuxName.hasMatch(name), isTrue);
      expect(name, startsWith('shared-'));
      final started = sharing().started.single;
      expect((started.mode, started.tmuxSession), (ShareMode.tmux, name));
      expect(started.people, {'uid-kit'});
      expect(find.byType(ShareSessionDialog), findsNothing);
      await finish(tester);

      // Names made for sharing differ, and never hold a character that
      // could be mistaken for another.
      final names = {for (var i = 0; i < 200; i++) newSharedTmuxName()};
      expect(names.length, greaterThan(190));
      expect(names.every((n) => RegExp(r'^shared-[a-hj-km-np-z2-9]{4}$').hasMatch(n)), isTrue);
    });

    testWidgets('the tab already shows tmux: its session is shared, and a live view is not offered', (tester) async {
      tmux.attachedTo('work');
      await openDialog(tester, shareContext(everyone));
      expect(find.text(l10n.shareTmuxNewSession), findsNothing);
      expect(find.text(l10n.shareLiveInTmux), findsOneWidget);
      await tapKey(tester, 'share-mode-live');
      expect(modeOn(tester, 'share-mode-live'), isFalse, reason: 'there is no terminal of its own to show');
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartTmux);
      expect(tmux.created, isEmpty);
      expect(sharing().started.single.tmuxSession, 'work');
      await finish(tester);
    });

    testWidgets('a tmux session whose name cannot be shared, and a host the others do not have yet', (tester) async {
      tmux.attachedTo('my session');
      await openDialog(tester, shareContext(everyone));
      expect(find.text(l10n.shareTmuxBadName), findsOneWidget);
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartTmux);
      expect(sharing().started, isEmpty, reason: 'neither way is possible');
      await finish(tester);

      // Not synced yet: a live view is the way, and is picked.
      tmux = FakeTmux();
      await openDialog(tester, shareContext(everyone, synced: false));
      expect(find.text(l10n.shareTmuxNeedsSync), findsOneWidget);
      expect(modeOn(tester, 'share-mode-live'), isTrue);
      await tapKey(tester, 'share-mode-tmux');
      expect(modeOn(tester, 'share-mode-tmux'), isFalse);
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartLive);
      expect(sharing().started.single.mode, ShareMode.live);
      await finish(tester);
    });

    testWidgets('tmux cannot be started on the host: nothing is shared, and it says why', (tester) async {
      tmux.cannotStart = true;
      await openDialog(tester, shareContext(everyone));
      await tapKey(tester, 'share-person-uid-kit');
      await tapText(tester, l10n.shareStartTmux);
      expect(find.text(l10n.shareTmuxFailed), findsOneWidget);
      expect(sharing().started, isEmpty);
      expect(find.byType(ShareSessionDialog), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a share that cannot start says why and keeps what was picked', (tester) async {
      await openDialog(tester, shareContext(everyone));
      await tapKey(tester, 'share-mode-live');
      await tapKey(tester, 'share-person-uid-kit');
      for (final (failure, message) in <(Object, String)>[
        (const ShareStartFailed(ShareStartProblem.tooMany), l10n.shareFailedTooMany),
        (const ShareStartFailed(ShareStartProblem.noAccess), l10n.shareFailedNoAccess),
        (const ShareStartFailed(ShareStartProblem.notReady), l10n.shareFailedNotReady),
        (const ShareStartFailed(ShareStartProblem.failed), l10n.shareFailedOffline),
        (StateError('anything else'), l10n.shareFailedOffline),
        // ZestSSH Cloud gave no answer: said as that, with its code.
        (
          const ShareStartFailed(ShareStartProblem.failed, cause: SocketException('Connection refused')),
          '${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)',
        ),
      ]) {
        sharing().failStart = failure;
        await tapText(tester, l10n.shareStartLive);
        expect(
            find.descendant(of: find.byKey(const ValueKey('share-error')), matching: find.text(message)), findsOneWidget,
            reason: '$failure');
        expect(picked(tester, 'uid-kit'), isTrue);
        expect(SessionShares.of('s1'), isNull);
      }
      // Picking again takes the message away; then it works.
      await tapKey(tester, 'share-person-uid-noa');
      expect(find.byKey(const ValueKey('share-error')), findsNothing);
      await tapText(tester, l10n.shareStartLive);
      expect(SessionShares.of('s1'), isNotNull);
      expect(find.byType(ShareSessionDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('a session already shared: more people are invited, and someone who said no can be asked again',
        (tester) async {
      final share = FakeShare(guests: [
        guest('uid-kit', ShareGuestState.watching),
        guest('uid-noa', ShareGuestState.declined, canType: false),
      ]);
      final people = [
        candidate('uid-kit', 'kit@example.com'),
        candidate('uid-noa', 'noa@example.com', level: CrateLevel.connect),
        candidate('uid-sam', 'sam@example.com'),
      ];
      await pumpApp(
        tester,
        open: (c) => showZestModal<void>(
          context: c,
          size: ZestModalSize.large,
          child: ShareSessionDialog(sessionId: 's1', shareContext: shareContext(people)),
        ),
      );
      SessionShares.add('s1', share, names: {'uid-kit': 'kit@example.com'});
      await tapKey(tester, 'open');
      // How it is shared was decided when it started.
      expect(find.byKey(const ValueKey('share-mode-tmux')), findsNothing);
      expect(find.byKey(const ValueKey('share-keyboard')), findsNothing);
      expect(find.text(l10n.shareAlreadyInvited), findsOneWidget);
      expect(picked(tester, 'uid-kit'), isTrue);
      await tapKey(tester, 'share-person-uid-kit');
      expect(picked(tester, 'uid-kit'), isTrue, reason: 'already invited: not something to change here');

      await tapText(tester, l10n.shareInviteMore);
      expect(share.calls, isEmpty, reason: 'nobody new picked');
      await tapKey(tester, 'share-person-uid-noa');
      await tapKey(tester, 'share-person-uid-sam');
      // The server is not reached: it says so, and nothing is lost.
      share.failInvite = StateError('offline');
      await tapText(tester, l10n.shareInviteMore);
      expect(find.text(l10n.shareFailedOffline), findsOneWidget);
      // ZestSSH Cloud gave no answer: said as that, with its code.
      share.failInvite = const SocketException('Connection refused');
      await tapText(tester, l10n.shareInviteMore);
      expect(find.text('${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)'), findsOneWidget);
      expect(find.text(l10n.shareFailedOffline), findsNothing);
      await tapText(tester, l10n.shareInviteMore);
      expect(
          share.calls,
          [
            'invite:uid-noa,uid-sam|uid-noa',
            'invite:uid-noa,uid-sam|uid-noa',
            'invite:uid-noa,uid-sam|uid-noa',
          ],
          reason: 'asked each time; noa is at the lowest level: watching only');
      expect(SessionShares.nameOf('s1', 'uid-sam'), 'sam@example.com');
      expect(find.byType(ShareSessionDialog), findsNothing);
      expect(sharing().started, isEmpty, reason: 'no second share of the same session');
      await finish(tester);
    });

    testWidgets('someone invited later can be the one who may end the session; in a shared tmux session nobody is',
        (tester) async {
      final people = [
        candidate('uid-kit', 'kit@example.com'),
        candidate('uid-noa', 'noa@example.com', level: CrateLevel.connect),
        candidate('uid-sam', 'sam@example.com'),
      ];
      Finder endChip(String uid) => find.descendant(
          of: find.byKey(ValueKey('share-person-$uid')), matching: find.byKey(const ValueKey('share-can-end')));
      Future<void> openOn(FakeShare share) async {
        await pumpApp(
          tester,
          open: (c) => showZestModal<void>(
            context: c,
            size: ZestModalSize.large,
            child: ShareSessionDialog(sessionId: 's1', shareContext: shareContext(people)),
          ),
        );
        SessionShares.add('s1', share, names: {'uid-kit': 'kit@example.com'});
        await tapKey(tester, 'open');
      }

      final share = FakeShare(guests: [guest('uid-kit', ShareGuestState.watching)]);
      await openOn(share);
      expect(endChip('uid-kit'), findsNothing, reason: 'already invited: the part they have is not changed here');
      await tapKey(tester, 'share-person-uid-noa');
      await tapKey(tester, 'share-person-uid-sam');
      await tester.ensureVisible(endChip('uid-sam'));
      await tester.pump();
      await tester.tap(endChip('uid-sam'));
      await settle(tester);
      await tapText(tester, l10n.shareInviteMore);
      expect(share.calls, ['invite:uid-noa,uid-sam|uid-noa|ends:uid-sam']);
      expect(share.guests.map((g) => (g.uid, g.canType, g.canEnd)), [
        ('uid-kit', true, false),
        ('uid-noa', false, false),
        ('uid-sam', false, true),
      ]);
      await finish(tester);

      // A shared tmux session: the same dialog offers no such part.
      SessionShares.reset();
      tmux.attachedTo('work');
      final shared = FakeShare(
          mode: ShareMode.tmux,
          tmuxSession: 'work',
          keyboardRequests: false,
          guests: [guest('uid-kit', ShareGuestState.connected, canType: false)]);
      await openOn(shared);
      await tapKey(tester, 'share-person-uid-sam');
      expect(find.byKey(const ValueKey('share-can-end')), findsNothing);
      await tapText(tester, l10n.shareInviteMore);
      expect(shared.calls, ['invite:uid-sam|']);
      await finish(tester);
    });

    testWidgets('eight people at most, counting those already on the list', (tester) async {
      final share = FakeShare(guests: [
        for (var i = 0; i < 7; i++) guest('uid-g$i', i == 0 ? ShareGuestState.declined : ShareGuestState.invited),
      ]);
      final people = [
        for (var i = 0; i < 7; i++) candidate('uid-g$i', 'g$i@example.com'),
        candidate('uid-kit', 'kit@example.com'),
        candidate('uid-sam', 'sam@example.com'),
      ];
      await pumpApp(
        tester,
        open: (c) => showZestModal<void>(
          context: c,
          size: ZestModalSize.large,
          child: ShareSessionDialog(sessionId: 's1', shareContext: shareContext(people)),
        ),
      );
      SessionShares.add('s1', share);
      await tapKey(tester, 'open');
      // The one who said no is asked again: still seven on the list.
      await tapKey(tester, 'share-person-uid-g0');
      await tapKey(tester, 'share-person-uid-kit');
      expect(find.text(l10n.shareTooManyPeople(kShareMaxPeople)), findsNothing);
      await tester.ensureVisible(find.byKey(const ValueKey('share-person-uid-sam')));
      await tapKey(tester, 'share-person-uid-sam');
      expect(find.text(l10n.shareTooManyPeople(kShareMaxPeople)), findsOneWidget);
      await tapText(tester, l10n.shareInviteMore);
      expect(share.calls, isEmpty);
      await tapKey(tester, 'share-person-uid-sam');
      await tapText(tester, l10n.shareInviteMore);
      expect(share.calls.single, startsWith('invite:uid-g0,uid-kit|'));
      await finish(tester);
    });

    testWidgets('a session that cannot be shared says why instead of opening the dialog', (tester) async {
      await pumpApp(tester, open: (c) => showShareSession(c, 's1'));
      // A host in the Tree.
      sharing().availability = (null, ShareUnavailable.notInCrate);
      await tapKey(tester, 'open');
      expect(find.text(l10n.shareNotInCrateSub('Web 1')), findsOneWidget);
      expect(find.text(l10n.shareNotInCrateBody), findsOneWidget);
      expect(find.byType(ShareSessionDialog), findsNothing);
      await tapText(tester, l10n.close);
      expect(find.text(l10n.shareNotInCrateBody), findsNothing);
      // The account's keys are not here, or the Orchard is closed.
      sharing().availability = (null, ShareUnavailable.notReady);
      await tapKey(tester, 'open');
      expect(find.text(l10n.shareNotReadyBody), findsOneWidget);
      expect(find.text(l10n.shareNotInCrateSub('Web 1')), findsNothing);
      await tapText(tester, l10n.close);
      // It can be shared: the dialog.
      sharing().availability = (shareContext(everyone), null);
      await tapKey(tester, 'open');
      expect(find.byType(ShareSessionDialog), findsOneWidget);
      await tapText(tester, l10n.cancel);
      expect(find.byType(ShareSessionDialog), findsNothing);
      // A session that is gone: nothing at all.
      sessions().show(const {});
      await tapKey(tester, 'open');
      expect(find.byType(Dialog), findsNothing);
      expect(find.text(l10n.shareNotReadyBody), findsNothing);
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
      await openDialog(tester, shareContext(everyone, withoutAccess: ['eve@example.com']));
      final all = rendered(tester).join('\n');
      for (final secret in ['Web 1', 'kit@example.com', 'noa@example.com', 'sam@example.com', 'eve@example.com', 'uid-lee']) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
      expect(all, contains('Production'), reason: 'a Crate is named, as everywhere else');
      await finish(tester);
    });
  });

  group('who is in a share', () {
    final names = {
      'uid-sam': 'sam@example.com',
      'uid-kit': 'kit@example.com',
      'uid-noa': 'noa@example.com',
      'uid-lee': 'lee@example.com',
      'uid-eve': 'eve@example.com',
      'uid-max': 'max@example.com',
    };

    Future<FakeShare> openParticipants(WidgetTester tester, FakeShare share) async {
      await pumpApp(tester, open: (c) => showShareParticipants(c, 's1'));
      SessionShares.add('s1', share, names: names);
      await tapKey(tester, 'open');
      return share;
    }

    String stateOf(WidgetTester tester, String uid) => tester
        .widgetList<Text>(find.descendant(of: find.byKey(ValueKey('share-guest-$uid')), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList()[2]!;

    testWidgets('a live view: where everyone stands, and the keyboard goes where it is given', (tester) async {
      final share = await openParticipants(
        tester,
        FakeShare()
          ..show([
            guest('uid-sam', ShareGuestState.watching, asks: true),
            guest('uid-kit', ShareGuestState.typing),
            guest('uid-noa', ShareGuestState.watching, canType: false),
            guest('uid-lee', ShareGuestState.invited),
            guest('uid-eve', ShareGuestState.declined),
            guest('uid-max', ShareGuestState.connected),
          ], holder: 'uid-kit'),
      );
      expect(find.text(l10n.shareChipLive), findsOneWidget);
      expect(find.text(l10n.shareLiveEncrypted), findsOneWidget);
      expect(find.text(l10n.shareYouCanStillType), findsOneWidget);
      expect(find.text('kit@example.com'), findsOneWidget);
      expect(stateOf(tester, 'uid-sam'), l10n.shareAsksKeyboard);
      expect(stateOf(tester, 'uid-kit'), l10n.shareStateTyping);
      expect(stateOf(tester, 'uid-noa'), l10n.shareStateWatchingOnly);
      expect(stateOf(tester, 'uid-lee'), l10n.shareStateInvited);
      expect(stateOf(tester, 'uid-eve'), l10n.shareStateDeclined);
      expect(stateOf(tester, 'uid-max'), l10n.shareStateConnecting);
      // Only someone watching who may type is offered the keyboard.
      for (final uid in ['uid-kit', 'uid-noa', 'uid-lee', 'uid-eve', 'uid-max']) {
        expect(find.byKey(ValueKey('share-give-$uid')), findsNothing, reason: uid);
      }
      expect(find.byKey(const ValueKey('share-take-back-uid-sam')), findsNothing);

      await tapKey(tester, 'share-take-back-uid-kit');
      expect(share.calls, ['takeBack']);
      expect(find.text(l10n.shareYouHaveKeyboard), findsOneWidget);
      expect(stateOf(tester, 'uid-kit'), l10n.shareStateWatching);
      // sam asked: not now, then yes.
      await tapText(tester, l10n.shareNotNow);
      expect(share.calls.last, 'deny:uid-sam');
      expect(stateOf(tester, 'uid-sam'), l10n.shareStateWatching);
      expect(find.text(l10n.shareNotNow), findsNothing);
      await tapKey(tester, 'share-give-uid-sam');
      expect(share.calls.last, 'give:uid-sam');
      expect(stateOf(tester, 'uid-sam'), l10n.shareStateTyping);
      expect(find.text(l10n.shareYouCanStillType), findsOneWidget);
      // Someone is taken off the list.
      await tapKey(tester, 'share-remove-uid-lee');
      expect(share.calls.last, 'remove:uid-lee');
      expect(find.byKey(const ValueKey('share-guest-uid-lee')), findsNothing);

      // The line to ZestSSH Cloud is down: it says so.
      share.show(share.guests, lineOpen: false);
      await settle(tester);
      expect(find.text(l10n.shareReconnecting), findsOneWidget);
      expect(find.text(l10n.shareLiveEncrypted), findsNothing);
      await finish(tester);
    });

    testWidgets('someone who may end the session: it says so, and they are not offered the keyboard', (tester) async {
      final share = await openParticipants(
        tester,
        FakeShare()
          ..show([
            guest('uid-sam', ShareGuestState.watching, canEnd: true),
            guest('uid-kit', ShareGuestState.watching),
            guest('uid-lee', ShareGuestState.invited, canEnd: true),
            guest('uid-max', ShareGuestState.connected, canEnd: true),
          ]),
      );
      expect(stateOf(tester, 'uid-sam'), l10n.shareStateWatchingCanEnd);
      expect(stateOf(tester, 'uid-kit'), l10n.shareStateWatching);
      // Not there yet, they stand where anyone invited stands.
      expect(stateOf(tester, 'uid-lee'), l10n.shareStateInvited);
      expect(stateOf(tester, 'uid-max'), l10n.shareStateConnecting);
      expect(find.byKey(const ValueKey('share-give-uid-sam')), findsNothing);
      expect(find.byKey(const ValueKey('share-give-uid-kit')), findsOneWidget);
      // Their invitation can be taken back like anyone's.
      await tapKey(tester, 'share-remove-uid-sam');
      expect(share.calls, ['remove:uid-sam']);
      expect(find.byKey(const ValueKey('share-guest-uid-sam')), findsNothing);
      await finish(tester);
    });

    testWidgets('stopping asks first; then everyone is cut off and the session is no longer shared', (tester) async {
      // (The tab went into tmux after the live view began: whoever is
      // attached there has nothing to do with this share.)
      tmux.attachedTo('work');
      final share = await openParticipants(tester, FakeShare()..show([guest('uid-sam', ShareGuestState.watching)]));
      await tapText(tester, l10n.shareStop);
      expect(find.text(l10n.shareStopConfirmTitle), findsOneWidget);
      expect(find.text(l10n.shareStopConfirmLive), findsOneWidget);
      await tapText(tester, l10n.cancel);
      expect(share.calls, isEmpty);
      expect(SessionShares.of('s1'), same(share));

      await tapText(tester, l10n.shareStop);
      await tapText(tester, l10n.shareStop);
      expect(share.calls, ['stop:stopped']);
      expect(SessionShares.of('s1'), isNull);
      expect(find.byType(ShareParticipantsDialog), findsNothing);
      expect(tmux.detachedOthers, 0, reason: 'a live view has nobody attached to anything');
      await finish(tester);
    });

    testWidgets('a shared tmux session: who is attached, and stopping detaches the others', (tester) async {
      tmux.attachedTo('work');
      final share = await openParticipants(
        tester,
        FakeShare(mode: ShareMode.tmux, tmuxSession: 'work', keyboardRequests: false)
          ..show([
            guest('uid-sam', ShareGuestState.connected, canType: false),
            guest('uid-kit', ShareGuestState.invited, canType: false),
          ]),
      );
      expect(find.text(l10n.sharePopTmuxTitle('work')), findsOneWidget);
      expect(find.text(l10n.shareTmuxOwnAccess), findsOneWidget);
      expect(find.text(l10n.shareStateAttached), findsNWidgets(2), reason: 'you, and sam');
      expect(stateOf(tester, 'uid-kit'), l10n.shareStateInvited);
      expect(find.byKey(const ValueKey('share-give-uid-sam')), findsNothing, reason: 'there is no keyboard to hand over');
      await tapText(tester, l10n.shareStop);
      expect(find.text(l10n.shareStopConfirmTmux), findsOneWidget);
      await tapText(tester, l10n.shareStop);
      expect(share.calls, ['stop:stopped']);
      expect(tmux.detachedOthers, 1);
      await finish(tester);
    });

    testWidgets('it ended while this was open: it says so', (tester) async {
      await openParticipants(tester, FakeShare()..show([guest('uid-sam', ShareGuestState.watching)]));
      SessionShares.sessionClosed('s1');
      await settle(tester);
      expect(find.text(l10n.shareEndedTitle), findsOneWidget);
      expect(find.text(l10n.shareEndedBody), findsOneWidget);
      expect(find.text(l10n.shareStop), findsNothing);
      await tapText(tester, l10n.close);
      expect(find.byType(ShareParticipantsDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('inviting more people opens the share dialog in its place', (tester) async {
      await openParticipants(tester, FakeShare()..show([guest('uid-kit', ShareGuestState.watching)]));
      sharing().availability = (shareContext(everyone), null);
      await tapText(tester, l10n.shareInviteMore);
      expect(find.byType(ShareParticipantsDialog), findsNothing);
      expect(find.byType(ShareSessionDialog), findsOneWidget);
      expect(find.text(l10n.shareAlreadyInvited), findsOneWidget);
      await finish(tester);
    });

    testWidgets('while recording, nobody\'s address is on screen', (tester) async {
      SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
      prefs = await SharedPreferences.getInstance();
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout;
      await pumpApp(
        tester,
        child: const Column(children: [
          SessionShareChip(sessionId: 's1'),
          SessionShareStrip(sessionId: 's1', always: true),
        ]),
      );
      SessionShares.add('s1', FakeShare()..show([guest('uid-sam', ShareGuestState.typing)], holder: 'uid-sam'),
          names: names);
      await settle(tester);
      await tapKey(tester, 'share-strip-s1');
      expect(find.byType(ShareParticipantsDialog), findsOneWidget);
      expect(rendered(tester).join('\n'), isNot(contains('sam@example.com')));
      await finish(tester);
    });
  });

  group('what a shared session shows about itself', () {
    final names = {'uid-sam': 'sam@example.com', 'uid-kit': 'kit@example.com'};

    testWidgets('the chip in its header: shared, how, with how many there now; a click says who', (tester) async {
      await pumpApp(tester, child: const Row(children: [Text('header'), SessionShareChip(sessionId: 's1')]));
      expect(find.byKey(const ValueKey('share-chip-s1')), findsNothing);

      final share = FakeShare()
        ..show([
          guest('uid-sam', ShareGuestState.watching),
          guest('uid-kit', ShareGuestState.invited),
        ]);
      SessionShares.add('s1', share, names: names);
      await settle(tester);
      expect(find.text(l10n.shareChipCount(l10n.shareChipLive, 1)), findsOneWidget);
      expect(find.byTooltip(l10n.shareChipTooltip), findsOneWidget);
      expect(find.byIcon(LucideIcons.users), findsOneWidget);
      // Someone gets the keyboard, someone's device is still connecting: the
      // count is of those watching (one connecting is not there yet), and
      // the chip keeps its face (the keyboard is the strip's to say).
      share.show([
        guest('uid-sam', ShareGuestState.typing),
        guest('uid-kit', ShareGuestState.connected),
      ], holder: 'uid-sam');
      await settle(tester);
      expect(find.text(l10n.shareChipCount(l10n.shareChipLive, 1)), findsOneWidget);
      expect(find.byIcon(LucideIcons.users), findsOneWidget);
      expect(find.byIcon(LucideIcons.keyboard), findsNothing);
      share.show([
        guest('uid-sam', ShareGuestState.typing),
        guest('uid-kit', ShareGuestState.watching),
      ], holder: 'uid-sam');
      await settle(tester);
      expect(find.text(l10n.shareChipCount(l10n.shareChipLive, 2)), findsOneWidget);
      // Nobody watching yet: none, not one.
      share.show([guest('uid-sam', ShareGuestState.connected), guest('uid-kit', ShareGuestState.invited)]);
      await settle(tester);
      expect(find.text(l10n.shareChipCount(l10n.shareChipLive, 0)), findsOneWidget);
      share.show([guest('uid-sam', ShareGuestState.watching, asks: true)]);
      await settle(tester);
      expect(find.byIcon(LucideIcons.users), findsOneWidget);

      await tapKey(tester, 'share-chip-s1');
      expect(find.byType(ShareParticipantsDialog), findsOneWidget);
      // No Close button: the header's close closes it.
      expect(find.widgetWithText(OutlinedButton, l10n.close), findsNothing);
      await tester.tap(find.byTooltip(l10n.close).last);
      await settle(tester);
      // Another session's share is not this one's.
      SessionShares.add('s2', FakeShare(mode: ShareMode.tmux, tmuxSession: 'work'));
      await settle(tester);
      expect(find.text(l10n.shareChipCount(l10n.shareChipTmux, 0)), findsNothing);
      // Stopped: the chip goes.
      await SessionShares.stop('s1');
      await settle(tester);
      expect(find.byKey(const ValueKey('share-chip-s1')), findsNothing);
      await finish(tester);
    });

    testWidgets('on a computer the line shows only while someone else types or asks, with the way out on it',
        (tester) async {
      await pumpApp(tester, child: const Column(children: [SessionShareStrip(sessionId: 's1'), Spacer()]));
      final share = FakeShare()..show([guest('uid-sam', ShareGuestState.watching)]);
      SessionShares.add('s1', share, names: names);
      await settle(tester);
      expect(find.byKey(const ValueKey('share-strip-s1')), findsNothing, reason: 'the chip says it; nothing to act on');

      share.show([guest('uid-sam', ShareGuestState.watching, asks: true)]);
      await settle(tester);
      expect(find.text(l10n.shareAskingBanner('sam@example.com')), findsOneWidget);
      await tapText(tester, l10n.shareNotNow);
      expect(share.calls, ['deny:uid-sam']);
      expect(find.byKey(const ValueKey('share-strip-s1')), findsNothing);

      share.show([guest('uid-sam', ShareGuestState.watching, asks: true)]);
      await settle(tester);
      await tapKey(tester, 'share-strip-give-s1');
      expect(share.calls.last, 'give:uid-sam');
      expect(find.text(l10n.shareTypingBanner('sam@example.com')), findsOneWidget);
      await tapKey(tester, 'share-strip-take-back-s1');
      expect(share.calls.last, 'takeBack');
      expect(find.byKey(const ValueKey('share-strip-s1')), findsNothing);
      await finish(tester);
    });

    testWidgets('on a phone the line is there the whole time, and opens who is there', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpApp(
          tester,
          size: const Size(390, 844),
          child: const Column(children: [SessionShareStrip(sessionId: 's1', always: true), Spacer()]),
        );
        expect(find.byKey(const ValueKey('share-strip-s1')), findsNothing, reason: 'not shared');
        final share = FakeShare(mode: ShareMode.tmux, tmuxSession: 'work')
          ..show([guest('uid-sam', ShareGuestState.connected, canType: false)]);
        SessionShares.add('s1', share, names: names);
        await settle(tester);
        expect(find.text(l10n.shareChipCount(l10n.shareChipTmux, 1)), findsOneWidget);
        expect(find.byIcon(LucideIcons.chevronRight), findsOneWidget);
        await tapKey(tester, 'share-strip-s1');
        expect(find.byType(ShareParticipantsDialog), findsOneWidget);
        expect(find.text(l10n.sharePopTmuxTitle('work')), findsOneWidget);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('a live view of someone else\'s session', () {
    Future<FakeView> openView(WidgetTester tester, IncomingShare share,
        {bool canAsk = true, bool canEnd = false, Size? size}) async {
      final view = FakeView(canAsk: canAsk, canEnd: canEnd);
      view.terminal
        ..resize(60, 12)
        ..write('deploy@web1:~\$ uptime\r\n 09:00:01 up 3 days\r\n');
      await pumpApp(
        tester,
        size: size ?? const Size(1100, 760),
        child: ShareViewScreen(shareId: share.shareId, onLeave: () => left.add('screen')),
      );
      ShareViews.add(share, view);
      await settle(tester);
      return view;
    }

    String stateLine(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('share-view-state'))).data!;

    testWidgets('on its way: connecting, waiting for the person sharing, setting up the channel', (tester) async {
      final view = await openView(tester, liveShare);
      expect(find.text(l10n.shareViewTitle('dana@example.com')), findsOneWidget);
      expect(find.text(l10n.shareInviteOn('Web 1', 'Production')), findsOneWidget);
      // With room, Leave says its word.
      expect(find.descendant(of: find.byKey(const ValueKey('share-view-leave')), matching: find.text(l10n.shareViewLeave)),
          findsOneWidget);
      expect(find.text(l10n.shareViewConnecting), findsOneWidget);
      expect(find.byType(TerminalView), findsNothing);
      view.show(ShareViewPhase.waitingForHost);
      await settle(tester);
      expect(find.text(l10n.shareViewWaiting('dana@example.com')), findsOneWidget);
      view.show(ShareViewPhase.joining);
      await settle(tester);
      expect(find.text(l10n.shareViewJoining), findsOneWidget);
      expect(find.byKey(const ValueKey('share-view-state')), findsNothing, reason: 'nothing to say about a keyboard yet');
      await finish(tester);
    });

    testWidgets('watching: their terminal at its own size, read-only until the keyboard is handed over',
        (tester) async {
      final view = await openView(tester, liveShare);
      view.show(ShareViewPhase.watching);
      await settle(tester);
      final terminal = find.byKey(const ValueKey('share-view-terminal-$_live'));
      expect(tester.widget<TerminalView>(terminal).readOnly, isTrue);
      expect(tester.widget<TerminalView>(terminal).autoResize, isFalse);
      expect(stateLine(tester), l10n.shareUiViewStatus(l10n.shareViewWatching));
      // It sits in the top left corner of its area, as a terminal sits in
      // its window, on the terminal's own ground from edge to edge.
      final area = tester.getRect(find.ancestor(of: terminal, matching: find.byType(ColoredBox)).first);
      expect((area.left, area.width), (0, 1100));
      expect(tester.getTopLeft(terminal), area.topLeft + const Offset(8, 8));
      final before = tester.getSize(terminal);
      // Their window grows: this one follows its size, not this window's.
      view.terminal.resize(120, 24);
      view.show(ShareViewPhase.watching);
      await settle(tester);
      final after = tester.getSize(terminal);
      expect(after.width / before.width, closeTo(2, 0.01));
      expect(after.height / before.height, closeTo(2, 0.01));

      // Asking for the keyboard.
      await tapKey(tester, 'share-view-ask');
      expect(view.calls, ['ask']);
      expect(find.text(l10n.shareViewAsked), findsOneWidget);
      await tapKey(tester, 'share-view-ask');
      expect(view.calls, ['ask'], reason: 'asked once; it waits for an answer');
      // It is handed over: the screen says so the whole time, and typing
      // is on. Handing it back is one tap.
      view.show(ShareViewPhase.watching, keyboard: ShareKeyboard.you);
      await settle(tester);
      expect(stateLine(tester), l10n.shareViewTyping);
      expect(tester.widget<TerminalView>(terminal).readOnly, isFalse);
      expect(find.byKey(const ValueKey('share-view-ask')), findsNothing);
      // What is typed here is typed into someone's terminal: the keyboard
      // is asked not to learn from it, until its person lets it (Settings).
      expect(tester.widget<TerminalView>(terminal).personalizedLearning, isFalse);
      await container.read(settingsUpdaterProvider).setKeyboardIncognito(false);
      await settle(tester);
      expect(tester.widget<TerminalView>(terminal).personalizedLearning, isTrue);
      await container.read(settingsUpdaterProvider).setKeyboardIncognito(true);
      await settle(tester);
      expect(tester.widget<TerminalView>(terminal).personalizedLearning, isFalse);
      // The keyboard without suggestions where its person chose it (Settings,
      // the compact keyboard).
      expect(tester.widget<TerminalView>(terminal).keyboardType, TextInputType.emailAddress);
      await container.read(settingsUpdaterProvider).setCompactKeyboard(true);
      await settle(tester);
      expect(tester.widget<TerminalView>(terminal).keyboardType, TextInputType.visiblePassword);
      await container.read(settingsUpdaterProvider).setCompactKeyboard(false);
      await settle(tester);
      expect(tester.widget<TerminalView>(terminal).keyboardType, TextInputType.emailAddress);
      await tapKey(tester, 'share-view-give-back');
      expect(view.calls.last, 'giveBack');
      expect(tester.widget<TerminalView>(terminal).readOnly, isTrue);
      // Someone else has it.
      view.show(ShareViewPhase.watching, keyboard: ShareKeyboard.someoneElse);
      await settle(tester);
      expect(stateLine(tester), l10n.shareUiViewStatus(l10n.shareViewSomeoneTyping));
      await finish(tester);
    });

    testWidgets('someone who can only watch is not offered the keyboard', (tester) async {
      final view = await openView(tester, liveShare, canAsk: false);
      view.show(ShareViewPhase.watching);
      await settle(tester);
      expect(find.byKey(const ValueKey('share-view-ask')), findsNothing);
      expect(find.byKey(const ValueKey('share-view-give-back')), findsNothing);
      expect(find.byKey(const ValueKey('share-view-end')), findsNothing);
      expect(stateLine(tester), l10n.shareUiViewStatus(l10n.shareViewWatching));
      await finish(tester);
    });

    testWidgets('someone invited to end the session: the screen says so, and ending it asks first', (tester) async {
      final view = await openView(tester, liveShare, canAsk: false, canEnd: true);
      // Nothing to end while there is nothing to watch.
      for (final phase in [ShareViewPhase.connecting, ShareViewPhase.waitingForHost, ShareViewPhase.joining]) {
        view.show(phase);
        await settle(tester);
        expect(find.byKey(const ValueKey('share-view-end')), findsNothing, reason: phase.name);
      }
      view.show(ShareViewPhase.watching);
      await settle(tester);
      expect(stateLine(tester), l10n.shareUiViewStatus(l10n.shareUiViewCanEndShort));
      // The whole sentence about the encryption is one hover away.
      expect(find.byTooltip(l10n.shareViewEncrypted), findsOneWidget);
      expect(find.byKey(const ValueKey('share-view-ask')), findsNothing);
      expect(find.byKey(const ValueKey('share-view-give-back')), findsNothing);
      expect(tester.widget<TerminalView>(find.byKey(const ValueKey('share-view-terminal-$_live'))).readOnly, isTrue);

      // The question says whose session it is and what ending it does.
      await tapKey(tester, 'share-view-end');
      expect(find.text(l10n.shareViewEndTitle('dana@example.com')), findsOneWidget);
      expect(find.text(l10n.shareViewEndBody), findsOneWidget);
      await tapText(tester, l10n.cancel);
      expect(view.calls, isEmpty, reason: 'nothing ends without a yes');
      expect(find.text(l10n.shareViewEndBody), findsNothing);

      await tapKey(tester, 'share-view-end');
      await tapText(tester, l10n.shareViewEnd);
      expect(view.calls, ['end']);
      expect(find.text(l10n.shareViewEndBody), findsNothing);
      expect(ShareViews.of(_live), same(view), reason: 'it goes on watching until the session has closed');

      // While someone else types it is still theirs to end.
      view.show(ShareViewPhase.watching, keyboard: ShareKeyboard.someoneElse);
      await settle(tester);
      expect(stateLine(tester), l10n.shareUiViewStatus(l10n.shareViewSomeoneTyping));
      expect(find.byKey(const ValueKey('share-view-end')), findsOneWidget);
      // The session closed: it says so, and there is nothing left to end.
      view.show(ShareViewPhase.ended, end: ShareViewEnd.sessionClosed);
      await settle(tester);
      expect(find.text(l10n.shareEndSessionClosed), findsOneWidget);
      expect(find.byKey(const ValueKey('share-view-end')), findsNothing);
      await finish(tester);
    });

    testWidgets('while recording, the question before ending a session names nobody real', (tester) async {
      SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
      prefs = await SharedPreferences.getInstance();
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout;
      final view = await openView(tester, liveShare, canAsk: false, canEnd: true);
      view.show(ShareViewPhase.watching);
      await settle(tester);
      await tapKey(tester, 'share-view-end');
      expect(find.text(l10n.shareViewEndBody), findsOneWidget);
      expect(rendered(tester).join('\n'), isNot(contains('dana@example.com')));
      await tapText(tester, l10n.cancel);
      expect(view.calls, isEmpty);
      await finish(tester);
    });

    testWidgets('leaving stops watching; going back keeps watching', (tester) async {
      final view = await openView(tester, liveShare);
      view.show(ShareViewPhase.watching);
      await settle(tester);
      await tapKey(tester, 'share-view-back');
      expect(left, ['screen']);
      expect(view.calls, isEmpty, reason: 'the view goes on while its screen is not in front');
      expect(ShareViews.of(_live), same(view));

      await tapKey(tester, 'share-view-leave');
      expect(view.calls, ['leave', 'dispose']);
      expect(ShareViews.of(_live), isNull);
      expect(left, ['screen', 'screen']);
      await finish(tester);
    });

    testWidgets('every way it can end is said in words, with one thing to do', (tester) async {
      final view = await openView(tester, liveShare);
      final who = 'dana@example.com';
      for (final (end, text) in [
        (ShareViewEnd.stopped, l10n.shareEndStopped(who)),
        (ShareViewEnd.sessionClosed, l10n.shareEndSessionClosed),
        (ShareViewEnd.removed, l10n.shareEndRemoved(who)),
        (ShareViewEnd.notFound, l10n.shareEndNotFound),
        (ShareViewEnd.signedOut, l10n.shareEndSignedOut),
        (ShareViewEnd.elsewhere, l10n.shareEndElsewhere),
        (ShareViewEnd.full, l10n.shareEndFull),
        (ShareViewEnd.refused, l10n.shareEndRefused(who)),
        (ShareViewEnd.failed, l10n.shareEndFailed),
        (ShareViewEnd.ended, l10n.shareEndEnded),
        (ShareViewEnd.left, l10n.shareEndEnded),
      ]) {
        view.show(ShareViewPhase.ended, end: end);
        await settle(tester);
        expect(find.text(text), findsOneWidget, reason: end.name);
        expect(find.byKey(const ValueKey('share-view-leave')), findsNothing, reason: 'there is nothing to leave');
        expect(find.byType(TerminalView), findsNothing);
      }
      expect(ShareViewEnd.values.length, 11, reason: 'a new way to end needs its sentence here');
      await tapKey(tester, 'share-view-close');
      expect(left, ['screen']);
      expect(ShareViews.of(_live), isNull);
      await finish(tester);
    });

    testWidgets('a view this device does not have (the app was restarted): it says it ended', (tester) async {
      await pumpApp(tester, child: ShareViewScreen(shareId: _live, onLeave: () => left.add('screen')));
      expect(find.text(l10n.shareEndEnded), findsOneWidget);
      await tapKey(tester, 'share-view-close');
      expect(left, ['screen']);
      await finish(tester);
    });

    testWidgets('nobody named: a teammate, on a host in the Crate; and nothing real while recording', (tester) async {
      final dana = await tester.runAsync(AccountKeys.generate);
      final sam = await tester.runAsync(AccountKeys.generate);
      final nameless = (await tester.runAsync(() => incomingShare(
          shareId: _live, mode: ShareMode.live, from: dana!, to: sam!, fromEmail: null, hostLabel: null)))!;
      final view = await openView(tester, nameless);
      expect(find.text(l10n.shareViewTitle(l10n.shareSomeone)), findsOneWidget);
      expect(find.text(l10n.shareInviteInCrate('Production')), findsOneWidget);
      view.show(ShareViewPhase.waitingForHost);
      await settle(tester);
      expect(find.text(l10n.shareViewWaiting(l10n.shareSomeone)), findsOneWidget);
      await finish(tester);

      SharedPreferences.setMockInitialValues({'recording_mode_enabled': true});
      prefs = await SharedPreferences.getInstance();
      Redactor.instance
        ..clearNames()
        ..enabled = true
        ..level = RedactLevel.layout
        ..registerNames(['Web 1']);
      ShareViews.reset();
      final masked = await openView(tester, liveShare);
      masked.show(ShareViewPhase.ended, end: ShareViewEnd.stopped);
      await settle(tester);
      final all = rendered(tester).join('\n');
      expect(all, isNot(contains('dana@example.com')));
      expect(all, isNot(contains('Web 1')));
      await finish(tester);
    });

    testWidgets('on a phone the title is whole: Leave is its icon alone, its word the tooltip', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final view = await openView(tester, liveShare, size: const Size(390, 844));
        view.show(ShareViewPhase.watching);
        await settle(tester);
        // It read "Session of dana@example.…" (found in a design review).
        final title = tester.renderObject<RenderParagraph>(
            find.descendant(of: find.byKey(const ValueKey('share-view-title')), matching: find.byType(RichText)));
        expect(title.didExceedMaxLines, isFalse);
        final leave = find.byKey(const ValueKey('share-view-leave'));
        expect(leave, findsOneWidget);
        expect(find.descendant(of: leave, matching: find.text(l10n.shareViewLeave)), findsNothing);
        expect(find.byTooltip(l10n.shareViewLeave), findsOneWidget);
        expect(tester.getSize(leave).width, tester.getSize(leave).height, reason: 'a square, as high as before');
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('on a small phone a wide terminal is drawn at a size that can be read, and pans', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final view = await openView(tester, liveShare, size: const Size(360, 640));
        view.terminal.resize(160, 48);
        view.show(ShareViewPhase.watching);
        await settle(tester);
        // Shrunk to fit 360, 160 columns would be a few pixels high: drawn
        // at the least size that can be read instead.
        final style = container.read(terminalStyleProvider);
        final terminal = find.byKey(const ValueKey('share-view-terminal-$_live'));
        final scale = tester.getSize(find.byType(FittedBox)).width / tester.getSize(terminal).width;
        expect(style.fontSize * scale, greaterThanOrEqualTo(11 - 0.01));
        // Not cut off: it pans, to its right edge and back.
        final pan = find.byKey(const ValueKey('share-view-pan'));
        expect(pan, findsOneWidget);
        expect(tester.getRect(find.byType(FittedBox)).left, greaterThanOrEqualTo(0));
        await tester.drag(pan, const Offset(-2000, 0));
        await settle(tester);
        expect(tester.getRect(find.byType(FittedBox)).right, lessThanOrEqualTo(360));
        expect(find.byKey(const ValueKey('share-view-ask')), findsOneWidget);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('panned, a drag up and down goes to one thing: the history while it can go that way, then the view',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final view = await openView(tester, liveShare, size: const Size(360, 640));
        view.terminal.resize(160, 48);
        // History above the screen: more lines than it shows.
        view.terminal.write(List.generate(200, (i) => 'line $i').join('\r\n'));
        view.show(ShareViewPhase.watching);
        await settle(tester);
        final terminal = find.byKey(const ValueKey('share-view-terminal-$_live'));
        expect(find.byKey(const ValueKey('share-view-pan')), findsOneWidget);
        final history = tester
            .stateList<ScrollableState>(find.descendant(of: terminal, matching: find.byType(Scrollable)))
            .first
            .position;
        // (A point on the screen: the terminal is wider than it.)
        double viewTop() => tester.getRect(find.byType(FittedBox)).top;
        final top = viewTop();
        final latest = history.pixels;
        expect(latest, greaterThan(0), reason: 'the newest lines are on screen, history above them');

        // The finger up: the history is at its newest already, so the view
        // moves up to show the terminal's lower rows; the history stays.
        await tester.dragFrom(const Offset(180, 300), const Offset(0, -200));
        await settle(tester);
        expect(viewTop(), lessThan(top), reason: 'the view moved to the lower rows');
        expect(history.pixels, latest);
        final moved = viewTop();

        // The finger down: the history scrolls back, and the view does not
        // move with it.
        await tester.dragFrom(const Offset(180, 300), const Offset(0, 120));
        await settle(tester);
        expect(history.pixels, lessThan(latest), reason: 'the history scrolled back');
        expect(viewTop(), moved, reason: 'one drag, one thing moved');
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('panned, in the alternate screen (vim, less) a drag up moves the view', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final view = await openView(tester, liveShare, size: const Size(360, 640));
        view.terminal.resize(160, 48);
        view.terminal.write('\x1b[?1049h');
        view.show(ShareViewPhase.watching);
        await settle(tester);
        expect(view.terminal.isUsingAltBuffer, isTrue);
        final terminal = find.byKey(const ValueKey('share-view-terminal-$_live'));
        expect(tester.getRect(terminal).contains(const Offset(180, 300)), isTrue, reason: 'the drag is on the terminal');
        double viewTop() => tester.getRect(find.byType(FittedBox)).top;
        final top = viewTop();
        await tester.dragFrom(const Offset(180, 300), const Offset(0, -200));
        await settle(tester);
        expect(viewTop(), lessThan(top), reason: 'the view moved to the lower rows');
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('shared with you', () {
    Future<void> openInvitations(WidgetTester tester, List<IncomingShare> shares, {Size? size}) async {
      await pumpApp(tester, open: (c) => showShareInvitations(c), size: size ?? const Size(1100, 760));
      invitations().show(shares);
      await tapKey(tester, 'open');
    }

    testWidgets('nothing waiting says so, and the list is asked for again as it opens', (tester) async {
      await openInvitations(tester, const []);
      expect(find.text(l10n.shareInvitesTitle), findsOneWidget);
      expect(find.text(l10n.shareInvitesEmpty), findsOneWidget);
      expect(invitations().refreshes, 1);
      // No footer: the header's close closes it.
      expect(find.byKey(const ValueKey('zest-dialog-primary')), findsNothing);
      await tester.tap(find.byTooltip(l10n.close).last);
      await settle(tester);
      expect(find.byType(ShareInvitationsDialog), findsNothing);
      await finish(tester);
    });

    testWidgets('each invitation says who, where and what joining means', (tester) async {
      await openInvitations(tester, [liveShare, tmuxShare, changedShare]);
      const who = 'dana@example.com';
      expect(find.text(l10n.shareInviteLive(who)), findsNWidgets(2));
      expect(find.text(l10n.shareInviteTmux(who)), findsOneWidget);
      expect(find.text(l10n.shareInviteOn('Web 1', 'Production')), findsNWidgets(3));
      expect(find.text(l10n.shareInviteLiveHow), findsNWidgets(2));
      expect(find.text(l10n.shareInviteTmuxHow('shared-k7q', 'deploy')), findsOneWidget);
      expect(find.text(l10n.shareInvitesEmpty), findsNothing);
      // Keys that changed since they were compared: said, and not joined.
      expect(find.text(l10n.shareInviteKeysChanged(who)), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('share-join-$_changed')));
      await tapKey(tester, 'share-join-$_changed');
      expect(joining().asked, isEmpty);
      // Declining takes it off the list.
      await tapKey(tester, 'share-decline-$_changed');
      expect(invitations().declined, [_changed]);
      expect(find.byKey(const ValueKey('share-invite-$_changed')), findsNothing);
      expect(find.byKey(const ValueKey('share-invite-$_live')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('someone asked to watch, and someone who may end the session, are told what joining means',
        (tester) async {
      final dana = (await tester.runAsync(AccountKeys.generate))!;
      final sam = (await tester.runAsync(AccountKeys.generate))!;
      const watchId = '11111111-1111-4111-8111-000000000008';
      const endId = '11111111-1111-4111-8111-000000000009';
      final toWatch = (await tester.runAsync(
          () => incomingShare(shareId: watchId, mode: ShareMode.live, from: dana, to: sam, mayEnd: true, watched: true)))!;
      // Invited to end it in a Crate that is not watched, and invited to an
      // ordinary live view of a watched Crate's session.
      final toEnd = (await tester.runAsync(
          () => incomingShare(shareId: endId, mode: ShareMode.live, from: dana, to: sam, mayEnd: true)))!;
      final plain = (await tester.runAsync(
          () => incomingShare(shareId: _live, mode: ShareMode.live, from: dana, to: sam, watched: true)))!;
      await pumpApp(tester, open: showShareInvitations);
      invitations().show([toWatch, toEnd, plain]);
      await tapKey(tester, 'open');
      Finder inCard(String id, String text) =>
          find.descendant(of: find.byKey(ValueKey('share-invite-$id')), matching: find.text(text));

      expect(inCard(watchId, l10n.shareInviteWatch('dana@example.com')), findsOneWidget);
      expect(inCard(watchId, l10n.shareInviteWatchHow('Production')), findsOneWidget);
      expect(l10n.shareInviteWatchHow('Production'), contains('starts when you join'));
      expect(inCard(endId, l10n.shareInviteLive('dana@example.com')), findsOneWidget);
      expect(inCard(endId, l10n.shareInviteLiveHowCanEnd), findsOneWidget);
      expect(inCard(_live, l10n.shareInviteLive('dana@example.com')), findsOneWidget);
      expect(inCard(_live, l10n.shareInviteLiveHow), findsOneWidget);
      await finish(tester);
    });

    testWidgets('watching a live view opens its screen; one that cannot be joined says so', (tester) async {
      await openInvitations(tester, [liveShare]);
      // This device cannot join right now (no account keys here).
      await tapKey(tester, 'share-join-$_live');
      expect(joining().asked, [_live]);
      expect(lastNotice(), l10n.shareFailedNotReady);
      expect(find.byType(ShareInvitationsDialog), findsOneWidget);

      final view = FakeView()..show(ShareViewPhase.watching);
      joining().views[_live] = view;
      await tapKey(tester, 'share-join-$_live');
      expect(find.byType(ShareInvitationsDialog), findsNothing);
      expect(find.byType(ShareViewScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('share-view-terminal-$_live')), findsOneWidget);
      // Back, and "Shared with you" again: it is under "Watching now", and
      // not among the invitations a second time.
      await tapKey(tester, 'share-view-back');
      expect(left, ['view']);
      await tapKey(tester, 'open');
      expect(find.text(l10n.shareWatchingNow.toUpperCase()), findsOneWidget);
      expect(find.byKey(const ValueKey('share-watching-$_live')), findsOneWidget);
      expect(find.byKey(const ValueKey('share-invite-$_live')), findsNothing);
      await tapKey(tester, 'share-open-$_live');
      expect(find.byType(ShareViewScreen), findsOneWidget);
      await tapKey(tester, 'share-view-back');
      // Leaving from the list stops watching; it is an invitation again.
      await tapKey(tester, 'open');
      await tapText(tester, l10n.shareViewLeave);
      expect(view.calls, ['leave', 'dispose']);
      expect(find.byKey(const ValueKey('share-watching-$_live')), findsNothing);
      expect(find.byKey(const ValueKey('share-invite-$_live')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a view that ended is not "watching now": its invitation is one to join again', (tester) async {
      await openInvitations(tester, [liveShare]);
      final view = FakeView()..show(ShareViewPhase.watching);
      joining().views[_live] = view;
      await tapKey(tester, 'share-join-$_live');
      await tapKey(tester, 'share-view-back');
      // This account joined from another device meanwhile: the view here is
      // over, and the invitation still stands.
      view.show(ShareViewPhase.ended, end: ShareViewEnd.elsewhere);
      await tapKey(tester, 'open');
      expect(find.text(l10n.shareWatchingNow.toUpperCase()), findsNothing);
      expect(find.byKey(const ValueKey('share-watching-$_live')), findsNothing);
      expect(find.byKey(const ValueKey('share-invite-$_live')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('joining a shared tmux session opens the session, or says why it cannot', (tester) async {
      await openInvitations(tester, [tmuxShare]);
      for (final (problem, message) in [
        (ShareTmuxJoinProblem.hostMissing, l10n.shareTmuxHostMissing),
        (ShareTmuxJoinProblem.noSession, l10n.shareTmuxNoSession),
        (ShareTmuxJoinProblem.orchardClosed, l10n.shareFailedNotReady),
      ]) {
        tmuxJoins.answer = (null, problem);
        await tapKey(tester, 'share-join-$_tmux');
        expect(lastNotice(), message, reason: problem.name);
        expect(find.byType(ShareInvitationsDialog), findsOneWidget);
      }
      tmuxJoins.answer = ('s9', null);
      await tapKey(tester, 'share-join-$_tmux');
      expect(tmuxJoins.asked, hasLength(4));
      expect(find.byType(ShareInvitationsDialog), findsNothing);
      expect(joining().asked, isEmpty, reason: 'a shared tmux session is not watched');
      await finish(tester);
    });

    testWidgets('on a phone it is a sheet, and everything on it can be reached', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await openInvitations(tester, [liveShare, tmuxShare, changedShare], size: const Size(360, 640));
        expect(find.text(l10n.shareInvitesTitle), findsOneWidget);
        await tester.ensureVisible(find.byKey(const ValueKey('share-decline-$_changed')));
        await tapKey(tester, 'share-decline-$_changed');
        expect(invitations().declined, [_changed]);
        await finish(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}

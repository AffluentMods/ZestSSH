// Session sharing in the running app (share_app_hooks.dart): when the list
// of invitations is looked at again, what is announced and with which
// words, and what signing out ends. The list is only asked for in a build
// with Orchards on: run with
//   flutter test --dart-define=ZEST_ORCHARDS=true

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_nudges.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/sharing/share_app_hooks.dart';
import 'package:zestssh/ui/screens/sharing/share_invitations.dart';
import 'package:zestssh/ui/screens/sharing/share_widgets.dart';
import 'package:zestssh/ui/screens/sharing/watch_ui.dart';

import '../visual/shots_util.dart';
import 'sharing_ui_fakes.dart';

const _orchard = '22222222-2222-4222-8222-222222222222';
const _live = '11111111-1111-4111-8111-000000000001';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

final _user = StateProvider<UserProfile?>((ref) => const UserProfile(uid: 'uid-sam', email: 'sam@example.com'));

/// The app's root, as far as sharing goes: it owns the hooks.
class _Root extends ConsumerStatefulWidget {
  const _Root();

  @override
  ConsumerState<_Root> createState() => _RootState();
}

class _RootState extends ConsumerState<_Root> {
  final navigator = GlobalKey<NavigatorState>();
  late final hooks = ShareAppHooks(ref, () => navigator.currentContext);

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: Center(child: Text('home'))),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late ProviderContainer container;
  late _MemoryStorage storage;
  late FakeTmuxJoins tmuxJoins;
  late IncomingShare share;

  setUpAll(() async {
    final dana = await AccountKeys.generate();
    final sam = await AccountKeys.generate();
    share = await incomingShare(shareId: _live, mode: ShareMode.live, from: dana, to: sam);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    ShareViews.reset();
    shareNoticeHandler = null;
    watchAskHandler = null;
    watchNoticeHandler = null;
    unwatchedAskHandler = null;
    storage = _MemoryStorage();
    tmuxJoins = FakeTmuxJoins();
  });

  tearDown(() async {
    shareNoticeHandler = null;
    watchAskHandler = null;
    watchNoticeHandler = null;
    unwatchedAskHandler = null;
    SessionShares.reset();
    ShareViews.reset();
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  FakeInvitations invitations() => container.read(shareInvitationsProvider.notifier) as FakeInvitations;
  List<AppNotification> notices() => container.read(notificationCenterProvider).history;

  Future<ShareAppHooks> pumpRoot(WidgetTester tester) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1100, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      currentUserProvider.overrideWith((ref) => ref.watch(_user)),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      tmuxHostProvider.overrideWith((ref, sessionId) => FakeTmux()),
      shareInvitationsProvider.overrideWith(FakeInvitations.new),
      shareJoiningProvider.overrideWith(FakeJoining.new),
      shareTmuxJoinsProvider.overrideWithValue(tmuxJoins),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const _Root()));
    await tester.pump();
    return tester.state<_RootState>(find.byType(_Root)).hooks;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  String skip() => 'run with --dart-define=ZEST_ORCHARDS=true';

  testWidgets('the list is looked at when ZestSSH Cloud nudges, an Orchard opens or closes, and the app comes to the front',
      (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    // Not started: nothing listens.
    shareInviteNudges.add(null);
    hooks.onForeground();
    await settle(tester);
    expect(invitations().refreshes, 0);

    hooks.start();
    await settle(tester);
    expect(invitations().refreshes, 0, reason: 'no Orchard is open: there is nothing to look for yet');
    shareInviteNudges.add(null);
    await settle(tester);
    expect(invitations().refreshes, 1);
    // Started twice is started once.
    hooks.start();
    shareInviteNudges.add(null);
    await settle(tester);
    expect(invitations().refreshes, 2);

    // An Orchard opens on this device: what waits in it can be opened now.
    await tester.runAsync(() => container.read(orchardDatabasesProvider.notifier).open(_orchard));
    await settle(tester);
    expect(invitations().refreshes, 3);
    // It closes (the app locked): what was listed for it goes.
    await tester.runAsync(() => container.read(orchardDatabasesProvider.notifier).close(_orchard));
    await settle(tester);
    expect(invitations().refreshes, 4);

    hooks.onForeground();
    await settle(tester);
    expect(invitations().refreshes, 5);

    // Stopped: nothing listens any more.
    hooks.stop();
    shareInviteNudges.add(null);
    hooks.onForeground();
    await tester.runAsync(() => container.read(orchardDatabasesProvider.notifier).open(_orchard));
    await settle(tester);
    expect(invitations().refreshes, 5);
    expect(shareNoticeHandler, isNull);
    await finish(tester);
  });

  testWidgets('a new invitation is announced without naming anyone or any host, and opens the list', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    hooks.start();
    invitations().show([share]);
    invitations().onNew!(share);
    await settle(tester);
    final notice = notices().single;
    expect((notice.id, notice.title, notice.body, notice.actionLabel),
        ('share-invite-$_live', l10n.shareInviteNoticeTitle, l10n.shareInviteNoticeBody, l10n.shareInviteNoticeView));
    // The bell keeps its history outside the encrypted database.
    final said = '${notice.title} ${notice.body}';
    for (final secret in ['dana@example.com', 'Web 1', 'Production', 'deploy']) {
      expect(said, isNot(contains(secret)));
    }
    // A second word about the same share takes the place of the first.
    invitations().onNew!(share);
    await settle(tester);
    expect(notices(), hasLength(1));

    notice.onAction!();
    await settle(tester);
    expect(find.byType(ShareInvitationsDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('share-invite-$_live')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('what happens in a share of this device: a request for the keyboard and an end from outside are announced',
      (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    hooks.start();
    final shared = FakeShare()..show([guest('uid-kit', ShareGuestState.watching, asks: true)]);
    SessionShares.add('s1', shared, names: {'uid-kit': 'kit@example.com'});

    // What is routine is not announced.
    for (final note in [
      ShareNote.joined,
      ShareNote.left,
      ShareNote.declined,
      ShareNote.keyboardGiven,
      ShareNote.keyboardBack,
      ShareNote.stopped,
    ]) {
      shareNoticeHandler!('s1', note, 'kit@example.com');
    }
    await settle(tester);
    expect(notices(), isEmpty);

    shareNoticeHandler!('s1', ShareNote.askedKeyboard, 'kit@example.com');
    await settle(tester);
    final asked = notices().single;
    expect((asked.id, asked.title, asked.body, asked.severity),
        ('share-keyboard-s1', l10n.shareKeyboardNoticeTitle, l10n.shareKeyboardNoticeBody, NotificationSeverity.warning));
    expect('${asked.title} ${asked.body}', isNot(contains('kit@example.com')));
    asked.onAction!();
    await settle(tester);
    expect(find.byType(ShareParticipantsDialog), findsOneWidget);
    expect(find.byKey(const ValueKey('share-give-uid-kit')), findsOneWidget);
    Navigator.of(tester.element(find.byType(ShareParticipantsDialog))).pop();
    await settle(tester);

    shareNoticeHandler!('s1', ShareNote.endedElsewhere, null);
    await settle(tester);
    expect(notices().first.title, l10n.shareStoppedNotice);
    expect(notices().first.severity, NotificationSeverity.warning);

    // Someone else's shared tmux session that this device joined stopped.
    tmuxJoins.onEnded!(_live, ShareLineEnd.ended);
    await settle(tester);
    expect(notices().first.title, l10n.shareTmuxStoppedNotice);
    expect(notices(), hasLength(3));

    // Someone invited to end the session ended it: the person whose
    // session it was is told why it closed. Who it was is in the team's
    // log of the session, not in a notice the bell keeps.
    shareNoticeHandler!('s1', ShareNote.endAsked, 'kit@example.com');
    await settle(tester);
    final ended = notices().first;
    expect((ended.title, ended.severity), (l10n.shareEndedByNotice, NotificationSeverity.warning));
    expect('${ended.title} ${ended.body ?? ''}', isNot(contains('kit@example.com')));
    expect(notices(), hasLength(4));
    await finish(tester);
  });

  testWidgets('signing out ends everything shared and watched from this device, and forgets the invitations',
      (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    hooks.start();
    final shared = FakeShare()..show([guest('uid-kit', ShareGuestState.watching)]);
    SessionShares.add('s1', shared);
    final view = FakeView()..show(ShareViewPhase.watching);
    ShareViews.add(share, view);
    invitations().show([share]);
    await settle(tester);

    // Another account signs in: that is not a sign-out.
    container.read(_user.notifier).state = const UserProfile(uid: 'uid-sam', email: 'sam@example.org');
    await settle(tester);
    expect(shared.calls, isEmpty);

    container.read(_user.notifier).state = null;
    await settle(tester);
    expect(shared.calls, ['stop:stopped']);
    expect(SessionShares.active.value, isEmpty);
    expect(view.calls, ['leave', 'dispose']);
    expect(ShareViews.active.value, isEmpty);
    expect(tmuxJoins.left, 1);
    expect(container.read(shareInvitationsProvider), isEmpty);

    // Signed out already: signing in is nothing to end.
    container.read(_user.notifier).state = const UserProfile(uid: 'uid-sam');
    await settle(tester);
    expect(tmuxJoins.left, 1);
    await finish(tester);
  });

  testWidgets('watched sessions: whom to ask is asked on the screen in front, and a session that is held or closed '
      'is said', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    expect((watchAskHandler, watchNoticeHandler), (null, null));
    hooks.start();
    final request = WatchRequest(
      sessionId: 's1',
      host: const WatchedHost(orchardId: _orchard, crateId: '33333333-3333-4333-8333-333333333333', crateName: 'Production'),
      crateName: 'Production',
      hostLabel: 'Web 1',
      people: [candidate('uid-kit', 'kit@example.com', level: CrateLevel.manage)],
    );

    // Asked: the dialog, and what it answers.
    Set<String>? answer;
    var answered = false;
    final asking = watchAskHandler!(request).then((picked) {
      answer = picked;
      answered = true;
    });
    await settle(tester);
    expect(find.byType(WatchAskDialog), findsOneWidget);
    expect(find.text(l10n.watchAskSub('Web 1', 'Production')), findsOneWidget);
    await tester.tap(find.text(l10n.watchAskButton).last);
    await settle(tester);
    await asking;
    expect(answered, isTrue);
    expect(answer, {'uid-kit'});

    // What happens to a watched session: said once for each session, gone
    // when someone watches again, and named as closed when it is.
    watchNoticeHandler!('s1', WatchNote.held);
    watchNoticeHandler!('s1', WatchNote.held);
    watchNoticeHandler!('s2', WatchNote.held);
    await settle(tester);
    expect([for (final n in notices()) (n.id, n.title, n.severity)], [
      ('watch-held-s2', l10n.watchHeldNotice, NotificationSeverity.warning),
      ('watch-held-s1', l10n.watchHeldNotice, NotificationSeverity.warning),
    ]);
    watchNoticeHandler!('s1', WatchNote.watchedAgain);
    await settle(tester);
    expect([for (final n in notices()) n.id], ['watch-held-s2']);
    // Let go on with nobody watching: typing is held no longer, so the
    // word that it is goes. Held again later, it is said again.
    watchNoticeHandler!('s2', WatchNote.unwatched);
    await settle(tester);
    expect(notices(), isEmpty);
    watchNoticeHandler!('s2', WatchNote.held);
    await settle(tester);
    expect([for (final n in notices()) n.id], ['watch-held-s2']);
    watchNoticeHandler!('s2', WatchNote.closedUnwatched);
    await settle(tester);
    expect([for (final n in notices()) (n.title, n.severity)],
        [(l10n.watchClosedNotice, NotificationSeverity.warning)]);

    // Stopped (the app's root went): nobody is there to ask.
    hooks.stop();
    expect((watchAskHandler, watchNoticeHandler), (null, null));
    await finish(tester);
  });

  testWidgets('going on with nobody watching: why is asked on the screen in front, once for a session at a time',
      (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final hooks = await pumpRoot(tester);
    expect(unwatchedAskHandler, isNull);
    hooks.start();
    UnwatchedRequest why(String sessionId, {bool held = false}) => UnwatchedRequest(
          sessionId: sessionId,
          host: const WatchedHost(
              orchardId: _orchard, crateId: '33333333-3333-4333-8333-333333333333', crateName: 'Production'),
          crateName: 'Production',
          hostLabel: 'Web 1',
          held: held,
        );
    Finder field() =>
        find.descendant(of: find.byKey(const ValueKey('unwatched-ask-reason')), matching: find.byType(EditableText));

    // Asked: the question, and what it answers.
    String? answer = 'not answered';
    final asking = unwatchedAskHandler!(why('s1')).then((given) => answer = given);
    await settle(tester);
    expect(find.byType(UnwatchedAskDialog), findsOneWidget);
    expect(find.text(l10n.unwatchedAskSub('Production', 'Web 1')), findsOneWidget);
    // Asked again for the same session while that is open (pressed twice):
    // given up at once, with no second question over the first.
    String? second = 'not answered';
    unawaited(unwatchedAskHandler!(why('s1', held: true)).then((given) => second = given));
    await settle(tester);
    expect(second, isNull);
    expect(find.byType(UnwatchedAskDialog), findsOneWidget);
    await tester.enterText(field(), 'restoring the database');
    await settle(tester);
    await tester.tap(find.text(l10n.unwatchedAskConnect).last);
    await settle(tester);
    await asking;
    expect(answer, 'restoring the database');
    expect(find.byType(UnwatchedAskDialog), findsNothing);

    // Answered: the same session can be asked again, and giving up is null.
    final again = unwatchedAskHandler!(why('s1', held: true)).then((given) => answer = given);
    await settle(tester);
    expect(find.text(l10n.unwatchedAskTitleHeld), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await again;
    expect(answer, isNull);

    // Stopped (the app's root went): nobody is there to ask.
    hooks.stop();
    expect(unwatchedAskHandler, isNull);
    await finish(tester);
  });

  testWidgets('with no screen to ask on, nobody is asked why, and nothing goes on', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    await tester.pumpWidget(const SizedBox());
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    late final WidgetRef held;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (context, ref, _) {
        held = ref;
        return const SizedBox();
      }),
    ));
    final hooks = ShareAppHooks(held, () => null)..start();
    expect(
        await unwatchedAskHandler!(const UnwatchedRequest(
          sessionId: 's1',
          host: WatchedHost(orchardId: _orchard, crateId: '33333333-3333-4333-8333-333333333333', crateName: ''),
          crateName: 'Production',
          hostLabel: 'Web 1',
        )),
        isNull);
    hooks.stop();
    await finish(tester);
  });

  testWidgets('someone asked to watch a session of a watched Crate is told that, and nobody is named', (tester) async {
    if (!kOrchardsEnabled) return markTestSkipped(skip());
    final dana = (await tester.runAsync(AccountKeys.generate))!;
    final sam = (await tester.runAsync(AccountKeys.generate))!;
    final asked = (await tester.runAsync(() => incomingShare(
        shareId: _live, mode: ShareMode.live, from: dana, to: sam, mayEnd: true, watched: true)))!;
    final mayEnd = (await tester.runAsync(() => incomingShare(
        shareId: '11111111-1111-4111-8111-000000000007', mode: ShareMode.live, from: dana, to: sam, mayEnd: true)))!;
    expect((asked.asksToWatch, mayEnd.asksToWatch, share.asksToWatch), (true, false, false));
    final hooks = await pumpRoot(tester);
    hooks.start();
    invitations().show([asked, mayEnd]);
    invitations().onNew!(asked);
    invitations().onNew!(mayEnd);
    await settle(tester);
    expect({for (final n in notices()) n.id: n.title}, {
      'share-invite-$_live': l10n.shareWatchNoticeTitle,
      'share-invite-11111111-1111-4111-8111-000000000007': l10n.shareInviteNoticeTitle,
    });
    for (final n in notices()) {
      expect('${n.title} ${n.body}', isNot(contains('dana@example.com')));
      expect('${n.title} ${n.body}', isNot(contains('Production')));
    }
    await finish(tester);
  });

  testWidgets('with Orchards off, nothing is listened to and nothing is asked', (tester) async {
    if (kOrchardsEnabled) return markTestSkipped('this is the build without Orchards');
    final hooks = await pumpRoot(tester);
    hooks.start();
    shareInviteNudges.add(null);
    hooks.onForeground();
    await settle(tester);
    expect(invitations().refreshes, 0);
    expect(invitations().onNew, isNull);
    expect(shareNoticeHandler, isNull);
    expect((watchAskHandler, watchNoticeHandler), (null, null));
    hooks.stop();
    await finish(tester);
  });
}

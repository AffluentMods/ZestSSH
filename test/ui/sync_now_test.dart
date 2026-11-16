import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/ui/screens/sync/sync_now.dart';

class _Sync extends Fake implements AutoSyncService {
  int calls = 0;
  Object? error;
  Completer<void>? hold;

  // What a pause of the background sync is said from.
  @override
  final ValueNotifier<String?> syncError = ValueNotifier<String?>(null);
  @override
  String? syncErrorDetail;
  @override
  bool syncErrorNeedsPassword = false;
  @override
  bool syncErrorNeedsSetup = false;
  @override
  bool syncErrorNeedsDeviceRoom = false;
  @override
  bool syncErrorFromManualRun = false;

  @override
  Future<int> syncNowManual() async {
    calls++;
    if (hold != null) await hold!.future;
    if (error != null) throw error!;
    return 7;
  }
}

class _Backend extends Fake implements SyncBackend {
  Object? error;

  @override
  Future<SyncStatus> getStatus() async {
    if (error != null) throw error!;
    return const SyncStatus(hasData: true, version: 7, blobSize: 4096);
  }
}

/// "Sync now" in Settings and on the Tree page (3.0):
/// both only said "Syncing..." or where else to look, and synced nothing.
/// They run the same pull, merge and push as the background sync now, and
/// say what happened.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  late _Sync sync;
  late _Backend backend;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    sync = _Sync();
    backend = _Backend();
  });

  Future<ProviderContainer> open(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        autoSyncServiceProvider.overrideWithValue(sync),
        syncBackendProvider.overrideWithValue(backend),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => runSyncNow(context, ref),
              child: const Text('sync'),
            ),
          ),
        ),
      ),
    ));
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  }

  List<String> said(ProviderContainer c) => [for (final n in c.read(notificationCenterProvider).history) n.title];

  testWidgets('syncs, and says the version this device is at', (tester) async {
    final c = await open(tester);
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.pump();
    expect(sync.calls, 1);
    expect(said(c), contains(en.profileSyncedVersion(7)));
    final state = c.read(syncStatusProvider);
    expect(state.isSyncing, isFalse);
    expect(state.lastSyncedAt, isNotNull);
    expect(state.blobSize, 4096);
    expect(state.error, isNull);
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('not set up on this device, says so', (tester) async {
    sync.error = SyncSetupRequiredException(en.syncNowNotSetUp);
    final c = await open(tester);
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.pump();
    final notice = c.read(notificationCenterProvider).history.first;
    expect(notice.title, en.syncNowNotSetUp);
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.actionLabel, isNull, reason: 'the account page\'s Sync now would not help: sync is not set up here');
    expect(notice.onAction, isNull);
    expect(said(c), isNot(contains(en.profileSyncedVersion(7))));
    expect(c.read(syncStatusProvider).error, en.syncNowNotSetUp);
    expect(c.read(syncStatusProvider).lastSyncedAt, isNull);
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('stopped, says why with what stands behind it to copy', (tester) async {
    sync.error = const SocketException('Connection refused');
    final c = await open(tester);
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.pump();
    final state = c.read(syncStatusProvider);
    expect(state.error, isNotNull);
    expect(state.isSyncing, isFalse);
    final notice = c.read(notificationCenterProvider).history.first;
    // A long message is a title and a body on a computer: together they are
    // what the Account page says.
    expect([notice.title, if (notice.body != null) notice.body].join(' '), state.error);
    expect(state.error, endsWith(')'), reason: 'it ends in its code');
    expect(notice.severity, NotificationSeverity.error);
    expect(notice.details, contains('Connection refused'));
    expect(notice.actionLabel, isNull);
    expect(state.lastSyncedAt, isNull);
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('a store status that cannot be read after does not undo the sync', (tester) async {
    backend.error = const SocketException('Connection reset');
    final c = await open(tester);
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.pump();
    expect(said(c), contains(en.profileSyncedVersion(7)));
    final state = c.read(syncStatusProvider);
    expect(state.lastSyncedAt, isNotNull);
    expect(state.error, isNull);
    await tester.pump(const Duration(seconds: 8));
  });

  testWidgets('a tap while one runs starts no second one', (tester) async {
    sync.hold = Completer<void>();
    final c = await open(tester);
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.tap(find.text('sync'));
    await tester.pump();
    expect(sync.calls, 1);
    expect(c.read(syncStatusProvider).isSyncing, isTrue);
    sync.hold!.complete();
    await tester.pump();
    await tester.pump();
    expect(c.read(syncStatusProvider).isSyncing, isFalse);
    sync.hold = null;
    await tester.tap(find.text('sync'));
    await tester.pump();
    await tester.pump();
    expect(sync.calls, 2, reason: 'once it is done, the next tap syncs');
    await tester.pump(const Duration(seconds: 8));
  });

  // 3.0: a device whose sync keys were no
  // longer the account's was told a server could not be reached, over and
  // over. It is told what happened, and the way out is one press away.
  group('keys that are no longer the account\'s', () {
    /// A notice's words, as one text (a long one is a title and a body).
    String words(AppNotification n) => [n.title, if (n.body != null) n.body!].join(' ');

    testWidgets('the notice offers "Sync now", which asks for the account page\'s own', (tester) async {
      sync.error = SyncKeysMismatchException(en.syncKeysNoLongerMatch);
      final c = await open(tester);
      await tester.tap(find.text('sync'));
      await tester.pump();
      await tester.pump();
      final notice = c.read(notificationCenterProvider).history.first;
      expect(words(notice), en.syncKeysNoLongerMatch);
      expect(notice.severity, NotificationSeverity.error);
      expect(notice.actionLabel, en.accountSyncNow, reason: 'the button the message names');
      expect(c.read(accountSyncNowRequestProvider), isFalse, reason: 'nothing is asked until it is pressed');
      notice.onAction!();
      expect(c.read(accountSyncNowRequestProvider), isTrue);
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgets('the button still asks after the screen it was raised on is gone', (tester) async {
      sync.error = SyncKeysMismatchException(en.syncKeysNoLongerMatch);
      final c = await open(tester);
      await tester.tap(find.text('sync'));
      await tester.pump();
      await tester.pump();
      final notice = c.read(notificationCenterProvider).history.first;
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .pushReplacement(MaterialPageRoute<void>(builder: (_) => const SizedBox()));
      await tester.pump();
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('sync'), findsNothing);
      notice.onAction!();
      expect(c.read(accountSyncNowRequestProvider), isTrue);
    });

    test('asked again while a request was never answered, it is asked anew', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      var heard = 0;
      c.listen<bool>(accountSyncNowRequestProvider, (_, asked) {
        if (asked) heard++;
      });
      final request = c.read(accountSyncNowRequestProvider.notifier);
      requestAccountSyncNow(request);
      expect(heard, 1);
      expect(c.read(accountSyncNowRequestProvider), isTrue);
      requestAccountSyncNow(request);
      expect(heard, 2);
      expect(c.read(accountSyncNowRequestProvider), isTrue);
    });

    testWidgets('the account page is opened for a request nobody took, and not when one was taken', (tester) async {
      late BuildContext context;
      late WidgetRef ref;
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Consumer(builder: (c, r, _) {
            context = c;
            ref = r;
            return const Scaffold();
          }),
        ),
      ));
      final c = ProviderScope.containerOf(context);
      // An account page on screen took the request the moment it was made.
      openAccountForSyncNow(context, ref);
      expect(c.read(settingsJumpProvider), isNull);
      expect(c.read(settingsPopupOpenProvider), isFalse);
      // Nobody took it: on a computer the account is a section of Settings,
      // which is a pop-up over whatever is shown, so no page is left for it.
      requestAccountSyncNow(c.read(accountSyncNowRequestProvider.notifier));
      openAccountForSyncNow(context, ref);
      expect(c.read(settingsJumpProvider), SettingsJumpTarget.account);
      expect(c.read(settingsPopupOpenProvider), isTrue);
      expect(c.read(activeSidebarNavProvider), NavSection.hosts, reason: 'the page shown stays the one shown');
      expect(c.read(accountSyncNowRequestProvider), isTrue, reason: 'the page takes it back when it is on screen');
    });
  });

  group('the background sync paused', () {
    ProviderContainer center() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('with nothing to say, nothing is said', () {
      final c = center();
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier), onSyncNow: () {});
      expect(said, isFalse);
      expect(c.read(notificationCenterProvider).history, isEmpty);
    });

    test('in a run somebody asked for: the screen it was asked on says it, the app does not', () {
      final c = center();
      sync.syncError.value = en.syncKeysNoLongerMatch;
      sync.syncErrorNeedsPassword = true;
      sync.syncErrorFromManualRun = true;
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier), onSyncNow: () {});
      expect(said, isFalse);
      expect(c.read(notificationCenterProvider).history, isEmpty);
    });

    test('keys no longer the account\'s: it stays until it is closed and offers "Sync now"', () {
      final c = center();
      sync.syncError.value = en.syncKeysNoLongerMatch;
      sync.syncErrorDetail = '403 Sync verification failed';
      sync.syncErrorNeedsPassword = true;
      var pressed = 0;
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier), onSyncNow: () => pressed++);
      expect(said, isTrue);
      final notice = c.read(notificationCenterProvider).history.single;
      expect(notice.title, en.syncPausedTitle);
      expect(notice.body, en.syncKeysNoLongerMatch);
      expect(notice.severity, NotificationSeverity.error);
      expect(notice.effectiveDismissDuration, Duration.zero, reason: 'it waits for the person to act');
      expect(notice.actionLabel, en.accountSyncNow);
      expect(notice.details, contains('403 Sync verification failed'));
      expect(notice.details, contains('Syncing'));
      notice.onAction!();
      expect(pressed, 1);
    });

    test('the cloud copy gone: it stays until it is closed and offers "Set up sync again", the same press', () {
      final c = center();
      sync.syncError.value = en.syncWasReset;
      sync.syncErrorDetail = '426 SYNC_WAS_RESET';
      sync.syncErrorNeedsSetup = true;
      var pressed = 0;
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier), onSyncNow: () => pressed++);
      expect(said, isTrue);
      final notice = c.read(notificationCenterProvider).history.single;
      expect(notice.title, en.syncPausedTitle);
      expect(notice.body, en.syncWasReset);
      expect(notice.effectiveDismissDuration, Duration.zero, reason: 'it waits for the person to act');
      expect(notice.actionLabel, en.syncSetUpAgain);
      expect(notice.actionLabel, isNot(en.accountSyncNow), reason: 'there is nothing to sync with: it says what the press leads to');
      expect(notice.details, contains('426 SYNC_WAS_RESET'));
      notice.onAction!();
      expect(pressed, 1, reason: 'the account page\'s Sync now finds the store empty and asks before setting up anew');
    });

    test('past the devices ZestSSH Cloud syncs for one person: it stays and offers "Sign out a device", '
        'never "Set up sync again"', () {
      final c = center();
      sync.syncError.value = en.syncCloudDeviceLimit;
      sync.syncErrorNeedsDeviceRoom = true;
      var room = 0;
      var syncNow = 0;
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier),
          onSyncNow: () => syncNow++, onMakeRoom: () => room++);
      expect(said, isTrue);
      final notice = c.read(notificationCenterProvider).history.single;
      expect(notice.effectiveDismissDuration, Duration.zero, reason: 'it waits for the person to act');
      expect(notice.actionLabel, en.syncDeviceRoomAction);
      notice.onAction!();
      expect((room, syncNow), (1, 0));
    });

    test('any other pause: said with what stands behind it, closing by itself, with no button', () {
      final c = center();
      sync.syncError.value = en.syncMergeFailed;
      sync.syncErrorDetail = 'a format from a newer version';
      final said = showSyncPausedNotice(sync, c.read(notificationCenterProvider.notifier), onSyncNow: () {});
      expect(said, isTrue);
      final notice = c.read(notificationCenterProvider).history.single;
      expect(notice.title, en.syncPausedTitle);
      expect(notice.body, en.syncMergeFailed);
      // Ten seconds, or as long as its words take to read where that is
      // longer (the 4.0 accessibility pass).
      expect(notice.effectiveDismissDuration, greaterThanOrEqualTo(const Duration(seconds: 10)));
      expect(notice.actionLabel, isNull);
      expect(notice.onAction, isNull);
      expect(notice.details, contains('a format from a newer version'));
    });

    test('the app\'s root says a pause through this, and opens the account page when asked', () {
      final app = File('lib/app.dart').readAsStringSync();
      expect(app, contains('_syncErrorShown = showSyncPausedNotice('));
      expect(app, contains('onSyncNow: () => requestAccountSyncNow(ref.read(accountSyncNowRequestProvider.notifier)),'));
      expect(app, contains('ref.listenManual<bool>(accountSyncNowRequestProvider, _onAccountSyncNowAsked);'));
      expect(app, contains('if (context != null) openAccountForSyncNow(context, ref);'));
    });
  });

  test('Settings and the Tree page sync through it', () {
    final settings = File('lib/ui/screens/settings/settings_screen.dart').readAsStringSync();
    expect(settings, contains('onTap: () => runSyncNow(context, ref),'));
    final tree = File('lib/ui/screens/tree/manage_tree_screen.dart').readAsStringSync();
    expect(tree, contains('? () => runSyncNow(context, ref)'));
    expect(tree, isNot(contains('_triggerSync')));
  });
}

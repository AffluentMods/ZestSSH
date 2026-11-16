import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

import 'fake_crate_server.dart';

/// An account in no team hears of an invitation without opening anything
/// at all: the server tells the live line the moment
/// someone invites it, but the line is open only while the account is in a
/// team, and its invitations were read otherwise only every quarter of an
/// hour, so the switcher's dot did not show until the person opened their
/// invitations. Now they are read on a short timer while the line is
/// closed, and at once when the app comes back to the front, only they
/// and not a whole sync; and each new one is told once in the bell, never
/// twice, also after a restart.

class _MemoryStorage implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

/// Counts the reads of the invitations.
class _Server extends FakeCrateServer {
  var reads = 0;

  @override
  Future<List<MyInvite>> myInvites() {
    reads++;
    return super.myInvites();
  }
}

/// Records whole syncs instead of making them: an account in no Orchard.
class _Recorder extends OrchardSyncCoordinator {
  _Recorder({required super.service, required super.server, required super.databases});

  var all = 0;

  @override
  Future<Map<String, CrateSyncReport>> syncAll() async {
    all++;
    return {};
  }
}

MyInvite _invite(String id, {String? by = 'owner@example.com', bool accepted = false}) => MyInvite(
      id: id,
      orchardId: 'orchard-$id',
      role: 'member',
      crates: 1,
      expiresAt: DateTime.now().add(const Duration(days: 3)),
      accepted: accepted,
      invitedBy: by,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late ProviderContainer container;
  late AppDatabase tree;
  late _Recorder recorder;
  late _Server crates;
  late StreamController<ConnectivityKind> network;
  late bool streamAsked;
  final tick = OrchardSyncScheduler.invitesTick;

  Future<ProviderContainer> makeContainer() async {
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(_MemoryStorage()),
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'new-1', email: 'new@example.com')),
      cloudReachProvider.overrideWith((ref) {
        final reach = CloudReachService(
          check: () async => throw const SocketException('Connection refused'),
          status: () async => null,
          timer: (wait, then) => Timer(const Duration(days: 1), () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
      orchardNetworkChangesProvider.overrideWithValue(() => network.stream),
      // In no team, the line is never asked for.
      orchardStreamProvider.overrideWith((ref) {
        streamAsked = true;
        final line = OrchardStream(
          url: Uri.parse('ws://127.0.0.1:9/v1/stream'),
          connect: (url) => WebSocket.connect(url.toString()),
          token: ({bool fresh = false}) async => 'token',
          session: () => null,
          retryDelay: (_, _) => const Duration(days: 1),
        );
        ref.onDispose(() => unawaited(line.dispose()));
        return line;
      }),
      orchardSyncProvider.overrideWith((ref) {
        final databases = ref.read(orchardDatabasesProvider.notifier);
        return recorder = _Recorder(
          service: OrchardService(server: crates, databases: databases, author: () async => null),
          server: crates,
          databases: databases,
        );
      }),
    ]);
    c.read(databaseSessionProvider.notifier).seed(tree);
    return c;
  }

  setUp(() async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    network = StreamController<ConnectivityKind>.broadcast();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    crates = _Server();
    streamAsked = false;
    OrchardSyncScheduler.invitesTick = const Duration(milliseconds: 100);
    container = await makeContainer();
  });

  tearDown(() async {
    OrchardSyncScheduler.invitesTick = tick;
    container.dispose();
    await network.close();
    await tree.close();
  });

  OrchardSyncScheduler scheduler() => container.read(orchardSyncSchedulerProvider);

  List<String> told() => [
        for (final n in container.read(notificationCenterProvider).history)
          if (n.id.startsWith('orchard-invite-')) n.id,
      ];

  /// The switchers' dot, as they draw it, over [container].
  Widget dot() => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) =>
                  spacesNeedAttention(ref) ? const SpacesAttentionDot() : const SizedBox.shrink(),
            ),
          ),
        ),
      );

  Future<void> until(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    await tester.pump();
  }

  testWidgets('an account in no team sees the dot once the short timer reads its invitations, with no whole sync',
      (tester) async {
    await tester.runAsync(() async {
      scheduler().start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpWidget(dot());
    expect(find.byType(SpacesAttentionDot), findsNothing);
    final syncs = recorder.all;
    final reads = crates.reads;

    // Someone invites it: the server's word goes to a line nobody has open.
    crates.mine.add(_invite('a'));
    await until(tester, () => told().isNotEmpty);
    expect(find.byType(SpacesAttentionDot), findsOneWidget, reason: 'without opening the invitations');
    expect(crates.reads, greaterThan(reads));
    expect(recorder.all, syncs, reason: 'only the invitations are read, not a whole sync');
    expect(streamAsked, isFalse, reason: 'no line is held open for an account in no team');
    // And it is told once in the bell, with who sent it.
    final notice = container.read(notificationCenterProvider).history.singleWhere((n) => n.id == 'orchard-invite-a');
    expect(notice.title, l10n.noticeInvitedTitle);
    expect(notice.body, l10n.noticeInvitedBody('owner@example.com'));
    await tester.pumpWidget(const SizedBox.shrink());
    // Without Orchards the scheduler does not start (OrchardSyncScheduler.start).
  }, skip: !kOrchardsEnabled);

  testWidgets('the app back in front reads the invitations at once, and shows the dot', (tester) async {
    // A timer that would not run within the test: only coming back reads.
    OrchardSyncScheduler.invitesTick = const Duration(hours: 1);
    await tester.runAsync(() async {
      scheduler().start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpWidget(dot());
    expect(find.byType(SpacesAttentionDot), findsNothing);
    final syncs = recorder.all;

    crates.mine.add(_invite('b', by: null));
    await tester.runAsync(() async => scheduler().foregrounded());
    await until(tester, () => told().isNotEmpty);
    expect(find.byType(SpacesAttentionDot), findsOneWidget);
    expect(recorder.all, syncs, reason: 'only the invitations are read');
    expect(container.read(notificationCenterProvider).history.singleWhere((n) => n.id == 'orchard-invite-b').body,
        l10n.noticeInvitedBodySomeone);

    // Focus coming back again at once asks nothing more.
    final reads = crates.reads;
    await tester.runAsync(() async {
      scheduler().foregrounded();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(crates.reads, reads);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !kOrchardsEnabled);

  test('the same invitation is told once: read again, after a restart, or by two reads at once', () async {
    crates.mine.add(_invite('a'));
    await scheduler().checkInvites();
    expect(told(), ['orchard-invite-a']);

    // Read again, and again by a whole sync: nothing new to tell.
    await scheduler().checkInvites(always: true);
    await scheduler().syncAll();
    expect(told(), ['orchard-invite-a']);

    // A second invitation is told, the first not again, both read at once.
    crates.mine.add(_invite('b'));
    await Future.wait([scheduler().checkInvites(always: true), scheduler().syncAll()]);
    expect(told()..sort(), ['orchard-invite-a', 'orchard-invite-b']);
    expect(container.read(notificationCenterProvider).history.where((n) => n.id == 'orchard-invite-b'), hasLength(1));

    // After a restart (a new app over the same device's Tree), nothing is told
    // again; one accepted elsewhere is not told at all.
    container.dispose();
    SharedPreferences.setMockInitialValues(const {});
    container = await makeContainer();
    // (What the bell kept from before the restart, if anything.)
    final before = {...told()};
    crates.mine.add(_invite('c', accepted: true));
    await scheduler().checkInvites();
    expect({...told()}, before);
    expect(told().where((id) => id == 'orchard-invite-c'), isEmpty);

    // One that is gone is forgotten; a new one is told, and only it. (The
    // accepted one keeps the line open now, so these reads are those of the
    // app coming back to the front.)
    crates.mine.removeWhere((i) => i.id == 'a');
    await scheduler().checkInvites(always: true);
    crates.mine.add(_invite('d'));
    await scheduler().checkInvites(always: true);
    expect({...told()}, {...before, 'orchard-invite-d'});
    expect(told().where((id) => id == 'orchard-invite-d'), hasLength(1));
  });

  test('signed out, nothing is read', () async {
    container.dispose();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      currentUserProvider.overrideWithValue(null),
      orchardSyncProvider.overrideWith((ref) {
        final databases = ref.read(orchardDatabasesProvider.notifier);
        return recorder = _Recorder(
          service: OrchardService(server: crates, databases: databases, author: () async => null),
          server: crates,
          databases: databases,
        );
      }),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    crates.mine.add(_invite('a'));
    await scheduler().checkInvites(always: true);
    expect(crates.reads, 0);
    expect(container.read(myInvitesProvider), isEmpty);
  });

  test('the notice names who sent the invitation, and says it plainly where nobody is named', () {
    final named = invitationNotification(_invite('x'), l10n: l10n);
    expect(named.id, 'orchard-invite-x');
    expect(named.body, 'owner@example.com invited you. To accept or decline, open Invitations in the menu where you '
        'switch to a team.');
    final unnamed = invitationNotification(_invite('y', by: null), l10n: l10n);
    expect(unnamed.body, l10n.noticeInvitedBodySomeone);
    for (final n in [named, unnamed]) {
      expect(n.severity.countsAsUnread, isTrue, reason: 'it stays in the bell until read');
    }
  });
}

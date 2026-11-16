import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_members.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// A team page that could not load what it shows says so the app's way
/// (a test build's Members page showed only "The
/// members could not be loaded.", at the very edge of the page, with the
/// error in the log alone): why, with its code, Retry and Copy details,
/// inside the page's margins. Where the refresh fails and the device holds
/// the team, the Members page shows the members it holds, with a notice
/// that they are not up to date. The Overview no longer shows the failure
/// as its "nothing needs you" row, and Roles says roles.

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  late AccountKeys myKeys;
  late OrchardSummary summary;

  /// A device of 'owner-1', with [storage] (a fresh one by default) and
  /// its account keys where [keysReady].
  ({OrchardService service, OrchardDatabasesNotifier databases}) device(WidgetTester tester,
      {bool keysReady = true}) {
    final storage = _MemoryStorage();
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    return (
      service: OrchardService(
        server: server,
        databases: databases,
        author: () async => keysReady ? CrateAuthor(uid: 'owner-1', keys: myKeys) : null,
      ),
      databases: databases,
    );
  }

  /// A team with Alice in it, on a device of its owner.
  Future<({OrchardService service, OrchardDatabasesNotifier databases})> team(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'owner-1');
    final d = device(tester);
    await tester.runAsync(() async {
      myKeys = await AccountKeys.generate();
      final aliceKeys = await AccountKeys.generate();
      await server.publish('owner-1', myKeys, email: 'me@example.com');
      await server.publish('alice', aliceKeys, email: 'alice@example.com');
      final orchardId = await d.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final role = server.recordOf(orchardId).roles.values.single.id;
      final r = server.recordOf(orchardId);
      await server.appendAs('owner-1', orchardId, [
        await signRecordEntry(myKeys,
            orchardId: orchardId,
            seq: r.seq + 1,
            prev: r.head,
            type: RecordTypes.memberAdd,
            body: {...recordKeysBody(await aliceKeys.publish('alice')), 'uid': 'alice', 'role': role},
            by: 'owner-1'),
      ], checkCopies: false);
      await d.service.refresh();
      summary = await readOrchardSummary(await d.databases.open(orchardId), orchardId);
    });
    return d;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpTeam(WidgetTester tester, ({OrchardService service, OrchardDatabasesNotifier databases}) d,
      TeamPage page, {List<Override> extra = const []}) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      orchardServiceProvider.overrideWithValue(d.service),
      orchardDatabasesProvider.overrideWith((ref) => d.databases),
      activeOrchardProvider.overrideWithValue(AsyncData(summary)),
      orchardSummariesProvider.overrideWith((ref) async => [summary]),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ...extra,
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    container.read(teamPageProvider.notifier).state = page;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: TeamView()),
      ),
    ));
    await settle(tester);
  }

  Future<void> pumpAlone(WidgetTester tester, OrchardService service, Widget page) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async => const []),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: page),
      ),
    ));
    await settle(tester);
  }

  String why(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('team-load-why'))).data!;
  String details(WidgetTester tester) =>
      tester.widget<CopyDetailsButton>(find.byKey(const ValueKey('team-load-details'))).detail;

  testWidgets('Members: ZestSSH Cloud cannot be read, so the members this device holds, marked, and Retry brings them up to date',
      (tester) async {
    final d = await team(tester);
    server.failOrchards = true;
    await pumpTeam(tester, d, TeamPage.members);

    expect(find.byKey(const ValueKey('member-alice')), findsOneWidget, reason: 'the members this device holds');
    expect(find.byKey(const ValueKey('team-load-stale')), findsOneWidget);
    expect(find.text(l10n.teamMembersFromDevice), findsOneWidget);
    expect(find.text(l10n.orchardMembersLoadFailed), findsNothing);
    expect(why(tester), '${l10n.cloudFault(503)} (ZS-1103)', reason: 'the service\'s own fault, with its code');
    expect(details(tester), contains('Where: Team members: bringing the team up to date'));
    expect(details(tester), contains('Code: ZS-1103'));
    expect(details(tester), contains('503'));
    // In the page's margins: where the list's filter starts.
    expect(tester.getTopLeft(find.byKey(const ValueKey('team-load-stale'))).dx,
        tester.getTopLeft(find.byKey(const ValueKey('members-filter'))).dx);

    server.failOrchards = false;
    await tester.tap(find.byKey(const ValueKey('team-load-retry')));
    await settle(tester);
    expect(find.byKey(const ValueKey('team-load-stale')), findsNothing);
    expect(find.byKey(const ValueKey('member-alice')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Members with nothing on this device and ZestSSH Cloud not read: the error inside the page, then Retry',
      (tester) async {
    await team(tester);
    // Another device of the account, which holds nothing of the team yet.
    final fresh = device(tester);
    server.failOrchards = true;
    await pumpAlone(tester, fresh.service, OrchardMembersView(orchardId: summary.id, pageLayout: true));

    expect(find.byKey(const ValueKey('team-load-failed')), findsOneWidget);
    expect(find.text(l10n.orchardMembersLoadFailed), findsOneWidget);
    expect(why(tester), '${l10n.cloudFault(503)} (ZS-1103)');
    expect(details(tester), contains('Where: Team members: reading them'));
    expect(tester.getTopLeft(find.byKey(const ValueKey('team-load-failed'))).dx, 28,
        reason: 'inside the page\'s padding, not at its edge');
    expect(find.byKey(const ValueKey('team-load-retry')), findsOneWidget);

    server.failOrchards = false;
    await tester.tap(find.byKey(const ValueKey('team-load-retry')));
    await settle(tester);
    expect(find.byKey(const ValueKey('team-load-failed')), findsNothing);
    expect(find.byKey(const ValueKey('member-alice')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failure on this device has the team page\'s own code (ZS-1405), in the dialog too', (tester) async {
    await team(tester);
    final locked = device(tester, keysReady: false);
    await pumpAlone(tester, locked.service, SingleChildScrollView(child: OrchardMembersView(orchardId: summary.id)));
    expect(find.byKey(const ValueKey('team-load-failed')), findsOneWidget);
    expect(why(tester), '${l10n.orchardErrorKeysNotReady} (ZS-1405)');
    expect(details(tester), contains('Code: ZS-1405 (A team page could not be loaded)'));
  });

  testWidgets('Roles on a phone: the roles that could not be read are said as roles, with code and Retry',
      (tester) async {
    await team(tester);
    final locked = device(tester, keysReady: false);
    await pumpAlone(tester, locked.service, SingleChildScrollView(child: OrchardRolesView(orchardId: summary.id)));
    expect(find.byKey(const ValueKey('team-load-failed')), findsOneWidget);
    expect(find.text(l10n.teamRolesLoadFailed), findsOneWidget);
    expect(find.text(l10n.orchardMembersLoadFailed), findsNothing);
    expect(why(tester), '${l10n.orchardErrorKeysNotReady} (ZS-1405)');
    expect(details(tester), contains('Where: Team roles: reading them'));
  });

  testWidgets('the Overview and the Roles table: members that could not be read are no "nothing needs you"',
      (tester) async {
    final d = await team(tester);
    var reads = 0;
    final failing = teamPeopleProvider(summary.id).overrideWith((ref) async {
      reads++;
      throw StateError('the team database could not be read');
    });
    await pumpTeam(tester, d, TeamPage.overview, extra: [failing]);
    expect(find.byKey(const ValueKey('team-load-failed')), findsOneWidget);
    expect(find.text(l10n.teamAttentionNone), findsNothing);
    expect(find.text(l10n.orchardMembersLoadFailed), findsOneWidget);
    expect(why(tester), '${l10n.orchardErrorNotDone} (ZS-1405)');
    expect(details(tester), contains('Where: Team overview: reading the members'));
    expect(details(tester), contains('the team database could not be read'));
    final before = reads;
    await tester.tap(find.byKey(const ValueKey('team-load-retry')));
    await settle(tester);
    expect(reads, greaterThan(before), reason: 'Retry reads them again');

    await tester.tap(find.byKey(const ValueKey('team-nav-roles')));
    await settle(tester);
    expect(find.byKey(const ValueKey('team-load-failed')), findsOneWidget);
    expect(find.text(l10n.teamRolesLoadFailed), findsOneWidget);
    expect(why(tester), '${l10n.orchardErrorNotDone} (ZS-1405)');
    await tester.pump(const Duration(seconds: 5));
  });
}

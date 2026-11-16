import 'package:drift/drift.dart' show driftRuntimeOptions, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/crate_records_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// A Crate's trash and changes on screen (3.0): what was deleted,
/// brought back with one tap; who deleted it only while version history is
/// on; the changes, with the version before an edit put back after a yes;
/// and the Crate row's buttons only for those who may use them.

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
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late OrchardService owner;
  late OrchardService alice;
  late String orchardId;
  late String crateId;
  final storages = <_MemoryStorage>[];
  final devices = <OrchardService, ({_MemoryStorage storage, String uid})>{};

  setUpAll(() async {
    for (final uid in ['owner-1', 'alice']) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService onStorage(_MemoryStorage storage, String uid) {
    final service = OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
    devices[service] = (storage: storage, uid: uid);
    return service;
  }

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return onStorage(storage, uid);
  }

  Future<void> sync(OrchardService s) =>
      OrchardSyncCoordinator(service: s, server: s.server, databases: s.databases).syncAll();

  Future<AppDatabase> ownerDb() => owner.databases.open(orchardId);

  Future<String?> labelOf(String id) async => (await (await ownerDb())
          .customSelect('SELECT label FROM connections WHERE id = ?', variables: [Variable(id)])
          .getSingleOrNull())
      ?.read<String>('label');

  /// Acme with the owner and alice (a member who may only use Production),
  /// recording [tracking]; web1 made, renamed [renames] times, then deleted
  /// when [deleted].
  Future<void> build(WidgetTester tester,
          {RecordTracking tracking = RecordTracking.none, List<String> renames = const [], bool deleted = false}) =>
      tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in keys.keys) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        alice = serviceFor('alice');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        crateId = server.recordOf(orchardId).roles.values.single.crates.keys.single;
        await owner.invite(orchardId, email: 'alice@example.com', role: server.recordOf(orchardId).roles.values.single.id);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        if (!tracking.isNone) await owner.setTracking(orchardId, tracking);
        final db = await ownerDb();
        await db.customStatement(
            "INSERT INTO connections (id, label, host, port, created_at, updated_at) VALUES ('web1', 'Web 1', 'web1.example.com', 22, 0, 0)");
        await sync(owner);
        for (final label in renames) {
          await db.customStatement("UPDATE connections SET label = ? WHERE id = 'web1'", [label]);
          await sync(owner);
        }
        if (deleted) {
          await db.customStatement("DELETE FROM connections WHERE id = 'web1'");
          await sync(owner);
        }
        await owner.refresh();
        await alice.refresh();
        await sync(alice);
      });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
      if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    return container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);
  }

  Future<void> pump(WidgetTester tester, OrchardService as, Widget Function(OrchardSummary, CrateSummary) child,
      {List<Override> extra = const []}) async {
    final device = devices[as]!;
    as = onStorage(device.storage, device.uid);
    late OrchardSummary summary;
    await tester.runAsync(() async => summary = await readOrchardSummary(await as.databases.open(orchardId), orchardId));
    final crate = summary.crates.firstWhere((c) => c.id == crateId);
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final me = device.uid;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(as),
        orchardDatabasesProvider.overrideWith((ref) => as.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: me, keys: keys[me]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        currentUserProvider.overrideWithValue(UserProfile(uid: me, email: '$me@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ...extra,
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: child(summary, crate))),
      ),
    ));
    await settle(tester);
  }

  String itemId() => server.items[crateId]!.keys.single;

  testWidgets('what was deleted comes back with one tap; who deleted it is not shown while history is off',
      (tester) async {
    await build(tester, renames: ['Web One'], deleted: true);
    await pump(tester, owner, (o, c) => CrateTrashView(orchard: o, crate: c));
    final row = find.byKey(ValueKey('crate-trash-${itemId()}'));
    expect(find.descendant(of: row, matching: find.text('Web One')), findsOneWidget);
    expect(find.descendant(of: row, matching: find.textContaining('Gone for good on')), findsOneWidget);
    expect(find.textContaining('Deleted by'), findsNothing, reason: 'the team records no history');

    await tester.tap(find.byKey(ValueKey('crate-trash-restore-${itemId()}')));
    await settle(tester);
    expect(toasted(tester, l10n.crateTrashRestored('Web One')), isTrue);
    expect(row, findsNothing);
    expect(find.byKey(const ValueKey('crate-trash-empty')), findsOneWidget);
    expect(await tester.runAsync(() => labelOf('web1')), 'Web One');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('with version history on, the trash says who deleted it', (tester) async {
    await build(tester, tracking: const RecordTracking(history: true), deleted: true);
    await pump(tester, owner, (o, c) => CrateTrashView(orchard: o, crate: c));
    expect(find.textContaining(l10n.crateTrashDeletedBy('owner-1@example.com')), findsOneWidget);
  });

  testWidgets('someone who may not add sees why there is no trash for them', (tester) async {
    await build(tester, deleted: true);
    await pump(tester, alice, (o, c) => CrateTrashView(orchard: o, crate: c));
    expect(find.text(l10n.crateTrashNeedsAdd), findsOneWidget);
  });

  testWidgets('the changes: who changed what, and the version before an edit put back after a yes', (tester) async {
    await build(tester, tracking: const RecordTracking(history: true), renames: ['Second', 'Third']);
    await pump(tester, owner, (o, c) => CrateChangesView(orchard: o, crate: c));
    expect(find.byKey(const ValueKey('crate-changes-since')), findsOneWidget);
    expect(find.text(l10n.crateChangeEdited('owner-1@example.com', 'Third')), findsOneWidget);
    expect(find.text(l10n.crateChangeEdited('owner-1@example.com', 'Second')), findsOneWidget);

    // The newest change's: Third replaced Second.
    final putBack = find
        .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('crate-change-put-back-'))
        .first;
    await tester.tap(putBack);
    await settle(tester);
    expect(find.text(l10n.crateChangePutBackTitle('Second')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(await tester.runAsync(() => labelOf('web1')), 'Third', reason: 'declined: nothing changed');

    await tester.tap(putBack);
    await settle(tester);
    await tester.tap(find.text(l10n.crateChangePutBackConfirm).last);
    await settle(tester);
    expect(await tester.runAsync(() => labelOf('web1')), 'Second');
    expect(toasted(tester, l10n.crateChangePutBackDone('Second')), isTrue);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a Crate row offers the trash to those who may add and the changes to managers while history is on',
      (tester) async {
    await build(tester);
    await pump(tester, owner, (o, c) => CrateRecordsLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-trash-open-$crateId')), findsOneWidget);
    expect(find.byKey(ValueKey('crate-changes-open-$crateId')), findsNothing, reason: 'history is off');

    await tester.runAsync(() => owner.setTracking(orchardId, const RecordTracking(history: true)));
    await pump(tester, owner, (o, c) => CrateRecordsLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-changes-open-$crateId')), findsOneWidget);

    await tester.runAsync(() async {
      await alice.refresh();
      await sync(alice);
    });
    await pump(tester, alice, (o, c) => CrateRecordsLine(orchard: o, crate: c));
    expect(find.byKey(ValueKey('crate-trash-open-$crateId')), findsNothing);
    expect(find.byKey(ValueKey('crate-changes-open-$crateId')), findsNothing);
  });

  testWidgets("an item's versions: the one now first, each earlier with who and when, one put back after a yes",
      (tester) async {
    await build(tester, tracking: const RecordTracking(history: true), renames: ['Second', 'Third']);
    await pump(tester, owner, (o, c) => ItemVersionsView(orchard: o, crateId: c.id, kind: 'host', itemKey: 'web1'));
    Finder row(int i, String text) => find.descendant(of: find.byKey(ValueKey('item-version-$i')), matching: find.text(text));
    expect(row(0, 'Third'), findsOneWidget);
    expect(row(0, l10n.itemVersionNow), findsOneWidget);
    expect(row(1, 'Second'), findsOneWidget);
    expect(row(2, 'Web 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('item-version-put-back-0')), findsNothing, reason: 'the one it has now');

    await tester.tap(find.byKey(const ValueKey('item-version-put-back-2')));
    await settle(tester);
    expect(find.text(l10n.itemVersionPutBackBody), findsOneWidget);
    await tester.tap(find.text(l10n.crateChangePutBackConfirm).last);
    await settle(tester);
    expect(await tester.runAsync(() => labelOf('web1')), 'Web 1');
    expect(toasted(tester, l10n.crateChangePutBackDone('Web 1')), isTrue);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets("a host's panel links to its versions for those who manage it, while history is on", (tester) async {
    await build(tester);
    List<Override> onScreen() => [
          activeSpaceProvider.overrideWith((ref) => OrchardSpace(orchardId)),
          itemCratesProvider('host').overrideWith((ref) => Stream.value({'web1': crateId})),
        ];
    Widget link(OrchardSummary o, CrateSummary c) => const ItemVersionsLink(kind: 'host', itemKey: 'web1', name: 'Web 1');
    await pump(tester, owner, link, extra: onScreen());
    expect(find.byKey(const ValueKey('item-versions-open')), findsNothing, reason: 'history is off');

    await tester.runAsync(() => owner.setTracking(orchardId, const RecordTracking(history: true)));
    await pump(tester, owner, link, extra: onScreen());
    expect(find.byKey(const ValueKey('item-versions-open')), findsOneWidget);

    // Alice may only use it: no link.
    await tester.runAsync(() async {
      await alice.refresh();
      await sync(alice);
    });
    await pump(tester, alice, link, extra: onScreen());
    expect(find.byKey(const ValueKey('item-versions-open')), findsNothing);
  });

  testWidgets('a deletion in the changes offers nothing to put back here: it comes back from the trash', (tester) async {
    await build(tester, tracking: const RecordTracking(history: true), renames: ['Second'], deleted: true);
    await pump(tester, owner, (o, c) => CrateChangesView(orchard: o, crate: c));
    final deletion = find.ancestor(
      of: find.text(l10n.crateChangeDeleted('owner-1@example.com', 'Second')),
      matching: find.byWidgetPredicate(
          (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('crate-change-')),
    );
    expect(deletion, findsOneWidget);
    expect(find.descendant(of: deletion, matching: find.text(l10n.crateChangePutBack)), findsNothing);
    expect(find.text(l10n.crateChangePutBack), findsOneWidget, reason: 'the edit before it still offers one');
  });
}


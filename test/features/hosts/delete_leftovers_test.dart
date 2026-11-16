import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart' show phoneHostActionsFor;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';

/// Three delete leftovers (3.4, after the deletes became one transaction
/// each in ad4c504c):
///  * a host's delete left its settings for each network behind (Move to...
///    took them; the delete never did);
///  * a network's delete left the port forwards' states on it (On, Off);
///  * a single host's delete (the Hosts page on a computer, a host's own
///    menu on a phone) did not catch a refusal of a team's vault: nothing was
///    said, and the error went uncaught. It is said now as the selection's
///    Delete says it.

const _team = '44444444-4444-4444-8444-444444444444';
const _open = '11111111-1111-4111-8111-111111111111'; // add, edit, no delete
const _full = '33333333-3333-4333-8333-333333333333'; // everything

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 11, 6);

  // ── The database: what a delete takes with it ─────────────────────────

  group('what a delete takes with it', () {
    late AppDatabase db;

    Future<void> network(String id, String name) => db.into(db.networks).insert(NetworksCompanion.insert(
          id: id,
          name: name,
          iconCodePoint: 0xe318,
          createdAt: at,
        ));

    Future<void> host(String id) => db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '192.168.10.21',
          createdAt: at,
          updatedAt: at,
        ));

    Future<void> hostOn(String id, String hostId, String networkId, String address) =>
        db.networksDao.insertOverride(HostNetworkOverridesCompanion.insert(
          id: id,
          connectionId: hostId,
          networkId: networkId,
          address: Value(address),
          createdAt: at,
          updatedAt: at,
        ));

    Future<void> forward(String id, String hostId, Map<String, String> states) async {
      await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: id,
            connectionId: hostId,
            type: 'local',
            bindPort: 8080,
            remoteHost: 'localhost',
            remotePort: 80,
            createdAt: at,
          ));
      for (final MapEntry(key: networkId, value: state) in states.entries) {
        await db.into(db.portForwardNetworkOverrides).insert(PortForwardNetworkOverridesCompanion.insert(
              id: 'o-$id-$networkId',
              ruleId: id,
              networkId: networkId,
              state: Value(state),
              createdAt: at,
              updatedAt: at,
            ));
      }
    }

    Future<List<String>> hostSettings() async =>
        [for (final o in await db.select(db.hostNetworkOverrides).get()) '${o.connectionId}@${o.networkId}']..sort();
    Future<List<String>> forwardStates() async =>
        [for (final o in await db.select(db.portForwardNetworkOverrides).get()) '${o.ruleId}@${o.networkId}=${o.state}']
          ..sort();

    ConnectionCrudNotifier hosts() =>
        ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);

    group('in your own space', () {
      setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
      tearDown(() => db.close());

      test("a host's delete takes its settings for each network; another host's stay", () async {
        await network('n-office', 'Office');
        await network('n-home', 'Home');
        await host('web-01');
        await host('web-02');
        await hostOn('hn-1', 'web-01', 'n-office', '192.168.20.11');
        await hostOn('hn-2', 'web-01', 'n-home', '192.168.10.11');
        await hostOn('hn-3', 'web-02', 'n-office', '192.168.20.12');

        await hosts().delete('web-01');

        expect(await db.connectionsDao.getById('web-01'), isNull);
        expect(await hostSettings(), ['web-02@n-office'], reason: "web-01's settings went with it");
      });

      test("a network's delete takes the port forwards' states on it; their states elsewhere and the forwards stay",
          () async {
        await network('n-office', 'Office');
        await network('n-home', 'Home');
        await host('web-01');
        await hostOn('hn-1', 'web-01', 'n-office', '192.168.20.11');
        await forward('f-web', 'web-01', {'n-office': 'off', 'n-home': 'on'});
        await forward('f-api', 'web-01', {'n-office': 'on'});

        await NetworkRepository(db.networksDao).delete('n-office');

        expect((await db.select(db.networks).get()).map((n) => n.id), ['n-home']);
        expect(await hostSettings(), isEmpty, reason: "the hosts' settings on it went, as before");
        expect(await forwardStates(), ['f-web@n-home=on'], reason: "the forwards' states on it went too");
        expect([for (final r in await db.portForwardRulesDao.getByConnection('web-01')) r.id]..sort(), ['f-api', 'f-web']);
      });
    });

    group("in a team's vault that refuses the delete", () {
      setUp(() async {
        FlutterSecureStorage.setMockInitialValues({});
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await db.customStatement(
            'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
            "VALUES (1, ?, 'Platform team', 'member-role', 1, ?)",
            [_team, _open]);
        await db.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
            '''(?, 'Staging', 'edit', '["add","connect","edit","reveal"]', 1), '''
            '''(?, 'Legacy', 'manage', '["add","connect","delete","edit","manage","reveal"]', 1)''',
            [_open, _full]);
      });
      tearDown(() => db.close());

      Matcher refused() => throwsA(predicate((e) => '$e'.contains('orchard-access')));

      /// Writes as the sync engine does (the write guard and the outbox quiet).
      Future<void> asServer(Future<void> Function() write) async {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await write();
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      }

      Future<void> placed(String kind, String key, String crate) => db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES (?, ?, ?, 3)',
          [kind, key, crate]);

      test("a host's delete refused: its settings for each network stay with it", () async {
        await asServer(() async {
          await network('n-office', 'Office');
          await placed('network', 'n-office', _full);
          await host('web-staging');
          await placed('host', 'web-staging', _open);
          await hostOn('hn-1', 'web-staging', 'n-office', '192.168.20.11');
        });

        await expectLater(hosts().delete('web-staging'), refused());

        expect(await db.connectionsDao.getById('web-staging'), isNotNull);
        expect(await hostSettings(), ['web-staging@n-office']);
      });

      test("a network's delete refused: the port forwards' states on it stay", () async {
        await asServer(() async {
          await network('n-office', 'Office');
          await placed('network', 'n-office', _open);
          await host('web-legacy');
          await placed('host', 'web-legacy', _full);
          await forward('f-legacy', 'web-legacy', {'n-office': 'off'});
          await placed('forward', 'f-legacy', _full);
        });

        await expectLater(NetworkRepository(db.networksDao).delete('n-office'), refused());

        expect((await db.select(db.networks).get()).map((n) => n.id), ['n-office']);
        expect(await forwardStates(), ['f-legacy@n-office=off']);
      });
    });
  });

  // ── The screens: a single host's delete that the vault refuses ─────────

  group("a single host's delete in a team's vault that refuses it", () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() => debugTopSnackBarOnPhone = true);
    tearDown(() => debugTopSnackBarOnPhone = null);

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// A team with one vault, Archive, where the screen reads that the role
    /// may delete and the database's own record says it may not (the case a
    /// single delete meets when the two disagree). Its host: db-archive.
    /// [crud] stands in for the hosts' writer.
    Future<void> setUpTeam(WidgetTester tester, {ConnectionCrudNotifier Function(AppDatabase db)? crud}) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
        await db.customStatement(
            'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
            "VALUES (1, ?, 'Platform team', 'member-role', 1, ?)",
            [_team, _open]);
        await db.customStatement(
            'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
            '''(?, 'Archive', 'edit', '["add","connect","edit"]', 1)''',
            [_open]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
        await db.connectionsDao.insertConnection(ConnectionsCompanion(
          id: const Value('h1'),
          label: const Value('db-archive'),
          host: const Value('192.168.10.31'),
          port: const Value(22),
          protocol: const Value('ssh'),
          createdAt: Value(at),
          updatedAt: Value(at),
        ));
        await db.customStatement(
            "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', 'h1', ?, 3)",
            [_open]);
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
      });
      addTearDown(() => db.close());
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        healthChecksEnabledProvider.overrideWith((ref) => false),
        syncIsActiveProvider.overrideWith((ref) async => true),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(_team)),
        activeOrchardProvider.overrideWithValue(const AsyncData(OrchardSummary(
          id: _team,
          name: 'Platform team',
          role: 'member-role',
          defaultCrateId: _open,
          crates: [CrateSummary(id: _open, name: 'Archive', level: 'manage', switches: CrateSwitches.all)],
        ))),
        itemCratesProvider.overrideWith(
            (ref, kind) => Stream.value(kind == 'host' ? const {'h1': _open} : const <String, String>{})),
        if (crud != null) connectionCrudProvider.overrideWith((ref) => crud(db)),
      ]);
      addTearDown(container.dispose);
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));
    }

    Future<List<String>> hostsLeft(WidgetTester tester) async =>
        [for (final c in (await tester.runAsync(() => db.connectionsDao.getAll()))!) c.id];

    Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

    testWidgets('on a computer, Delete from the host\'s menu: the refusal is said and the host stays', (tester) async {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
      messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
          MockStreamHandler.inline(onListen: (arguments, events) {}));
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await setUpTeam(tester);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: HostsHomePage(onConnectTo: (_) {}, onOpenSftp: (_) {})),
        ),
      ));
      await settle(tester);
      Object? ex;
      while ((ex = tester.takeException()) != null) {
        expect(ex.toString(), contains('overflowed'));
      }

      final card = find.byWidgetPredicate((w) => w is HostCard && w.data.id == 'h1');
      final click = await tester.startGesture(tester.getCenter(card),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await click.up();
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('host-menu-delete')));
      await settle(tester);
      expect(inQuestion(l10n.hostsHomeDeleteConnectionTitle), findsOneWidget);
      await tester.tap(inQuestion(l10n.delete));
      await settle(tester);

      expect(tester.takeException(), isNull, reason: 'the refusal is caught');
      expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
      expect(await hostsLeft(tester), ['h1']);
      await finish(tester);
    });

    /// A phone's host actions for h1 (its own menu's Delete runs them once
    /// asked), on a button.
    Future<void> pumpPhoneDelete(WidgetTester tester) async {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              // Which vault each host is in, as the phone's Hosts tab keeps
              // it watched.
              ref.watch(itemCratesProvider('host'));
              final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
              final item = all.where((c) => c.connection.id == 'h1').firstOrNull;
              if (item == null) return const SizedBox();
              final actions = phoneHostActionsFor(context, ref, item, onConnect: (_) {});
              return Center(
                child: TextButton(
                  key: const ValueKey('phone-delete'),
                  onPressed: actions.delete,
                  child: const Text('delete'),
                ),
              );
            }),
          ),
        ),
      ));
      await settle(tester);
    }

    testWidgets("on a phone, the host's own Delete: the refusal is said and the host stays", (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await setUpTeam(tester);
      await pumpPhoneDelete(tester);
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('phone-delete'))).onPressed, isNotNull,
          reason: 'the screen reads that the role may delete');

      await tester.tap(find.byKey(const ValueKey('phone-delete')));
      await settle(tester);

      expect(tester.takeException(), isNull, reason: 'the refusal is caught');
      expect(find.text(l10n.orchardWriteNotAllowed), findsOneWidget);
      expect(await hostsLeft(tester), ['h1']);
      await finish(tester);
    });

    testWidgets('any other failure says the host was not deleted, with its details', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await setUpTeam(tester, crud: _FailingHosts.new);
      await pumpPhoneDelete(tester);

      await tester.tap(find.byKey(const ValueKey('phone-delete')));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text(l10n.hostNotDeleted), findsOneWidget);
      expect(find.text(l10n.orchardWriteNotAllowed), findsNothing);
      expect(await hostsLeft(tester), ['h1']);
      await finish(tester);
    });
  });
}

/// The hosts' writer, its delete failing as a disk might.
class _FailingHosts extends ConnectionCrudNotifier {
  _FailingHosts(AppDatabase db) : super(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);

  @override
  Future<void> delete(String id) async => throw StateError('disk I/O error');
}

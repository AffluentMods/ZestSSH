import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// A delete a team vault refuses changes nothing (found in a
/// review). A delete is several writes: a host's tags, port forwards, other
/// accounts and the hosts that jump through it, a key's hosts, a snippet's
/// or a group's hosts, a port forward's or a network's overrides, and the
/// tombstone that deletes it on your other devices. They were written one by
/// one before the item itself, which the vault's write guard refuses for a
/// role that may edit but not delete: the item stayed, and what was written
/// before it was lost. Each delete is now one transaction.

const _team = '44444444-4444-4444-8444-444444444444';
const _open = '11111111-1111-4111-8111-111111111111'; // add, edit, no delete
const _full = '33333333-3333-4333-8333-333333333333'; // everything

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  final at = DateTime(2026, 11, 5);

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

  /// [key] of [kind] is on the server, in [crate].
  Future<void> placed(String kind, String key, String crate) => db.customStatement(
      'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES (?, ?, ?, 3)',
      [kind, key, crate]);

  Future<void> host(String id, String crate,
      {String? identityId, String? groupId, String? snippetId, String? connectViaId}) async {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '192.168.10.21',
          identityId: Value(identityId),
          groupId: Value(groupId),
          snippetId: Value(snippetId),
          connectViaId: Value(connectViaId),
          createdAt: at,
          updatedAt: at,
        ));
    await placed('host', id, crate);
  }

  Future<void> forward(String id, String hostId, String crate) async {
    await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: id,
          connectionId: hostId,
          type: 'local',
          bindPort: 8080,
          remoteHost: 'localhost',
          remotePort: 80,
          createdAt: at,
        ));
    await db.into(db.portForwardNetworkOverrides).insert(PortForwardNetworkOverridesCompanion.insert(
          id: 'o-$id',
          ruleId: id,
          networkId: 'n-office',
          state: const Value('off'),
          createdAt: at,
          updatedAt: at,
        ));
    await placed('forward', id, crate);
  }

  Future<Connection?> hostRow(String id) => db.connectionsDao.getById(id);
  Future<List<String>> tombstones() async => [for (final t in await db.tombstonesDao.getAll()) t.entityId];
  Future<int> queued() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n');
  Future<List<String>> forwardOverrides() async =>
      [for (final r in await db.select(db.portForwardNetworkOverrides).get()) r.ruleId]..sort();

  ConnectionCrudNotifier hosts() =>
      ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);

  group('a host', () {
    Future<void> seed(String crate) => asServer(() async {
          await host('web-staging', crate);
          await db.connectionTagsDao.setTagsForConnection('web-staging', ['prod', 'web']);
          await db.hostAccountsDao.setOtherAccounts('web-staging', ['k-deploy']);
          // Its port forward is in a vault where the role may delete.
          await forward('f-web', 'web-staging', _full);
          // A host that reaches another through it.
          await host('app-legacy', _full, connectViaId: 'web-staging');
        });

    test('the role may edit but not delete: refused, and its tags, forwards, accounts and jump stay; no tombstone',
        () async {
      await seed(_open);
      await expectLater(hosts().delete('web-staging'), refused());

      expect(await hostRow('web-staging'), isNotNull);
      expect(await db.connectionTagsDao.getTagsForConnection('web-staging'), ['prod', 'web']);
      expect(await db.hostAccountsDao.otherAccountsOf('web-staging'), ['k-deploy']);
      expect([for (final r in await db.portForwardRulesDao.getByConnection('web-staging')) r.id], ['f-web']);
      expect(await forwardOverrides(), ['f-web']);
      expect((await hostRow('app-legacy'))!.connectViaId, 'web-staging');
      expect(await tombstones(), isEmpty, reason: 'nothing deletes it on another device');
      expect(await queued(), 0, reason: 'nothing of it goes to the server');
    });

    test('the role may delete: it goes with all of it, as before', () async {
      await seed(_full);
      await hosts().delete('web-staging');

      expect(await hostRow('web-staging'), isNull);
      expect(await db.connectionTagsDao.getTagsForConnection('web-staging'), isEmpty);
      expect(await db.hostAccountsDao.otherAccountsOf('web-staging'), isEmpty);
      expect(await db.portForwardRulesDao.getByConnection('web-staging'), isEmpty);
      expect(await forwardOverrides(), isEmpty);
      expect((await hostRow('app-legacy'))!.connectViaId, isNull);
      expect((await tombstones())..sort(), ['f-web', 'web-staging']);
    });
  });

  test('a key: refused, its hosts still sign in with it, and its secrets stay; no tombstone', () async {
    await asServer(() async {
      for (final id in ['k-staging', 'k-ci']) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: id,
              username: 'deploy',
              authMethod: 'password',
              createdAt: at,
            ));
      }
      await placed('key', 'k-staging', _open);
      await placed('key', 'k-ci', _full);
      await OrchardIdentitySecrets(db).write('k-staging', IdentitySecret.password, 'correct-horse');
      // One host signs in with it, another has it as its other account.
      await host('db-legacy', _full, identityId: 'k-staging');
      await db.hostAccountsDao.setOtherAccounts('db-legacy', ['k-ci']);
      await host('cache-legacy', _full, identityId: 'k-ci');
      await db.hostAccountsDao.setOtherAccounts('cache-legacy', ['k-staging']);
    });
    final keys = IdentityCrudNotifier(
        db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);

    await expectLater(keys.delete('k-staging'), refused());

    expect(await db.identitiesDao.getById('k-staging'), isNotNull);
    expect((await hostRow('db-legacy'))!.identityId, 'k-staging');
    expect(await db.hostAccountsDao.otherAccountsOf('db-legacy'), ['k-ci']);
    expect(await db.hostAccountsDao.otherAccountsOf('cache-legacy'), ['k-staging']);
    final secret = await db.customSelect("SELECT password FROM orchard_secrets WHERE identity_id = 'k-staging'").get();
    expect([for (final r in secret) r.read<String?>('password')], ['correct-horse']);
    expect(await tombstones(), isEmpty);
    expect(await queued(), 0);
  });

  test('a snippet: refused, and the host that runs it at sign-in still does; no tombstone', () async {
    await asServer(() async {
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
            id: 's-staging',
            label: 'Tail the app log',
            command: 'tail -f /var/log/app.log',
            createdAt: at,
            updatedAt: at,
          ));
      await placed('snippet', 's-staging', _open);
      await host('web-legacy', _full, snippetId: 's-staging');
    });

    await expectLater(SnippetCrudNotifier(db.snippetsDao, db.connectionsDao).delete('s-staging'), refused());

    expect(await db.snippetsDao.getById('s-staging'), isNotNull);
    expect((await hostRow('web-legacy'))!.snippetId, 's-staging');
    expect(await tombstones(), isEmpty);
    expect(await queued(), 0);
  });

  test('a group: refused, and its hosts stay in it; no tombstone', () async {
    await asServer(() async {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
            id: 'g-staging',
            name: 'Staging',
            createdAt: at,
          ));
      await placed('group', 'g-staging', _open);
      await host('web-legacy', _full, groupId: 'g-staging');
    });

    await expectLater(GroupCrudNotifier(db.connectionGroupsDao, db.connectionsDao).delete('g-staging'), refused());

    expect((await db.select(db.connectionGroups).get()).map((g) => g.id), ['g-staging']);
    expect((await hostRow('web-legacy'))!.groupId, 'g-staging');
    expect(await tombstones(), isEmpty);
    expect(await queued(), 0);
  });

  test('a port forward: refused, and its per-network states stay; no tombstone', () async {
    await asServer(() async {
      await host('web-legacy', _full);
      await forward('f-staging', 'web-legacy', _open);
    });

    await expectLater(db.portForwardRulesDao.deleteRule('f-staging'), refused());

    expect([for (final r in await db.portForwardRulesDao.getByConnection('web-legacy')) r.id], ['f-staging']);
    expect(await forwardOverrides(), ['f-staging']);
    expect(await tombstones(), isEmpty);
    expect(await queued(), 0);
  });

  test("a network: refused, and its hosts' settings there stay; no tombstone", () async {
    await asServer(() async {
      await db.into(db.networks).insert(NetworksCompanion.insert(
            id: 'n-office',
            name: 'Office',
            iconCodePoint: 0xe318,
            createdAt: at,
          ));
      await placed('network', 'n-office', _open);
      await host('web-legacy', _full);
      await db.networksDao.insertOverride(HostNetworkOverridesCompanion.insert(
            id: 'hn-1',
            connectionId: 'web-legacy',
            networkId: 'n-office',
            address: const Value('192.168.20.12'),
            createdAt: at,
            updatedAt: at,
          ));
    });

    await expectLater(NetworkRepository(db.networksDao).delete('n-office'), refused());

    expect((await db.select(db.networks).get()).map((n) => n.id), ['n-office']);
    expect([for (final o in await db.networksDao.getOverridesForHost('web-legacy')) o.address], ['192.168.20.12']);
    expect(await tombstones(), isEmpty);
    expect(await queued(), 0);
  });

  test('a terminal trigger and a snippet category: refused, and no tombstone', () async {
    await asServer(() async {
      await db.into(db.terminalTriggers).insert(TerminalTriggersCompanion.insert(
            id: 't-staging',
            name: 'Out of memory',
            pattern: 'Out of memory',
            createdAt: at,
          ));
      await placed('trigger', 't-staging', _open);
      await db.into(db.snippetCategories).insert(SnippetCategoriesCompanion.insert(name: 'Deploy'));
      await placed('category', 'Deploy', _open);
    });

    await expectLater(db.terminalTriggersDao.deleteTrigger('t-staging'), refused());
    await expectLater(db.snippetCategoriesDao.deleteByName('Deploy'), refused());

    expect((await db.select(db.terminalTriggers).get()).map((t) => t.id), ['t-staging']);
    expect((await db.select(db.snippetCategories).get()).map((c) => c.name), ['Deploy']);
    expect(await tombstones(), isEmpty);
  });
}

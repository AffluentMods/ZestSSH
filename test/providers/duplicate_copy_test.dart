import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// Duplicate for a host and a key: a host's copy is named in
/// the app's language (it was "(copy)" in English in every language), and
/// in a team's space a copy stays in its source's Crate where this account
/// can add there (it went into the Crate new items go to, wherever its
/// source was).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const ops = '11111111-1111-4111-8111-111111111111'; // where new items go
  const prod = '22222222-2222-4222-8222-222222222222'; // add too
  const view = '33333333-3333-4333-8333-333333333333'; // connect only
  const storage = FlutterSecureStorage();

  late AppDatabase db;
  late ConnectionCrudNotifier hosts;
  late IdentityCrudNotifier keys;

  Future<void> openOrchard() async {
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '44444444-4444-4444-8444-444444444444', 'Example Ops', 'member-role', 1, ?)",
        [ops]);
    await db.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
        '''(?, 'Ops', 'edit', '["add","connect","edit","reveal"]', 1), '''
        '''(?, 'Prod', 'edit', '["add","connect","edit","reveal"]', 1), '''
        '''(?, 'View', 'connect', '["connect","forward","sftp"]', 1)''',
        [ops, prod, view]);
  }

  void cruds() {
    hosts = ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);
    keys = IdentityCrudNotifier(db.identitiesDao, IdentitySecretStore.forDatabase(db, storage), db.connectionsDao);
  }

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => db.close());

  Future<Connection> host(String id) async => (await db.connectionsDao.getById(id))!;

  /// An item as the sync engine leaves it: in [crate], and on the server.
  Future<void> fromServer(String kind, String id, String crate, Future<void> Function() insert) async {
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await insert();
    await db.customStatement(
        'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES (?, ?, ?, 7)',
        [kind, id, crate]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  Future<void> insertHost(String id) => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: id,
        host: '192.168.10.21',
        port: const Value(22),
        createdAt: DateTime(2026, 10, 24),
        updatedAt: DateTime(2026, 10, 24),
      ));

  test("a host's copy takes the name it is given", () async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    cruds();
    final id = await hosts.create(label: 'web-01', host: '192.168.10.21');
    final copy = await hosts.duplicate(await host(id), label: 'web-01 (Kopie)');
    expect((await host(copy)).label, 'web-01 (Kopie)');
    expect((await host(copy)).host, '192.168.10.21');
  });

  test("in a team's space a host's copy stays in its source's Crate", () async {
    await openOrchard();
    cruds();
    await fromServer('host', 'db-primary', prod, () => insertHost('db-primary'));
    final placement = CratePlacement(db);
    final copy = await hosts.duplicate(await host('db-primary'), label: 'db-primary (copy)');
    expect(await placement.crateOf('host', copy), prod, reason: 'beside its source, not where new items go');
    expect((await host(copy)).label, 'db-primary (copy)');
  });

  test("a team host's copy keeps the team's shared SFTP bookmarks: it is the same server", () async {
    await openOrchard();
    cruds();
    const shared = '[{"label":"Service","path":"/opt/x/service"}]';
    await fromServer('host', 'db-primary', prod, () async {
      await insertHost('db-primary');
      await db.connectionsDao.setSharedPins('db-primary', shared);
    });
    final copy = await hosts.duplicate(await host('db-primary'), label: 'db-primary (copy)');
    expect((await host(copy)).sharedPins, shared);
  });

  test('a copy of a host in a Crate this account cannot add to goes where new items go', () async {
    await openOrchard();
    cruds();
    await fromServer('host', 'nas', view, () => insertHost('nas'));
    final copy = await hosts.duplicate(await host('nas'), label: 'nas (copy)');
    expect(await CratePlacement(db).crateOf('host', copy), ops);
  });

  test('a refused copy leaves nothing behind', () async {
    await openOrchard();
    cruds();
    await fromServer('host', 'nas', view, () => insertHost('nas'));
    // Nowhere this account may add: the copy is refused, whole.
    await db.customStatement('UPDATE orchard_crates SET switches = \'["connect"]\'');
    await expectLater(hosts.duplicate(await host('nas'), label: 'nas (copy)'),
        throwsA(predicate((e) => '$e'.contains('orchard-access'))));
    expect((await db.select(db.connections).get()).map((c) => c.id), ['nas']);
    final meta = await db.customSelect("SELECT item_key FROM crate_items_meta WHERE kind = 'host'").get();
    expect(meta.map((r) => r.read<String>('item_key')), ['nas']);
  });

  test("in a team's space a key's copy stays in its source's Crate, with its secrets", () async {
    await openOrchard();
    cruds();
    final id = await keys.create(
        label: 'deploy key', username: 'deploy', authMethod: 'publicKey', keyType: 'ed25519', privateKeyPem: 'PEM');
    await CratePlacement(db).place('key', id, prod);
    final copy = await keys.duplicate((await db.identitiesDao.getById(id))!, label: 'deploy key (copy)');
    expect(await CratePlacement(db).crateOf('key', copy), prod);
    expect(await keys.getPrivateKey(copy), 'PEM');
  });

  test('every Duplicate of a host names its copy in the app\'s language', () {
    final provider = File('lib/providers/connection_providers.dart').readAsStringSync();
    expect(provider, isNot(contains('(copy)')), reason: 'the name is the caller\'s, in the app\'s language');
    for (final path in const [
      'lib/features/hosts/pages/hosts_home_page.dart',
      'lib/ui/screens/home/home_screen.dart',
    ]) {
      final src = File(path).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      final calls = RegExp(r'connectionCrudProvider\) ?\.duplicate\(').allMatches(src).length;
      final named = RegExp(r'connectionCrudProvider\) ?\.duplicate\([^;]*label: [^;]*homeCopyLabelSuffix\(')
          .allMatches(src)
          .length;
      expect(calls, greaterThan(0), reason: path);
      expect(named, calls, reason: '$path: every copy is named with homeCopyLabelSuffix');
    }
  });
}

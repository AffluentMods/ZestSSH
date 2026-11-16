import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// A host's other accounts (3.0, accounts per host): identities it can also
/// be signed in to with, in their order, beside its default one
/// (connections.identity_id). They go with the host when it is deleted, are
/// copied with it, and an identity that is deleted leaves every host, its
/// first other account taking its place where it was the default.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;

  Future<void> identity(String id, String username) => db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: id,
        label: '$username key',
        username: username,
        authMethod: 'publicKey',
        createdAt: DateTime.utc(2026, 10, 15),
      ));

  Future<void> host(String id, {String? identityId}) => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: id,
        host: '$id.example.com',
        identityId: Value(identityId),
        createdAt: DateTime.utc(2026, 10, 15),
        updatedAt: DateTime.utc(2026, 10, 15),
      ));

  Future<String?> defaultOf(String id) async =>
      (await (db.select(db.connections)..where((c) => c.id.equals(id))).getSingle()).identityId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    for (final (id, user) in [('alex', 'alex'), ('root', 'root'), ('deploy', 'deploy'), ('backup', 'backup')]) {
      await identity(id, user);
    }
  });

  tearDown(() => db.close());

  test('the other accounts keep their order, each once, and never the default', () async {
    await host('web', identityId: 'alex');
    await db.hostAccountsDao.setOtherAccounts('web', ['root', 'deploy', 'root', 'alex']);
    expect(await db.hostAccountsDao.otherAccountsOf('web'), ['root', 'deploy']);
    await host('db', identityId: 'root');
    await db.hostAccountsDao.setOtherAccounts('db', ['backup']);
    expect(await db.hostAccountsDao.getAllAssignments(), {
      'db': ['backup'],
      'web': ['root', 'deploy'],
    });
    await db.hostAccountsDao.setOtherAccounts('web', ['root']);
    expect(await db.hostAccountsDao.otherAccountsOf('web'), ['root']);
    await db.hostAccountsDao.setOtherAccounts('web', const []);
    expect(await db.hostAccountsDao.otherAccountsOf('web'), isEmpty);
    expect(await db.hostAccountsDao.otherAccountsOf('db'), ['backup'], reason: 'another host is not touched');
  });

  test('the same accounts again change nothing, and tell nobody', () async {
    await host('web', identityId: 'alex');
    await db.hostAccountsDao.setOtherAccounts('web', ['deploy', 'root']);
    var told = 0;
    final listening = db.tableUpdates(TableUpdateQuery.onTable(db.hostAccounts)).listen((_) => told++);
    addTearDown(listening.cancel);
    await db.hostAccountsDao.setOtherAccounts('web', ['deploy', 'root']);
    await pumpEventQueue();
    expect(told, 0);
    await db.hostAccountsDao.setOtherAccounts('web', ['root', 'deploy']);
    await pumpEventQueue();
    expect(told, greaterThan(0), reason: 'another order is a change');
    expect(await db.hostAccountsDao.otherAccountsOf('web'), ['root', 'deploy']);
  });

  test('an identity that goes leaves every host; where it was the default, the first other account takes its place',
      () async {
    await host('web', identityId: 'alex');
    await db.hostAccountsDao.setOtherAccounts('web', ['deploy', 'root']);
    await host('db', identityId: 'root');
    await db.hostAccountsDao.setOtherAccounts('db', ['alex']);
    await host('nas', identityId: 'alex');
    await host('lab');
    await db.hostAccountsDao.removeIdentity('alex');
    expect(await defaultOf('web'), 'deploy');
    expect(await db.hostAccountsDao.otherAccountsOf('web'), ['root']);
    expect(await defaultOf('db'), 'root');
    expect(await db.hostAccountsDao.otherAccountsOf('db'), isEmpty);
    expect(await defaultOf('nas'), isNull, reason: 'no other account to take its place');
    expect(await defaultOf('lab'), isNull);
  });

  test('a host deleted takes its other accounts with it; a duplicate is signed in to as its original', () async {
    final hosts = ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);
    await host('web', identityId: 'alex');
    await db.hostAccountsDao.setOtherAccounts('web', ['deploy', 'root']);
    final source = await (db.select(db.connections)..where((c) => c.id.equals('web'))).getSingle();
    final copy = await hosts.duplicate(source, label: 'web (copy)');
    expect(await defaultOf(copy), 'alex');
    expect(await db.hostAccountsDao.otherAccountsOf(copy), ['deploy', 'root']);

    await hosts.delete('web');
    expect(await db.hostAccountsDao.otherAccountsOf('web'), isEmpty);
    expect(await db.hostAccountsDao.otherAccountsOf(copy), ['deploy', 'root'], reason: 'the copy keeps its own');
  });

  test('deleting an identity in the app is what takes it off the hosts', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final keys = IdentityCrudNotifier(
      db.identitiesDao,
      IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()),
      db.connectionsDao,
    );
    await host('web', identityId: 'alex');
    await db.hostAccountsDao.setOtherAccounts('web', ['root']);
    await host('db', identityId: 'root');
    await keys.delete('alex');
    expect(await defaultOf('web'), 'root');
    expect(await db.hostAccountsDao.otherAccountsOf('web'), isEmpty);
    await keys.delete('root');
    expect((await defaultOf('web'), await defaultOf('db')), (null, null));
    expect(await db.select(db.hostAccounts).get(), isEmpty);
  });
}

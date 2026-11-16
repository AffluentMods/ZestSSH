import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A host's other accounts in sync (3.0, accounts per host; blob v22): they
/// travel as `host_accounts`, `{hostId: [identityIds in order]}`, and a
/// restore makes each host's list the blob's for every host the blob holds,
/// as the host's own row is taken; a host only one device has keeps its own.
/// The blob is untrusted: only identities that are there, bounded, never the
/// host's default. A deleted host or identity takes its rows with it.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const storage = FlutterSecureStorage();
  late SettingsService settings;
  final dbs = <AppDatabase>[];

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    settings = SettingsService(await SharedPreferences.getInstance());
  });

  tearDown(() async {
    for (final db in dbs) {
      await db.close();
    }
    dbs.clear();
  });

  Future<AppDatabase> device({bool withData = true}) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    dbs.add(db);
    if (!withData) return db;
    for (final user in ['alex', 'root', 'deploy']) {
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: user,
            label: '$user key',
            username: user,
            authMethod: 'publicKey',
            createdAt: DateTime.utc(2026, 10, 15),
            updatedAt: Value(DateTime.utc(2026, 10, 15)),
          ));
    }
    for (final (id, identity) in [('web', 'alex'), ('db', 'root')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: id,
            host: '$id.example.com',
            identityId: Value(identity),
            createdAt: DateTime.utc(2026, 10, 15),
            updatedAt: DateTime.utc(2026, 10, 15),
          ));
    }
    await db.hostAccountsDao.setOtherAccounts('web', ['root', 'deploy']);
    return db;
  }

  SyncDataService sync(AppDatabase db) => memoryDataService(db, storage, settings);

  test('they travel in order, for the hosts that have any, in blob 22', () async {
    final a = await device();
    final blob = await sync(a).gatherAll();
    expect(blob['schema_version'], 22);
    expect(SyncDataService.supportedSchemaVersion, 22);
    expect(blob['host_accounts'], {
      'web': ['root', 'deploy'],
    });
  });

  test('restored on another device as they were; taking the last one off travels too', () async {
    final a = await device();
    final b = await device(withData: false);
    expect((await sync(b).restoreAll(await sync(a).gatherAll())).success, isTrue);
    expect(await b.hostAccountsDao.otherAccountsOf('web'), ['root', 'deploy']);
    expect(await b.hostAccountsDao.otherAccountsOf('db'), isEmpty);

    await a.hostAccountsDao.setOtherAccounts('web', const []);
    final blob = await sync(a).gatherAll();
    expect(blob['host_accounts'], isEmpty);
    await sync(b).restoreAll(blob);
    expect(await b.hostAccountsDao.otherAccountsOf('web'), isEmpty);
  });

  test('a host only this device has keeps its own; a blob without the list changes nothing', () async {
    final a = await device();
    final b = await device();
    await b.into(b.connections).insert(ConnectionsCompanion.insert(
          id: 'lab',
          label: 'lab',
          host: 'lab.example.com',
          identityId: const Value('deploy'),
          createdAt: DateTime.utc(2026, 10, 15),
          updatedAt: DateTime.utc(2026, 10, 15),
        ));
    await b.hostAccountsDao.setOtherAccounts('lab', ['alex']);
    await a.hostAccountsDao.setOtherAccounts('web', ['deploy']);
    await sync(b).restoreAll(await sync(a).gatherAll());
    expect(await b.hostAccountsDao.otherAccountsOf('lab'), ['alex']);
    expect(await b.hostAccountsDao.otherAccountsOf('web'), ['deploy']);

    final without = await sync(a).gatherAll()..remove('host_accounts');
    await b.hostAccountsDao.setOtherAccounts('web', ['root']);
    await sync(b).restoreAll(without);
    expect(await b.hostAccountsDao.otherAccountsOf('web'), ['root']);
  });

  test('from an untrusted blob: only identities that are here, each once, never the default, and so many at most',
      () async {
    final a = await device();
    final b = await device();
    final blob = await sync(a).gatherAll();
    blob['host_accounts'] = {
      'web': ['root', 'nobody', 42, 'x' * 200, 'alex', 'root', 'deploy'],
      'db': [for (var i = 0; i < 64; i++) 'missing-$i', 'deploy'],
      'ghost': ['root'],
    };
    await sync(b).restoreAll(jsonDecode(jsonEncode(blob)) as Map<String, dynamic>);
    expect(await b.hostAccountsDao.otherAccountsOf('web'), ['root', 'deploy']);
    expect(await b.hostAccountsDao.otherAccountsOf('db'), isEmpty, reason: 'the 65th of a list is not read');
    expect(await b.hostAccountsDao.otherAccountsOf('ghost'), isEmpty);

    blob['host_accounts'] = {
      'db': [for (var i = 0; i < 63; i++) 'missing-$i', 'deploy'],
    };
    await sync(b).restoreAll(jsonDecode(jsonEncode(blob)) as Map<String, dynamic>);
    expect(await b.hostAccountsDao.otherAccountsOf('db'), ['deploy'], reason: 'the 64th is');
  });

  test('a change of accounts alone is a change to push', () async {
    final a = await device();
    final key = List<int>.filled(32, 7);
    final before = SyncDataService.contentFingerprint(await sync(a).gatherAll(), key);
    expect(SyncDataService.contentFingerprint(await sync(a).gatherAll(), key), before);
    await a.hostAccountsDao.setOtherAccounts('web', ['deploy', 'root']);
    expect(SyncDataService.contentFingerprint(await sync(a).gatherAll(), key), isNot(before));
  });

  test('a host deleted on one device takes its accounts with it on the other; so does an identity, and a leftover',
      () async {
    final a = await device();
    final b = await device(withData: false);
    await sync(b).restoreAll(await sync(a).gatherAll());
    expect(await b.hostAccountsDao.otherAccountsOf('web'), ['root', 'deploy']);

    // A host only this device has, with an account that the other device
    // deletes: the blob says nothing of this host, so only the sweep takes
    // the row that names the identity that is gone.
    await b.into(b.connections).insert(ConnectionsCompanion.insert(
          id: 'lab',
          label: 'lab',
          host: 'lab.example.com',
          identityId: const Value('alex'),
          createdAt: DateTime.utc(2026, 10, 15),
          updatedAt: DateTime.utc(2026, 10, 15),
        ));
    await b.hostAccountsDao.setOtherAccounts('lab', ['deploy']);

    await ConnectionCrudNotifier(a.connectionsDao, a.portForwardRulesDao, a.connectionTagsDao).delete('web');
    await a.identitiesDao.deleteIdentity('deploy');
    await b.into(b.hostAccounts).insert(HostAccountsCompanion.insert(connectionId: 'ghost', identityId: 'root', position: 0));
    await sync(b).restoreAll(await sync(a).gatherAll());
    expect(await (b.select(b.connections)..where((c) => c.id.equals('web'))).getSingleOrNull(), isNull);
    expect(await (b.select(b.identities)..where((i) => i.id.equals('deploy'))).getSingleOrNull(), isNull);
    expect(await b.hostAccountsDao.otherAccountsOf('lab'), isEmpty);
    expect(await b.select(b.hostAccounts).get(), isEmpty);
  });
}

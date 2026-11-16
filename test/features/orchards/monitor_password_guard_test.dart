import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';

import '../../helpers/orchard_db_fixture.dart';

/// The host monitor signs in by itself (3.0): a password this
/// account may not see goes only to a host it cannot change, so a host it
/// could point elsewhere is simply not polled with it; nor is one from a
/// Crate that asks again, which only the person can let go there.

const _keysConnect = '12121212-1212-4212-8212-121212121212';
const _hostsConnect = '34343434-3434-4434-8434-343434343434';
const _keysAsk = '56565656-5656-4565-8565-565656565656';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late ProviderContainer container;
  late String keyId;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db); // the Crate new items go to: everything
    Future<void> crate(String id, Set<String> switches) => db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'connect', ?, 1)",
        [id, jsonEncode(switchList(switches))]);
    await crate(_keysConnect, levelSwitches(CrateLevel.connect));
    await crate(_hostsConnect, levelSwitches(CrateLevel.connect));
    final crud = IdentityCrudNotifier(
        db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
    keyId = await crud.create(label: 'prod', username: 'deploy', authMethod: 'password', password: 'hunter2');
    final now = DateTime(2026, 9, 24);
    for (final id in ['h-mine', 'h-team']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '10.0.0.1',
          port: const Value(22),
          identityId: Value(keyId),
          createdAt: now,
          updatedAt: now));
    }
    // As the sync engine leaves them: the key at Connect, one host in a
    // Crate this account may change (where new items go), one in a Crate it
    // may not.
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement(
        'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
        "('key', ?, ?, 1), ('host', 'h-mine', ?, 1), ('host', 'h-team', ?, 1)",
        [keyId, _keysConnect, kFixtureCrateId, _hostsConnect]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      identitiesDaoProvider.overrideWithValue(db.identitiesDao),
      identityCrudProvider.overrideWithValue(crud),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<Connection> host(String id) async =>
      (await (db.select(db.connections)..where((c) => c.id.equals(id))).get()).single;

  test('a hidden password is not sent to a host this account could re-point', () async {
    final factory = container.read(sshConnectionFactoryProvider);
    expect(await factory.resolveCredentialsSilently(await host('h-mine')), isNull);
    final team = await factory.resolveCredentialsSilently(await host('h-team'));
    expect(team?.password, 'hunter2', reason: 'a host someone else keeps: used, never shown');
  });

  test('nor one from a Crate that asks again: nobody is here to confirm it is them', () async {
    // The key at Use (shown to this account), in a Crate that asks again.
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, confirm_reveal) VALUES (?, 'c', 'use', ?, 1, 1)",
        [_keysAsk, jsonEncode(switchList(levelSwitches(CrateLevel.use)))]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement(
        "UPDATE crate_items_meta SET crate_id = ? WHERE kind = 'key' AND item_key = ?", [_keysAsk, keyId]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');

    final factory = container.read(sshConnectionFactoryProvider);
    expect(await factory.resolveCredentialsSilently(await host('h-mine')), isNull,
        reason: 'a host this account may change: the person confirms first');
    final team = await factory.resolveCredentialsSilently(await host('h-team'));
    expect(team?.password, 'hunter2', reason: 'a host someone else keeps: used without asking');
  });
}

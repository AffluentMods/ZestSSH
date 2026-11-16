import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
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

/// Server Monitor signs in by itself, and with a key that has a password
/// saved with it as that, it has the password too, tried after the key
/// (3.0, accounts per host): where it may go with nobody to ask. Not one an
/// Orchard keeps from this account, to a host it may change, nor one
/// from a Crate that asks again, to such a host: the key alone there,
/// and where the password cannot be read. A password only left from before
/// the identity became a key is never taken.

const _keysConnect = '12121212-1212-4212-8212-121212121212';
const _hostsConnect = '34343434-3434-4434-8434-343434343434';
const _keysAsk = '56565656-5656-4565-8565-565656565656';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const saved = 'correct-horse-battery';
  final pem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();

  late AppDatabase db;
  late ProviderContainer container;
  late String keyId;

  /// A key with [saved] saved with it, tried after it where [afterKey], in
  /// [db] (an Orchard's where [orchard]), and two hosts it signs in to:
  /// h-mine, which this account may change, and h-team, which it may not.
  /// The store of secrets is [secrets] where one is given.
  Future<void> start({bool orchard = false, bool afterKey = true, IdentitySecretStore? secrets}) async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: orchard);
    if (orchard) {
      await seedOrchardAsOwner(db);
      Future<void> crate(String id, CrateLevel level, {bool asksAgain = false}) => db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, confirm_reveal) '
          "VALUES (?, 'c', ?, ?, 1, ?)",
          [id, level.name, jsonEncode(switchList(levelSwitches(level))), asksAgain ? 1 : 0]);
      await crate(_keysConnect, CrateLevel.connect);
      await crate(_hostsConnect, CrateLevel.connect);
      await crate(_keysAsk, CrateLevel.use, asksAgain: true);
    }
    final store = IdentitySecretStore.forDatabase(db, const FlutterSecureStorage());
    keyId = await IdentityCrudNotifier(db.identitiesDao, store, db.connectionsDao)
        .create(label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: pem, password: saved);
    await (db.update(db.identities)..where((i) => i.id.equals(keyId)))
        .write(IdentitiesCompanion(passwordAfterKey: Value(afterKey)));
    final now = DateTime(2026, 10, 15);
    for (final id in ['h-mine', 'h-team']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id, label: id, host: '$id.example.com', identityId: Value(keyId), createdAt: now, updatedAt: now));
    }
    if (orchard) {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await db.customStatement(
          'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
          "('key', ?, ?, 1), ('host', 'h-mine', ?, 1), ('host', 'h-team', ?, 1)",
          [keyId, kFixtureCrateId, kFixtureCrateId, _hostsConnect]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      identitiesDaoProvider.overrideWithValue(db.identitiesDao),
      identityCrudProvider.overrideWithValue(
          IdentityCrudNotifier(db.identitiesDao, secrets ?? store, db.connectionsDao)),
    ]);
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// What the monitor signs in to the host [id] with: the password, and
  /// whether it has the key. Null: it does not poll the host.
  Future<({String? password, bool key})?> monitorSignsIn(String id) async {
    final host = (await (db.select(db.connections)..where((c) => c.id.equals(id))).get()).single;
    final creds = await container.read(sshConnectionFactoryProvider).resolveCredentialsSilently(host);
    return creds == null ? null : (password: creds.password, key: creds.keyPairs?.isNotEmpty ?? false);
  }

  Future<void> keyIn(String crateId) async {
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement(
        "UPDATE crate_items_meta SET crate_id = ? WHERE kind = 'key' AND item_key = ?", [crateId, keyId]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  test('your Tree: the key, and the password after it', () async {
    await start();
    expect(await monitorSignsIn('h-mine'), (password: saved, key: true));
  });

  test('a password only left from before the identity became a key: the key alone', () async {
    await start(afterKey: false);
    expect(await monitorSignsIn('h-mine'), (password: null, key: true));
  });

  test('one that cannot be read: the key alone', () async {
    await start(secrets: _PasswordUnreadable(const SecureStorageIdentitySecrets(FlutterSecureStorage())));
    expect(await monitorSignsIn('h-mine'), (password: null, key: true));
  });

  test('an Orchard password this account may not see: the key alone to a host it may change', () async {
    await start(orchard: true);
    await keyIn(_keysConnect);
    expect(await monitorSignsIn('h-mine'), (password: null, key: true));
    expect(await monitorSignsIn('h-team'), (password: saved, key: true));
  });

  test('one from a Crate that asks again: the key alone to a host it may change, nobody being here to confirm',
      () async {
    await start(orchard: true);
    await keyIn(_keysAsk);
    expect(await monitorSignsIn('h-mine'), (password: null, key: true));
    expect(await monitorSignsIn('h-team'), (password: saved, key: true));
  });
}

/// The store of [_inner], where the password cannot be read: as on a device
/// whose keychain lost the entry.
class _PasswordUnreadable implements IdentitySecretStore {
  _PasswordUnreadable(this._inner);

  final IdentitySecretStore _inner;

  @override
  Future<String?> read(String identityId, IdentitySecret secret) async => secret == IdentitySecret.password
      ? throw PlatformException(code: '-25300', message: 'no such item')
      : _inner.read(identityId, secret);

  @override
  Future<void> write(String identityId, IdentitySecret secret, String? value) => _inner.write(identityId, secret, value);

  @override
  Future<void> deleteAll(String identityId) => _inner.deleteAll(identityId);
}

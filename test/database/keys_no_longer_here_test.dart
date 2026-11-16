import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory.
class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};

  /// Names whose delete fails, as a keychain that refuses does.
  final refused = <String>{};

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        return Future<String?>.value(kept[key]);
      case #write:
        final value = i.namedArguments[#value] as String?;
        value == null ? kept.remove(key) : kept[key!] = value;
        return Future<void>.value();
      case #delete:
        if (refused.contains(key)) return Future<void>.error(StateError('the keychain refused $key'));
        kept.remove(key);
        return Future<void>.value();
      case #readAll:
        return Future<Map<String, String>>.value(Map.of(kept));
      case #containsKey:
        return Future<bool>.value(kept.containsKey(key));
    }
    return super.noSuchMethod(i);
  }
}

/// A key that is no longer here is named by nothing (3.0): deleted here, it
/// left its hosts and their other accounts but a network's settings for a
/// host kept naming it; deleted on another device, or dropped by a stale
/// device adopting the cloud, what this device kept of its hosts (a host
/// kept as it is here, a network's settings for it) kept naming it. A host
/// naming a key that is not there signed in with nothing (the default user,
/// no key). Now each of them stops naming it, as deleting it here does: a
/// host whose default it was signs in with its first other account (or
/// none), and a network's settings for a host name it no more. Dropped, a
/// key's passphrase and certificate leave secure storage with the rest.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final at = DateTime.utc(2026, 10, 16, 9);
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<void> key(String id) => db.into(db.identities).insertOnConflictUpdate(IdentitiesCompanion.insert(
      id: id, label: id, username: 'deploy', authMethod: 'publicKey', createdAt: at, updatedAt: Value(at)));

  Future<void> host(String id, String? keyId) => db.into(db.connections).insert(ConnectionsCompanion.insert(
      id: id, label: id, host: '$id.example.com', identityId: Value(keyId), createdAt: at, updatedAt: at));

  Future<void> onOffice(String id, String hostId, String? keyId, {String? address}) =>
      db.into(db.hostNetworkOverrides).insert(HostNetworkOverridesCompanion.insert(
          id: id,
          connectionId: hostId,
          networkId: 'n-office',
          identityId: Value(keyId),
          address: Value(address),
          createdAt: at,
          updatedAt: at));

  Future<String?> keyOf(String hostId) async => (await db.connectionsDao.getById(hostId))!.identityId;

  Future<Map<String, String?>> officeKeys() async =>
      {for (final o in await db.select(db.hostNetworkOverrides).get()) o.id: o.identityId};

  test("deleted here: a network's settings for a host name it no more, and keep the rest", () async {
    await key('k-old');
    await key('k-other');
    await host('h-web', 'k-other');
    await onOffice('o-1', 'h-web', 'k-old', address: '10.50.0.11');
    await onOffice('o-2', 'h-db', 'k-other');
    await db.hostAccountsDao.removeIdentity('k-old');
    expect(await officeKeys(), {'o-1': null, 'o-2': 'k-other'});
    final o1 = await (db.select(db.hostNetworkOverrides)..where((o) => o.id.equals('o-1'))).getSingle();
    expect(o1.address, '10.50.0.11', reason: 'the rest of the settings stay');
  });

  test('what names a key that is not here names it no more: a host takes its first other account, or none; an '
      "other account and a network's settings are let go; keys that are here stay named", () async {
    await key('k-here');
    await key('k-next');
    await host('h-web', 'k-gone');
    await host('h-db', 'k-gone');
    await host('h-mail', 'k-here');
    await db.hostAccountsDao.setOtherAccounts('h-web', ['k-next', 'k-gone']);
    await db.hostAccountsDao.setOtherAccounts('h-mail', ['k-gone', 'k-next', 'k-only-account']);
    await onOffice('o-1', 'h-mail', 'k-gone');
    await onOffice('o-2', 'h-mail', 'k-here');
    // Gone keys named nowhere else: only as another account, only by a
    // network's settings.
    await onOffice('o-3', 'h-db', 'k-only-network');

    await db.hostAccountsDao.forgetMissingIdentities();
    expect(await keyOf('h-web'), 'k-next', reason: 'its first other account');
    expect(await keyOf('h-db'), isNull);
    expect(await keyOf('h-mail'), 'k-here');
    expect(await db.hostAccountsDao.otherAccountsOf('h-web'), isEmpty);
    expect(await db.hostAccountsDao.otherAccountsOf('h-mail'), ['k-next']);
    expect(await officeKeys(), {'o-1': null, 'o-2': 'k-here', 'o-3': null});
  });

  group('through sync', () {
    late _Vault vault;
    late SyncDataService data;

    setUp(() async {
      SharedPreferences.setMockInitialValues(const {});
      vault = _Vault();
      data = memoryDataService(db, vault, SettingsService(await SharedPreferences.getInstance()));
    });

    test('a key deleted on another device: what this device kept of its hosts names it no more', () async {
      await key('k-gone');
      await key('k-stays');
      await host('h-web', 'k-gone');
      await onOffice('o-1', 'h-web', 'k-gone');
      final blob = await data.gatherAll();
      // The other device has deleted k-gone (and its host's default with it,
      // a change this device's own copy of the host is kept over).
      blob['identities'] = [for (final i in blob['identities'] as List) if ((i as Map)['id'] != 'k-gone') i];
      blob['tombstones'] = [
        {'entityType': 'identities', 'entityId': 'k-gone', 'deletedAt': at.add(const Duration(hours: 1)).toIso8601String()},
      ];
      expect((await data.restoreAll(blob)).success, isTrue);
      expect(await db.identitiesDao.getById('k-gone'), isNull);
      expect(await keyOf('h-web'), isNull);
      expect(await officeKeys(), {'o-1': null});
    });

    test('dropped by a stale device adopting the cloud: named no more, its passphrase and certificate gone too',
        () async {
      await key('k-local');
      await host('h-web', 'k-local');
      vault.kept
        ..['identity_key_k-local'] = 'PEM'
        ..['identity_passphrase_k-local'] = 'a passphrase'
        ..['identity_cert_k-local'] = 'Y2VydA=='
        ..['identity_password_k-local'] = 'a password';
      await data.dropLocalOnly(const StaleReconcileReport({'identities': ['k-local']}));
      expect(await db.identitiesDao.getById('k-local'), isNull);
      expect(await keyOf('h-web'), isNull);
      expect(vault.kept.keys.where((k) => k.contains('k-local')), isEmpty);
    });

    // Fixed in 3.4.2: the secrets went first, one by one, and a failure part
    // way left the key listed with some of its secrets gone.
    test('dropped while a secret cannot be deleted: the key and what names it are gone, never listed half', () async {
      await key('k-local');
      await host('h-web', 'k-local');
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: 's-local', label: 'Uptime', command: 'uptime', createdAt: at, updatedAt: at));
      vault.kept
        ..['identity_password_k-local'] = 'a password'
        ..['identity_key_k-local'] = 'PEM';
      vault.refused.add('identity_key_k-local');
      await data.dropLocalOnly(const StaleReconcileReport({
        'identities': ['k-local'],
        'snippets': ['s-local'],
      }));
      expect(await db.identitiesDao.getById('k-local'), isNull, reason: 'dropped, as the person chose');
      expect(await keyOf('h-web'), isNull);
      expect(await db.select(db.snippets).get(), isEmpty, reason: 'the rest of the drop went through');
      expect(vault.kept['identity_password_k-local'], isNull);
      expect(vault.kept['identity_key_k-local'], 'PEM', reason: 'left with no key, for the sweep of such secrets');
    });
  });
}

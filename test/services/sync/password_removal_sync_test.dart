import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory.
class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};

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

class _Device {
  _Device(SettingsService settings)
      : db = AppDatabase.forTesting(NativeDatabase.memory()),
        vault = _Vault() {
    data = memoryDataService(db, vault, settings);
  }

  final AppDatabase db;
  final _Vault vault;
  late final SyncDataService data;
}

/// A saved password taken off a key on one device (moved into a password
/// manager, or removed) is taken off it on the person's other devices by sync,
/// and no device's push brings it back. A pull wrote only the secrets a blob
/// held, so the removal never travelled, and the next push of another device
/// (which sends every secret it holds) put the password back on the device it
/// was taken off (found in a data review). Where this device changed
/// the key too, the store went back, or the blob's writer sent no passphrase or
/// certificate (before version 22), what is here is kept.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final mergeKey = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final t1 = DateTime.utc(2026, 10, 2, 9);
  final t2 = DateTime.utc(2026, 10, 3, 9);
  late SettingsService settings;
  late _Device a;
  late _Device b;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    a = _Device(settings);
    b = _Device(settings);
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  Future<void> passwordKey(_Device d) async {
    await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'web', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
    d.vault.kept['identity_password_k-1'] = 'the old password';
  }

  Future<void> keyWithPassphrase(_Device d) async {
    await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-2', label: 'deploy key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    d.vault.kept['identity_key_k-2'] = '-----BEGIN OPENSSH PRIVATE KEY----- made up';
    d.vault.kept['identity_passphrase_k-2'] = 'made-up passphrase';
  }

  /// "Move to a password manager" on [d]: the key names where the password is,
  /// and ZestSSH keeps none for it (IdentityCrudNotifier.clearSecrets).
  Future<void> moveToPasswordManager(_Device d) async {
    final ref = PasswordRef.onePassword('op://Private/web1/password')!.encode();
    await (d.db.update(d.db.identities)..where((t) => t.id.equals('k-1'))).write(
        IdentitiesCompanion(authMethod: const Value('passwordManager'), passwordRef: Value(ref), updatedAt: Value(t1)));
    d.vault.kept.remove('identity_password_k-1');
  }

  test('a password moved into a password manager on A is taken off B, and B\'s next push does not bring it back', () async {
    await passwordKey(a);
    await passwordKey(b);
    final last = SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey);

    await moveToPasswordManager(a);
    final pushedByA = await a.data.gatherAll();
    final baseOfA = SyncDataService.itemHashes(pushedByA, mergeKey);

    expect((await b.data.restoreAll(pushedByA, merge: SyncMergeBase(key: mergeKey, base: last))).success, isTrue);
    expect((await b.db.identitiesDao.getById('k-1'))!.authMethod, 'passwordManager');
    expect(b.vault.kept['identity_password_k-1'], isNull, reason: 'the password taken out of ZestSSH on A stayed on B');

    final pushedByB = await b.data.gatherAll();
    expect((await a.data.restoreAll(pushedByB, merge: SyncMergeBase(key: mergeKey, base: baseOfA))).success, isTrue);
    expect(a.vault.kept['identity_password_k-1'], isNull, reason: 'the removed password came back to A from B');
  });

  test('a passphrase removed from a key on A is removed on B; its private key stays', () async {
    await keyWithPassphrase(a);
    await keyWithPassphrase(b);
    final last = SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey);
    await (a.db.update(a.db.identities)..where((t) => t.id.equals('k-2'))).write(IdentitiesCompanion(updatedAt: Value(t1)));
    a.vault.kept.remove('identity_passphrase_k-2');

    expect((await b.data.restoreAll(await a.data.gatherAll(), merge: SyncMergeBase(key: mergeKey, base: last))).success,
        isTrue);
    expect(b.vault.kept['identity_passphrase_k-2'], isNull);
    expect(b.vault.kept['identity_key_k-2'], isNotNull);
  });

  test('where B changed the key too, B keeps its password', () async {
    await passwordKey(a);
    await passwordKey(b);
    final last = SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey);
    await moveToPasswordManager(a);
    // B renamed the key after A moved its password.
    await (b.db.update(b.db.identities)..where((t) => t.id.equals('k-1')))
        .write(IdentitiesCompanion(label: const Value('web renamed'), updatedAt: Value(t2)));

    expect((await b.data.restoreAll(await a.data.gatherAll(), merge: SyncMergeBase(key: mergeKey, base: last))).success,
        isTrue);
    expect(b.vault.kept['identity_password_k-1'], 'the old password');
  });

  test('a store that went back takes no secret off a key', () async {
    await passwordKey(a);
    await passwordKey(b);
    final last = SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey);
    await moveToPasswordManager(a);

    final pulled = await b.data
        .restoreAll(await a.data.gatherAll(), merge: SyncMergeBase(key: mergeKey, base: last, storeWentBack: true));
    expect(pulled.success, isTrue);
    expect(b.vault.kept['identity_password_k-1'], 'the old password');
  });

  test('a blob older than version 22 (its writer sent no passphrase) takes none off a key', () async {
    await keyWithPassphrase(a);
    await keyWithPassphrase(b);
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), mergeKey);
    // An older device's push: the key renamed there, its secrets without the passphrase.
    await (a.db.update(a.db.identities)..where((t) => t.id.equals('k-2')))
        .write(IdentitiesCompanion(label: const Value('renamed there'), updatedAt: Value(t1)));
    final old = await a.data.gatherAll();
    old['schema_version'] = 21;
    (old['secrets'] as Map)['k-2'] = {'privateKey': '-----BEGIN OPENSSH PRIVATE KEY----- made up'};

    expect((await b.data.restoreAll(old, merge: SyncMergeBase(key: mergeKey, base: last))).success, isTrue);
    expect((await b.db.identitiesDao.getById('k-2'))!.label, 'renamed there');
    expect(b.vault.kept['identity_passphrase_k-2'], 'made-up passphrase');
  });
}

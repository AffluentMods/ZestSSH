
import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/password_change.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

Future<void> _addHost(AppDatabase db, String id) => db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value('host-$id'),
      host: Value('$id.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 11, 7)),
      updatedAt: Value(DateTime.utc(2026, 11, 7)),
    ));

/// Changing the sync password reads the store, asks for the new password
/// (typed twice), and writes the store again under it. The write named no
/// version: a device that synced while the password was being typed had its
/// upload replaced by the copy read before it. The write is now made only
/// onto the version that was read, and where the store has moved on it is
/// read again and the change made on what it holds now.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
  const storage = FlutterSecureStorage();

  late SettingsService settings;
  late AppDatabase one;
  late AppDatabase two;
  late SyncDataService dataOne;
  late SyncDataService dataTwo;
  late MemoryStoreBackend store;
  late SecretKey dek;
  late SecretKey mek;
  late Uint8List salt;
  late Uint8List verHash;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    settings = SettingsService(await SharedPreferences.getInstance());
    one = AppDatabase.forTesting(NativeDatabase.memory());
    two = AppDatabase.forTesting(NativeDatabase.memory());
    dataOne = memoryDataService(one, storage, settings);
    dataTwo = memoryDataService(two, storage, settings);
    store = MemoryStoreBackend(MemoryStore());
    salt = SyncService.generateSalt();
    dek = SyncService.generateDek();
    mek = await SyncService.deriveKey('the old password', salt, params: fast);
    verHash = await SyncService.computeVerificationHash(mek);
    await _addHost(one, 'a1');
    await _addHost(two, 'a1');
    await store.push(
      data: await dataOne.gatherAll(),
      dek: dek,
      salt: salt,
      verificationHash: verHash,
      wrappedDekPassword: await SyncService.wrapDek(dek, mek),
      createOnly: true,
      argon2Params: fast,
    );
  });

  tearDown(() async {
    await one.close();
    await two.close();
  });

  Future<Set<String>> hostsInStore() async {
    final pulled = await store.pull();
    final data = await SyncService.decrypt(pulled.encryptedData, dek);
    return {for (final c in data['connections'] as List) (c as Map)['id'] as String};
  }

  /// The other device adds a host and syncs, onto [version].
  Future<int> otherDeviceSyncs(String host, int version, {Uint8List? withSalt, SecretKey? withMek}) async {
    await _addHost(two, host);
    final s = withSalt ?? salt;
    final m = withMek ?? mek;
    return (await store.push(
      data: await dataTwo.gatherAll(),
      dek: dek,
      salt: s,
      verificationHash: await SyncService.computeVerificationHash(m),
      wrappedDekPassword: withMek == null ? null : await SyncService.wrapDek(dek, m),
      expectedVersion: version,
      argon2Params: fast,
    ))
        .version;
  }

  Future<PasswordChangeWritten> change(SyncPullResult read, {SyncBackend? through}) => pushPasswordChange(
        backend: through ?? store,
        pulled: read,
        dek: dek,
        currentMek: mek,
        newPassword: 'the new password',
        oldVerificationHash: verHash,
        stamp: dataOne.stampForPush,
      );

  test('with nothing in between, the store is written once under the new password', () async {
    final read = await store.pull();
    final written = await change(read);
    expect(written.version, read.version + 1);
    final now = await store.pull();
    expect(now.salt, written.salt);
    expect(await SyncService.unwrapDek(now.wrappedDekPassword!, written.mek), isNotNull);
    await expectLater(SyncService.unwrapDek(now.wrappedDekPassword!, mek), throwsA(anything),
        reason: 'the old password no longer opens it');
    expect(await hostsInStore(), {'a1'});
  });

  test('a device that synced while the new password was typed keeps what it sent', () async {
    final read = await store.pull();
    // Meanwhile, on the other device:
    final v2 = await otherDeviceSyncs('b2', read.version);

    final written = await change(read);
    expect(written.version, v2 + 1, reason: 'written onto what the store held then');
    expect(await hostsInStore(), {'a1', 'b2'}, reason: "the other device's host is still in the store");
    final now = await store.pull();
    expect(await SyncService.unwrapDek(now.wrappedDekPassword!, written.mek), isNotNull);
  });

  test('a store whose password was changed elsewhere meanwhile is not written over', () async {
    final read = await store.pull();
    final otherSalt = SyncService.generateSalt();
    final otherMek = await SyncService.deriveKey('changed on the other device', otherSalt, params: fast);
    final v2 = await otherDeviceSyncs('b2', read.version, withSalt: otherSalt, withMek: otherMek);

    await expectLater(change(read), throwsA(isA<SyncConflictException>()));
    final now = await store.pull();
    expect(now.version, v2, reason: 'nothing was written');
    expect(await SyncService.unwrapDek(now.wrappedDekPassword!, otherMek), isNotNull);
    expect(await hostsInStore(), {'a1', 'b2'});
  });

  test('which stores refuse a write that crosses another: said for the two that do not', () {
    expect({for (final kind in SyncBackendKind.values) if (!kind.refusesCrossingWrites) kind},
        {SyncBackendKind.webdav, SyncBackendKind.googleDrive});
  });
}

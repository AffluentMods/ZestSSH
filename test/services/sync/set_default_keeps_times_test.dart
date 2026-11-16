import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// "Set as default" on a key writes only the keys whose flag changes
/// (IdentitiesDao.setDefault). It wrote every key, and the database stamps a
/// row an UPDATE touches as changed now, so every key read as just edited: a
/// key deleted on another device before this one pulled outlived the
/// tombstone here (edit beats delete), and the next push sent it, private key
/// and all, back to every device (found in a data review).
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final t0 = DateTime.utc(2026, 10, 1, 9);
  late AppDatabase db;
  late SyncDataService data;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    FlutterSecureStorage.setMockInitialValues({});
    final settings = SettingsService(await SharedPreferences.getInstance());
    db = AppDatabase.forTesting(NativeDatabase.memory());
    data = memoryDataService(db, const FlutterSecureStorage(), settings);
  });

  tearDown(() => db.close());

  Future<void> key(String id, {bool isDefault = false}) => db.into(db.identities).insert(IdentitiesCompanion.insert(
      id: id,
      label: id,
      username: 'deploy',
      authMethod: 'publicKey',
      isDefault: Value(isDefault),
      createdAt: t0,
      updatedAt: Value(t0)));

  test('only the keys whose default flag changes are stamped as changed', () async {
    await key('k-was', isDefault: true);
    await key('k-new');
    await key('k-other');

    await db.identitiesDao.setDefault('k-new');

    final was = (await db.identitiesDao.getById('k-was'))!;
    final now = (await db.identitiesDao.getById('k-new'))!;
    final other = (await db.identitiesDao.getById('k-other'))!;
    expect((was.isDefault, now.isDefault, other.isDefault), (false, true, false));
    expect(other.updatedAt!.toUtc(), t0, reason: 'a key whose flag did not change is no changed key');
    expect(was.updatedAt!.isAfter(t0), isTrue, reason: 'the old default did change');
    expect(now.updatedAt!.isAfter(t0), isTrue);

    // Setting the default it already has changes nothing.
    final before = (await db.identitiesDao.getById('k-new'))!.updatedAt;
    await db.identitiesDao.setDefault('k-new');
    expect((await db.identitiesDao.getById('k-new'))!.updatedAt, before);
    expect((await db.identitiesDao.getById('k-other'))!.updatedAt!.toUtc(), t0);
  });

  test('a key deleted elsewhere is deleted here though another key was set as default meanwhile', () async {
    await key('k-old');
    await key('k-new');
    // Another device deleted k-old a while ago (its tombstone is in the store).
    final deletedAt = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
    // Here, before this device pulls, the person makes k-new the default.
    await db.identitiesDao.setDefault('k-new');
    expect((await db.identitiesDao.getById('k-old'))!.updatedAt!.toUtc(), t0);

    // The pull brings the other device's tombstone for k-old.
    final blob = await data.gatherAll()
      ..['identities'] = <Object>[]
      ..['tombstones'] = [
        {'entityType': 'identities', 'entityId': 'k-old', 'deletedAt': deletedAt.toIso8601String()},
      ];
    expect((await data.restoreAll(blob)).success, isTrue);
    expect(await db.identitiesDao.getById('k-old'), isNull, reason: 'the key deleted on the other device stays here');
    expect(await db.identitiesDao.getById('k-new'), isNotNull);
  });
}

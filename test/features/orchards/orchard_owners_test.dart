import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';

/// Each team on a device is the account's that joined it; before,
/// every team on the device was listed for whoever signed in, and a team
/// showed, with errors, to an account that was not in it. It is listed and
/// opened for its own account only, and stays on the device for the others.
class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// Databases in files, as on a device: what a closed one held is there
/// when it opens again (an in-memory one is gone with its close).
class _FileStorage implements OrchardDatabaseStorage {
  _FileStorage(this.dir);

  final Directory dir;

  File _file(String orchardId) => File('${dir.path}${Platform.pathSeparator}$orchardId.db');

  @override
  Future<bool> exists(String orchardId) => _file(orchardId).exists();

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      AppDatabase.forTesting(NativeDatabase(_file(orchardId)), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async {
    if (await _file(orchardId).exists()) await _file(orchardId).delete();
  }

  @override
  Future<List<String>> list() async => [
        for (final f in dir.listSync())
          if (f.path.endsWith('.db')) f.uri.pathSegments.last.replaceAll('.db', ''),
      ];
}

Future<_FileStorage> _files() async {
  final dir = await Directory.systemTemp.createTemp('orchard_owners_');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {/* a file still held: the system's temp folder clears it */}
  });
  return _FileStorage(dir);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  test('a team is listed and opened for the account that joined it, and for no other; nothing is deleted', () async {
    const secure = FlutterSecureStorage();
    final storage = _MemoryStorage();
    String? signedIn = 'uid-alex';
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure),
        storage: storage, owners: OrchardOwners(secure), account: () => signedIn);
    addTearDown(databases.closeAll);

    await databases.open('team-a');
    expect(await databases.onDevice(), ['team-a']);
    expect(await OrchardOwners(secure).read(), {'team-a': 'uid-alex'});

    // Signed out: nothing is listed, and nothing opens.
    await databases.closeAll();
    signedIn = null;
    expect(await databases.onDevice(), isEmpty);
    await expectLater(databases.open('team-a'), throwsA(isA<OrchardOfAnotherAccount>()));

    // Another account: the team stays on the device, out of its sight.
    signedIn = 'uid-sam';
    expect(await databases.onDevice(), isEmpty);
    await expectLater(databases.open('team-a'), throwsA(isA<OrchardOfAnotherAccount>()));
    expect(storage.dbs.keys, ['team-a'], reason: 'kept on the device');

    // Its own team is its own.
    await databases.open('team-b');
    expect(await databases.onDevice(), ['team-b']);

    // The first account back: its team again.
    await databases.closeAll();
    signedIn = 'uid-alex';
    expect(await databases.onDevice(), ['team-a']);
    expect(await databases.open('team-a'), isNotNull);
  });

  // It went to whichever account opened it first: on a computer whose
  // first start of the new version had someone else signed in,
  // theirs.
  test('a team from before owners were kept is claimed only by an account its own record names as a member',
      () async {
    const secure = FlutterSecureStorage();
    final storage = await _files();
    // A database already on the device, with no owner kept for it, whose
    // record names alex.
    final before = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure), storage: storage);
    final db = await before.open('old-team');
    await db.customStatement("INSERT INTO member_keys (uid, role, status) VALUES ('uid-alex', 'owner', 'active')");
    await db.customStatement("INSERT INTO member_keys (uid, role, status) VALUES ('uid-kim', 'member', 'removed')");
    await before.closeAll();

    String? signedIn = 'uid-sam';
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure),
        storage: storage, owners: OrchardOwners(secure), account: () => signedIn);
    addTearDown(databases.closeAll);

    // Not a member: not listed, it does not open, and it stays nobody's.
    expect(await databases.onDevice(), isEmpty);
    await expectLater(databases.open('old-team'), throwsA(isA<OrchardOfAnotherAccount>()));
    expect(await OrchardOwners(secure).read(), isEmpty);
    expect(await storage.list(), ['old-team'], reason: 'kept on the device');

    // Someone who left it is not a member either.
    signedIn = 'uid-kim';
    expect(await databases.onDevice(), isEmpty);

    // Its member: listed, opened, and theirs from then on.
    signedIn = 'uid-alex';
    expect(await databases.onDevice(), ['old-team']);
    expect(await OrchardOwners(secure).read(), {'old-team': 'uid-alex'});
  });

  test('signed out, no team is listed or opens, not even one from before owners were kept', () async {
    const secure = FlutterSecureStorage();
    final storage = await _files();
    final before = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure), storage: storage);
    await before.open('old-team');
    await before.closeAll();

    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure),
        storage: storage, owners: OrchardOwners(secure), account: () => null);
    addTearDown(databases.closeAll);
    expect(await databases.onDevice(), isEmpty);
    await expectLater(databases.open('old-team'), throwsA(isA<OrchardOfAnotherAccount>()));
    await expectLater(databases.open('new-team'), throwsA(isA<OrchardOfAnotherAccount>()));
  });

  test('a team whose key is gone is made again, empty, for the account here', () async {
    const secure = FlutterSecureStorage();
    final storage = await _files();
    final before = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure), storage: storage);
    await before.open('old-team');
    await before.closeAll();
    await OrchardDatabaseKeys(secure).delete('old-team');

    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure),
        storage: storage, owners: OrchardOwners(secure), account: () => 'uid-sam');
    addTearDown(databases.closeAll);
    final again = await databases.open('old-team');
    expect(await again.customSelect('SELECT uid FROM member_keys').get(), isEmpty);
    expect(await OrchardOwners(secure).read(), {'old-team': 'uid-sam'});
  });

  test('forgetting a team forgets whose it was', () async {
    const secure = FlutterSecureStorage();
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(secure),
        storage: _MemoryStorage(), owners: OrchardOwners(secure), account: () => 'uid-alex');
    await databases.open('team-a');
    await databases.forget('team-a');
    expect(await OrchardOwners(secure).read(), isEmpty);
    await databases.closeAll();
  });
}

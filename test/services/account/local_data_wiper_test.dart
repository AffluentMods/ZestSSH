import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account/local_data_wiper.dart';

void main() {
  late AppDatabase db;
  late Directory root;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    root = await Directory.systemTemp.createTemp('zest-wipe-');
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('everything goes except the key of the database that is still open',
      () async {
    await db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('h1'),
      label: const Value('prod'),
      host: const Value('prod.example.com'),
      port: const Value(22),
      protocol: const Value('ssh'),
      createdAt: Value(DateTime.utc(2026, 9, 22)),
      updatedAt: Value(DateTime.utc(2026, 9, 22)),
    ));
    FlutterSecureStorage.setMockInitialValues({
      AppDatabase.encryptionKeyStorageKey: 'db-key',
      'identity_key_1': '-----BEGIN OPENSSH PRIVATE KEY-----',
      'identity_password_1': 'hunter2',
      'identity_cert_1': 'cert',
      'sync_dek': 'dek',
      'session_token': 'jwt',
    });
    SharedPreferences.setMockInitialValues({'sync_mode': 'auto', 'theme': 3});
    const storage = FlutterSecureStorage();
    final prefs = await SharedPreferences.getInstance();

    // ZestSSH's own folder, and a folder it shares with the person.
    final logs = await Directory(p.join(root.path, 'ZestSSH', 'session-logs'))
        .create(recursive: true);
    File(p.join(logs.path, 'prod.log')).writeAsStringSync('rm -rf /tmp/x');
    final shared = await Directory(p.join(root.path, 'Documents', 'profile'))
        .create(recursive: true);
    final avatar = File(p.join(shared.path, 'avatar_1726990000.png'))
      ..writeAsStringSync('png');
    final theirs = File(p.join(shared.path, 'passport.png'))
      ..writeAsStringSync('keep me');
    final migrationCopy = File(p.join(root.path, 'pre_v40.db'))
      ..writeAsStringSync('old rows');
    var databaseCopiesDeleted = false;

    await LocalDataWiper(
      database: db,
      secureStorage: storage,
      preferences: prefs,
      targets: WipeTargets(
        ownedDirectories: [Directory(p.join(root.path, 'ZestSSH'))],
        ownedFiles: [
          (
            directory: shared,
            matches: (n) => n.startsWith('avatar_') && n.endsWith('.png'),
          ),
        ],
      ),
      deleteDatabaseCopies: () async => databaseCopiesDeleted = true,
      listMigrationBackups: () async => [migrationCopy],
    ).wipe();

    expect(await db.connectionsDao.getAll(), isEmpty);
    expect(await storage.readAll(),
        {AppDatabase.encryptionKeyStorageKey: 'db-key'});
    expect(prefs.getKeys(), isEmpty);
    expect(databaseCopiesDeleted, isTrue);
    expect(migrationCopy.existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'ZestSSH')).existsSync(), isFalse);
    expect(avatar.existsSync(), isFalse);
    expect(theirs.readAsStringSync(), 'keep me',
        reason: 'only files ZestSSH wrote are removed from a shared folder');
  });

  test('missing folders are not an error', () async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await LocalDataWiper(
      database: db,
      secureStorage: const FlutterSecureStorage(),
      preferences: await SharedPreferences.getInstance(),
      targets: WipeTargets(
        ownedDirectories: [Directory(p.join(root.path, 'never-made'))],
        ownedFiles: [
          (
            directory: Directory(p.join(root.path, 'also-missing')),
            matches: (_) => true,
          ),
        ],
      ),
      deleteDatabaseCopies: () async {},
      listMigrationBackups: () async => const [],
    ).wipe();
  });
}

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/backup_dirty_watch.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The automatic backup's "changed since the last one" flag (22 October
/// 2026): it followed the host list as filtered on screen, so a search set
/// it and a change to a key, a snippet or a network did not. It follows what
/// a backup holds now.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final at = DateTime.utc(2026, 10, 22);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer();
    container.read(databaseSessionProvider.notifier).seed(db);
    container.listen(backupDirtyWatchProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  bool dirty() => container.read(backupDirtyProvider);
  void clean() => container.read(backupDirtyProvider.notifier).state = false;
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('a key, a snippet and a network changed each mark it', () async {
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'i1', label: 'deploy key', username: 'deploy', authMethod: 'publicKey', createdAt: at));
    await settle();
    expect(dirty(), isTrue, reason: 'a key');

    clean();
    await db.into(db.snippets)
        .insert(SnippetsCompanion.insert(id: 's1', label: 'Uptime', command: 'uptime', createdAt: at, updatedAt: at));
    await settle();
    expect(dirty(), isTrue, reason: 'a snippet');

    clean();
    await db.into(db.networks)
        .insert(NetworksCompanion.insert(id: 'n1', name: 'Office', iconCodePoint: 0, createdAt: at));
    await settle();
    expect(dirty(), isTrue, reason: 'a network');
  });

  test('nothing a backup holds changed, nothing is marked: the command history and a search do not', () async {
    await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(id: 'c1', command: 'ls', createdAt: at));
    await settle();
    expect(dirty(), isFalse);
  });

  // 3.4.2: every connect wrote when the host was last connected to and when
  // its key was last seen, and that alone marked it, so every connect ended
  // in a backup on going to the background and the history rolled over.
  test('a connect alone does not mark it: the host\'s last connect and its key\'s last seen are bookkeeping',
      () async {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'web', host: 'web.example.com', createdAt: at, updatedAt: at));
    await db.into(db.knownHosts).insert(KnownHostsCompanion.insert(
        id: 'k1',
        host: 'web.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:demo-one',
        publicKeyBase64: 'AAAAdemo',
        firstSeen: at,
        lastSeen: at));
    await settle();
    expect(dirty(), isTrue, reason: 'a new host and a newly trusted key are changes');

    clean();
    await db.connectionsDao.touchLastConnected('h1');
    await (db.update(db.knownHosts)..where((t) => t.id.equals('k1'))).write(KnownHostsCompanion(
        lastSeen: Value(at.add(const Duration(hours: 3))), locallyVerified: const Value(true)));
    await settle();
    expect(dirty(), isFalse, reason: 'only what a connect writes by itself changed');

    await (db.update(db.knownHosts)..where((t) => t.id.equals('k1')))
        .write(const KnownHostsCompanion(fingerprint: Value('SHA256:demo-two')));
    await settle();
    expect(dirty(), isTrue, reason: 'a host key that changed is a change');

    clean();
    await (db.update(db.connections)..where((t) => t.id.equals('h1'))).write(const ConnectionsCompanion(
        label: Value('web (prod)')));
    await settle();
    expect(dirty(), isTrue, reason: 'a host renamed is a change');
  });

  test('locked, it listens to nothing; unlocked again, to the database open then', () async {
    await container.read(databaseSessionProvider.notifier).close();
    final again = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(again.close);
    container.read(databaseSessionProvider.notifier).seed(again);
    await settle();
    await again.into(again.snippets)
        .insert(SnippetsCompanion.insert(id: 's2', label: 'Disk', command: 'df -h', createdAt: at, updatedAt: at));
    await settle();
    expect(dirty(), isTrue);
  });
}

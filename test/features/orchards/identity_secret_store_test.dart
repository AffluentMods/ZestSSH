import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import '../../helpers/orchard_db_fixture.dart';

/// Where an identity's secrets live (3.0): your Tree's keys keep
/// them in the OS secure storage under the names they always had; an
/// Orchard's keys keep them in the Orchard's own database, where they sync
/// with the key and never meet the Tree's clean-up of unknown secrets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase tree;
  late AppDatabase orchard;
  const storage = FlutterSecureStorage();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(orchard);
  });
  tearDown(() async {
    await tree.close();
    await orchard.close();
  });

  IdentityCrudNotifier crudFor(AppDatabase db) => IdentityCrudNotifier(
        db.identitiesDao,
        IdentitySecretStore.forDatabase(db, storage),
        db.connectionsDao,
      );

  test("your Tree's keys keep their secrets in secure storage, as before", () async {
    final crud = crudFor(tree);
    final id = await crud.create(
      label: 'deploy',
      username: 'root',
      authMethod: 'key',
      password: 'pw',
      privateKeyPem: 'PEM',
      keyPassphrase: 'pp',
    );
    final all = await storage.readAll();
    expect(all['identity_password_$id'], 'pw');
    expect(all['identity_key_$id'], 'PEM');
    expect(all['identity_passphrase_$id'], 'pp');
    expect(await crud.getPrivateKey(id), 'PEM');

    await crud.delete(id);
    expect((await storage.readAll()).keys.where((k) => k.contains(id)), isEmpty);
  });

  test("an Orchard's keys keep their secrets in the Orchard, and they sync", () async {
    final crud = crudFor(orchard);
    final id = await crud.create(
      label: 'team key',
      username: 'deploy',
      authMethod: 'key',
      password: 'pw',
      privateKeyPem: 'PEM',
      keyPassphrase: 'pp',
    );
    expect(await storage.readAll(), isEmpty, reason: 'nothing in the OS secure storage');
    expect(await crud.getPassword(id), 'pw');
    expect(await crud.getPrivateKey(id), 'PEM');
    expect(await crud.getKeyPassphrase(id), 'pp');

    // Changing only a secret queues the key for its Crate.
    await orchard.customStatement('DELETE FROM crate_outbox');
    await crud.setPassword(id, 'pw-2');
    final queued = await orchard.customSelect('SELECT kind, item_key FROM crate_outbox').get();
    expect(queued.map((r) => (r.read<String>('kind'), r.read<String>('item_key'))), [('key', id)]);

    await crud.delete(id);
    final left = await orchard.customSelect('SELECT COUNT(*) AS n FROM orchard_secrets').getSingle();
    expect(left.read<int>('n'), 0);
  });

  test('a certificate is kept, read back and removed in the same place', () async {
    final secrets = IdentitySecretStore.forDatabase(orchard, storage);
    await secrets.write('k-1', IdentitySecret.certificate, 'Y2VydA==');
    expect(await secrets.read('k-1', IdentitySecret.certificate), 'Y2VydA==');
    await secrets.write('k-1', IdentitySecret.certificate, null);
    expect(await secrets.read('k-1', IdentitySecret.certificate), isNull);
    expect(await storage.readAll(), isEmpty);
  });
}

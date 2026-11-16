import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/features/hosts/host_share_file.dart' show shareSecretsOf;

/// A key's own password in the key editors (3.0, accounts per host): which
/// password is in use (shown, shared, copied, sent), and what a save does
/// with it, changing it only where the field was changed.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('what a save does with it', () {
    ({String? write, bool? afterKey, bool clear}) save({
      String kind = 'publicKey',
      String? openedKind = 'publicKey',
      String shown = '',
      required String text,
    }) =>
        keyPasswordOnSave(kind: kind, openedKind: openedKind, shown: shown, text: text);

    test('a field as it was leaves the password and the switch as they were', () {
      expect(save(shown: 'saved', text: 'saved'), (write: null, afterKey: null, clear: false));
      expect(save(text: ''), (write: null, afterKey: null, clear: false),
          reason: 'a password left from before the identity became a key: not shown, not touched');
    });

    test('changed, what it shows is tried after the key', () {
      expect(save(shown: 'saved', text: 'new one'), (write: 'new one', afterKey: true, clear: false));
      expect(save(text: 'first one'), (write: 'first one', afterKey: true, clear: false));
    });

    test('emptied, nothing is tried, and a password it had shown is taken off', () {
      expect(save(shown: 'saved', text: ''), (write: null, afterKey: false, clear: true));
    });

    test('a new key: what the field shows, or nothing', () {
      expect(save(openedKind: null, text: 'first one'), (write: 'first one', afterKey: true, clear: false));
      expect(save(openedKind: null, text: ''), (write: null, afterKey: false, clear: false));
    });

    test('a password key made a key: its password, still shown, is now tried after the key; emptied, taken off', () {
      expect(save(openedKind: 'password', shown: 'saved', text: 'saved'), (write: 'saved', afterKey: true, clear: false));
      expect(save(openedKind: 'password', shown: 'saved', text: ''), (write: null, afterKey: false, clear: true));
    });
  });

  group('which password is in use', () {
    Identity identity(String kind, {bool afterKey = false}) => Identity(
          id: 'k',
          label: 'k',
          username: 'deploy',
          authMethod: kind,
          usesAgent: false,
          colorIndex: 0,
          isDefault: false,
          allowUnattended: false,
          passwordAfterKey: afterKey,
          createdAt: DateTime(2026, 10, 15),
        );

    test("a password key's own, and one tried after a key; never one left from before", () {
      expect(passwordInUseBy(identity('password')), isTrue);
      for (final kind in ['publicKey', 'certificate', 'hardwareToken']) {
        expect(passwordInUseBy(identity(kind, afterKey: true)), isTrue, reason: kind);
        expect(passwordInUseBy(identity(kind)), isFalse, reason: kind);
      }
      expect(passwordInUseBy(identity('teamCertificate', afterKey: true)), isFalse);
      expect(passwordInUseBy(identity('passwordManager', afterKey: true)), isFalse);
    });
  });

  group('a copy of a key', () {
    late AppDatabase db;
    late IdentityCrudNotifier crud;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      db = AppDatabase.forTesting(NativeDatabase.memory());
      crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
    });

    tearDown(() => db.close());

    test('keeps its own password tried after it; never one left from before', () async {
      final withOne = await crud.create(
          label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'pem', password: 'saved',
          passwordAfterKey: true);
      final copy = (await db.identitiesDao.getById(
          await crud.duplicate((await db.identitiesDao.getById(withOne))!, label: 'deploy key (copy)')))!;
      expect(copy.passwordAfterKey, isTrue);
      expect(await crud.getPassword(copy.id), 'saved');

      final leftOver = await crud.create(
          label: 'old key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'pem', password: 'from before');
      final other = (await db.identitiesDao.getById(
          await crud.duplicate((await db.identitiesDao.getById(leftOver))!, label: 'old key (copy)')))!;
      expect(other.passwordAfterKey, isFalse);
      expect(await crud.getPassword(other.id), isNull);
    });

    test('a shared host file carries a password in use, never one left from before', () async {
      final withOne = (await db.identitiesDao.getById(await crud.create(
          label: 'deploy key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'pem', password: 'saved',
          passwordAfterKey: true)))!;
      final leftOver = (await db.identitiesDao.getById(await crud.create(
          label: 'old key', username: 'deploy', authMethod: 'publicKey', privateKeyPem: 'pem', password: 'from before')))!;
      final own = (await db.identitiesDao.getById(
          await crud.create(label: 'root', username: 'root', authMethod: 'password', password: 'its own')))!;
      expect(await shareSecretsOf(crud, withOne, password: true, key: true), (password: 'saved', privateKeyPem: 'pem'));
      expect(await shareSecretsOf(crud, leftOver, password: true, key: true), (password: null, privateKeyPem: 'pem'));
      expect(await shareSecretsOf(crud, own, password: true, key: false), (password: 'its own', privateKeyPem: null));
      expect(await shareSecretsOf(crud, withOne, password: false, key: false), (password: null, privateKeyPem: null));
      expect(await shareSecretsOf(crud, null, password: true, key: true), (password: null, privateKeyPem: null));
    });

    test('a save takes it off: the switch, and the password where asked', () async {
      final id = await crud.create(
          label: 'deploy key', username: 'deploy', authMethod: 'publicKey', password: 'saved', passwordAfterKey: true);
      await crud.update(id: id, passwordAfterKey: false);
      expect((await db.identitiesDao.getById(id))!.passwordAfterKey, isFalse);
      expect(await crud.getPassword(id), 'saved', reason: 'kept unless asked');
      await crud.update(id: id, clearPassword: true);
      expect(await crud.getPassword(id), isNull);
      await crud.update(id: id, label: 'renamed');
      expect((await db.identitiesDao.getById(id))!.passwordAfterKey, isFalse, reason: 'nothing said, nothing changed');
    });
  });
}

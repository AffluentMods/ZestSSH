import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory. [refuses] says which names it
/// does not take (a keychain that is locked, or full, or says no).
class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};
  bool Function(String name)? refuses;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        return Future<String?>.value(kept[key]);
      case #write:
        if (refuses?.call(key!) ?? false) return Future<void>.error(StateError('the keychain did not take it'));
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

/// A pull writes a key's row in the database and then its password or private
/// key in the device's secure storage. Where that second write failed, the
/// pull still counted as done: the device noted itself as synced, and its next
/// push sent the key without the secret, which other devices read as a secret
/// taken off the key and took off too. Now such a key is owed: the pull is not
/// done, nothing is sent, and the next pull writes it again.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final mergeKey = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final t1 = DateTime.utc(2026, 10, 2, 9);
  final t2 = DateTime.utc(2026, 10, 3, 9);
  const password = 'identity_password_k-1';
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

  Future<void> passwordKey(_Device d, {String secret = 'the old password', DateTime? at}) async {
    await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'web', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(at ?? t0)));
    d.vault.kept[password] = secret;
  }

  /// A and B hold the same key; A then changes its password. What A pushes,
  /// and what both last synced.
  Future<({Map<String, dynamic> pushed, Map<String, String> last})> changedOnA() async {
    await passwordKey(a);
    await passwordKey(b);
    final last = SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey);
    await (a.db.update(a.db.identities)..where((t) => t.id.equals('k-1')))
        .write(IdentitiesCompanion(username: const Value('deployer'), updatedAt: Value(t1)));
    a.vault.kept[password] = 'the new password';
    return (pushed: await a.data.gatherAll(), last: last);
  }

  test('a key whose secret the device did not take is told of, and written again by the next pull', () async {
    final s = await changedOnA();
    final noted = <Set<String>>[];
    b.vault.refuses = (name) => name == password;

    var result = await b.data.restoreAll(s.pushed,
        merge: SyncMergeBase(key: mergeKey, base: s.last, onTaken: (taken) async => noted.add(taken)));
    expect(result.success, isTrue);
    expect(result.secretsOwed, {'identities/k-1'});
    expect(noted.single, contains('identities/k-1'), reason: 'noted with the rows, before any secret is written');
    expect((await b.db.identitiesDao.getById('k-1'))!.username, 'deployer', reason: 'the row is here');
    expect(b.vault.kept[password], 'the old password', reason: 'its new password is not');

    // The pull made again, told what is owed, writes it.
    b.vault.refuses = null;
    result = await b.data.restoreAll(s.pushed,
        merge: SyncMergeBase(key: mergeKey, base: s.last, owed: const {'identities/k-1'}));
    expect(result.success, isTrue);
    expect(result.secretsOwed, isEmpty);
    expect(result.taken, contains('identities/k-1'));
    expect(b.vault.kept[password], 'the new password');
  });

  test('a key changed here since is the person\'s own change: what is owed does not take its place', () async {
    final s = await changedOnA();
    b.vault.refuses = (name) => name == password;
    await b.data.restoreAll(s.pushed, merge: SyncMergeBase(key: mergeKey, base: s.last));
    b.vault.refuses = null;
    await (b.db.update(b.db.identities)..where((t) => t.id.equals('k-1')))
        .write(IdentitiesCompanion(label: const Value('web, renamed here'), updatedAt: Value(t2)));
    b.vault.kept[password] = 'typed here afterwards';

    final result = await b.data.restoreAll(s.pushed,
        merge: SyncMergeBase(key: mergeKey, base: s.last, owed: const {'identities/k-1'}));
    expect(result.taken, isNot(contains('identities/k-1')));
    expect(b.vault.kept[password], 'typed here afterwards');
    expect((await b.db.identitiesDao.getById('k-1'))!.label, 'web, renamed here');
  });

  test('what is owed is kept in the profile\'s database, and cleared when nothing is', () async {
    expect(await b.data.loadSecretsOwed(), isEmpty);
    await b.data.saveSecretsOwed({'identities/k-2', 'identities/k-1'});
    expect(await b.data.loadSecretsOwed(), {'identities/k-1', 'identities/k-2'});
    await b.data.saveSecretsOwed(const {});
    expect(await b.data.loadSecretsOwed(), isEmpty);
  });

  group('background sync', () {
    const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
    late MemoryStoreBackend store;
    late AutoSyncService sync;
    late SecretKey dek;
    late Uint8List salt;
    late Uint8List verHash;
    late SecretKey mek;

    setUp(() async {
      L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
      salt = SyncService.generateSalt();
      dek = SyncService.generateDek();
      mek = await SyncService.deriveKey('correct-password', salt, params: fast);
      verHash = await SyncService.computeVerificationHash(mek);
      await settings.setSyncMode('auto');
      store = MemoryStoreBackend(MemoryStore());
      sync = AutoSyncService(
        syncDataService: b.data,
        settingsService: settings,
        secureStorage: b.vault,
        resolveBackend: () => store,
        timer: (wait, then) => Timer(const Duration(days: 1), then),
      );
      b.vault.kept['sync_salt'] = base64Encode(salt);
      await sync.storeSyncCredentials(dek, verHash, argon2Params: fast);
    });

    tearDown(() => sync.dispose());

    Future<int> push(_Device from, {bool first = false, int? expected}) async => (await store.push(
          data: await from.data.gatherAll(),
          dek: dek,
          salt: salt,
          verificationHash: verHash,
          wrappedDekPassword: first ? await SyncService.wrapDek(dek, mek) : null,
          createOnly: first,
          expectedVersion: expected,
          argon2Params: fast,
        ))
            .version;

    test('a pull that left a secret unwritten is not noted as synced and sends nothing; the next one finishes it', () async {
      await passwordKey(a);
      await passwordKey(b);
      final v1 = await push(a, first: true);
      await settings.setSyncServerVersion(v1);
      await b.data.saveSyncBase(SyncDataService.itemHashes(await b.data.gatherAll(), await dek.extractBytes()));
      // A changes the key's password and syncs.
      await (a.db.update(a.db.identities)..where((t) => t.id.equals('k-1')))
          .write(IdentitiesCompanion(username: const Value('deployer'), updatedAt: Value(t1)));
      a.vault.kept[password] = 'the new password';
      final v2 = await push(a, expected: v1);
      final sent = store.store.counter;

      // B's keychain does not take the new password.
      b.vault.refuses = (name) => name == password;
      await sync.triggerSync().timeout(const Duration(seconds: 20));
      expect(await b.data.loadSecretsOwed(), {'identities/k-1'});
      expect(settings.syncServerVersion, v1, reason: 'not noted as having synced the newer version');
      expect(store.store.counter, sent, reason: 'nothing was sent from this device');
      expect(sync.syncError.value, lookupAppLocalizations(const Locale('en')).syncSecretsNotKept);
      expect(b.vault.kept[password], 'the old password');

      // The keychain takes it again: the next sync makes the pull again and is done.
      b.vault.refuses = null;
      sync.resetFailures();
      await sync.triggerSync().timeout(const Duration(seconds: 20));
      expect(b.vault.kept[password], 'the new password');
      expect(await b.data.loadSecretsOwed(), isEmpty);
      expect(settings.syncServerVersion, v2);

      // And what A then gets back from the store still holds its password.
      final onStore = await store.pull();
      final data = await SyncService.decrypt(onStore.encryptedData, dek);
      expect(((data['secrets'] as Map)['k-1'] as Map)['password'], 'the new password');
    });
  });
}

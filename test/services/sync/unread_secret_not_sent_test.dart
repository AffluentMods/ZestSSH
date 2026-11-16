// A key's secret that is kept on a device but does not open there (its seal is
// another database's, or damaged) reads as none. A sync from that device sent
// the key as one with no secret, and every other device deleted its own
// readable private key and passphrase (found in a security review). Now
// nothing is gathered from such a device: its sync fails instead.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

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

SyncDataService _service(AppDatabase db, FlutterSecureStorage storage, SettingsService s) => SyncDataService(
      database: db,
      connectionsDao: db.connectionsDao,
      identitiesDao: db.identitiesDao,
      groupsDao: db.connectionGroupsDao,
      knownHostsDao: db.knownHostsDao,
      snippetsDao: db.snippetsDao,
      snippetCategoriesDao: db.snippetCategoriesDao,
      portForwardRulesDao: db.portForwardRulesDao,
      networksDao: db.networksDao,
      connectionTagsDao: db.connectionTagsDao,
      secureStorage: storage,
      settingsService: s,
    );

class _Device {
  _Device(SettingsService settings)
      : db = AppDatabase.forTesting(NativeDatabase.memory()),
        vault = _Vault() {
    data = _service(db, vault, settings);
  }

  final AppDatabase db;
  final _Vault vault;
  late final SyncDataService data;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final mergeKey = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  const madeUpKey = '-----BEGIN OPENSSH PRIVATE KEY----- made up';
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

  Future<void> key(_Device d) async {
    await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-2', label: 'deploy key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    d.vault.kept['identity_key_k-2'] = madeUpKey;
    d.vault.kept['identity_passphrase_k-2'] = 'made-up passphrase';
  }

  /// On [d] the key's secrets are still in the storage, but sealed by a seal
  /// this database does not have: every read of them answers none.
  void sealDoesNotOpen(_Device d) {
    d.vault.kept['identity_key_k-2'] = '${SecretSeal.prefix}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    d.vault.kept['identity_passphrase_k-2'] = '${SecretSeal.prefix}BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
  }

  test('a device that cannot open the secrets of a key gathers nothing: it throws, and says of no key that it has none', () async {
    await key(a);
    final before = await a.data.gatherAll();
    expect((before['secrets'] as Map)['k-2'], isNotNull);
    sealDoesNotOpen(a);
    await expectLater(a.data.gatherAll(), throwsA(isA<SecretSealBroken>()));
  });

  // What the person on that device is told (it
  // fails with a clear error). It was "Sync could not finish on this device",
  // with nothing of which key or what to do.
  test('the failure names the key and what to do, with its code, for sync and for a backup, and never the secret', () async {
    await key(a);
    sealDoesNotOpen(a);
    late KeySecretUnread thrown;
    try {
      await a.data.gatherAll();
      fail('gathered');
    } on KeySecretUnread catch (e) {
      thrown = e;
    }
    expect(thrown.label, 'deploy key');
    expect(thrown.slot, 'identity_key_k-2');

    final said = SyncFailure.onDevice(thrown);
    expect(said.message, '${gl10n.keySecretUnreadHere('deploy key')} (ZS-1206)');
    expect(said.message, contains('deploy key'));
    expect(ErrorCodes.find('ZS-1206'), ErrorCodes.syncKeySecretUnread);
    expect(said.detail, contains('identity_key_k-2'));
    expect('${said.message} ${said.detail}', isNot(contains('zseal1:')), reason: 'the stored value is in neither');

    final backup = await BackupService(a.data).exportBackup('a password long enough');
    expect(backup.success, isFalse);
    expect(backup.error, said.message, reason: 'a backup says the same, and writes no file without the secret');
    expect(backup.filePath, isNull);
  });

  test('so the other device keeps its private key and passphrase', () async {
    await key(a);
    await key(b);
    sealDoesNotOpen(a);
    Map<String, dynamic>? pushedByA;
    try {
      pushedByA = await a.data.gatherAll();
    } on SecretSealBroken {
      pushedByA = null;
    }
    expect(pushedByA, isNull, reason: 'nothing to push');
    expect(b.vault.kept['identity_key_k-2'], madeUpKey);
    expect(b.vault.kept['identity_passphrase_k-2'], 'made-up passphrase');
  });

  test('a key that truly has no secret, and one whose secrets read, gather as before', () async {
    await key(a);
    await a.db.into(a.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-3', label: 'agent only', username: 'ops', authMethod: 'agent', createdAt: t0, updatedAt: Value(t0)));
    final all = await a.data.gatherAll();
    expect((all['secrets'] as Map)['k-2'], isNotNull);
    expect((all['secrets'] as Map).containsKey('k-3'), isFalse);
  });

  test('a secret taken off a key on one device still goes from the other (the removal sync is for)', () async {
    await key(a);
    await key(b);
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), mergeKey);
    a.vault.kept.remove('identity_passphrase_k-2');
    final pushedByA = await a.data.gatherAll();
    final result = await b.data.restoreAll(pushedByA, merge: SyncMergeBase(key: mergeKey, base: last));
    expect(result.success, isTrue);
    expect(b.vault.kept['identity_key_k-2'], madeUpKey);
    expect(b.vault.kept['identity_passphrase_k-2'], isNull);
  });
}

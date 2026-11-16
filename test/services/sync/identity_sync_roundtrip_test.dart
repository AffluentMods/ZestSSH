import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

/// Empty-prefs settings service (no synced settings seeded); (re)built in
/// setUp so each round-trip starts from a clean SharedPreferences.
late SettingsService _settings;

/// Guards the identity serialize/deserialize field-set contract in cloud sync.
///
/// A hardware-token / agent-backed identity used to lose its agent binding on a
/// synced device (usesAgent defaulted to false) AND cause a non-converging
/// push/pull loop: `gatherAll()` serialized `usesAgent` / `agentSocketPath` /
/// `cert*` via `toJson()`, but the restore companion never wrote them, so the
/// round-tripped local row differed from the source and produced a different
/// `contentFingerprint`. The fix: `usesAgent` SYNCS (restored on the other
/// device) while the device-specific `agentSocketPath` and the `cert*` mirror
/// cache stay device-local (stripped from the serialize). Serialize and restore
/// must agree on the exact same field set or the fingerprint diverges.
SyncDataService _service(AppDatabase db, FlutterSecureStorage storage) =>
    SyncDataService(
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
      settingsService: _settings,
    );

Future<void> _seedAgentIdentity(AppDatabase db) {
  return db.identitiesDao.insertIdentity(IdentitiesCompanion(
    id: const Value('agent-1'),
    label: const Value('YubiKey'),
    username: const Value('root'),
    authMethod: const Value('hardwareToken'),
    usesAgent: const Value(true),
    agentSocketPath: const Value(r'\\.\pipe\openssh-ssh-agent'),
    keyType: const Value('sk-ssh-ed25519'),
    certSerial: const Value('deadbeef'),
    certKeyId: const Value('ca-key-id'),
    certPrincipals: const Value('root,admin'),
    certValidBefore: Value(DateTime.utc(2030)),
    allowUnattended: const Value(true),
    createdAt: Value(DateTime.utc(2026)),
  ));
}

/// A 1Password agent key and a password kept in 1Password (3.0).
Future<void> _seedPasswordManagerIdentities(AppDatabase db) async {
  await db.identitiesDao.insertIdentity(IdentitiesCompanion(
    id: const Value('agent-1p'),
    label: const Value('1Password key'),
    username: const Value('deploy'),
    authMethod: const Value('hardwareToken'),
    usesAgent: const Value(true),
    agentSource: const Value('1password'),
    agentSocketPath: const Value('/home/a/.1password/agent.sock'),
    publicKeyData: const Value('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA deploy'),
    createdAt: Value(DateTime.utc(2026)),
  ));
  await db.identitiesDao.insertIdentity(IdentitiesCompanion(
    id: const Value('pm-1'),
    label: const Value('db-prod'),
    username: const Value('postgres'),
    authMethod: const Value('passwordManager'),
    passwordRef: Value(PasswordRef.onePassword('op://Engineering/db-prod/password')!.encode()),
    createdAt: Value(DateTime.utc(2026)),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Empty mock keychain - the agent identity stores no password/private key.
  FlutterSecureStorage.setMockInitialValues({});

  // Fixed DEK so the HMAC fingerprint is deterministic across the round-trip.
  final key = List<int>.filled(32, 7);
  const storage = FlutterSecureStorage();

  late AppDatabase src;
  late AppDatabase dst;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    _settings = SettingsService(await SharedPreferences.getInstance());
    src = AppDatabase.forTesting(NativeDatabase.memory());
    dst = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await src.close();
    await dst.close();
  });

  test(
      'serialize: usesAgent travels, but socket / cert / allowUnattended are '
      'device-local', () async {
    await _seedAgentIdentity(src);
    final blob = await _service(src, storage).gatherAll();
    final id0 = (blob['identities'] as List).single as Map;

    expect(id0['usesAgent'], isTrue, reason: 'usesAgent must sync');
    for (final k in const [
      'agentSocketPath',
      'certSerial',
      'certKeyId',
      'certPrincipals',
      'certValidBefore',
      'allowUnattended',
    ]) {
      expect(id0.containsKey(k), isFalse,
          reason: '$k is device-local and must not travel in the sync blob');
    }
  });

  test('restore preserves usesAgent - no agent data-loss on a synced device',
      () async {
    await _seedAgentIdentity(src);
    final blob = await _service(src, storage).gatherAll();
    await _service(dst, storage).restoreAll(blob);

    final restored = await dst.identitiesDao.getById('agent-1');
    expect(restored, isNotNull);
    expect(restored!.usesAgent, isTrue,
        reason: 'a synced agent identity must stay agent-backed');
    expect(restored.authMethod, 'hardwareToken');
    // Device-local fields are intentionally NOT restored (regenerated / set up
    // per device) - leaving them absent keeps the fingerprint stable.
    expect(restored.agentSocketPath, isNull);
    expect(restored.certSerial, isNull);
    // allowUnattended is device-local and defaults OFF on the new device.
    expect(restored.allowUnattended, isFalse);
  });

  test('password managers: whose agent and where a password lives travel; the socket path stays', () async {
    await _seedPasswordManagerIdentities(src);
    final blob = await _service(src, storage).gatherAll();
    final ids = {for (final i in blob['identities'] as List) (i as Map)['id']: i};
    expect(ids['agent-1p']!['agentSource'], '1password');
    expect(ids['agent-1p']!.containsKey('agentSocketPath'), isFalse);
    expect(ids['pm-1']!['passwordRef'], PasswordRef.onePassword('op://Engineering/db-prod/password')!.encode());

    await _service(dst, storage).restoreAll(blob);
    final agent = await dst.identitiesDao.getById('agent-1p');
    final pm = await dst.identitiesDao.getById('pm-1');
    expect((agent!.agentSource, agent.agentSocketPath), ('1password', null));
    expect((pm!.authMethod, PasswordRef.decode(pm.passwordRef)?.target),
        ('passwordManager', 'op://Engineering/db-prod/password'));
    // No password was ever stored for it, here or there.
    expect(await storage.read(key: 'identity_password_pm-1'), isNull);

    // Stable: no push loop.
    final again = await _service(dst, storage).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key));
  });

  test('password managers: a bad reference or agent from the blob is dropped, never used', () async {
    await _service(dst, storage).restoreAll({
      'schema_version': 19,
      'identities': [
        {
          'id': 'pm-bad',
          'label': 'x',
          'username': 'x',
          'authMethod': 'passwordManager',
          'passwordRef': '{"v":1,"m":"op","t":"--out-file=/tmp/x"}',
          'agentSource': 'evil',
          'createdAt': 0,
        },
        {
          'id': 'pm-raw',
          'label': 'y',
          'username': 'y',
          'authMethod': 'passwordManager',
          'passwordRef': 'op://Eng/db/password',
          'createdAt': 0,
        },
      ],
    });
    final bad = await dst.identitiesDao.getById('pm-bad');
    final raw = await dst.identitiesDao.getById('pm-raw');
    expect((bad!.authMethod, bad.passwordRef, bad.agentSource), ('passwordManager', null, null));
    expect(raw!.passwordRef, isNull, reason: 'only the stored form is read');
  });

  test('round-trip contentFingerprint is STABLE (no ping-pong push loop)',
      () async {
    await _seedAgentIdentity(src);
    final blobA = await _service(src, storage).gatherAll();
    final fpA = SyncDataService.contentFingerprint(blobA, key);

    await _service(dst, storage).restoreAll(blobA);
    final blobB = await _service(dst, storage).gatherAll();
    final fpB = SyncDataService.contentFingerprint(blobB, key);

    expect(fpB, fpA,
        reason: 'pull -> restore -> gather must yield an identical fingerprint, '
            'or two devices push to each other forever');
  });

  test("a key's password tried after it (3.0, accounts per host): the switch travels with the key, its password "
      'with the secrets; a blob without it reads as off', () async {
    FlutterSecureStorage.setMockInitialValues({'identity_password_key-1': 'saved-with-the-key'});
    await src.identitiesDao.insertIdentity(IdentitiesCompanion(
      id: const Value('key-1'),
      label: const Value('deploy key'),
      username: const Value('deploy'),
      authMethod: const Value('publicKey'),
      passwordAfterKey: const Value(true),
      createdAt: Value(DateTime.utc(2026, 10, 15)),
    ));
    final blob = await _service(src, storage).gatherAll();
    expect(((blob['identities'] as List).single as Map)['passwordAfterKey'], isTrue);
    expect((blob['secrets'] as Map)['key-1'], {'password': 'saved-with-the-key'});

    await _service(dst, storage).restoreAll(blob);
    expect((await dst.identitiesDao.getById('key-1'))!.passwordAfterKey, isTrue);
    final again = await _service(dst, storage).gatherAll();
    expect(SyncDataService.contentFingerprint(again, key), SyncDataService.contentFingerprint(blob, key),
        reason: 'no push loop');

    // A blob that does not say it (made before the switch was there): off,
    // on a device where it was on, and for a key new there.
    final older = jsonDecode(jsonEncode(blob)) as Map<String, dynamic>;
    ((older['identities'] as List).single as Map).remove('passwordAfterKey');
    await _service(dst, storage).restoreAll(older);
    expect((await dst.identitiesDao.getById('key-1'))!.passwordAfterKey, isFalse);
    final fresh = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);
    await _service(fresh, storage).restoreAll(older);
    expect((await fresh.identitiesDao.getById('key-1'))!.passwordAfterKey, isFalse);
  });
}

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory.
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

/// A device: its database, its secure storage, and its sync data.
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

/// What a key holds goes with it to another device and into a backup (3.0):
/// its password and private key, as before, and now its saved passphrase and
/// its certificate too. Before, a certificate key arrived without its
/// certificate (and signed in with the bare key, which a server that needs
/// the certificate refuses), and a key whose passphrase was saved asked for
/// it again. A pull that merges takes them where the key changed there only
/// and keeps this device's where it changed here only; what is too large, or
/// a certificate that is no base64, is not written; a blob of an older
/// version without them leaves this device's own; and a deleted key's
/// passphrase and certificate are swept from secure storage with the rest.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final mergeKey = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final cert = base64.encode(utf8.encode('a certificate, as its bytes'));
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

  Future<void> key(_Device d, String id, String method) => d.db.into(d.db.identities).insertOnConflictUpdate(
      IdentitiesCompanion.insert(
          id: id, label: id, username: 'deploy', authMethod: method, createdAt: t0, updatedAt: Value(t0)));

  /// The secrets [d] holds for the key [id], by kind.
  Map<String, String> secretsOf(_Device d, String id) => {
        for (final kind in ['password', 'key', 'passphrase', 'cert']) kind: ?d.vault.kept['identity_${kind}_$id'],
      };

  Future<void> both(Future<void> Function(_Device d) f) async {
    await f(a);
    await f(b);
  }

  test("a key's password, private key, saved passphrase and certificate all go with it, to a device that joins and "
      'into a backup restored', () async {
    await key(a, 'k-pass', 'publicKey');
    await key(a, 'k-cert', 'certificate');
    await key(a, 'k-word', 'password');
    // A key its agent holds, with its certificate: nothing else is saved.
    await key(a, 'k-agent', 'hardwareToken');
    a.vault.kept
      ..['identity_key_k-pass'] = 'PEM, locked'
      ..['identity_passphrase_k-pass'] = 'made-up passphrase'
      ..['identity_key_k-cert'] = 'PEM'
      ..['identity_cert_k-cert'] = cert
      ..['identity_password_k-word'] = 'made-up password'
      ..['identity_cert_k-agent'] = cert;
    final blob = await a.data.gatherAll();
    expect((blob['secrets'] as Map)['k-pass'], {'privateKey': 'PEM, locked', 'passphrase': 'made-up passphrase'});
    expect((blob['secrets'] as Map)['k-cert'], {'privateKey': 'PEM', 'certificate': cert});
    final result = await b.data.restoreAll(blob);
    expect(result.success, isTrue);
    expect(secretsOf(b, 'k-pass'), {'key': 'PEM, locked', 'passphrase': 'made-up passphrase'});
    expect(secretsOf(b, 'k-cert'), {'key': 'PEM', 'cert': cert});
    expect(secretsOf(b, 'k-word'), {'password': 'made-up password'});
    expect(secretsOf(b, 'k-agent'), {'cert': cert}, reason: 'a certificate alone goes too');
  });

  test('a pull that merges: changed there only, taken; changed here only, kept; the same, as it is', () async {
    await both((d) async {
      await key(d, 'k-1', 'certificate');
      await key(d, 'k-2', 'publicKey');
      d.vault.kept
        ..['identity_key_k-1'] = 'PEM 1'
        ..['identity_cert_k-1'] = cert
        ..['identity_key_k-2'] = 'PEM 2'
        ..['identity_passphrase_k-2'] = 'first passphrase';
    });
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), mergeKey);
    expect(last, SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey), reason: 'in step');

    // A new certificate on A; a new passphrase on B.
    final renewed = base64.encode(utf8.encode('a renewed certificate'));
    a.vault.kept['identity_cert_k-1'] = renewed;
    b.vault.kept['identity_passphrase_k-2'] = 'second passphrase';
    expect(SyncDataService.itemHashes(await a.data.gatherAll(), mergeKey)['identities/k-1'], isNot(last['identities/k-1']),
        reason: 'a certificate alone is a change of the key');

    final result = await b.data.restoreAll(await a.data.gatherAll(), merge: SyncMergeBase(key: mergeKey, base: last));
    expect(result.success, isTrue);
    expect(secretsOf(b, 'k-1'), {'key': 'PEM 1', 'cert': renewed});
    expect(secretsOf(b, 'k-2'), {'key': 'PEM 2', 'passphrase': 'second passphrase'});
    expect(result.keptHere, 1, reason: 'the passphrase changed here goes with the next push');
  });

  test('too large, or a certificate that is no base64: not written, and the rest of the key still is', () async {
    await key(b, 'k-1', 'certificate');
    await key(b, 'k-2', 'publicKey');
    final blob = await b.data.gatherAll();
    blob['secrets'] = {
      'k-1': {'privateKey': 'PEM 1', 'certificate': 'not base64 at all!', 'passphrase': 'p' * 4097},
      'k-2': {'privateKey': 'PEM 2', 'certificate': base64.encode(List.filled(48 * 1024 + 1, 7)), 'passphrase': 'p' * 4096},
    };
    final result = await b.data.restoreAll(blob);
    expect(result.success, isTrue);
    expect(secretsOf(b, 'k-1'), {'key': 'PEM 1'});
    expect(secretsOf(b, 'k-2'), {'key': 'PEM 2', 'passphrase': 'p' * 4096}, reason: 'a certificate over 64 KB as base64');
  });

  test("a blob of an older version, without them, leaves this device's own as they are", () async {
    await both((d) => key(d, 'k-1', 'certificate'));
    a.vault.kept['identity_key_k-1'] = 'PEM';
    b.vault.kept
      ..['identity_key_k-1'] = 'PEM'
      ..['identity_cert_k-1'] = cert
      ..['identity_passphrase_k-1'] = 'kept passphrase';
    final blob = await a.data.gatherAll();
    expect((blob['secrets'] as Map)['k-1'], {'privateKey': 'PEM'});
    expect((await b.data.restoreAll(blob)).success, isTrue);
    expect(secretsOf(b, 'k-1'), {'key': 'PEM', 'cert': cert, 'passphrase': 'kept passphrase'});
  });

  test('a key that is gone: its passphrase and certificate are swept from this device with its other secrets',
      () async {
    await key(a, 'k-stays', 'publicKey');
    b.vault.kept
      ..['identity_key_k-gone'] = 'PEM'
      ..['identity_passphrase_k-gone'] = 'a passphrase'
      ..['identity_cert_k-gone'] = cert
      ..['identity_password_k-gone'] = 'a password'
      ..['unrelated'] = 'left alone';
    expect((await b.data.restoreAll(await a.data.gatherAll())).success, isTrue);
    expect(secretsOf(b, 'k-gone'), isEmpty);
    expect(b.vault.kept['unrelated'], 'left alone');
  });
}

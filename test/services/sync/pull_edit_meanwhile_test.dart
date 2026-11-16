import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory. [onRead] runs before each read
/// of a secret: the place in a pull where this device's items have been read
/// from the database and its keys' secrets are still being read.
class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};
  void Function()? onRead;
  int reads = 0;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        reads++;
        onRead?.call();
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

/// What is saved on this device while a pull reads it is not lost (found
/// in a review). A pull read this device's items first and
/// wrote after, and the reading takes a while: every table, then four
/// secrets of every key. An edit saved in that gap was judged by what had
/// been read before it, so where another device had changed the same item,
/// the edit was written over with nothing said: to the pull the item was
/// unchanged here. Now the transaction that writes asks first whether
/// anything was written to the database since the reading began, and reads
/// this device again inside itself where something was; what is saved after
/// that waits for the pull and lands on top of it. A pull with nothing saved
/// meanwhile reads this device once, as before.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final key = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final t1 = DateTime.utc(2026, 10, 2, 9);
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

  Future<void> host(_Device d, String id, String label, DateTime at) => d.db.into(d.db.connections).insertOnConflictUpdate(
      ConnectionsCompanion.insert(id: id, label: label, host: '$id.example.com', createdAt: t0, updatedAt: at));

  Future<String?> labelOf(_Device d, String id) async => (await d.db.connectionsDao.getById(id))?.label;

  /// A key with a secret, so that a pull has secrets to read.
  Future<void> deployKey(_Device d) async {
    await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-1', label: 'deploy key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    d.vault.kept['identity_key_k-1'] = '-----BEGIN OPENSSH PRIVATE KEY----- made up';
  }

  test('a host edited here while a pull reads this device is not written over by another device\'s change to it',
      () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await host(d, 'h2', 'web-2', t0);
      await deployKey(d);
    }
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    await host(a, 'h1', 'web-1 renamed on A', t1);
    await host(a, 'h2', 'web-2 renamed on A', t1);
    final fromA = await a.data.gatherAll();

    // The person saves the host on B while B's pull is reading B: from
    // outside the pull, as a screen does.
    final outside = Zone.current;
    Future<void>? saved;
    b.vault.onRead = () {
      saved ??= outside.run(() => host(b, 'h1', 'web-1 edited on B during the pull', DateTime.now()));
    };

    final result = await b.data.restoreAll(fromA, merge: SyncMergeBase(key: key, base: last));
    b.vault.onRead = null;
    expect(result.success, isTrue);
    expect(saved, isNotNull, reason: 'the pull read a secret, and the edit was made then');
    await saved;

    expect(await labelOf(b, 'h1'), 'web-1 edited on B during the pull');
    expect(await labelOf(b, 'h2'), 'web-2 renamed on A', reason: 'what was not edited here is taken as before');
    // The edit is a change made here since the last sync: the next push
    // sends it.
    final now = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    expect(now['connections/h1'], isNot(SyncDataService.itemHashes(fromA, key)['connections/h1']));
  });

  test('a host added here while a pull reads this device is there after the pull', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await deployKey(d);
    }
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    await host(a, 'h1', 'web-1 renamed on A', t1);
    final fromA = await a.data.gatherAll();

    final outside = Zone.current;
    Future<void>? saved;
    b.vault.onRead = () {
      saved ??= outside.run(() => host(b, 'h9', 'added on B during the pull', DateTime.now()));
    };
    final result = await b.data.restoreAll(fromA, merge: SyncMergeBase(key: key, base: last));
    b.vault.onRead = null;
    expect(result.success, isTrue);
    await saved;
    expect(await labelOf(b, 'h9'), 'added on B during the pull');
    expect(await labelOf(b, 'h1'), 'web-1 renamed on A');
  });

  test('a pull with nothing saved meanwhile reads this device once; with something saved meanwhile, twice', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await host(d, 'h2', 'web-2', t0);
      await deployKey(d);
    }
    b.vault.reads = 0;
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    final oneReading = b.vault.reads;
    expect(oneReading, greaterThan(0));

    await host(a, 'h1', 'web-1 renamed on A', t1);
    b.vault.reads = 0;
    final quiet = await b.data.restoreAll(await a.data.gatherAll(), merge: SyncMergeBase(key: key, base: last));
    expect(quiet.success, isTrue);
    expect(b.vault.reads, oneReading);
    expect(await labelOf(b, 'h1'), 'web-1 renamed on A');

    final next = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    await host(a, 'h2', 'web-2 renamed on A', t1);
    final fromA = await a.data.gatherAll();
    final outside = Zone.current;
    Future<void>? saved;
    b.vault.onRead = () {
      saved ??= outside.run(() => host(b, 'h9', 'added on B during the pull', DateTime.now()));
    };
    b.vault.reads = 0;
    final busy = await b.data.restoreAll(fromA, merge: SyncMergeBase(key: key, base: next));
    b.vault.onRead = null;
    expect(busy.success, isTrue);
    expect(b.vault.reads, oneReading * 2);
    await saved;
    expect(await labelOf(b, 'h2'), 'web-2 renamed on A');
    expect(await labelOf(b, 'h9'), 'added on B during the pull');
  });

  test('a secret of this device that cannot be read still stops the pull as an error thrown, and writes nothing',
      () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await deployKey(d);
    }
    final last = SyncDataService.itemHashes(await b.data.gatherAll(), key);
    await host(a, 'h1', 'web-1 renamed on A', t1);
    final fromA = await a.data.gatherAll();
    // Still in the storage, but sealed by a seal this database does not have.
    b.vault.kept['identity_key_k-1'] = '${SecretSeal.prefix}AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

    await expectLater(
      b.data.restoreAll(fromA, merge: SyncMergeBase(key: key, base: last)),
      throwsA(isA<SecretSealBroken>()),
    );
    expect(await labelOf(b, 'h1'), 'web-1', reason: 'nothing of the pull was written');
  });
}

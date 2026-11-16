import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

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

/// A name that is too long, or empty, in a synced or restored record does
/// not stop the restore (found in security
/// reviews). The table takes 1 to 255
/// characters for a host's label, a key's label and user name and a group's
/// name. The restore let 512 and 256 through, and none at all, and the write
/// threw: one such record, from another device or a damaged copy, and
/// nothing of the pull was taken, at every sync. A snippet's had been held
/// to its limits before; these three had not. And a text cut at its limit
/// could end on half a character.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final t0 = DateTime.utc(2026, 10, 1, 9);
  // U+1F34B, a lemon: two UTF-16 units.
  final lemon = String.fromCharCode(0x1F34B);
  late AppDatabase from;
  late AppDatabase into;
  late SyncDataService sender;
  late SyncDataService receiver;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    final settings = SettingsService(await SharedPreferences.getInstance());
    from = AppDatabase.forTesting(NativeDatabase.memory());
    into = AppDatabase.forTesting(NativeDatabase.memory());
    sender = memoryDataService(from, _Vault(), settings);
    receiver = memoryDataService(into, _Vault(), settings);
  });

  tearDown(() async {
    await from.close();
    await into.close();
  });

  /// One group, one key, two hosts (one in the group, with the key).
  Future<Map<String, dynamic>> blob() async {
    await from.into(from.connectionGroups).insert(
        ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: t0, updatedAt: Value(t0)));
    await from.into(from.identities).insert(IdentitiesCompanion.insert(
        id: 'k1', label: 'deploy key', username: 'deploy', authMethod: 'publicKey', createdAt: t0, updatedAt: Value(t0)));
    await from.into(from.connections).insert(ConnectionsCompanion.insert(
        id: 'h1',
        label: 'web-1',
        host: 'h1.example.com',
        createdAt: t0,
        updatedAt: t0,
        groupId: const Value('g1'),
        identityId: const Value('k1')));
    await from.into(from.connections).insert(ConnectionsCompanion.insert(
        id: 'h2', label: 'web-2', host: 'h2.example.com', createdAt: t0, updatedAt: t0));
    return sender.gatherAll();
  }

  Map of(Map<String, dynamic> blob, String list, String id) =>
      (blob[list] as List).cast<Map>().singleWhere((r) => r['id'] == id);

  Future<void> restore(Map<String, dynamic> blob) async {
    final restored = await receiver.restoreAll(blob);
    expect(restored.success, isTrue, reason: restored.error);
  }

  Future<String?> hostLabel(String id) async => (await into.connectionsDao.getById(id))?.label;

  test('a host label longer than the table takes is cut to it, and the rest of the pull comes', () async {
    final b = await blob();
    of(b, 'connections', 'h1')['label'] = 'y' * 600;
    await restore(b);
    expect(await hostLabel('h1'), 'y' * 255);
    expect(await hostLabel('h2'), 'web-2');
  });

  test('a host with no label, or one of nothing but spaces and marks that are taken out, is named by its address', () async {
    final b = await blob();
    of(b, 'connections', 'h1')['label'] = '';
    of(b, 'connections', 'h2')['label'] = '  ${String.fromCharCodes([0x202E, 0x0007])} ';
    await restore(b);
    expect(await hostLabel('h1'), 'h1.example.com');
    expect(await hostLabel('h2'), 'h2.example.com');
  });

  test('a cut never ends on half a character', () async {
    final b = await blob();
    of(b, 'connections', 'h1')['label'] = '${'x' * 254}$lemon and more';
    of(b, 'connections', 'h2')['label'] = '${'x' * 253}$lemon and more';
    await restore(b);
    final across = (await hostLabel('h1'))!;
    expect(across, 'x' * 254, reason: 'the character lay across the limit: left out whole');
    final within = (await hostLabel('h2'))!;
    expect(within, '${'x' * 253}$lemon', reason: 'the character ended at the limit: kept');
    expect(within.length, 255);
  });

  test('a group name of 256 is cut; a group with no name is left out and its host still comes', () async {
    final b = await blob();
    of(b, 'connection_groups', 'g1')['name'] = 'n' * 256;
    await restore(b);
    expect((await into.select(into.connectionGroups).getSingle()).name, 'n' * 255);

    of(b, 'connection_groups', 'g1')['name'] = '';
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    final settings = SettingsService(await SharedPreferences.getInstance());
    final second = await memoryDataService(other, _Vault(), settings).restoreAll(b);
    expect(second.success, isTrue, reason: second.error);
    expect(await other.select(other.connectionGroups).get(), isEmpty);
    expect((await other.connectionsDao.getById('h1'))!.label, 'web-1');
  });

  test('a key label and user name longer than the table takes are cut; no label is the user name', () async {
    final b = await blob();
    of(b, 'identities', 'k1')
      ..['label'] = 'L' * 512
      ..['username'] = 'u' * 256;
    await restore(b);
    var key = await into.select(into.identities).getSingle();
    expect(key.label, 'L' * 255);
    expect(key.username, 'u' * 255);

    of(b, 'identities', 'k1')
      ..['label'] = ''
      ..['username'] = 'deploy'
      ..['updatedAt'] = DateTime.utc(2026, 10, 2).toIso8601String();
    await restore(b);
    key = await into.select(into.identities).getSingle();
    expect(key.label, 'deploy');
    expect(key.username, 'deploy');
  });

  test('a key with no user name is left out, and the hosts still come', () async {
    final b = await blob();
    of(b, 'identities', 'k1')['username'] = '';
    await restore(b);
    expect(await into.select(into.identities).get(), isEmpty);
    expect(await hostLabel('h1'), 'web-1');
    expect(await hostLabel('h2'), 'web-2');
  });
}

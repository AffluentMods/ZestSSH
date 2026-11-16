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

/// The ids a restored record points at are held to what an id can be (found
/// in security reviews).
/// A record's own id was already refused where it was empty or longer than
/// 128 characters; the ids of the records it points at (a host's key, group,
/// snippet and jump host, a forward's host) were taken as sent.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final t0 = DateTime.utc(2026, 10, 1, 9);
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

  Future<Map<String, dynamic>> blobWithAHostAndAForward() async {
    await from.into(from.connectionGroups).insert(
        ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: t0, updatedAt: Value(t0)));
    await from.into(from.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'web-1', host: 'h1.example.com', createdAt: t0, updatedAt: t0, groupId: const Value('g1')));
    await from.into(from.portForwardRules).insert(PortForwardRulesCompanion.insert(
        id: 'pf1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: 'localhost', remotePort: 80, createdAt: t0));
    return sender.gatherAll();
  }

  test('ids of the usual kind come as they are', () async {
    final blob = await blobWithAHostAndAForward();
    expect((await receiver.restoreAll(blob)).success, isTrue);
    expect((await into.connectionsDao.getById('h1'))!.groupId, 'g1');
    final rules = await into.portForwardRulesDao.getAll();
    expect(rules.single.connectionId, 'h1');
  });

  test('an id of another record that is empty or longer than an id can be points at nothing', () async {
    final blob = await blobWithAHostAndAForward();
    final host = (blob['connections'] as List).cast<Map>().single;
    host['groupId'] = 'g' * 5000;
    host['identityId'] = '';
    host['snippetId'] = 's' * 129;
    host['connectViaId'] = 'x' * 100000;
    expect((await receiver.restoreAll(blob)).success, isTrue);
    final got = (await into.connectionsDao.getById('h1'))!;
    expect(got.label, 'web-1', reason: 'the host itself comes');
    expect(got.groupId, isNull);
    expect(got.identityId, isNull);
    expect(got.snippetId, isNull);
    expect(got.connectViaId, isNull);
  });

  test('a forward of no host, or of an id no host can have, is not kept', () async {
    final blob = await blobWithAHostAndAForward();
    final rule = (blob['port_forward_rules'] as List).cast<Map>().single;
    rule['connectionId'] = 'h' * 5000;
    expect((await receiver.restoreAll(blob)).success, isTrue);
    expect(await into.portForwardRulesDao.getAll(), isEmpty);

    rule['connectionId'] = '';
    expect((await receiver.restoreAll(blob)).success, isTrue);
    expect(await into.portForwardRulesDao.getAll(), isEmpty);
  });
}

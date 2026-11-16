import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/memory_store_backend.dart';

/// A device's own secure storage, in memory: what the sync reads and writes
/// of it (each device's keys' secrets are its own).
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

/// A pull merges three ways (3.0; checking the claim "on merge,
/// timestamps are compared and newest wins"). Every pull
/// took every item of the store over this device's own, so a change made
/// here was undone by the next pull whenever another device had synced
/// meanwhile; and a pull stamped the rows it rewrote unchanged as changed
/// then, so a delete made elsewhere before that never applied here. Now an
/// item changed only there is taken, one changed only here is kept (and
/// counted, for the push that follows), one that is the same is not
/// written, and one changed on both sides goes to the later change; a key's
/// secrets and a host's tags and other accounts go with them; and no row is
/// stamped as changed by a restore.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final key = List<int>.generate(32, (i) => i * 7 % 256);
  final t0 = DateTime.utc(2026, 10, 1, 9);
  final t1 = DateTime.utc(2026, 10, 2, 9);
  final t2 = DateTime.utc(2026, 10, 3, 9);
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
      ConnectionsCompanion.insert(
          id: id, label: label, host: '$id.example.com', createdAt: t0, updatedAt: at));

  Future<String?> labelOf(_Device d, String id) async => (await d.db.connectionsDao.getById(id))?.label;

  /// What [d] last synced: what it holds now.
  Future<Map<String, String>> base(_Device d) async => SyncDataService.itemHashes(await d.data.gatherAll(), key);

  /// [to] pulls what [from] holds, merging with [last] (what [to] last
  /// synced; none: no base yet).
  Future<SyncRestoreResult> pull(_Device to, _Device from, Map<String, String>? last) async =>
      to.data.restoreAll(await from.data.gatherAll(), merge: SyncMergeBase(key: key, base: last));

  test('changed here and not there: kept, and counted; changed there and not here: taken; the same: not written',
      () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await host(d, 'h2', 'web-2', t0);
      await host(d, 'h3', 'web-3', t0);
      await host(d, 'h4', 'web-4', t0);
      await host(d, 'h5', 'web-5', t0);
    }
    final last = await base(b);
    await host(a, 'h1', 'web-1 renamed on A', t1);
    await host(b, 'h2', 'web-2 renamed on B', t1);
    // Written again unchanged, later than the change made on the other side:
    // what the other side changed is taken all the same, and what this side
    // changed is kept.
    await host(b, 'h4', 'web-4', t2);
    await host(a, 'h4', 'web-4 renamed on A', t1);
    await host(a, 'h5', 'web-5', t2);
    await host(b, 'h5', 'web-5 renamed on B', t1);

    final result = await pull(b, a, last);
    expect(result.success, isTrue);
    expect(await labelOf(b, 'h1'), 'web-1 renamed on A', reason: 'changed there only');
    expect(await labelOf(b, 'h2'), 'web-2 renamed on B', reason: 'changed here only: kept');
    expect(await labelOf(b, 'h4'), 'web-4 renamed on A', reason: 'changed there only, written later here');
    expect(await labelOf(b, 'h5'), 'web-5 renamed on B', reason: 'changed here only, written later there');
    expect(result.keptHere, 2);
    expect(result.recordsRestored, 2, reason: 'the same was not written');
    expect((await b.db.connectionsDao.getById('h3'))!.updatedAt, t0.toLocal());
  });

  test('changed on both sides: the later change wins, whichever side made it', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await host(d, 'h2', 'web-2', t0);
    }
    final last = await base(b);
    await host(a, 'h1', 'A first', t1);
    await host(b, 'h1', 'B later', t2);
    await host(a, 'h2', 'A later', t2);
    await host(b, 'h2', 'B first', t1);
    final result = await pull(b, a, last);
    expect(await labelOf(b, 'h1'), 'B later');
    expect(await labelOf(b, 'h2'), 'A later');
    expect(result.keptHere, 1);
  });

  test('with no base yet: a host or a snippet changed later here is kept; the other kinds go to the other devices\' '
      'copy, whose times of change every earlier pull stamped', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await d.db.into(d.db.connectionGroups).insert(
          ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: t0, updatedAt: Value(t0)));
    }
    await host(a, 'h1', 'A first', t1);
    await host(b, 'h1', 'B later', t2);
    await (a.db.update(a.db.connectionGroups)..where((g) => g.id.equals('g1')))
        .write(ConnectionGroupsCompanion(name: const Value('Web on A'), updatedAt: Value(t1)));
    await (b.db.update(b.db.connectionGroups)..where((g) => g.id.equals('g1')))
        .write(ConnectionGroupsCompanion(name: const Value('Web on B'), updatedAt: Value(t2)));
    final result = await pull(b, a, null);
    expect(await labelOf(b, 'h1'), 'B later');
    final group = (await b.db.connectionGroupsDao.getById('g1'))!;
    expect(group.name, 'Web on A');
    expect(group.updatedAt, t1.toLocal(), reason: 'taken with the time it was changed there');
    expect(result.keptHere, 1);
  });

  test('a pull stamps nothing it does not change, merged or not, so a delete made elsewhere before it still '
      'applies', () async {
    for (final d in [a, b]) {
      await d.db.into(d.db.connectionGroups).insert(
          ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
          id: 'i1', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.networks).insert(NetworksCompanion.insert(
          id: 'n1', name: 'Office', iconCodePoint: 0xe1ba, createdAt: t0, updatedAt: Value(t0)));
      await d.db
          .into(d.db.snippetCategories)
          .insert(SnippetCategoriesCompanion.insert(name: 'Ops', updatedAt: Value(t0)));
      await host(d, 'h1', 'web-1', t0);
      await d.db.into(d.db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'p1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: 'localhost', remotePort: 80,
          createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.hostNetworkOverrides).insert(HostNetworkOverridesCompanion.insert(
          id: 'o-${d == a ? 'a' : 'b'}', connectionId: 'h1', networkId: 'n1', createdAt: t0, updatedAt: t0));
      await d.db.into(d.db.portForwardNetworkOverrides).insert(PortForwardNetworkOverridesCompanion.insert(
          id: 'f-${d == a ? 'a' : 'b'}', ruleId: 'p1', networkId: 'n1', createdAt: t0, updatedAt: t0));
    }
    Future<Map<String, int?>> times(_Device d) async => {
          for (final (table, k, id) in [
            ('connection_groups', 'id', 'g1'),
            ('identities', 'id', 'i1'),
            ('networks', 'id', 'n1'),
            ('snippet_categories', 'name', 'Ops'),
            ('port_forward_rules', 'id', 'p1'),
            ('host_network_overrides', 'id', d == a ? 'o-a' : 'o-b'),
            ('port_forward_network_overrides', 'id', d == a ? 'f-a' : 'f-b'),
          ])
            table: (await d.db.customSelect('SELECT updated_at AS t FROM $table WHERE $k = ?',
                    variables: [Variable<String>(id)]).getSingleOrNull())
                ?.read<int?>('t'),
        };
    final before = await times(b);
    // A pull of the same, merged; and a restore with no merge (a backup).
    await pull(b, a, await base(b));
    expect(await times(b), before);
    await b.data.restoreAll(await a.data.gatherAll());
    expect(await times(b), before, reason: 'written, and its time of change put back');

    // A deletes the group, before the pulls above, and B pulls that.
    await a.db.tombstonesDao.mark('connection_groups', 'g1', at: t1);
    await a.db.customStatement("DELETE FROM connection_groups WHERE id = 'g1'");
    await pull(b, a, await base(b));
    expect(await b.db.connectionGroupsDao.getById('g1'), isNull);
  });

  test('every kind of item changed here and not there is kept, and every kind changed there and not here is '
      'taken', () async {
    Future<void> seed(_Device d) async {
      await host(d, 'h1', 'web-1', t0);
      await d.db.into(d.db.connectionGroups).insert(
          ConnectionGroupsCompanion.insert(id: 'g1', name: 'Web', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
          id: 'i1', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.networks).insert(NetworksCompanion.insert(
          id: 'n1', name: 'Office', iconCodePoint: 0xe1ba, createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.snippets).insert(SnippetsCompanion.insert(
          id: 's1', label: 'Disk', command: 'df -h', createdAt: t0, updatedAt: t0));
      await d.db
          .into(d.db.snippetCategories)
          .insert(SnippetCategoriesCompanion.insert(name: 'Ops', updatedAt: Value(t0)));
      await d.db.into(d.db.portForwardRules).insert(PortForwardRulesCompanion.insert(
          id: 'p1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: 'localhost', remotePort: 80,
          createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.terminalTriggers).insert(TerminalTriggersCompanion.insert(
          id: 't1', name: 'Errors', pattern: 'ERROR', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.commandHistory).insert(
          CommandHistoryCompanion.insert(id: 'c1', command: 'uptime', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.hostNetworkOverrides).insert(HostNetworkOverridesCompanion.insert(
          id: 'o-${d == a ? 'a' : 'b'}', connectionId: 'h1', networkId: 'n1', createdAt: t0, updatedAt: t0));
      await d.db.into(d.db.portForwardNetworkOverrides).insert(PortForwardNetworkOverridesCompanion.insert(
          id: 'f-${d == a ? 'a' : 'b'}', ruleId: 'p1', networkId: 'n1', createdAt: t0, updatedAt: t0));
    }

    /// Changes every item of [d], as [word] says.
    Future<void> change(_Device d, String word) async {
      final at = Variable<int>(t1.millisecondsSinceEpoch ~/ 1000);
      for (final sql in [
        "UPDATE connections SET label = 'web $word', updated_at = ? WHERE id = 'h1'",
        "UPDATE connection_groups SET name = 'Web $word', updated_at = ? WHERE id = 'g1'",
        "UPDATE identities SET label = 'deploy $word', updated_at = ? WHERE id = 'i1'",
        "UPDATE networks SET name = 'Office $word', updated_at = ? WHERE id = 'n1'",
        "UPDATE snippets SET label = 'Disk $word', updated_at = ? WHERE id = 's1'",
        "UPDATE snippet_categories SET sort_order = 5, updated_at = ? WHERE name = 'Ops'",
        "UPDATE port_forward_rules SET remote_port = 81, updated_at = ? WHERE id = 'p1'",
        "UPDATE terminal_triggers SET pattern = 'ERROR $word', updated_at = ? WHERE id = 't1'",
        "UPDATE command_history SET host_label = 'web $word', updated_at = ? WHERE id = 'c1'",
        "UPDATE host_network_overrides SET port = 2222, updated_at = ? WHERE connection_id = 'h1'",
        "UPDATE port_forward_network_overrides SET state = 'off', updated_at = ? WHERE rule_id = 'p1'",
      ]) {
        await d.db.customUpdate(sql, variables: [at]);
      }
    }

    Future<Map<String, String>> items(_Device d) async =>
        {for (final e in SyncDataService.itemHashes(await d.data.gatherAll(), key).entries) e.key: e.value};

    // Changed here only: every one kept.
    await seed(a);
    await seed(b);
    var last = await base(b);
    await change(b, 'on B');
    final kept = await items(b);
    var result = await pull(b, a, last);
    expect(await items(b), kept);
    expect(result.keptHere, kept.keys.where((k) => !k.startsWith('settings/')).length, reason: 'every item');
    expect(result.keptHere, 11);

    // Changed there only: every one taken.
    await a.db.close();
    await b.db.close();
    a = _Device(settings);
    b = _Device(settings);
    await seed(a);
    await seed(b);
    last = await base(b);
    await change(a, 'on A');
    result = await pull(b, a, last);
    final there = await items(a);
    final hereNow = await items(b);
    for (final name in there.keys) {
      if (name.startsWith('settings/')) continue;
      expect(hereNow[name], there[name], reason: name);
    }
    expect(result.keptHere, 0);
  });

  test('a key\'s secrets are part of it: a password changed here is kept, one changed there is taken', () async {
    for (final d in [a, b]) {
      await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
          id: 'i1', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
      await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
          id: 'i2', label: 'backup', username: 'backup', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
      d.vault.kept['identity_password_i1'] = 'first-password';
      d.vault.kept['identity_password_i2'] = 'second-password';
    }
    final last = await base(b);
    b.vault.kept['identity_password_i1'] = 'changed on B';
    a.vault.kept['identity_password_i2'] = 'changed on A';
    final result = await pull(b, a, last);
    expect(b.vault.kept['identity_password_i1'], 'changed on B');
    expect(b.vault.kept['identity_password_i2'], 'changed on A');
    expect(result.keptHere, 1);
  });

  test('a host\'s tags and other accounts are part of it: changed here, kept; changed there, taken', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
      await host(d, 'h2', 'web-2', t0);
      await d.db.into(d.db.identities).insert(IdentitiesCompanion.insert(
          id: 'i1', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: t0, updatedAt: Value(t0)));
      await d.db.connectionTagsDao.setTagsForConnection('h1', {'prod'});
      await d.db.connectionTagsDao.setTagsForConnection('h2', {'prod'});
    }
    final last = await base(b);
    await b.db.connectionTagsDao.setTagsForConnection('h1', {'prod', 'eu'});
    await b.db.hostAccountsDao.setOtherAccounts('h1', ['i1']);
    await a.db.connectionTagsDao.setTagsForConnection('h2', {'staging'});
    await a.db.hostAccountsDao.setOtherAccounts('h2', ['i1']);
    final result = await pull(b, a, last);
    expect((await b.db.connectionTagsDao.getTagsForConnection('h1')).toSet(), {'prod', 'eu'});
    expect((await b.db.hostAccountsDao.getAllAssignments())['h1'], ['i1'], reason: 'changed here only: kept');
    expect((await b.db.connectionTagsDao.getTagsForConnection('h2')).toSet(), {'staging'});
    expect((await b.db.hostAccountsDao.getAllAssignments())['h2'], ['i1']);
    expect(result.keptHere, 1);
  });

  test('settings: one changed here and not there is kept, one changed there is taken', () async {
    await settings.setBellEnabled(true);
    await settings.setCursorBlink(true);
    final there = await b.data.gatherAll();
    final last = SyncDataService.itemHashes(there, key);
    // Changed here, after the last sync: the bell. Changed there: the cursor.
    await settings.setBellEnabled(false);
    final incoming = {
      ...there,
      'settings': {...there['settings'] as Map, 'cursor_blink': false},
    };
    final result = await b.data.restoreAll(incoming, merge: SyncMergeBase(key: key, base: last));
    expect(settings.bellEnabled, isFalse, reason: 'changed here only: kept');
    expect(settings.cursorBlink, isFalse, reason: 'changed there only: taken');
    expect(result.keptHere, 1);
  });

  test('a backup writes every item it holds, as before', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
    }
    await host(b, 'h1', 'B later', t2);
    final result = await b.data.restoreAll(await a.data.gatherAll(), asBackup: true);
    expect(await labelOf(b, 'h1'), 'web-1');
    expect(result.keptHere, 0);
  });

  test('joining sync (no merge, no backup) keeps a later change made here, and counts it for the push', () async {
    for (final d in [a, b]) {
      await host(d, 'h1', 'web-1', t0);
    }
    await host(b, 'h1', 'B later', t2);
    final result = await b.data.restoreAll(await a.data.gatherAll());
    expect(await labelOf(b, 'h1'), 'B later');
    expect(result.keptHere, 1);
  });

  test('what each item is named and hashed by: the same content is the same hash wherever it was written, an '
      'override is named by its pair, and the key matters', () {
    final one = {
      'connections': [
        {'id': 'h1', 'label': 'web', 'port': 22, 'updatedAt': 1},
      ],
      'host_network_overrides': [
        {'id': 'o1', 'connectionId': 'h1', 'networkId': 'n1', 'port': 2222},
      ],
      'settings': {'bell_enabled': true},
    };
    final other = {
      'connections': [
        {'port': 22, 'label': 'web', 'id': 'h1', 'updatedAt': 99},
      ],
      'host_network_overrides': [
        {'networkId': 'n1', 'connectionId': 'h1', 'port': 2222, 'id': 'o-elsewhere'},
      ],
      'settings': {'bell_enabled': true},
    };
    final h = SyncDataService.itemHashes(one, key);
    expect(h.keys.toSet(), {'connections/h1', 'host_network_overrides/h1|n1', 'settings/bell_enabled'});
    expect(SyncDataService.itemHashes(other, key), h);
    expect(SyncDataService.itemHashes(one, [1, 2, 3])['connections/h1'], isNot(h['connections/h1']));
  });

  test('what a device last synced is kept on it, and forgotten when sync is taken apart', () async {
    expect(await b.data.loadSyncBase(), isNull);
    await b.data.saveSyncBase({'connections/h1': 'abc'});
    expect(await b.data.loadSyncBase(), {'connections/h1': 'abc'});
    await b.data.clearSyncBase();
    expect(await b.data.loadSyncBase(), isNull);
  });
}

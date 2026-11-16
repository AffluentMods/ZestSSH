import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_import_writer.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

/// Cloud import (3.0): what the person chose lands in the space they chose.
/// New hosts carry their link, tags, group and sign-in key; a host already
/// here is linked, not doubled; an update keeps the person's edits; gone
/// hosts are only marked; in an Orchard, hosts go into the chosen Crate and
/// its rules decide, one host at a time.

const _orchard = '66666666-6666-4666-8666-666666666666';
const _canAdd = '11111111-1111-4111-8111-111111111111';
const _cannotAdd = '22222222-2222-4222-8222-222222222222';

CloudMachine _m(String id, String name, String address, {List<String> tags = const [], CloudOs os = CloudOs.linux}) =>
    CloudMachine(provider: CloudProvider.hetzner, id: id, name: name, publicAddress: address, tags: tags, os: os);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  var n = 0;
  String ids() => 'id-${++n}';
  final at = DateTime.utc(2026, 9, 26, 12);

  group('in the Tree', () {
    late AppDatabase db;
    setUp(() {
      n = 0;
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    test('new hosts: address, port 22, sign-in key, group, tags and the link', () async {
      await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: 'key-1', label: 'root key', username: 'root', authMethod: 'publicKey', createdAt: at));
      final rows = planCloudImport(
        provider: CloudProvider.hetzner,
        machines: [_m('42', 'builder', '203.0.113.8', tags: ['role:ci', 'Keep'])],
        hosts: await cloudExistingHosts(db),
        label: 'Hetzner CI',
        preferPrivate: false,
      );
      final out = await applyCloudImport(
        CloudImportTarget(db: db, label: 'Hetzner CI', identityId: 'key-1', groupName: 'Hetzner CI'),
        rows,
        now: () => at,
        newId: ids,
      );
      expect(out.added, 1);
      expect(out.failures, isEmpty);
      final host = (await db.connectionsDao.getAll()).single;
      expect(host.label, 'builder');
      expect(host.host, '203.0.113.8');
      expect(host.port, 22);
      expect(host.identityId, 'key-1');
      final group = (await db.connectionGroupsDao.getAll()).single;
      expect(group.name, 'Hetzner CI');
      expect(host.groupId, group.id);
      expect(await db.connectionTagsDao.getTagsForConnection(host.id), ['keep', 'role:ci']);
      final link = CloudLink.decode(host.cloudSource)!;
      expect((link.provider, link.machineId, link.label, link.address, link.name),
          (CloudProvider.hetzner, '42', 'Hetzner CI', '203.0.113.8', 'builder'));

      // Importing again changes nothing and adds nothing.
      final again = planCloudImport(
        provider: CloudProvider.hetzner,
        machines: [_m('42', 'builder', '203.0.113.8')],
        hosts: await cloudExistingHosts(db),
        label: 'Hetzner CI',
        preferPrivate: false,
      );
      expect(again.single.status, CloudRowStatus.imported);
      final second = await applyCloudImport(CloudImportTarget(db: db, label: 'Hetzner CI', groupName: 'hetzner ci'), again, newId: ids);
      expect(second.changedAnything, isFalse);
      expect(await db.connectionsDao.getAll(), hasLength(1));
      expect(await db.connectionGroupsDao.getAll(), hasLength(1));
    });

    test('an existing group of the same name is used, whatever its case', () async {
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion.insert(id: 'g1', name: 'hetzner ci', createdAt: at));
      await applyCloudImport(
        CloudImportTarget(db: db, label: 'x', groupName: 'Hetzner CI'),
        planCloudImport(provider: CloudProvider.hetzner, machines: [_m('1', 'a', '5.5.5.5')], hosts: const [], label: 'x', preferPrivate: false),
        newId: ids,
      );
      expect((await db.connectionsDao.getAll()).single.groupId, 'g1');
      expect(await db.connectionGroupsDao.getAll(), hasLength(1));
    });

    test('a host already here by address is linked, keeping everything of its own', () async {
      await db.connectionsDao.insertConnection(ConnectionsCompanion.insert(
          id: 'mine', label: 'My builder', host: '203.0.113.8', createdAt: at, updatedAt: at));
      final rows = planCloudImport(
        provider: CloudProvider.hetzner,
        machines: [_m('42', 'builder', '203.0.113.8')],
        hosts: await cloudExistingHosts(db),
        label: 'Hetzner CI',
        preferPrivate: false,
      );
      expect(rows.single.status, CloudRowStatus.here);
      final out = await applyCloudImport(CloudImportTarget(db: db, label: 'Hetzner CI'), rows, now: () => at, newId: ids);
      expect(out.linked, 1);
      final host = (await db.connectionsDao.getAll()).single;
      expect(host.label, 'My builder');
      final link = CloudLink.decode(host.cloudSource)!;
      expect(link.machineId, '42');
      expect(link.name, 'My builder', reason: 'its name is theirs, so a rename at Hetzner never overwrites it');
    });

    test('a moved machine updates its host; a host the person re-pointed stays theirs; gone ones are marked, never removed',
        () async {
      String link(String id, String a, String name) =>
          CloudLink(provider: CloudProvider.hetzner, machineId: id, label: 'Hetzner CI', address: a, name: name).encode();
      for (final (id, label, host, l) in [
        ('h1', 'web', '1.1.1.1', link('1', '1.1.1.1', 'web')),
        ('h2', 'db', '10.8.0.2', link('2', '2.2.2.2', 'db')),
        ('h3', 'old', '3.3.3.3', link('3', '3.3.3.3', 'old')),
      ]) {
        await db.connectionsDao.insertConnection(
            ConnectionsCompanion.insert(id: id, label: label, host: host, cloudSource: Value(l), createdAt: at, updatedAt: at));
      }
      final rows = planCloudImport(
        provider: CloudProvider.hetzner,
        machines: [_m('1', 'web', '1.1.1.9'), _m('2', 'db-2', '2.2.2.9')],
        hosts: await cloudExistingHosts(db),
        label: 'Hetzner CI',
        preferPrivate: false,
      );
      final later = at.add(const Duration(hours: 1));
      final out = await applyCloudImport(CloudImportTarget(db: db, label: 'Hetzner CI'), rows, now: () => later, newId: ids);
      expect((out.updated, out.gone, out.added), (2, 1, 0));
      final by = {for (final c in await db.connectionsDao.getAll()) c.id: c};
      expect(by['h1']!.host, '1.1.1.9');
      expect(by['h1']!.updatedAt.toUtc(), later, reason: 'so the change syncs');
      expect(by['h2']!.host, '10.8.0.2', reason: 'their own address');
      expect(by['h2']!.label, 'db-2', reason: 'the name was still the imported one');
      expect(CloudLink.decode(by['h3']!.cloudSource)!.gone, isTrue);
      expect(by['h3']!.host, '3.3.3.3');
    });

    test('rows with nothing to do are skipped', () async {
      final out = await applyCloudImport(
        CloudImportTarget(db: db, label: 'x'),
        [
          CloudRow(machine: _m('1', 'a', '5.5.5.5'), status: CloudRowStatus.noAddress, selected: false),
          const CloudRow(status: CloudRowStatus.gone, selected: false),
        ],
        newId: ids,
      );
      expect(out.changedAnything, isFalse);
      expect(out.failures, isEmpty);
    });
  });

  group('in an Orchard', () {
    late AppDatabase db;
    setUp(() async {
      n = 0;
      db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
          "VALUES (1, ?, 'Acme', 'member-role', 1, ?)",
          [_orchard, _cannotAdd]);
      Future<void> crate(String id, Set<String> switches) => db.customStatement(
          "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'c', 'use', ?, 1)",
          [id, jsonEncode(switchList(switches))]);
      await crate(_canAdd, levelSwitches(CrateLevel.edit));
      await crate(_cannotAdd, levelSwitches(CrateLevel.connect));
    });
    tearDown(() => db.close());

    Future<String?> crateOf(String kind, String key) async => (await db
            .customSelect('SELECT crate_id FROM crate_items_meta WHERE kind = ? AND item_key = ?',
                variables: [Variable(kind), Variable(key)])
            .getSingleOrNull())
        ?.read<String>('crate_id');

    test('new hosts and their group go into the chosen Crate, even when new items usually go elsewhere', () async {
      final out = await applyCloudImport(
        CloudImportTarget(db: db, label: 'Tailnet', crateId: _canAdd, groupName: 'Tailnet'),
        planCloudImport(
          provider: CloudProvider.tailscale,
          machines: [
            const CloudMachine(provider: CloudProvider.tailscale, id: 'n1', name: 'pve', publicAddress: '100.64.0.10'),
          ],
          hosts: const [],
          label: 'Tailnet',
          preferPrivate: false,
        ),
        newId: ids,
      );
      expect(out.failures, isEmpty);
      expect(out.added, 1);
      final host = (await db.connectionsDao.getAll()).single;
      expect(await crateOf('host', host.id), _canAdd);
      expect(await crateOf('group', host.groupId!), _canAdd);
      final queued = await db.customSelect('SELECT kind FROM crate_outbox ORDER BY kind').get();
      expect(queued.map((r) => r.read<String>('kind')), ['group', 'host'], reason: 'both wait to sync');
    });

    test('a Crate that does not allow adding refuses each host; nothing is left half-made', () async {
      final out = await applyCloudImport(
        CloudImportTarget(db: db, label: 'Tailnet', crateId: _cannotAdd),
        planCloudImport(
          provider: CloudProvider.tailscale,
          machines: [
            const CloudMachine(provider: CloudProvider.tailscale, id: 'n1', name: 'a', publicAddress: '100.64.0.10'),
            const CloudMachine(provider: CloudProvider.tailscale, id: 'n2', name: 'b', publicAddress: '100.64.0.11'),
          ],
          hosts: const [],
          label: 'Tailnet',
          preferPrivate: false,
        ),
        newId: ids,
      );
      expect(out.added, 0);
      expect(out.failures.map((f) => f.name), ['a', 'b']);
      expect(out.failures.first.error, contains('orchard-access'));
      expect(await db.connectionsDao.getAll(), isEmpty);
      final meta = await db.customSelect('SELECT COUNT(*) AS n FROM crate_items_meta').getSingle();
      expect(meta.read<int>('n'), 0, reason: 'no placement left for a host that was never written');
    });
  });
}

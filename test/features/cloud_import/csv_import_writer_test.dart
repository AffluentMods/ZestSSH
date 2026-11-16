import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_writer.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';

import '../orchards/setup/setup_world.dart';

/// Hosts from a CSV file (3.0), written into the space chosen: each with its
/// group (found by name, else made), tags, way of connecting, note, and how
/// it signs in (the key the file names, else a key of its own for the user
/// it names, made once); lines with a problem are left out; in an Orchard,
/// what is made goes into the chosen Crate and its rules decide, one host at
/// a time, and a key the file names is the Crate's own, else the only one of
/// its name, never one of another Crate whose sessions are watched.

const _orchard = '66666666-6666-4666-8666-666666666666';
const _canAdd = '11111111-1111-4111-8111-111111111111';
const _cannotAdd = '22222222-2222-4222-8222-222222222222';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  var n = 0;
  String ids() => 'id-${++n}';
  final at = DateTime.utc(2026, 10, 15, 12);
  String userKey(String user) => '$user (imported)';

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('in the Tree', () {
    late AppDatabase db;
    setUp(() {
      n = 0;
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() => db.close());

    // A file names the address and the key both: `host=evil,key=root` aimed the
    // password saved with that key at its own server, with only the key's name
    // in the review (found in a security audit).
    group('a key that would send a host a password of the person\'s', () {
      Future<void> saved(String id, String label, {String method = 'password', String? password, bool afterKey = false}) async {
        await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
            id: id, label: label, username: 'root', authMethod: method, passwordAfterKey: Value(afterKey), createdAt: at));
        if (password != null) {
          FlutterSecureStorage.setMockInitialValues({'identity_password_$id': password});
        }
      }

      test('goes to the host only with a tick for its line', () async {
        await saved('k-root', 'root', password: 'made-up-password');
        final file = readCsvHosts('name,host,key\nEvil,evil.example.com,root\nKept,kept.example.com,root\n');
        final out = await applyCsvImport(CsvImportTarget(db: db, userKeyLabel: userKey), file.rows,
            passwordsAllowed: {file.rows.last.line}, now: () => at, newId: ids);
        expect(out.added, 2);
        final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c.identityId};
        expect(hosts['Evil'], isNull, reason: 'asks when connecting; the password goes nowhere');
        expect(hosts['Kept'], 'k-root');
      });

      test('the key made for a user the file names counts too', () async {
        await saved('k-imported', 'root (imported)', password: 'made-up-password');
        final file = readCsvHosts('name,host,user\nEvil,evil.example.com,root\n');
        await applyCsvImport(CsvImportTarget(db: db, userKeyLabel: userKey), file.rows, now: () => at, newId: ids);
        expect((await db.connectionsDao.getAll()).single.identityId, isNull);
        expect(await db.identitiesDao.getAll(), hasLength(1), reason: 'and no second key of that name is made');
      });

      test('one with a password saved after its key, or from a password manager, counts; one that holds none does not',
          () async {
        await saved('k-after', 'after', method: 'publicKey', password: 'made-up-password', afterKey: true);
        await saved('k-manager', 'manager', method: 'passwordManager');
        await saved('k-plain', 'plain', method: 'publicKey');
        await saved('k-empty', 'empty');
        final place = await CsvPlace.of(db);
        expect(place.keyNamed('after').key!.holdsPassword, isTrue);
        expect(place.keyNamed('manager').key!.holdsPassword, isTrue);
        expect(place.keyNamed('plain').key!.holdsPassword, isFalse);
        expect(place.keyNamed('empty').key!.holdsPassword, isFalse, reason: 'it asks each time, and has nothing to send');
      });
    });

    test('Compatibility mode on every new host where the import asks for it, off otherwise', () async {
      final file = readCsvHosts('name,host\nOld 1,old-01.example.com\nOld 2,old-02.example.com\n');
      await applyCsvImport(CsvImportTarget(db: db, userKeyLabel: userKey, compatibilityMode: true), file.rows,
          now: () => at, newId: ids);
      final plain = readCsvHosts('name,host\nNew,new.example.com\n');
      await applyCsvImport(CsvImportTarget(db: db, userKeyLabel: userKey), plain.rows, now: () => at, newId: ids);
      final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c.compatibilityMode};
      expect(hosts, {'Old 1': true, 'Old 2': true, 'New': false});
    });

    test('each host with its group, tags, protocol, note and the key it names; a user\'s own key made once and '
        'found again; lines with a problem left out', () async {
      await db.identitiesDao.insertIdentity(IdentitiesCompanion.insert(
          id: 'k-deploy', label: 'Deploy Key', username: 'deploy', authMethod: 'publicKey', createdAt: at));
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion.insert(id: 'g-prod', name: 'Production', createdAt: at));
      final file = readCsvHosts('name,host,port,user,group,tags,key,protocol,note\n'
          'Web 1,web-01.example.com,2222,,production,web;eu,deploy key,ssh,Front end\n'
          'DB,db.example.com,,dba,Databases,,,mosh,\n'
          'Cache,cache.example.com,,dba,Databases,,,,\n'
          'Broken,,22,,,,,,\n'
          'Odd port,odd.example.com,99999,,,,,,\n');
      final out = await applyCsvImport(CsvImportTarget(db: db, userKeyLabel: userKey), file.rows, now: () => at, newId: ids);
      expect(out.failures, isEmpty);
      expect((out.added, out.keysMade, out.groupsMade), (3, 1, 1));

      final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c};
      expect(hosts.keys.toSet(), {'Web 1', 'DB', 'Cache'});
      final web = hosts['Web 1']!;
      expect((web.host, web.port, web.identityId, web.groupId, web.protocol, web.note),
          ('web-01.example.com', 2222, 'k-deploy', 'g-prod', 'ssh', 'Front end'));
      expect((await db.connectionTagsDao.getTagsForConnection(web.id)).toSet(), {'web', 'eu'});
      final dba = (await db.identitiesDao.getAll()).singleWhere((i) => i.label == 'dba (imported)');
      expect((dba.username, dba.authMethod), ('dba', 'password'));
      expect(hosts['DB']!.identityId, dba.id);
      expect(hosts['Cache']!.identityId, dba.id, reason: 'one key for each user');
      expect(hosts['DB']!.protocol, 'mosh');
      expect(hosts['DB']!.groupId, hosts['Cache']!.groupId);
      expect(hosts['DB']!.port, 22);
      expect(hosts['DB']!.createdAt, at.toLocal());

      // A second file: the user's key is found again by its name, not made.
      final again = await applyCsvImport(
          CsvImportTarget(db: db, userKeyLabel: userKey), readCsvHosts('host,user\nweb-09.example.com,dba\n').rows,
          newId: ids);
      expect((again.added, again.keysMade), (1, 0));
      final web9 = (await db.connectionsDao.getAll()).singleWhere((c) => c.host == 'web-09.example.com');
      expect(web9.identityId, dba.id);
      expect(web9.label, 'web-09.example.com');
    });

    test('a key the file names that is not here: the user\'s own key, where it names one; none otherwise', () async {
      final out = await applyCsvImport(
        CsvImportTarget(db: db, userKeyLabel: userKey),
        readCsvHosts('host,user,key\na.example.com,ops,Missing\nb.example.com,,Missing\n').rows,
        newId: ids,
      );
      expect(out.added, 2);
      final hosts = {for (final c in await db.connectionsDao.getAll()) c.host: c};
      expect(hosts['a.example.com']!.identityId, isNotNull);
      expect(hosts['b.example.com']!.identityId, isNull, reason: 'asked when connecting');
    });

    test('the addresses already here, as an import compares them', () async {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h1', label: 'Web', host: 'Web-01.Example.com', port: const Value(2222), createdAt: at, updatedAt: at));
      expect((await CsvPlace.of(db)).addresses, {csvAddressKey('web-01.example.com', 2222)});
    });

    test('a key is found by its name in any case; a name two keys share, or none has, is not used, and says '
        'why', () async {
      Future<void> key(String id, String label, String user) => db.identitiesDao.insertIdentity(
          IdentitiesCompanion.insert(id: id, label: label, username: user, authMethod: 'publicKey', createdAt: at));
      await key('k-deploy', 'Deploy Key', 'deploy');
      await key('k-ops-1', 'ops', 'ops');
      await key('k-ops-2', 'OPS', 'ops');
      final place = await CsvPlace.of(db);
      final deploy = place.keyNamed('deploy KEY');
      expect(deploy.key, (id: 'k-deploy', label: 'Deploy Key', user: 'deploy', holdsPassword: false));
      expect(deploy.problem, isNull);
      expect(place.keyNamed('ops').key, isNull);
      expect(place.keyNamed('ops').problem, CsvKeyProblem.twice);
      expect(place.keyNamed('nobody').key, isNull);
      expect(place.keyNamed('nobody').problem, CsvKeyProblem.missing);

      final out = await applyCsvImport(
        CsvImportTarget(db: db, userKeyLabel: userKey),
        readCsvHosts('host,user,key\na.example.com,root,ops\nb.example.com,,ops\nc.example.com,,deploy key\n').rows,
        newId: ids,
      );
      expect((out.added, out.keysMade), (3, 1));
      final hosts = {for (final c in await db.connectionsDao.getAll()) c.host: c};
      final root = (await db.identitiesDao.getAll()).singleWhere((i) => i.label == 'root (imported)');
      expect(hosts['a.example.com']!.identityId, root.id, reason: "neither ops: the user's own key");
      expect(hosts['b.example.com']!.identityId, isNull, reason: 'asked when connecting');
      expect(hosts['c.example.com']!.identityId, 'k-deploy');
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

    test('hosts, their group and their user\'s key go into the chosen Crate, even when new items usually go '
        'elsewhere', () async {
      final out = await applyCsvImport(
        CsvImportTarget(db: db, crateId: _canAdd, userKeyLabel: userKey),
        readCsvHosts('host,user,group\nweb-01.example.com,deploy,Web\n').rows,
        newId: ids,
      );
      expect(out.failures, isEmpty);
      expect(out.added, 1);
      final host = (await db.connectionsDao.getAll()).single;
      expect(await crateOf('host', host.id), _canAdd);
      expect(await crateOf('group', host.groupId!), _canAdd);
      expect(await crateOf('key', host.identityId!), _canAdd);
    });

    test('a Crate that does not allow adding refuses each host; nothing is left half-made', () async {
      final out = await applyCsvImport(
        CsvImportTarget(db: db, crateId: _cannotAdd, userKeyLabel: userKey),
        readCsvHosts('name,host\na,a.example.com\nb,b.example.com\n').rows,
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

  group('in an Orchard, with its record', () {
    late SetupWorld world;
    late SetupDevice owner;
    late ({String id, String production, String staging, String members}) o;
    late AppDatabase orchard;
    late String deployHere, deployThere, root;

    setUpAll(SetupWorld.makeKeys);

    setUp(() async {
      n = 0;
      world = SetupWorld();
      await world.start();
      owner = world.device(SetupWorld.owner);
      o = await world.orchard(owner);
      deployHere = await owner.addKey(o.id, 'deploy', crateId: o.production);
      deployThere = await owner.addKey(o.id, 'Deploy', crateId: o.staging);
      root = await owner.addKey(o.id, 'root', crateId: o.staging);
      orchard = await owner.db(o.id);
    });

    tearDown(() => world.stop());

    test("a key the file names: the Crate's own, else the only one of its name, wherever it is", () async {
      final production = await CsvPlace.of(orchard, crateId: o.production);
      expect(production.keyNamed('DEPLOY').key?.id, deployHere, reason: "the Crate's own, though Staging has one too");
      expect(production.keyNamed('root').key?.id, root, reason: 'the only one of its name');
      final staging = await CsvPlace.of(orchard, crateId: o.staging);
      expect(staging.keyNamed('deploy').key?.id, deployThere);
      await owner.addKey(o.id, 'root', crateId: o.staging);
      expect((await CsvPlace.of(orchard, crateId: o.production)).keyNamed('root').problem, CsvKeyProblem.twice,
          reason: 'two of its name, and neither in the Crate');
    });

    test("one of another Crate whose sessions are watched is not used; its own Crate's hosts use it", () async {
      await owner.service.setCrateWatched(o.id, o.staging, true);
      expect((await latestRecordIn(orchard))!.crates[o.staging]!.watched, isTrue);
      final production = await CsvPlace.of(orchard, crateId: o.production);
      expect(production.keyNamed('root').key, isNull);
      expect(production.keyNamed('root').problem, CsvKeyProblem.watched);
      expect(production.keyNamed('deploy').key?.id, deployHere);
      expect((await CsvPlace.of(orchard, crateId: o.staging)).keyNamed('root').key?.id, root);

      final out = await applyCsvImport(
        CsvImportTarget(db: orchard, crateId: o.production, userKeyLabel: userKey),
        readCsvHosts('host,user,key\nweb-9.example.com,admin,root\nweb-10.example.com,,root\n').rows,
        newId: ids,
      );
      expect(out.failures, isEmpty);
      final hosts = {for (final c in await orchard.connectionsDao.getAll()) c.host: c};
      final admin = (await orchard.identitiesDao.getAll()).singleWhere((i) => i.label == 'admin (imported)');
      expect(hosts['web-9.example.com']!.identityId, admin.id, reason: "the user's own key, in Production");
      expect(await CratePlacement(orchard).crateOf('key', admin.id), o.production);
      expect(hosts['web-10.example.com']!.identityId, isNull, reason: 'asked when connecting');
    });
  });
}

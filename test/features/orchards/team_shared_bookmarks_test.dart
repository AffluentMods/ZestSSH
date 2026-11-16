import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/models/shared_pins.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show itemRecordFormatOf;
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart' show decodePins;
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';

import '../../helpers/orchard_db_fixture.dart';

/// A team host's shared SFTP bookmarks (4.0, connections.shared_pins): the
/// folders a team keeps for one server ("in a team, multiple people might go
/// to /opt/x/service"). They travel in the host's team record to every member
/// who can see it, held to their bounds; a host without them keeps the record
/// a version before them wrote; a version before them reads such a record as
/// it reads any with a column it does not know; and they never go into
/// personal sync, where a member's own pins already travel.

const _two = '[{"label":"Service","path":"/opt/x/service"},{"label":"/var/log/x","path":"/var/log/x"}]';

Future<void> _applying(AppDatabase db, Future<void> Function() body) => db.transaction(() async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await body();
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });

Map<String, Object?> _hostRecord({Object? shared, bool withShared = true}) => {
      'connections': [
        {
          'id': 'h-1',
          'label': 'svc-01',
          'host': '192.0.2.40',
          'protocol': 'ssh',
          'created_at': 1790000000,
          if (withShared) 'shared_pins': shared,
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('the list, as it is kept', () {
    test('a list within its bounds stays exactly as it is', () {
      expect(sanitizeSharedPinsJson(_two), _two);
      expect(decodePins(sanitizeSharedPinsJson(_two)).map((p) => p.path), ['/opt/x/service', '/var/log/x']);
    });

    test('nothing, or anything but a list of bookmarks, is none', () {
      for (final bad in [null, '', '[]', 'not json', '{"label":"x","path":"/x"}', '[1, "two"]', 42]) {
        expect(sanitizeSharedPinsJson(bad), isNull, reason: '$bad');
      }
    });

    test('controls and the marks that turn text around are taken out; a long name is cut, a path is never', () {
      final long = 'n' * 300;
      final out = decodePins(sanitizeSharedPinsJson(jsonEncode([
        {'label': 'Ser\u202Evice\n', 'path': '/opt/x/\u200Bservice'},
        {'label': long, 'path': '/srv/a'},
        {'label': 'Too long', 'path': '/${'p' * kMaxSharedPinPathChars}'},
        {'label': 'Relative', 'path': 'opt/x'},
        {'label': 'No path'},
        {'label': 'Twice', 'path': '/opt/x/service'},
      ])));
      expect([for (final p in out) p.path], ['/opt/x/service', '/srv/a']);
      expect(out.first.label, 'Service');
      expect(out[1].label.length, kMaxSharedPinLabelChars);
    });

    test('at most $kMaxSharedPins, the first ones', () {
      final many = jsonEncode([for (var i = 0; i < kMaxSharedPins + 10; i++) {'label': 'f$i', 'path': '/srv/f$i'}]);
      final out = decodePins(sanitizeSharedPinsJson(many));
      expect(out.length, kMaxSharedPins);
      expect(out.last.path, '/srv/f${kMaxSharedPins - 1}');
    });

    test('a folder can be shared when it is absolute and short enough to keep whole', () {
      expect(canSharePinPath('/opt/x/service'), isTrue);
      expect(canSharePinPath('relative/path'), isFalse);
      expect(canSharePinPath('/${'p' * kMaxSharedPinPathChars}'), isFalse);
    });
  });

  group("the host's team record", () {
    late AppDatabase a;
    late AppDatabase b;
    setUp(() async {
      a = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      b = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
      await seedOrchardAsOwner(a);
      await seedOrchardAsOwner(b);
    });
    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('a host with none sends the record a version before the column sent: no such field', () async {
      await _applying(a, () => OrchardItemStore(a).write('host', 'h-1', data: _hostRecord(withShared: false), editedAt: 1));
      final data = await OrchardItemStore(a).read('host', 'h-1');
      final row = (data!['connections'] as List).single as Map;
      expect(row.containsKey('shared_pins'), isFalse);
      expect(row.containsKey('pins'), isFalse, reason: 'your own pins never travel');
    });

    test('shared bookmarks reach every member: written on one device, read the same on another', () async {
      await _applying(a, () => OrchardItemStore(a).write('host', 'h-1', data: _hostRecord(withShared: false), editedAt: 1));
      await a.connectionsDao.setSharedPins('h-1', _two);
      final sent = await OrchardItemStore(a).read('host', 'h-1');
      expect(((sent!['connections'] as List).single as Map)['shared_pins'], _two);

      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: sent, editedAt: 2));
      expect((await b.connectionsDao.getById('h-1'))!.sharedPins, _two);
      expect(await OrchardItemStore(b).read('host', 'h-1'), sent);

      // A member's own pins on the other device stay theirs when the record is written again.
      await b.connectionsDao.setPins('h-1', '[{"label":"Mine","path":"/home/deploy"}]');
      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: sent, editedAt: 3));
      expect((await b.connectionsDao.getById('h-1'))!.pins, contains('/home/deploy'));
    });

    test('a record without them clears them (the last one was removed)', () async {
      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: _hostRecord(shared: _two), editedAt: 1));
      expect((await b.connectionsDao.getById('h-1'))!.sharedPins, _two);
      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: _hostRecord(withShared: false), editedAt: 2));
      expect((await b.connectionsDao.getById('h-1'))!.sharedPins, isNull);
    });

    test('a record with a bad list keeps the host and drops the list; one past the bounds is held to them', () async {
      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: _hostRecord(shared: 'not a list'), editedAt: 1));
      final host = await b.connectionsDao.getById('h-1');
      expect(host!.label, 'svc-01');
      expect(host.sharedPins, isNull);

      final many = jsonEncode([for (var i = 0; i < 80; i++) {'label': 'f$i', 'path': '/srv/f$i'}]);
      await _applying(b, () => OrchardItemStore(b).write('host', 'h-1', data: _hostRecord(shared: many), editedAt: 2));
      expect(decodePins((await b.connectionsDao.getById('h-1'))!.sharedPins).length, kMaxSharedPins);
    });

    test('the record stays in the format every version from 3.0 reads', () {
      expect(itemRecordFormatOf('host', _hostRecord(shared: _two)), 1);
    });

    test('a version before the column takes the host and keeps the list for the next change it sends', () async {
      // What versions from 3.0 do with a column of a host they do not know,
      // as shared_pins is to them: the host is written, the column kept apart
      // and sent back with that device's next change of the host. (This
      // version knows shared_pins, so a column it does not know stands in.)
      const unknown = 'a_column_newer_than_this_app';
      final store = OrchardItemStore(b);
      final received = _hostRecord(withShared: false);
      ((received['connections'] as List).single as Map<String, Object?>)[unknown] = _two;
      await _applying(b, () => store.write('host', 'h-1', data: received, editedAt: 1));
      expect((await b.connectionsDao.getById('h-1'))!.label, 'svc-01');

      final extras = store.extrasOf('host', received);
      await b.customStatement("UPDATE connections SET label = 'svc-02' WHERE id = 'h-1'");
      final sent = store.withExtras('host', (await store.read('host', 'h-1'))!, extras);
      final row = (sent['connections'] as List).single as Map;
      expect(row['label'], 'svc-02');
      expect(row[unknown], _two, reason: 'the team keeps its bookmarks');
    });
  });

  group('personal sync', () {
    late AppDatabase tree;
    late AppDatabase other;
    setUp(() {
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      other = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await tree.close();
      await other.close();
    });

    SyncDataService service(AppDatabase db, SettingsService s) => SyncDataService(
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
          secureStorage: const FlutterSecureStorage(),
          settingsService: s,
        );

    test('never carries shared bookmarks, and takes none from a blob; the payload stays version 22', () async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(const {});
      final s = SettingsService(await SharedPreferences.getInstance());
      await tree.connectionsDao.insertConnection(ConnectionsCompanion(
        id: const Value('h-1'),
        label: const Value('svc-01'),
        host: const Value('192.0.2.40'),
        pins: const Value('[{"label":"Mine","path":"/home/deploy"}]'),
        sharedPins: const Value(_two),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));

      final blob = await service(tree, s).gatherAll();
      expect(blob['schema_version'], 22);
      final host = (blob['connections'] as List).single as Map;
      expect(host.containsKey('sharedPins'), isFalse);
      expect(host['pins'], contains('/home/deploy'), reason: 'your own pins travel as before');

      (host as Map<String, dynamic>)['sharedPins'] = _two;
      await service(other, s).restoreAll(blob);
      final restored = await other.connectionsDao.getById('h-1');
      expect(restored!.pins, contains('/home/deploy'));
      expect(restored.sharedPins, isNull);
    });
  });
}

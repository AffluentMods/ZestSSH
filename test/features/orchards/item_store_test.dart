import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import '../../helpers/orchard_db_fixture.dart';

/// Every kind of Orchard item survives the trip to another device: the rows
/// it is made of read into a record and write back the same on a device
/// that never had them, with the columns that stay on a device left at
/// their defaults there (3.0).

/// Fills every column of [table] from the live schema: the item's key in
/// its key column, a value of the column's type everywhere else.
Future<void> _insertFull(AppDatabase db, String table, String key, int variant) async {
  final keyColumn = AppDatabase.orchardItemTables[table]!.$2;
  final columns = await db.customSelect('PRAGMA table_info($table)').get();
  final names = <String>[];
  final values = <Object?>[];
  for (final c in columns) {
    final name = c.read<String>('name');
    final type = c.read<String>('type').toUpperCase();
    names.add('"$name"');
    if (name == keyColumn) {
      values.add(key);
    } else if (name == 'id') {
      values.add('$table-$key-$variant');
    } else if (table == 'connections' && name == 'protocol') {
      // A remote screen (4.0): the one kind of host whose options a record
      // carries, and only as a JSON object (OrchardItemStore.write).
      values.add('vnc');
    } else if (table == 'connections' && name == 'screen_options') {
      values.add('{"v":$variant}');
    } else if (table == 'connections' && name == 'shared_pins') {
      // A team's shared SFTP bookmarks (4.0): a list a record carries only
      // as one within its bounds (OrchardItemStore.write).
      values.add('[{"label":"Service $variant","path":"/opt/x/service-$variant"}]');
    } else if (type.contains('INT')) {
      values.add(1);
    } else if (type.contains('REAL')) {
      values.add(1.5);
    } else if (type.contains('BLOB')) {
      values.add(Uint8List.fromList([1, 2, 3]));
    } else {
      values.add('v$variant-$name');
    }
  }
  await db.customStatement(
    'INSERT INTO $table (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})',
    values,
  );
}

Future<void> _applying(AppDatabase db, Future<void> Function() body) => db.transaction(() async {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await body();
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  for (final entry in OrchardItemStore.tablesOfKind.entries) {
    final kind = entry.key;
    final tables = entry.value;
    test('a $kind reaches a device that never had it, every column intact', () async {
      for (final table in tables) {
        await _insertFull(a, table, 'k-1', 1);
        if (table != tables.first && table != 'orchard_secrets') {
          await _insertFull(a, table, 'k-1', 2);
        }
      }
      final data = await OrchardItemStore(a).read(kind, 'k-1');
      expect(data, isNotNull);

      await _applying(b, () => OrchardItemStore(b).write(kind, 'k-1', data: data, editedAt: 1758585600000));
      expect(await OrchardItemStore(b).read(kind, 'k-1'), data);
      final queued = await b.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle();
      expect(queued.read<int>('n'), 0);

      // A second write replaces the rows rather than adding to them.
      await _applying(b, () => OrchardItemStore(b).write(kind, 'k-1', data: data, editedAt: 1758585600000));
      expect(await OrchardItemStore(b).read(kind, 'k-1'), data);

      await _applying(b, () => OrchardItemStore(b).write(kind, 'k-1', data: null, editedAt: 1758585600000));
      expect(await OrchardItemStore(b).read(kind, 'k-1'), isNull);
      for (final table in tables) {
        final left = await b.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle();
        expect(left.read<int>('n'), 0, reason: '$table is empty after the deletion');
      }
    });
  }

  test('a team\'s forward listens on each device as that device says: its address, gateway ports and flags stay there',
      () async {
    // What another device of the team sends: a listener open to the network, the server's gateway ports, a command.
    Future<void> arrives(Map<String, Object?> row) => _applying(b, () => OrchardItemStore(b).write('forward', 'pf-1', data: {
          'port_forward_rules': [row],
        }, editedAt: 1758585600000));
    final sent = <String, Object?>{
      'id': 'pf-1',
      'connection_id': 'h-1',
      'type': 'local',
      'bind_address': '0.0.0.0',
      'bind_port': 8080,
      'remote_host': 'db.example.com',
      'remote_port': 5432,
      'gateway_ports': 1,
      'ssh_flags': '-o ProxyCommand=sh',
      'created_at': 1758585600,
    };
    await arrives(sent);
    Future<Map<String, Object?>> here() async =>
        (await b.customSelect('SELECT * FROM port_forward_rules WHERE id = ?', variables: [const Variable('pf-1')]).getSingle())
            .data;
    var row = await here();
    expect(row['bind_address'], '127.0.0.1', reason: 'on loopback until this device says otherwise');
    expect(row['gateway_ports'], 0);
    expect(row['ssh_flags'], isNull);
    expect(row['bind_port'], 8080, reason: 'the rest of the forward travels');
    expect(row['remote_host'], 'db.example.com');

    // This device opens it to its network; the team's next change of the forward leaves that as it is.
    await b.customStatement("UPDATE port_forward_rules SET bind_address = '0.0.0.0', gateway_ports = 1 WHERE id = 'pf-1'");
    await arrives({...sent, 'bind_address': '127.0.0.1', 'gateway_ports': 0, 'bind_port': 8081});
    row = await here();
    expect(row['bind_address'], '0.0.0.0');
    expect(row['gateway_ports'], 1);
    expect(row['bind_port'], 8081);

    // And what this device sends says nothing of them.
    final data = await OrchardItemStore(b).read('forward', 'pf-1');
    final out = (data!['port_forward_rules'] as List).single as Map;
    expect(out.keys, isNot(anyOf(contains('bind_address'), contains('gateway_ports'), contains('ssh_flags'))));
    expect(out, containsPair('bind_port', 8081));
  });

  test('a column from a newer version is left out, not refused', () async {
    await _applying(b, () => OrchardItemStore(b).write('category', 'Ops', data: {
          'snippet_categories': [
            {'name': 'Ops', 'color_index': 2, 'a_column_from_the_future': 'x'},
          ],
        }, editedAt: 1758585600000));
    final data = await OrchardItemStore(b).read('category', 'Ops');
    expect((data!['snippet_categories'] as List).single, containsPair('color_index', 2));
  });

  test('a record with a row of another item changes nothing', () async {
    await _insertFull(b, 'connections', 'h-other', 1);
    final before = await OrchardItemStore(b).read('host', 'h-other');
    await expectLater(
      OrchardItemStore(b).write('host', 'h-1', data: {
        'connections': [
          {'id': 'h-1', 'label': 'mine', 'host': 'a', 'created_at': 1},
        ],
        'connection_tags': [
          {'connection_id': 'h-other', 'tag': 'hijack', 'created_at': 1},
        ],
      }, editedAt: 1758585600000),
      throwsFormatException,
    );
    expect(await OrchardItemStore(b).read('host', 'h-1'), isNull);
    expect(await OrchardItemStore(b).read('host', 'h-other'), before);
  });

  group('what a newer version added', () {
    const crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
    Map<String, Object?> received() => {
          'connections': [
            {
              'id': 'h-1',
              'label': 'web',
              'host': 'a',
              'created_at': 1,
              'future_col': 'kept',
              'pinned': 1,
            },
          ],
          'connection_tags': [
            {'connection_id': 'h-1', 'tag': 'eu', 'created_at': 1, 'future_tag': 5},
            {'connection_id': 'h-1', 'tag': 'prod', 'created_at': 1},
          ],
          'future_table': [
            {'connection_id': 'h-1', 'x': 1},
          ],
        };

    test('is kept apart from what this version knows', () {
      final extras = OrchardItemStore(b).extrasOf('host', received(), record: {'future_top': true});
      expect(extras.record, {'future_top': true});
      expect(extras.tables, {
        'future_table': [
          {'connection_id': 'h-1', 'x': 1},
        ],
      });
      expect(
        extras.columns,
        {
          'connections': [
            {'id': 'h-1', 'future_col': 'kept'},
          ],
          'connection_tags': [
            {'connection_id': 'h-1', 'tag': 'eu', 'future_tag': 5},
          ],
        },
        reason: 'pinned is known: it stays on each device and is not carried along',
      );
      final again = ItemExtras.decode(extras.encode());
      expect(again.record, extras.record);
      expect(again.tables, extras.tables);
      expect(again.columns, extras.columns);
      expect(OrchardItemStore(b).extrasOf('host', {
        'connections': [
          {'id': 'h-1', 'label': 'web', 'host': 'a', 'created_at': 1},
        ],
      }).encode(), isNull, reason: 'nothing unknown, nothing kept');
      expect(ItemExtras.decode('not json').isEmpty, isTrue);
    });

    test('goes back out with this device\'s rows, except for a row deleted here', () async {
      final store = OrchardItemStore(b);
      final extras = store.extrasOf('host', received());
      await _applying(b, () => store.write('host', 'h-1', data: received(), editedAt: 1758585600000));
      await b.customStatement(
          "UPDATE connections SET label = 'web-2', pinned = 1 WHERE id = 'h-1'");
      await b.customStatement("DELETE FROM connection_tags WHERE tag = 'eu'");

      final sent = store.withExtras('host', (await store.read('host', 'h-1'))!, extras);
      final main = (sent['connections'] as List).single as Map<String, Object?>;
      expect(main['label'], 'web-2');
      expect(main['future_col'], 'kept');
      expect(main.containsKey('pinned'), isFalse);
      final tags = (sent['connection_tags'] as List).cast<Map<String, Object?>>();
      expect([for (final t in tags) t['tag']], ['prod']);
      expect(tags.single.containsKey('future_tag'), isFalse);
      expect(sent['future_table'], [
        {'connection_id': 'h-1', 'x': 1},
      ]);
    });

    test('is taken into the rows once this version knows it, quietly', () async {
      // An older version kept a column and a table it did not know that this
      // version does: the host's note, and its tags.
      final store = OrchardItemStore(b);
      await _applying(
          b,
          () => store.write('host', 'h-1', data: {
                'connections': [
                  {'id': 'h-1', 'label': 'web', 'host': 'a', 'created_at': 1},
                ],
              }, editedAt: 1758585600000));
      const kept = ItemExtras(
        record: {'future_top': 1},
        tables: {
          'connection_tags': [
            {'connection_id': 'h-1', 'tag': 'kept', 'created_at': 1},
          ],
          'future_table': [
            {'connection_id': 'h-1', 'x': 1},
          ],
        },
        columns: {
          'connections': [
            {'id': 'h-1', 'note': 'from a newer app', 'future_col': 'still unknown'},
          ],
        },
      );
      await b.customStatement(
        'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at, extra) '
        "VALUES ('host', 'h-1', ?, 5, 1758585600000, ?)",
        [crate, kept.encode()],
      );

      expect(await store.absorbKnownExtras(), 1);
      final note = await b.customSelect("SELECT note FROM connections WHERE id = 'h-1'").getSingle();
      expect(note.read<String?>('note'), 'from a newer app');
      final tags = await b.customSelect("SELECT tag FROM connection_tags WHERE connection_id = 'h-1'").get();
      expect([for (final t in tags) t.read<String>('tag')], ['kept']);
      final queued = await b.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle();
      expect(queued.read<int>('n'), 0, reason: 'the rows now match the version received');

      final left = ItemExtras.decode((await b
              .customSelect("SELECT extra FROM crate_items_meta WHERE item_key = 'h-1'")
              .getSingle())
          .read<String?>('extra'));
      expect(left.record, {'future_top': 1});
      expect(left.tables, {
        'future_table': [
          {'connection_id': 'h-1', 'x': 1},
        ],
      });
      expect(left.columns, {
        'connections': [
          {'id': 'h-1', 'future_col': 'still unknown'},
        ],
      });
      expect(await store.absorbKnownExtras(), 0, reason: 'nothing more to take in');
    });
  });
}

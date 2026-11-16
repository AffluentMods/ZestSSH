import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import '../../helpers/orchard_db_fixture.dart';

/// A team item with a date no date can hold (found in a security
/// review): a member could write a host whose `created_at` was 10^13. It passed
/// the item store's check (`is int`), and every read of the team's hosts then
/// threw (`RangeError (millisecondsSinceEpoch)`), on every member's device; an
/// `edited_at` far past the year 9999 did the same to the screens that show when
/// an item was changed. Such an item is refused now, as any malformed one is.

/// Fills every column of [table] with a value of its type (dates: 1 second).
Future<void> _insertFull(AppDatabase db, String table, String key) async {
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
      values.add('$table-$key');
    } else if (type.contains('INT')) {
      values.add(1);
    } else if (type.contains('REAL')) {
      values.add(1.5);
    } else if (type.contains('BLOB')) {
      values.add(Uint8List.fromList([1, 2, 3]));
    } else {
      values.add('v-$name');
    }
  }
  await db.customStatement(
    'INSERT INTO $table (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})',
    values,
  );
}

Future<void> _applying(AppDatabase db, Future<void> Function() body) =>
    db.transaction(() async {
      await db.customStatement(
        'UPDATE orchard_sync_control SET applying = 1 WHERE id = 1',
      );
      await body();
      await db.customStatement(
        'UPDATE orchard_sync_control SET applying = 0 WHERE id = 1',
      );
    });

Map<String, dynamic> _record({required int editedAt}) => {
  'v': 1,
  'kind': 'host',
  'key': 'k-1',
  'author': 'uid-member',
  'author_key': 1,
  'edited_at': editedAt,
  'deleted': false,
  'data': <String, dynamic>{},
};

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

  /// A whole host as another member's device sends it, with [createdAt] in its row.
  Future<Map<String, Object?>> hostWith(int createdAt) async {
    for (final table in OrchardItemStore.tablesOfKind['host']!) {
      await _insertFull(a, table, 'k-1');
    }
    final data = (await OrchardItemStore(a).read('host', 'k-1'))!;
    final rows = (data['connections']! as List).cast<Map<String, Object?>>();
    rows.first['created_at'] = createdAt;
    return data;
  }

  test(
    'a host whose date no date can hold is refused, nothing is written, and the hosts still read',
    () async {
      final data = await hostWith(10000000000000);
      await expectLater(
        _applying(
          b,
          () => OrchardItemStore(
            b,
          ).write('host', 'k-1', data: data, editedAt: 1758585600000),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        await OrchardItemStore(b).read('host', 'k-1'),
        isNull,
        reason: 'nothing written',
      );
      expect(
        await b.select(b.connections).get(),
        isEmpty,
        reason: 'and the team\'s hosts read without a throw',
      );
    },
  );

  test(
    'the last second of the year 9999 is still a date, and is taken',
    () async {
      final data = await hostWith(253402300799);
      await _applying(
        b,
        () => OrchardItemStore(
          b,
        ).write('host', 'k-1', data: data, editedAt: 1758585600000),
      );
      final hosts = await b.select(b.connections).get();
      expect(hosts.single.createdAt.year, 9999);
    },
  );

  test(
    'an item record changed at a time no date can hold is not an item record',
    () {
      expect(
        ItemRecord.fromJson(_record(editedAt: 1758585600000)).editedAt,
        1758585600000,
      );
      expect(
        ItemRecord.fromJson(_record(editedAt: kItemEditedAtMaxMs)).editedAt,
        kItemEditedAtMaxMs,
      );
      for (final bad in [10000000000000000, kItemEditedAtMaxMs + 1, -1]) {
        expect(
          () => ItemRecord.fromJson(_record(editedAt: bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    },
  );
}

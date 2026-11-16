import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';

/// Coverage for the Part B (schema v18) home-screen columns -
/// `sizeTier` / `pinned` / `note` - and the arrange-mode DAO surface.
///
/// The single most important assertion here is `schemaVersion == 18`: this
/// codebase has previously shipped a migration whose `schemaVersion` was
/// left unbumped, so the onUpgrade path never ran and existing users hit a
/// "no such column" data-loss failure. This test fails fast if a future
/// column is added without bumping the version.
Future<void> _insert(
  AppDatabase db,
  String id, {
  int? sizeTier,
  bool? pinned,
  String? note,
  int? sortOrder,
}) async {
  final now = DateTime.now();
  await db.connectionsDao.insertConnection(ConnectionsCompanion(
    id: Value(id),
    label: Value('label-$id'),
    host: Value('host-$id'),
    port: const Value(22),
    sizeTier: sizeTier == null ? const Value.absent() : Value(sizeTier),
    pinned: pinned == null ? const Value.absent() : Value(pinned),
    note: note == null ? const Value.absent() : Value(note),
    sortOrder: sortOrder == null ? const Value.absent() : Value(sortOrder),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

void main() {
  late AppDatabase db;
  late ConnectionsDao dao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = db.connectionsDao;
  });

  tearDown(() async {
    await db.close();
  });

  test('schemaVersion is >= 18 - guards the unbumped-migration regression',
      () {
    // Part B added the v18 columns; the migration only runs when the target
    // schemaVersion is at least 18. Later additive bumps (v19+) push this
    // higher, so assert the floor to keep catching an un-bumped v18 without
    // breaking on every subsequent schema addition.
    expect(db.schemaVersion, greaterThanOrEqualTo(18));
  });

  group('Part B columns (v18) exist with correct defaults', () {
    test('an inserted connection defaults to Medium / unpinned / no note',
        () async {
      await _insert(db, 'a');
      final c = await dao.getById('a');
      expect(c, isNotNull);
      expect(c!.sizeTier, 1, reason: 'Medium is the default tier');
      expect(c.pinned, false);
      expect(c.note, isNull);
    });

    test('updateSizeTier / setPinned / updateNote round-trip', () async {
      await _insert(db, 'a');

      await dao.updateSizeTier('a', 2);
      await dao.setPinned('a', true);
      await dao.updateNote('a', 'prod box - do not reboot');

      final c = await dao.getById('a');
      expect(c!.sizeTier, 2);
      expect(c.pinned, true);
      expect(c.note, 'prod box - do not reboot');

      // Clearing the note writes NULL, not empty string.
      await dao.updateNote('a', null);
      expect((await dao.getById('a'))!.note, isNull);
    });
  });

  group('applyLayout (arrange-mode batch write)', () {
    test('writes each row\'s sortOrder while preserving pinned + sizeTier',
        () async {
      await _insert(db, 'a', sizeTier: 2, pinned: true);
      await _insert(db, 'b', sizeTier: 0);
      await _insert(db, 'c');

      // Simulate the drag result "c, a, b" - the UI passes each card's
      // current pinned/sizeTier alongside the new index.
      await dao.applyLayout([
        (id: 'c', sortOrder: 0, pinned: false, sizeTier: 1),
        (id: 'a', sortOrder: 1, pinned: true, sizeTier: 2),
        (id: 'b', sortOrder: 2, pinned: false, sizeTier: 0),
      ]);

      final a = await dao.getById('a');
      final b = await dao.getById('b');
      final c = await dao.getById('c');

      expect(c!.sortOrder, 0);
      expect(a!.sortOrder, 1);
      expect(b!.sortOrder, 2);

      // The other columns carried through untouched.
      expect(a.pinned, true);
      expect(a.sizeTier, 2);
      expect(b.sizeTier, 0);
    });
  });
}

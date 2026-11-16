import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/database.dart';

/// Insert a stub connection so foreign-key-style references (we don't
/// CASCADE, but the test still wants realistic ids) are well-formed.
Future<void> _insertStubConnection(AppDatabase db, String id) async {
  final now = DateTime.now();
  await db.into(db.connections).insert(ConnectionsCompanion(
        id: Value(id),
        label: Value('label-$id'),
        host: Value('host-$id'),
        port: const Value(22),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
}

void main() {
  late AppDatabase db;
  late ConnectionTagsDao dao;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    dao = db.connectionTagsDao;
  });

  tearDown(() async {
    await db.close();
  });

  group('normalize', () {
    test('lowercases input', () {
      expect(ConnectionTagsDao.normalize('Production'), 'production');
    });

    test('trims surrounding whitespace', () {
      expect(ConnectionTagsDao.normalize('  prod  '), 'prod');
    });

    test('collapses internal whitespace', () {
      expect(ConnectionTagsDao.normalize('hot   path'), 'hot path');
    });

    test('returns null for whitespace-only input', () {
      expect(ConnectionTagsDao.normalize('   '), isNull);
      expect(ConnectionTagsDao.normalize(''), isNull);
    });

    test('truncates to 32 chars', () {
      final long = 'a' * 50;
      expect(ConnectionTagsDao.normalize(long)!.length, 32);
    });
  });

  group('addTag / removeTag', () {
    test('persists a tag with canonical form', () async {
      await _insertStubConnection(db, 'c1');
      final canonical = await dao.addTag('c1', '  Prod  ');
      expect(canonical, 'prod');
      expect(await dao.getTagsForConnection('c1'), ['prod']);
    });

    test('addTag is idempotent on the same connection', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'PROD');
      await dao.addTag('c1', 'prod');
      expect(await dao.getTagsForConnection('c1'), ['prod']);
    });

    test('addTag drops empty input without throwing', () async {
      await _insertStubConnection(db, 'c1');
      final result = await dao.addTag('c1', '   ');
      expect(result, isNull);
      expect(await dao.getTagsForConnection('c1'), isEmpty);
    });

    test('removeTag deletes only the matching tag', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'staging');
      await dao.removeTag('c1', 'prod');
      expect(await dao.getTagsForConnection('c1'), ['staging']);
    });

    test('removeTag is case-insensitive (canonicalises input)', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.removeTag('c1', 'PROD');
      expect(await dao.getTagsForConnection('c1'), isEmpty);
    });
  });

  group('setTagsForConnection', () {
    test('replaces existing tags with the new set', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'us-east');

      await dao.setTagsForConnection('c1', ['us-west', 'staging']);
      expect(
        await dao.getTagsForConnection('c1'),
        ['staging', 'us-west'],
      );
    });

    test('empty list clears all tags', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.setTagsForConnection('c1', const []);
      expect(await dao.getTagsForConnection('c1'), isEmpty);
    });

    test('canonicalises and dedups within the same call', () async {
      await _insertStubConnection(db, 'c1');
      await dao.setTagsForConnection('c1', ['Prod', '  prod  ', 'PROD']);
      expect(await dao.getTagsForConnection('c1'), ['prod']);
    });
  });

  group('clearTagsForConnection', () {
    test('removes every tag for the given connection', () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await dao.addTag('c1', 'a');
      await dao.addTag('c1', 'b');
      await dao.addTag('c2', 'a');
      await dao.clearTagsForConnection('c1');
      expect(await dao.getTagsForConnection('c1'), isEmpty);
      expect(await dao.getTagsForConnection('c2'), ['a']);
    });
  });

  group('getAllTags / getConnectionIdsWithTag', () {
    test('returns distinct sorted vocabulary', () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'staging');
      await dao.addTag('c2', 'prod');
      await dao.addTag('c2', 'dev');
      expect(
        await dao.getAllTags(),
        ['dev', 'prod', 'staging'],
      );
    });

    test('connections with tag are scoped correctly', () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await _insertStubConnection(db, 'c3');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c2', 'prod');
      await dao.addTag('c3', 'dev');
      final hosts = (await dao.getConnectionIdsWithTag('PROD'))..sort();
      expect(hosts, ['c1', 'c2']);
    });

    test('unknown tag returns empty list', () async {
      expect(await dao.getConnectionIdsWithTag('nope'), isEmpty);
    });
  });

  group('renameTagGlobally', () {
    test('moves tag to new name everywhere', () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c2', 'prod');
      await dao.renameTagGlobally('prod', 'production');
      expect(await dao.getTagsForConnection('c1'), ['production']);
      expect(await dao.getTagsForConnection('c2'), ['production']);
    });

    test('merges into existing target tag without duplicating', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'production');
      await dao.renameTagGlobally('prod', 'production');
      expect(await dao.getTagsForConnection('c1'), ['production']);
    });

    test('no-op when canonical forms match', () async {
      await _insertStubConnection(db, 'c1');
      await dao.addTag('c1', 'prod');
      await dao.renameTagGlobally('prod', '  PROD  ');
      expect(await dao.getTagsForConnection('c1'), ['prod']);
    });
  });

  group('deleteTagGlobally', () {
    test('removes tag from every connection', () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await dao.addTag('c1', 'prod');
      await dao.addTag('c1', 'dev');
      await dao.addTag('c2', 'prod');
      await dao.deleteTagGlobally('prod');
      expect(await dao.getTagsForConnection('c1'), ['dev']);
      expect(await dao.getTagsForConnection('c2'), isEmpty);
    });
  });

  group('watchAllAssignments', () {
    test('emits a map keyed by connection id with sorted tag lists',
        () async {
      await _insertStubConnection(db, 'c1');
      await _insertStubConnection(db, 'c2');
      await dao.addTag('c1', 'b');
      await dao.addTag('c1', 'a');
      await dao.addTag('c2', 'z');

      final snapshot = await dao.watchAllAssignments().first;
      expect(snapshot, {
        'c1': ['a', 'b'],
        'c2': ['z'],
      });
    });
  });
}

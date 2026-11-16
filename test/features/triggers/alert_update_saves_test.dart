import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/trigger_providers.dart';

/// An edit of a saved alert is saved. The edit was written as an insert that
/// left the row's createdAt out, which the database refused, so every edit of
/// a saved alert failed ("This alert could not be saved", ZS-1906); the tests
/// of the alerts page use a stand-in for the database and never saw it.
void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('editing a saved alert keeps every field, and its created time', () async {
    final crud = TriggerCrud(db.terminalTriggersDao);
    final id = await crud.create(name: 'Disk', pattern: 'No space left', highlight: true, highlightColor: 0xFFFF7A1A);
    final before = (await db.terminalTriggersDao.getById(id))!;

    await crud.update(
      id: id,
      name: 'Disk full',
      pattern: 'No space left on device',
      caseSensitive: true,
      notify: false,
      highlight: true,
      highlightColor: null,
      playSound: true,
      connectionId: null,
      enabled: false,
    );

    final after = (await db.terminalTriggersDao.getById(id))!;
    expect(after.name, 'Disk full');
    expect(after.pattern, 'No space left on device');
    expect(after.caseSensitive, isTrue);
    expect(after.notify, isFalse);
    expect(after.highlightColor, isNull, reason: 'a cleared colour is saved as cleared');
    expect(after.playSound, isTrue);
    expect(after.enabled, isFalse);
    expect(after.createdAt, before.createdAt);
    expect(await db.terminalTriggersDao.getAll(), hasLength(1));
  });
}

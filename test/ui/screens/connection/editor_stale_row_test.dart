import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart' show keptFromSync;

/// The host editor's Save after a sync changed the host meanwhile (found in a
/// review): it wrote every field of the form, so another
/// device's change went back and, stamped as changed now, won everywhere.
/// A field the person did not touch now takes what is there now.
void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<Connection> row() async => (await db.select(db.connections).get()).single;

  test('a field changed elsewhere stays changed; a field the person changed is theirs', () async {
    final at = DateTime(2026, 11, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'db-primary', host: '192.0.2.10', createdAt: at, updatedAt: at));
    final loaded = await row();
    // Another device moves the port and renames it; the pull writes it here.
    await (db.update(db.connections)..where((c) => c.id.equals('h1'))).write(
        ConnectionsCompanion(port: const Value(2222), label: const Value('db-main'), updatedAt: Value(DateTime(2026, 11, 2))));
    final now = await row();
    final kept = keptFromSync(loaded, now);
    // The form still holds what the editor read for the port; the person
    // typed a new address.
    expect(kept(22, (c) => c.port), 2222);
    expect(kept('db-primary', (c) => c.label), 'db-main');
    expect(kept('192.0.2.99', (c) => c.host), '192.0.2.99');
    // A field cleared elsewhere stays cleared when the form still holds it.
    expect(kept<String?>(null, (c) => c.note), isNull);
  });

  test('with no change meanwhile, the form is written as it is', () async {
    final at = DateTime(2026, 11, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'db-primary', host: '192.0.2.10', createdAt: at, updatedAt: at));
    final loaded = await row();
    final kept = keptFromSync(loaded, await row());
    expect(kept(2200, (c) => c.port), 2200);
    expect(kept(22, (c) => c.port), 22);
    expect(keptFromSync(null, loaded)(2200, (c) => c.port), 2200);
  });
}

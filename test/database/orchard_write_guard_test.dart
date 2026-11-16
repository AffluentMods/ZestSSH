import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';

/// No write this account may not make reaches an Orchard's database (3.0):
/// a new item needs add in its Crate, a change to one on the
/// server needs edit, removing it needs delete. Columns that stay on the
/// device (pins, order) and changes the sync engine applies are not
/// checked, so nothing can be left on a device that its Crate would never
/// take.

const _open = '11111111-1111-4111-8111-111111111111'; // add, edit, no delete
const _view = '22222222-2222-4222-8222-222222222222'; // connect only
const _full = '33333333-3333-4333-8333-333333333333'; // everything

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await db.customStatement(
        'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
        "VALUES (1, '44444444-4444-4444-8444-444444444444', 'Acme', 'member-role', 1, ?)",
        [_open]);
    await db.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES '
        '''(?, 'Open', 'edit', '["add","connect","edit","reveal"]', 1), '''
        '''(?, 'View', 'connect', '["connect","forward","sftp"]', 1), '''
        '''(?, 'Full', 'manage', '["add","connect","delete","edit","manage","reveal"]', 1)''',
        [_open, _view, _full]);
  });

  tearDown(() => db.close());

  Future<void> host(String id) => db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: id,
        label: id,
        host: '10.0.0.1',
        port: const Value(22),
        createdAt: DateTime(2026, 9, 24),
        updatedAt: DateTime(2026, 9, 24),
      ));

  /// [id] as the sync engine leaves it: in [crate], and on the server.
  Future<void> fromServer(String id, String crate) async {
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await host(id);
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 7)",
        [id, crate]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  Matcher refused() => throwsA(predicate((e) => '$e'.contains('orchard-access')));

  test('a new item needs add in the Crate it goes to', () async {
    await host('h-new'); // the Crate new items go to allows add
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id) VALUES ('host', 'h-placed', ?)", [_view]);
    await expectLater(host('h-placed'), refused(), reason: 'placed in a Crate this account only connects to');
    expect((await db.select(db.connections).get()).map((c) => c.id), ['h-new']);
  });

  test('an item from the server changes only with edit, and goes only with delete', () async {
    await fromServer('h-view', _view);
    await fromServer('h-open', _open);
    await fromServer('h-full', _full);

    await expectLater(
        db.customStatement("UPDATE connections SET host = '10.6.6.6' WHERE id = 'h-view'"), refused());
    await expectLater(db.customStatement("DELETE FROM connections WHERE id = 'h-view'"), refused());
    // Its tags are part of it: adding one is a change too.
    await expectLater(
        db.customStatement(
            "INSERT INTO connection_tags (connection_id, tag) VALUES ('h-view', 'prod')"),
        refused());

    await db.customStatement("UPDATE connections SET host = '10.0.0.2' WHERE id = 'h-open'");
    await expectLater(db.customStatement("DELETE FROM connections WHERE id = 'h-open'"), refused(),
        reason: 'edit but no delete');
    await db.customStatement("DELETE FROM connections WHERE id = 'h-full'");

    final rows = {for (final c in await db.select(db.connections).get()) c.id: c.host};
    expect(rows, {'h-view': '10.0.0.1', 'h-open': '10.0.0.2'});
  });

  test('what stays on the device, and what the server sends, is not checked', () async {
    await fromServer('h-view', _view);
    // A pin, the order, when it was last used: on this device only.
    await db.customStatement("UPDATE connections SET pinned = 1, sort_order = 3 WHERE id = 'h-view'");
    await db.customStatement(
        "UPDATE connections SET last_connected = 1790000000 WHERE id = 'h-view'");
    // The sync engine writing a change from the server.
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.customStatement("UPDATE connections SET label = 'renamed' WHERE id = 'h-view'");
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    final c = (await db.select(db.connections).get()).single;
    expect((c.label, c.pinned), ('renamed', true));
    expect(await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle().then((r) => r.read<int>('n')), 0,
        reason: 'nothing of it goes back to the server');
  });

  test('a pinned host key needs edit, new or not, and delete to remove it', () async {
    const addOnly = '55555555-5555-4555-8555-555555555555';
    await db.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) '
        '''VALUES (?, 'Drop box', 'custom', '["add","connect"]', 1)''',
        [addOnly]);
    Future<void> pin(String id, String crate) async {
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id) VALUES ('hostkey', ?, ?)", [id, crate]);
      await db.customStatement(
          "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, 'web1', 22, '', '[]')", [id]);
    }

    await expectLater(pin('drop|22|', addOnly), refused(), reason: 'add is not enough to pin trust for everyone');
    await host('h-drop-ok'); // a host is: add is enough there
    await pin('open|22|', _open);
    await db.customStatement("UPDATE team_host_keys SET host_keys = '[\"ssh-ed25519 AAAA\"]' WHERE id = 'open|22|'");
    await expectLater(db.customStatement("DELETE FROM team_host_keys WHERE id = 'open|22|'"), refused(),
        reason: 'edit but no delete');
    await pin('full|22|', _full);
    await db.customStatement("DELETE FROM team_host_keys WHERE id = 'full|22|'");
    expect([for (final r in await db.customSelect('SELECT id FROM team_host_keys').get()) r.read<String>('id')],
        ['open|22|']);
    // Queued for its Crate like any item.
    expect(
        [for (final r in await db.customSelect("SELECT item_key FROM crate_outbox WHERE kind = 'hostkey'").get()) r.read<String>('item_key')]..sort(),
        ['full|22|', 'open|22|']);
  });

  test('an account that can add nowhere adds nothing', () async {
    await db.customStatement('UPDATE orchard_info SET default_crate_id = NULL WHERE id = 1');
    await expectLater(host('h-orphan'), refused());
  });
}

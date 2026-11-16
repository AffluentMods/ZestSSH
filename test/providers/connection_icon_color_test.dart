import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/models/host_icon_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/connection_providers.dart';

/// Saving what colours a host's icon (3.0): with a new host, with a change
/// that names it and only with such a change, and with a copy of a host,
/// which also takes the icon itself along.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const green = Color(0xFF22C55E);
  // A 1x1 PNG.
  const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

  late AppDatabase db;
  late ConnectionCrudNotifier crud;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crud = ConnectionCrudNotifier(db.connectionsDao, db.portForwardRulesDao, db.connectionTagsDao);
  });
  tearDown(() => db.close());

  Future<Connection> host(String id) async => (await db.connectionsDao.getById(id))!;

  test('a new host has its icon in its own colour unless it is made with another choice', () async {
    final plain = await crud.create(label: 'web-01', host: '192.168.10.21');
    expect((await host(plain)).iconColor, isNull);
    final follows = await crud.create(label: 'web-02', host: '192.168.10.22', iconColor: HostIconColor.followsLabel);
    expect((await host(follows)).iconColor, HostIconColor.followsLabel);
    final custom = await crud.create(label: 'db-primary', host: '192.168.10.31', iconColor: HostIconColor.custom(green));
    expect((await host(custom)).iconColor, 0xFF22C55E);
  });

  test('a change writes the choice only when it says so, and can put it back to the icon\'s own', () async {
    final id = await crud.create(label: 'web-01', host: '192.168.10.21', iconId: 'debian');

    await crud.update(id: id, iconColor: HostIconColor.custom(green), setIconColor: true);
    expect((await host(id)).iconColor, 0xFF22C55E);

    // Any other change leaves it, whatever it passes or does not pass.
    await crud.update(id: id, label: 'web-01b');
    await crud.update(id: id, iconColor: HostIconColor.followsLabel);
    await crud.update(id: id, iconId: 'ubuntu', setIcon: true);
    final after = await host(id);
    expect(after.label, 'web-01b');
    expect(after.iconId, 'ubuntu');
    expect(after.iconColor, 0xFF22C55E, reason: 'not named, not touched');

    await crud.update(id: id, iconColor: HostIconColor.followsLabel, setIconColor: true);
    expect((await host(id)).iconColor, HostIconColor.followsLabel);

    // Null is a choice (the icon's own colour), so it is written too.
    await crud.update(id: id, iconColor: null, setIconColor: true);
    final own = await host(id);
    expect(own.iconColor, isNull);
    expect(own.iconId, 'ubuntu', reason: 'the icon itself is another matter');
  });

  test('a copy of a host has its icon, its picture and its icon\'s colour', () async {
    final chosen = await crud.create(
        label: 'web-01', host: '192.168.10.21', iconId: 'debian', iconColor: HostIconColor.custom(green));
    final uploaded = await crud.create(
        label: 'mac-studio', host: '192.168.10.30', customIcon: png, iconColor: HostIconColor.followsLabel);
    final plain = await crud.create(label: 'cache-01', host: '192.168.10.41');

    final a = await host(await crud.duplicate(await host(chosen), label: 'web-01 (copy)'));
    expect([a.iconId, a.customIcon, a.iconColor], ['debian', null, 0xFF22C55E]);
    final b = await host(await crud.duplicate(await host(uploaded), label: 'mac-studio (copy)'));
    expect([b.iconId, b.customIcon, b.iconColor], [null, png, HostIconColor.followsLabel]);
    final c = await host(await crud.duplicate(await host(plain), label: 'cache-01 (copy)'));
    expect([c.iconId, c.customIcon, c.iconColor], [null, null, null]);
  });
}

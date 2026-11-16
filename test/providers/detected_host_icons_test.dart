import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/os_detection_providers.dart';

/// The system seen on a host was the device's own (a
/// phone that had not connected drew letters where the computer drew
/// Proxmox, OPNsense, Graylog). Now a host keeps its system's icon, which
/// syncs, where it has none of its own; a picked or uploaded icon is never
/// replaced, and a Linux whose kind was not told gives none.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('every host with no icon of its own keeps the one seen on it, and only those', () async {
    final plain = await crud.create(label: 'web-01', host: '192.168.10.21');
    final picked = await crud.create(label: 'db-primary', host: '192.168.10.31', iconId: 'debian');
    final uploaded = await crud.create(label: 'nas', host: '192.168.20.5', customIcon: png);
    final generic = await crud.create(label: 'box', host: '192.168.20.9');
    final unseen = await crud.create(label: 'web-02', host: '192.168.10.22');
    final before = (await host(plain)).updatedAt;

    final kept = await keepDetectedHostIcons(
      dao: db.connectionsDao,
      crud: crud,
      seen: {plain: OsKind.ubuntu, picked: OsKind.ubuntu, uploaded: OsKind.truenas, generic: OsKind.linux},
    );

    expect(kept, 1);
    final after = await host(plain);
    expect(after.iconId, 'ubuntu');
    expect(after.updatedAt.isBefore(before), isFalse, reason: 'a change, so it syncs');
    expect((await host(picked)).iconId, 'debian', reason: 'a picked icon stays');
    expect((await host(uploaded)).customIcon, png, reason: 'an uploaded icon stays');
    expect((await host(uploaded)).iconId, isNull);
    expect((await host(generic)).iconId, isNull, reason: 'no real icon for a Linux of no told kind');
    expect((await host(unseen)).iconId, isNull);

    // Again: nothing left to do.
    expect(await keepDetectedHostIcons(dao: db.connectionsDao, crud: crud, seen: {plain: OsKind.ubuntu}), 0);
  });

  test('a system just seen is kept on that host alone, and a host not here (a team\'s) is skipped', () async {
    final a = await crud.create(label: 'web-01', host: '192.168.10.21');
    final b = await crud.create(label: 'web-02', host: '192.168.10.22');
    final kept = await keepDetectedHostIcons(
      dao: db.connectionsDao,
      crud: crud,
      seen: {a: OsKind.debian, b: OsKind.alpine},
      onlyId: a,
    );
    expect(kept, 1);
    expect((await host(a)).iconId, 'debian');
    expect((await host(b)).iconId, isNull);
    expect(
      await keepDetectedHostIcons(dao: db.connectionsDao, crud: crud, seen: {'team-host': OsKind.debian}, onlyId: 'team-host'),
      0,
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Deleting a team against the REAL server routes on a real
/// Postgres: an owner deletes with the signed entry, every member's device
/// is held back and holds the signed deletion, an owner undoes it, deletes
/// it again, the day comes and the clean-up job purges it; then each device
/// removes it, or asks, by the rule the devices keep. The same on the
/// in-memory server: team_deletion_test.dart. Start the server first, with
/// new kinds of entry on:
///
///   NEW_TEAM_RECORD_KINDS=1 node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running, or runs with them off. ZESTSSH_TEST_API
/// overrides the base URL (default http://127.0.0.1:39200/v1); the server's
/// test routes (/test/teams/...) are beside /v1.

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Device {
  _Device(this.storage, this.service, this.coordinator, this.author);

  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
  final CrateAuthor author;
  final gone = <TeamGone>[];

  Future<AppDatabase> db(String orchardId) => coordinator.databases.open(orchardId);

  Future<String> status(String orchardId) async =>
      (await (await db(orchardId)).customSelect('SELECT status FROM orchard_info').getSingle()).read<String>('status');

  Future<bool> holds(String orchardId) async => (await coordinator.databases.onDevice()).contains(orchardId);
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid) => 'fb:$uid:${now()}:${now()}';

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'delete-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid)).publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  setUpAll(() async {
    try {
      final probe = await account('probe');
      final r = await client
          .get(Uri.parse('$base/orchards'), headers: {'Authorization': 'Bearer ${token(probe.uid)}'})
          .timeout(const Duration(seconds: 2));
      final pending = await client.post(Uri.parse('$root/test/teams/pending')).timeout(const Duration(seconds: 30));
      serverUp = r.statusCode == 200 && (jsonDecode(r.body) as Map)['new_record_kinds'] == true && pending.statusCode == 200;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  String skip() => 'app contract server with NEW_TEAM_RECORD_KINDS=1 (and /test/teams) not running at $base';

  _Device device(CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    late final _Device d;
    final service = OrchardService(server: server, databases: databases, author: () async => me, onTeamDeleted: (g) => d.gone.add(g));
    d = _Device(storage, service, OrchardSyncCoordinator(service: service, server: server, databases: databases), me);
    devices.add(d);
    return d;
  }

  Future<void> join(_Device by, _Device person, String orchardId) async {
    final role = (await by.service.roles(orchardId)).single.id;
    await by.service.invite(orchardId, email: '${person.author.uid}@example.com', role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
  }

  Future<Map<String, dynamic>> testRoute(String path) async {
    final r = await client.post(Uri.parse('$root$path'));
    expect(r.statusCode, 200, reason: r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  test('deleted, held back, undone, deleted again and purged: each device holds the signed deletion, and '
      'removes the team by its own rule', () async {
    if (!serverUp) return markTestSkipped(skip());
    final ownerId = await account('owner');
    final aliceId = await account('alice');
    final owner = device(ownerId);
    final alice = device(aliceId);
    final o = await owner.service.createOrchard('Going', firstCrateName: 'Production', memberRoleName: 'Member');
    await join(owner, alice, o);
    await owner.coordinator.syncAll();
    expect(await alice.coordinator.syncAll(), contains(o));

    // Asked: every member is held back, and holds the owner's signed entry.
    final asked = await owner.service.deleteTeam(o);
    expect(asked.by, ownerId.uid);
    expect(asked.purgeAt.difference(asked.askedAt), const Duration(days: kTeamDeleteDays));
    expect(await alice.coordinator.syncAll(), isEmpty);
    expect(await alice.status(o), kDeletingStatus);
    expect((await LocalRecord.load(await alice.db(o), o)).latest.deleting?.by, ownerId.uid);

    // Nothing else goes in meanwhile, here or there.
    await expectLater(owner.service.setMemberEndsAt(o, aliceId.uid, null), throwsA(isA<OrchardRecordRefused>()));

    // Undone before the day: everyone is let back in.
    await owner.service.restoreTeam(o);
    expect(await owner.status(o), 'active');
    expect(await alice.coordinator.syncAll(), contains(o));
    expect(await alice.status(o), 'active');

    // Asked again, and the day comes: too late to undo, then purged.
    await owner.service.deleteTeam(o);
    await alice.service.refresh();
    expect((await testRoute('/test/teams/$o/day-comes'))['found'], isTrue);
    await expectLater(
        owner.service.restoreTeam(o), throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'undo-too-late')));
    expect((await testRoute('/test/teams/purge'))['purged'], greaterThanOrEqualTo(1));

    // Alice saw the deletion only just now: her device asks.
    await alice.service.refresh();
    expect(await alice.holds(o), isTrue);
    expect(await alice.status(o), kDeletedStatus);
    await alice.service.removeDeletedTeam(o);
    expect(await alice.holds(o), isFalse);
    expect(alice.gone.single.name, 'Going');

    // The owner's device, eight days on by its own clock: removed unasked.
    OrchardService.debugNow = () => DateTime.now().add(const Duration(days: 8));
    await owner.service.refresh();
    expect(await owner.holds(o), isFalse);
    expect(owner.gone.single.byMe, isTrue);

    // The id is taken for good, and the record's fingerprints answer for it.
    final local = await owner.service.server.recordHolds(o, 1, Uint8List(32));
    expect(local.holds, isFalse, reason: 'only to a device that shows it held the entry');
  });
}

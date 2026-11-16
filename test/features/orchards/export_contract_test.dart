import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Event export (3.0) against the REAL server routes on a real
/// Postgres: an owner's export.set goes into the record the server checks
/// (with a recent sign-in, on and off), an invitation says that the Orchard
/// sends its events on, and the owner's device reads the activity forward
/// from the last note it has and sends each event once. The server sends
/// nothing itself and never sees where the events go. Start the server:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running.

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

class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Device {
  final storage = _MemoryStorage();
  final keychain = _Keychain();

  /// How long ago this device's sign-in was, in seconds.
  var signedInAgo = 0;
  late final OrchardsApi server;
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;
  late final OrchardEventExporter exporter;

  /// The events its receiver took, in order.
  final taken = <Map<String, dynamic>>[];
  var requests = 0;
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid, {int ago = 0}) => 'fb:$uid:${now() - ago}:${now()}';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'export-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(CrateAuthor me) {
    final d = _Device();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: d.storage);
    d.server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid, ago: d.signedInAgo));
    d.service = OrchardService(server: d.server, databases: databases, author: () async => me);
    d.coordinator = OrchardSyncCoordinator(service: d.service, server: d.server, databases: databases);
    d.exporter = OrchardEventExporter(
      service: () => d.service,
      settings: ExportSettingsStore(d.keychain),
      post: (to, body) async {
        d.requests++;
        d.taken.addAll([
          for (final line in body.split('\n'))
            if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
        ]);
        return const ExportDelivery.delivered(204);
      },
    );
    devices.add(d);
    return d;
  }

  test('event export through the real routes: the record takes it, an invitation says so, and the activity '
      'read forward goes out once', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final dave = await account('dave');
    final o = device(owner);
    final id = await o.service.createOrchard('Exporting', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await o.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final role = (await o.service.roles(id)).single.id;
    await o.service.invite(id, email: '${alice.uid}@example.com', role: role);
    final a = device(alice);
    await a.service.acceptInvite((await a.service.myInvites()).single.id);
    await o.service.confirmInvite(id, (await o.service.invites(id)).single);
    await a.coordinator.syncAll();
    await o.service.invite(id, email: '${dave.uid}@example.com', role: role);
    final d = device(dave);
    final to = ExportDestination.of('https://logs.example.com/in', ExportFormat.lines,
        headerName: 'Authorization', headerValue: 'Splunk token-1')!;
    Matcher answered(int status, String code) => throwsA(isA<OrchardServerException>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.code, 'code', code));

    // Not before activity is recorded: the server hands no activity over.
    expect((await d.service.myInvites()).single.exported, isFalse);
    final key = await o.exporter.newKey();
    await expectLater(o.exporter.setUp(id, to, key), answered(409, 'activity-off'));
    await o.service.setTracking(id, const RecordTracking(activity: true));
    await a.service.refresh();
    expect((await d.service.myInvites()).single.exported, isFalse, reason: 'recording is not sending on');

    // A member did something before it is set up: not sent on.
    await a.service.recordActivity(id, ActivityKind.reveal, crateId: crate, itemKind: 'key', itemKey: 'k-0', name: 'before');
    expect(await a.service.activityRound(id), 1);

    // A sign-in that is not recent: the server asks for one, and nothing is
    // kept or sent.
    o.signedInAgo = 3 * 3600;
    await expectLater(
      o.exporter.setUp(id, to, key),
      throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in', isTrue)),
    );
    expect(o.keychain.values, isEmpty);
    expect(o.requests, 0);
    o.signedInAgo = 0;

    // Set up: the record on the server has the key and nothing else of it.
    await o.exporter.setUp(id, to, key);
    final entries = (await o.server.record(id, after: 0)).entries;
    expect(entries.last.type, RecordTypes.exportSet);
    expect(entries.last.body, {'on': true, 'key': key.key});
    expect([for (final e in entries) e.bodyJson].join().contains('logs.example.com'), isFalse);
    expect((await d.service.myInvites()).single.exported, isTrue);
    // The first event is the entry itself, signed with that key.
    expect(o.taken.single['id'], 'record-${entries.last.seq}');
    expect(await verifyExportEvent(o.taken.single, key: key.publicKey), isTrue);
    // Every member's device reads in the record that it is on, and whose.
    await a.service.refresh();
    final hers = await a.exporter.standing(id);
    expect((hers.on, hers.isOwner, hers.record!.by, hers.sendsHere), (true, false, owner.uid, false));

    // What members do from now on goes out, once, in the order it came.
    await a.service.recordActivity(id, ActivityKind.reveal, crateId: crate, itemKind: 'key', itemKey: 'k-1', name: 'deploy key');
    await a.service.recordActivity(id, ActivityKind.connect, crateId: crate, itemKind: 'connection', itemKey: 'c-1', name: 'web-01');
    expect(await a.service.activityRound(id), 2);
    await o.exporter.round(id);
    expect([for (final e in o.taken.skip(1)) e['message']], [
      '${alice.uid}@example.com opened the secrets of deploy key',
      '${alice.uid}@example.com connected to web-01',
    ]);
    expect([for (final e in o.taken.skip(1)) (e['type'], e['crate']['name'])],
        [('activity', 'Production'), ('activity', 'Production')]);
    for (final e in o.taken) {
      expect(await verifyExportEvent(e, key: key.publicKey), isTrue, reason: '${e['id']}');
    }
    final sent = o.requests;
    await o.exporter.round(id);
    expect(o.requests, sent, reason: 'nothing new, nothing sent');
    await a.service.recordActivity(id, ActivityKind.copy, crateId: crate, itemKind: 'key', itemKey: 'k-1', name: 'deploy key');
    expect(await a.service.activityRound(id), 1);
    await o.exporter.round(id);
    expect(o.taken, hasLength(4));
    expect(o.taken.last['message'], '${alice.uid}@example.com copied a secret of deploy key');
    // The route itself: forward from just after a note, oldest first; not
    // both ways at once; owners only.
    final all = await o.server.activity(id, after: 0);
    expect(all.events, hasLength(4));
    expect([for (final e in all.events) e.id], [for (final e in all.events) e.id]..sort());
    expect((await o.server.activity(id, after: all.events[2].id)).events.single.id, all.events[3].id);
    expect((await o.server.activity(id)).events.first.id, all.events.last.id, reason: 'newest first the other way');
    await expectLater(a.server.activity(id, after: 0), answered(403, 'owners-only'));
    final both = await client.get(Uri.parse('$base/orchards/$id/activity?after=1&before=9'),
        headers: {'Authorization': 'Bearer ${token(owner.uid)}'});
    expect(both.statusCode, 400);

    // Turning it off needs a recent sign-in as well; then the last event
    // says so, the device keeps nothing, and an invitation says it is off.
    o.signedInAgo = 3 * 3600;
    await expectLater(
      o.exporter.turnOff(id),
      throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in', isTrue)),
    );
    expect((await d.service.myInvites()).single.exported, isTrue);
    o.signedInAgo = 0;
    await o.exporter.turnOff(id);
    expect((o.taken.last['action'], o.taken.last['change']), ('export.set', 'export_off'));
    expect(o.keychain.values, isEmpty);
    expect((await d.service.myInvites()).single.exported, isFalse);
    expect((await o.exporter.standing(id)).on, isFalse);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show sealActivity;
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/local_state_store.dart';

import '../fake_crate_server.dart';

/// Event export (3.0) on the device that sends: an owner sets it
/// up, the record takes the key and this device keeps the rest, and from
/// then on every entry of the record and everything members do goes out
/// once, in order, signed, to the address the owner gave. What is not taken
/// waits and goes with the next round. It ends with the entry that ends it,
/// and the device then forgets the key and the address: before a change it
/// makes itself it says what it had left, and where another device took
/// over it says what members did until then. It does not stop on its own,
/// and it does not say everything again when its copy of the Orchard went
/// and came back. The (fake) server holds the record's rules and hands
/// activity to owners only, as ZestSSH Cloud does; it never sees an address.

const _owner = 'owner-1';
const _owner2 = 'owner-2';
const _alice = 'alice';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  /// How often the databases on the device were listed.
  var lists = 0;

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async {
    lists++;
    return dbs.keys.toList();
  }
}

/// One device's secure storage, which counts how often it is read and
/// written.
class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};
  var reads = 0;
  var writes = 0;

  /// Nothing can be written just now.
  var failWrites = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        reads++;
        return Future<String?>.value(values[key]);
      case #write:
        if (failWrites) return Future<void>.error(StateError('The storage takes nothing'));
        writes++;
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// The system that receives the events: every request it got, and what it
/// answers the next ones with.
class _Receiver {
  final requests = <({ExportDestination to, String body})>[];

  /// What it answers a request with (by its number, from 0); taken when
  /// null.
  ExportDelivery? Function(int request)? answer;

  /// Every event it took, in the order they came, read as its format lays
  /// them out.
  final taken = <Map<String, dynamic>>[];

  /// While set, a request waits for it before it is answered.
  Completer<void>? hold;

  Future<ExportDelivery> post(ExportDestination to, String body) async {
    final n = requests.length;
    requests.add((to: to, body: body));
    await hold?.future;
    final refused = answer?.call(n);
    if (refused != null) return refused;
    taken.addAll(eventsOf(to.format, body));
    return const ExportDelivery.delivered(200);
  }

  static List<Map<String, dynamic>> eventsOf(ExportFormat format, String body) => switch (format) {
        ExportFormat.array => [for (final e in jsonDecode(body) as List) e as Map<String, dynamic>],
        ExportFormat.lines => [
            for (final line in body.split('\n'))
              if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
          ],
      };

  List<String> get ids => [for (final e in taken) e['id'] as String];
}

class _Device {
  _Device(this.shared, this.uid, this.keys, this.name, this.receiver, {_Device? restartOf, DateTime Function()? now})
      : keychain = restartOf?.keychain ?? _Keychain(),
        storage = restartOf?.storage ?? _MemoryStorage() {
    server = shared.as(uid, signIn: () => name);
    service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => keysReady ? CrateAuthor(uid: uid, keys: keys) : null,
      deviceKeys: DeviceIdentityStore(keychain),
      // As the app wires it: before a change made here ends the sending,
      // the device says what it has left.
      flushEvents: (orchardId) async {
        if (failFlush) throw StateError('Nothing can be sent just now');
        await exporter.flush(orchardId);
      },
    );
    exporter = OrchardEventExporter(
      service: () => service,
      settings: ExportSettingsStore(keychain),
      post: receiver.post,
      onChanged: () => changes++,
      now: now,
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;
  final String name;
  final _Receiver receiver;
  late final CrateServer server;
  final _Keychain keychain;
  final _MemoryStorage storage;
  late final OrchardService service;
  late final OrchardEventExporter exporter;

  /// How often the exporter said that where it stands may have changed.
  var changes = 0;

  /// The account's keys are on the device (false: signed out, or not yet).
  var keysReady = true;

  /// Asking for what is left to send fails.
  var failFlush = false;

  /// The entry of its secure storage that notes how far it got.
  String noteKey(String orchardId) => 'orchard_export_v1.$uid.$orchardId.sent';

  Future<AppDatabase> db(String orchardId) => service.databases.open(orchardId);

  /// What this device keeps in its secure storage for event export.
  Map<String, String> get kept => {
        for (final e in keychain.values.entries)
          if (e.key.startsWith('orchard_export_v1')) e.key: e.value,
      };

  Future<Object?> state(String orchardId, String key) async {
    final raw = await LocalStateStore(await db(orchardId)).read(key);
    return raw == null ? null : jsonDecode(raw);
  }

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

const _activity = RecordTracking(activity: true);

/// Lets everything else run until [done].
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 5000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late _Receiver receiver;
  final devices = <_Device>[];
  final to = ExportDestination.of('https://logs.example.com/in', ExportFormat.lines,
      headerName: 'Authorization', headerValue: 'Splunk token-1')!;

  setUpAll(() async {
    for (final uid in [_owner, _owner2, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    receiver = _Receiver();
    for (final uid in [_owner, _owner2, _alice]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid, String name, {_Device? restartOf, _Receiver? into, DateTime Function()? now}) {
    final d = _Device(server, uid, keys[uid]!, name, into ?? receiver, restartOf: restartOf, now: now);
    if (restartOf == null) devices.add(d);
    return d;
  }

  Future<void> join(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final invite = (await by.service.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, person.uid);
    await by.service.confirmInvite(orchardId, (await by.service.invites(orchardId)).single);
    await person.service.refresh();
  }

  /// An Orchard of the owner's laptop with alice in it as a member, which
  /// records activity.
  Future<({String id, String crate, String member, _Device laptop, _Device alice})> recording() async {
    final laptop = device(_owner, 'laptop');
    final id = await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = server.recordOf(id).roles.values.single;
    final alice = device(_alice, 'alice-laptop');
    await join(laptop, alice, id, role.id);
    await laptop.service.setTracking(id, _activity);
    await alice.service.refresh();
    return (id: id, crate: role.crates.keys.single, member: role.id, laptop: laptop, alice: alice);
  }

  /// [who] does [kind] with an item, and its device sends the note.
  Future<void> does(_Device who, String orchardId, ActivityKind kind, String crate, String name) async {
    await who.service.recordActivity(orchardId, kind, crateId: crate, itemKind: 'key', itemKey: 'k-$name', name: name);
    expect(await who.service.activityRound(orchardId), 1);
  }

  /// A note of activity nobody can read, as the server keeps it.
  void garbage(String orchardId, String uid) =>
      server.plantActivity(orchardId, uid, Uint8List.fromList(List.filled(40, 3)), at: DateTime.utc(2026, 10, 2, 9));

  test('set up: the record takes the key, this device keeps the rest, and the entry that turned it on is the '
      'first event; nothing from before goes', () async {
    final o = await recording();
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'before');
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'before');
    var standing = await o.laptop.exporter.standing(o.id);
    expect((standing.isOwner, standing.activityOn, standing.on, standing.sendsHere), (true, true, false, false));
    expect(standing.destination, isNull);
    expect(o.laptop.kept, isEmpty);
    expect(o.laptop.changes, 0);

    final key = await o.laptop.exporter.newKey();
    final before = server.entriesOf(o.id).length;
    await o.laptop.exporter.setUp(o.id, to, key);

    // The record: one entry more, with the key and nothing else.
    final entry = server.entriesOf(o.id).last;
    expect(server.entriesOf(o.id), hasLength(before + 1));
    expect((entry.type, entry.by), (RecordTypes.exportSet, _owner));
    expect(entry.body, {'on': true, 'key': key.key});
    expect(server.recordOf(o.id).eventExport!.keyText, key.key);
    expect(server.recordOf(o.id).eventExport!.by, _owner);
    // Nothing of the address reaches the server.
    final everything = [for (final e in server.entriesOf(o.id)) e.bodyJson].join();
    expect(everything.contains('logs.example.com'), isFalse);
    expect(everything.contains('token-1'), isFalse);

    // This device: the private half, the address and where activity starts,
    // and beside them a note of how far it got.
    expect(o.laptop.kept.keys.toSet(), {
      'orchard_export_v1.$_owner',
      'orchard_export_v1.$_owner.${o.id}',
      'orchard_export_v1.$_owner.${o.id}.sent',
    });
    final kept = jsonDecode(o.laptop.kept['orchard_export_v1.$_owner.${o.id}']!) as Map;
    expect(kept['seed'], base64Encode(key.seed));
    expect(kept['to'], to.toJson());
    expect(kept['activity_from'], server.activityRows[o.id]!.last.id);

    // The first round went at once: one request, to that address, with the
    // entry itself as its only event.
    expect(receiver.requests, hasLength(1));
    expect(receiver.requests.single.to.url.toString(), 'https://logs.example.com/in');
    expect(receiver.requests.single.to.headers['Authorization'], 'Splunk token-1');
    expect(receiver.requests.single.body.endsWith('\n'), isTrue);
    final event = receiver.taken.single;
    expect(event['id'], 'record-${entry.seq}');
    expect((event['type'], event['action'], event['change']), ('record', 'export.set', 'export_on'));
    expect(event['actor'], {'uid': _owner, 'email': 'owner-1@example.com'});
    expect(event['orchard'], {'id': o.id, 'name': 'Acme'});
    expect(event['message'], 'owner-1@example.com: Turned event export on');
    expect(event['time_source'], 'seen');
    expect((event['record'] as Map)['seq'], entry.seq);
    expect((event['record'] as Map)['hash'], [for (final b in entry.hash(o.id)) b.toRadixString(16).padLeft(2, '0')].join());
    expect(event['key'], key.key);
    expect(await verifyExportEvent(event, key: key.publicKey), isTrue);
    expect(await verifyExportEvent(event, key: server.recordOf(o.id).eventExport!.key), isTrue,
        reason: 'the key the record names is the one to check with');

    standing = await o.laptop.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.record!.by), (true, true, _owner));
    expect(standing.record!.keyText, key.key);
    expect(standing.destination!.toJson(), to.toJson());
    expect((standing.status.sent, standing.status.failure), (1, null));
    expect(standing.status.sentAt, isNotNull);
    expect(o.laptop.changes, greaterThan(0));
    expect((await o.laptop.exporter.keyHere(o.id))!.key, key.key);
    final far = {'key': key.key, 'record': entry.seq, 'activity': server.activityRows[o.id]!.last.id};
    expect(await o.laptop.state(o.id, OrchardEventExporter.sentKey), far);
    expect(jsonDecode(o.laptop.kept[o.laptop.noteKey(o.id)]!), far);

    // A member sees that it is on, and who set it up; nothing more.
    await o.alice.service.refresh();
    final hers = await o.alice.exporter.standing(o.id);
    expect((hers.isOwner, hers.on, hers.sendsHere, hers.record!.by), (false, true, false, _owner));
    expect(hers.destination, isNull);
    expect(await o.alice.exporter.keyHere(o.id), isNull);
  });

  test('what happens after goes out once, in order, signed: the entries of the record, then what members do',
      () async {
    var clock = DateTime.utc(2026, 10, 2, 12);
    final o = await recording();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, now: () => clock);
    final key = await laptop.exporter.newKey();
    await laptop.exporter.setUp(o.id, to, key);
    receiver.taken.clear();
    receiver.requests.clear();
    final idle = (laptop.changes, laptop.keychain.writes);
    await laptop.exporter.round(o.id);
    expect(receiver.requests, isEmpty, reason: 'nothing new, nothing sent');
    expect((laptop.changes, laptop.keychain.writes), idle, reason: 'and nothing to tell a page, or to note');

    // The team changes, and its members do things.
    final auditors = await laptop.service.saveRole(o.id, name: 'Auditors', can: {}, crates: {});
    final vault = await laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await laptop.service.suspendMember(o.id, _alice);
    // (An entry this device kept before it noted when it first saw one.)
    await (await laptop.db(o.id)).customStatement(
        'UPDATE orchard_record_entries SET first_seen = NULL WHERE seq = (SELECT MAX(seq) FROM orchard_record_entries)');
    await laptop.service.resumeMember(o.id, _alice);
    await o.alice.service.refresh();
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'deploy key');
    await does(o.alice, o.id, ActivityKind.connect, o.crate, 'web-01');
    garbage(o.id, _alice);
    await laptop.service.recordActivity(o.id, ActivityKind.export, crateId: vault, itemKind: 'identity', itemKey: 'i-1');
    await laptop.service.activityRound(o.id);

    clock = DateTime.utc(2026, 10, 2, 12, 5);
    server.activityReads.clear();
    final storage = (laptop.keychain.reads, laptop.keychain.writes);
    await laptop.exporter.round(o.id);
    expect(receiver.requests, hasLength(2), reason: 'the record, then the activity');
    expect(server.activityReads, hasLength(1), reason: 'a page that says it is the last is the last one asked for');
    expect((laptop.keychain.reads, laptop.keychain.writes), (storage.$1, storage.$2 + 1),
        reason: 'how far it got is noted once a round, and the system\'s storage is asked nothing');
    final entries = server.entriesOf(o.id);
    final rows = server.activityRows[o.id]!;
    expect(receiver.ids, [
      for (final e in entries.skip(entries.length - 4)) 'record-${e.seq}',
      for (final r in rows.skip(rows.length - 4)) 'activity-${r.id}',
    ]);
    for (final e in receiver.taken) {
      expect(await verifyExportEvent(e, key: key.publicKey), isTrue, reason: '${e['id']}');
      expect((e['v'], e['source']), (1, 'zestssh'));
      expect(e['orchard'], {'id': o.id, 'name': 'Acme'});
    }
    final [role, added, suspended, resumed, revealed, connected, unreadable, exported] = receiver.taken;
    // A role the owners made goes out by the name they gave it.
    expect((role['action'], role['change'], role['message']),
        ('role.set', 'role_added', 'owner-1@example.com: Added the role Auditors'));
    expect(role['role'], {'id': auditors, 'name': 'Auditors'});
    expect((added['action'], added['change'], added['message']),
        ('crate.add', 'crate_added', 'owner-1@example.com: Added the vault Vault'));
    expect(added['crate'], {'id': vault, 'name': 'Vault'});
    expect((suspended['action'], suspended['change'], suspended['message']),
        ('member.suspend', 'member_suspended', 'owner-1@example.com: Suspended alice@example.com'));
    expect(suspended['target'], {'uid': _alice, 'email': 'alice@example.com'});
    // Without a time of its own it goes out with the time of sending, and
    // says so; the others with when this device first saw them.
    expect((suspended['time_source'], suspended['time']), ('sent', '2026-10-02T12:05:00.000Z'));
    expect((added['time_source'], resumed['time_source']), ('seen', 'seen'));
    expect(DateTime.parse(added['time'] as String).difference(DateTime.now()).inMinutes.abs(), lessThan(5));
    expect((resumed['action'], resumed['message']), ('member.resume', 'owner-1@example.com: Resumed alice@example.com'));
    expect((revealed['type'], revealed['action'], revealed['time_source']), ('activity', 'reveal', 'device'));
    expect(revealed['actor'], {'uid': _alice, 'email': 'alice@example.com'});
    expect(revealed['message'], 'alice@example.com opened the secrets of deploy key');
    expect(revealed['crate'], {'id': o.crate, 'name': 'Production'});
    expect(revealed['item'], {'kind': 'key', 'id': 'k-deploy key', 'name': 'deploy key'});
    expect(DateTime.parse(revealed['time'] as String).isBefore(DateTime.now().add(const Duration(minutes: 1))), isTrue);
    expect(revealed['received'], exportTime(rows[rows.length - 4].at));
    expect((connected['action'], connected['message']), ('connect', 'alice@example.com connected to web-01'));
    // A note that does not open goes out as what it is.
    expect((unreadable['action'], unreadable['time_source']), ('unreadable', 'received'));
    expect(unreadable['actor'], {'uid': _alice, 'email': 'alice@example.com'});
    expect(unreadable['message'], 'A note of activity from alice@example.com could not be read.');
    expect(unreadable['time'], '2026-10-02T09:00:00.000Z');
    expect(unreadable.containsKey('item'), isFalse);
    // An item without a name is said to have none.
    expect((exported['action'], exported['message']), ('export', 'owner-1@example.com exported An unnamed item'));
    expect(exported['item'], {'kind': 'identity', 'id': 'i-1'});
    expect(exported['crate'], {'id': vault, 'name': 'Vault'});

    // How far it got, and how it went.
    expect(await laptop.state(o.id, OrchardEventExporter.sentKey),
        {'key': key.key, 'record': entries.last.seq, 'activity': rows.last.id});
    final status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.sentAt, status.failure), (9, clock.millisecondsSinceEpoch ~/ 1000, null));

    // Nothing twice: not by the next round, not by rounds asked for at
    // once, nor after the app was started again.
    receiver.requests.clear();
    await laptop.exporter.round(o.id);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'at once');
    await Future.wait([laptop.exporter.round(o.id), laptop.exporter.round(o.id), laptop.exporter.rounds()]);
    expect(receiver.requests, hasLength(1));
    expect(receiver.ids.toSet(), hasLength(receiver.ids.length));
    receiver.requests.clear();
    final again = device(_owner, 'laptop', restartOf: laptop);
    await again.exporter.rounds();
    expect(receiver.requests, isEmpty);
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'db password');
    await again.exporter.rounds();
    expect(receiver.requests, hasLength(1));
    expect(receiver.taken.last['message'], 'alice@example.com copied a secret of db password');
    expect((await again.exporter.standing(o.id)).status.sent, 11);

    // A round asked for while one runs is that one. What is to go now, for
    // sure, is asked for as a round that starts after it.
    receiver.hold = Completer<void>();
    receiver.taken.clear();
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'first');
    final running = again.exporter.round(o.id);
    await _until(() => receiver.requests.length == 2);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'second');
    expect(identical(again.exporter.round(o.id), running), isTrue);
    final after = again.exporter.flush(o.id);
    receiver.hold!.complete();
    receiver.hold = null;
    await after;
    expect([for (final e in receiver.taken) (e['item'] as Map)['name']], ['first', 'second']);
    expect(receiver.requests, hasLength(3));

    // How far it got is kept twice: in the Orchard's database after every
    // request, and beside the key after every round, where it outlives the
    // database. What is not what this device wrote for this key counts for
    // nothing, and of the two the further one counts.
    final store = LocalStateStore(await again.db(o.id));
    final noteKey = again.noteKey(o.id);
    final far = again.keychain.values[noteKey]!;
    expect(jsonDecode(far), await again.state(o.id, OrchardEventExporter.sentKey));
    final on = entries.firstWhere((e) => e.type == RecordTypes.exportSet).seq;
    final last = server.entriesOf(o.id).last.seq;
    final newest = server.activityRows[o.id]!.last.id;
    // (A round after a start of the app, which reads afresh what is kept.)
    Future<void> fresh() => device(_owner, 'laptop', restartOf: again).exporter.round(o.id);
    for (final planted in [
      'not what it wrote',
      '[1]',
      jsonEncode({'key': 'another key', 'record': 9999, 'activity': 9999}),
      jsonEncode({'key': key.key, 'record': '9999', 'activity': 9999}),
      jsonEncode({'key': key.key, 'record': 9999}),
    ]) {
      // The database's is not this device's: the note holds.
      await store.write(OrchardEventExporter.sentKey, planted);
      receiver.requests.clear();
      await fresh();
      expect(receiver.requests, isEmpty, reason: planted);
      // The note is not: the database's holds, and the note is made again.
      await store.write(OrchardEventExporter.sentKey, far);
      again.keychain.values[noteKey] = planted;
      await fresh();
      expect(receiver.requests, isEmpty, reason: planted);
      expect(again.keychain.values[noteKey], far, reason: planted);
      // Neither: from the entry that turned it on, so that nothing is left
      // out (an event may come twice, never not at all).
      await store.write(OrchardEventExporter.sentKey, planted);
      again.keychain.values[noteKey] = planted;
      receiver.taken.clear();
      await fresh();
      expect(receiver.ids.first, 'record-$on', reason: planted);
      expect(receiver.ids.last, 'activity-$newest', reason: planted);
      expect(again.keychain.values[noteKey], far, reason: planted);
    }
    // Each is behind in one thing: the further one counts for each.
    for (final (inDatabase, noted) in [
      ({'record': last, 'activity': 0}, {'record': 0, 'activity': newest}),
      ({'record': 0, 'activity': newest}, {'record': last, 'activity': 0}),
    ]) {
      await store.write(OrchardEventExporter.sentKey, jsonEncode({'key': key.key, ...inDatabase}));
      again.keychain.values[noteKey] = jsonEncode({'key': key.key, ...noted});
      receiver.requests.clear();
      await fresh();
      expect(receiver.requests, isEmpty, reason: '$inDatabase $noted');
      expect(again.keychain.values[noteKey], far);
    }
    // The note cannot be written: nothing is lost, the database's holds.
    await store.write(OrchardEventExporter.sentKey, far);
    again.keychain.values.remove(noteKey);
    again.keychain.failWrites = true;
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'not noted');
    receiver.taken.clear();
    final unnoted = device(_owner, 'laptop', restartOf: again);
    await unnoted.exporter.round(o.id);
    await unnoted.exporter.round(o.id);
    expect(receiver.ids, ['activity-${server.activityRows[o.id]!.last.id}']);
    expect(unnoted.changes, 1, reason: 'its pages hear that it went all the same');
    again.keychain.failWrites = false;
    await unnoted.exporter.round(o.id);
    expect(jsonDecode(again.keychain.values[noteKey]!), await again.state(o.id, OrchardEventExporter.sentKey));
  });

  test('a session that ran with nobody watching goes out with what the sending device reads of its report: when, '
      'and where it holds the key of the Crate, the host, the reason and how the service stood', () async {
    final o = await recording();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop);
    final key = await laptop.exporter.newKey();
    await laptop.exporter.setUp(o.id, to, key);
    await laptop.exporter.round(o.id);
    receiver.taken.clear();

    // alice reports one, and her device's own sync is what sends it.
    o.alice.service.unwatchedRan(await o.alice.service.keepUnwatchedReport(o.id,
        crateId: o.crate, hostLabel: 'db-primary', reason: 'restoring the database', reach: 'fault 503'));
    expect(await o.alice.service.unwatchedRound(o.id), 1);
    await laptop.service.refresh();
    await laptop.exporter.round(o.id);
    final entry = server.entriesOf(o.id).last;
    final at = (jsonDecode(entry.bodyJson) as Map)['at'] as int;
    final event = receiver.taken.single;
    expect((event['id'], event['type'], event['action'], event['change']),
        ('record-${entry.seq}', 'record', 'session.unwatched', 'session_unwatched'));
    expect(event['actor'], {'uid': _alice, 'email': 'alice@example.com'});
    expect(event['crate'], {'id': o.crate, 'name': 'Production'});
    expect(event['message'], 'alice@example.com: Connected to a host in Production with nobody watching');
    expect(event['session'], {
      'at': exportTime(DateTime.fromMillisecondsSinceEpoch(at * 1000)),
      'host': 'db-primary',
      'reason': 'restoring the database',
      'service': 'fault 503',
    });
    expect(await verifyExportEvent(event, key: key.publicKey), isTrue);

    // One this device cannot open (sealed with nothing it holds): when, and
    // nothing made up for the rest.
    await o.alice.service.change(o.id, RecordTypes.sessionUnwatched,
        {'crate': o.crate, 'at': 1790000000, 'gen': 1, 'sealed': base64Encode(List<int>.filled(60, 9))});
    await laptop.service.refresh();
    receiver.taken.clear();
    await laptop.exporter.round(o.id);
    expect(receiver.taken.single['session'], {'at': '2026-09-21T14:13:20.000Z'});
    expect(receiver.taken.single['change'], 'session_unwatched');

    // Every other entry goes out with nothing of the kind.
    await laptop.service.setCrateUnwatchedAway(o.id, o.crate, true);
    receiver.taken.clear();
    await laptop.exporter.round(o.id);
    expect(receiver.taken.single['change'], 'unwatched_away_on');
    expect(receiver.taken.single.containsKey('session'), isFalse);
    expect(receiver.taken.single['message'],
        'owner-1@example.com: Let everyone connect to Production while ZestSSH Cloud cannot be reached');
  });

  test('a request that is not taken: nothing is skipped, it is said why, and the next round sends it again',
      () async {
    var clock = DateTime.utc(2026, 10, 2, 12);
    final o = await recording();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, now: () => clock);
    final key = await laptop.exporter.newKey();
    receiver.answer = (_) => const ExportDelivery.failed(ExportFailure.refused, status: 503);
    await laptop.exporter.setUp(o.id, to, key);
    final seq = server.entriesOf(o.id).last.seq;
    expect(receiver.taken, isEmpty);
    var status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.sentAt, status.failure, status.failedStatus, status.failedAt),
        (0, null, ExportFailure.refused, 503, clock.millisecondsSinceEpoch ~/ 1000));
    expect(await laptop.state(o.id, OrchardEventExporter.sentKey), isNull, reason: 'it got nowhere');

    // More happens meanwhile; the next try fails another way.
    await laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'deploy key');
    clock = DateTime.utc(2026, 10, 2, 12, 1);
    receiver.answer = (_) => const ExportDelivery.failed(ExportFailure.timeout);
    await laptop.exporter.round(o.id);
    status = (await laptop.exporter.standing(o.id)).status;
    expect((status.failure, status.failedStatus, status.failedAt),
        (ExportFailure.timeout, null, clock.millisecondsSinceEpoch ~/ 1000));
    expect(receiver.requests, hasLength(2), reason: 'one try a round: the activity waits behind the record');

    // It works again: everything, in order, from the entry that turned it on.
    receiver.answer = null;
    clock = DateTime.utc(2026, 10, 2, 12, 2);
    await laptop.exporter.round(o.id);
    expect(receiver.ids, ['record-$seq', 'record-${seq + 1}', 'activity-${server.activityRows[o.id]!.last.id}']);
    status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.sentAt, status.failure, status.failedStatus, status.failedAt),
        (3, clock.millisecondsSinceEpoch ~/ 1000, null, null, null));

    // A hundred to a request, and a request that fails keeps what the ones
    // before it delivered.
    for (var i = 0; i < 230; i++) {
      garbage(o.id, _alice);
    }
    receiver.requests.clear();
    receiver.taken.clear();
    receiver.answer = (n) => n == 1 ? const ExportDelivery.failed(ExportFailure.unreachable) : null;
    await laptop.exporter.round(o.id);
    expect([for (final r in receiver.requests) _Receiver.eventsOf(r.to.format, r.body).length], [100, 100]);
    expect(receiver.taken, hasLength(100));
    final rows = server.activityRows[o.id]!;
    expect((await laptop.state(o.id, OrchardEventExporter.sentKey) as Map)['activity'], rows[rows.length - 131].id);
    status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.failure), (103, ExportFailure.unreachable));
    // A round that goes nowhere at all keeps when events last went, and
    // says since when they do not.
    final lastWent = clock.millisecondsSinceEpoch ~/ 1000;
    clock = DateTime.utc(2026, 10, 2, 12, 9);
    receiver.answer = (_) => const ExportDelivery.failed(ExportFailure.unreachable);
    await laptop.exporter.round(o.id);
    status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.sentAt, status.failure, status.failedAt),
        (103, lastWent, ExportFailure.unreachable, clock.millisecondsSinceEpoch ~/ 1000));
    receiver.requests.removeLast();
    receiver.answer = null;
    await laptop.exporter.round(o.id);
    expect([for (final r in receiver.requests.skip(2)) _Receiver.eventsOf(r.to.format, r.body).length], [100, 30]);
    expect(receiver.ids, [for (final r in rows.skip(rows.length - 230)) 'activity-${r.id}']);
    expect(receiver.ids.toSet(), hasLength(230));
    expect((await laptop.exporter.standing(o.id)).status.sent, 233);

    // The same with the record's entries: a hundred and thirty of them, the
    // second request not taken, then the rest; each entry once.
    for (var i = 0; i < 65; i++) {
      await laptop.service.setTracking(o.id, const RecordTracking(activity: true, history: true));
      await laptop.service.setTracking(o.id, _activity);
    }
    final last = server.entriesOf(o.id).last.seq;
    receiver.requests.clear();
    receiver.taken.clear();
    receiver.answer = (n) => n == 1 ? const ExportDelivery.failed(ExportFailure.refused, status: 500) : null;
    await laptop.exporter.round(o.id);
    expect(receiver.ids, [for (var s = last - 129; s <= last - 30; s++) 'record-$s']);
    expect((await laptop.state(o.id, OrchardEventExporter.sentKey) as Map)['record'], last - 30);
    receiver.answer = null;
    await laptop.exporter.round(o.id);
    expect(receiver.ids, [for (var s = last - 129; s <= last; s++) 'record-$s']);

    // Set up again on this device, with another key: how it went before is
    // not how it goes now.
    await laptop.exporter.setUp(o.id, to, await laptop.exporter.newKey());
    status = (await laptop.exporter.standing(o.id)).status;
    expect((status.sent, status.failure), (1, null));

    // A status that does not read as one (written by something else, or
    // half written) is no status and never an error: the page says nothing
    // was sent yet, and the next round keeps a new one.
    final kept = LocalStateStore(await laptop.db(o.id));
    for (final planted in ['not what it wrote', '[1]', '7', '"sent"']) {
      await kept.write(OrchardEventExporter.statusKey, planted);
      final none = (await laptop.exporter.standing(o.id)).status;
      expect((none.sent, none.sentAt, none.failure, none.failedAt), (0, null, null, null), reason: planted);
      await laptop.service.setTracking(o.id, const RecordTracking(activity: true, history: true));
      await laptop.service.setTracking(o.id, _activity);
      await laptop.exporter.round(o.id);
      expect((await laptop.exporter.standing(o.id)).status.sent, 2, reason: planted);
    }
  });

  test('a round sends no more than ten requests; what is left goes with the next, a page of activity at a time',
      () async {
    final o = await recording();
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    for (var i = 0; i < 1050; i++) {
      garbage(o.id, _alice);
    }
    receiver.requests.clear();
    receiver.taken.clear();
    server.activityReads.clear();
    await o.laptop.exporter.round(o.id);
    expect(receiver.requests, hasLength(OrchardEventExporter.maxRequests));
    expect(receiver.taken, hasLength(1000));
    // Read forward from where it got, two hundred at a time.
    final rows = server.activityRows[o.id]!;
    final first = rows[rows.length - 1050].id;
    expect([for (final r in server.activityReads) r.after].take(3), [first - 1, first + 199, first + 399]);
    expect(server.activityReads.every((r) => r.before == null), isTrue);
    await o.laptop.exporter.round(o.id);
    expect(receiver.requests, hasLength(11));
    expect(receiver.ids, [for (final r in rows.skip(rows.length - 1050)) 'activity-${r.id}']);
    await o.laptop.exporter.round(o.id);
    expect(receiver.requests, hasLength(11));
  });

  test('turned off: the entry that says so is the last event, and the device forgets the key and the address',
      () async {
    final o = await recording();
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'last look');
    await o.laptop.exporter.turnOff(o.id);
    final entries = server.entriesOf(o.id);
    expect(entries.last.type, RecordTypes.exportSet);
    expect(entries.last.body, {'on': false});
    expect(server.recordOf(o.id).eventExport, isNull);
    // What it had not sent yet went first, what members did included: once
    // it is off, that is no longer this device's to send.
    expect(receiver.ids, [
      'record-${entries.last.seq - 2}',
      'record-${entries.last.seq - 1}',
      'activity-${server.activityRows[o.id]!.last.id}',
      'record-${entries.last.seq}',
    ]);
    final last = receiver.taken.last;
    expect((last['action'], last['change'], last['message']),
        ('export.set', 'export_off', 'owner-1@example.com: Turned event export off'));
    expect(await verifyExportEvent(last, key: key.publicKey), isTrue);

    expect(o.laptop.kept, isEmpty);
    expect(await o.laptop.state(o.id, OrchardEventExporter.sentKey), isNull);
    expect(await o.laptop.state(o.id, OrchardEventExporter.statusKey), isNull);
    final standing = await o.laptop.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.destination, standing.status.sent), (false, false, null, 0));
    expect(await o.laptop.exporter.keyHere(o.id), isNull);

    // Nothing goes any more, whatever happens.
    receiver.requests.clear();
    await o.laptop.service.createCrate(o.id, 'Another', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'deploy key');
    await o.laptop.exporter.round(o.id);
    await o.laptop.exporter.rounds();
    expect(receiver.requests, isEmpty);
    // A device that sends for nobody asks its secure storage once, and
    // then nothing.
    final reads = o.laptop.keychain.reads;
    final lists = o.laptop.storage.lists;
    await o.laptop.exporter.rounds();
    expect(o.laptop.storage.lists, lists, reason: 'nor does it look which Orchards are on the device');
    await o.laptop.exporter.round(o.id);
    expect(o.laptop.keychain.reads, reads);
    // A device that never sent, the same: one look, remembered.
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await phone.exporter.rounds();
    final once = phone.keychain.reads;
    final listed = phone.storage.lists;
    await phone.exporter.rounds();
    await phone.exporter.round(o.id);
    await phone.exporter.standing(o.id);
    expect((phone.keychain.reads, phone.storage.lists), (once, listed));

    // Set up again with the very key it had (nothing stops an owner): it
    // starts with the entry that turned it on this time, and nothing from
    // the time it was off goes.
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'while it was off');
    receiver.requests.clear();
    receiver.taken.clear();
    await o.laptop.exporter.setUp(o.id, to, key);
    expect(receiver.ids, ['record-${server.entriesOf(o.id).last.seq}']);
    expect(await verifyExportEvent(receiver.taken.single, key: key.publicKey), isTrue);
  });

  test('it ends with what it rests on: activity no longer recorded, or its owner no longer one; the entry '
      'that ended it is the last thing said, taken or not', () async {
    // Activity is turned off, by another owner.
    final o = await recording();
    final second = device(_owner2, 'second-laptop');
    await join(o.laptop, second, o.id, FixedRoles.owner);
    var key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'not sent yet');
    await second.service.refresh();
    await second.service.setTracking(o.id, const RecordTracking(history: true));
    await o.laptop.service.refresh();
    final told = o.laptop.changes;
    server.activityReads.clear();
    await o.laptop.exporter.rounds();
    expect(o.laptop.changes, told + 1, reason: 'its pages hear that it is over');
    expect((await o.laptop.exporter.standing(o.id)).activityOn, isFalse, reason: 'history alone is not activity');
    // Ended from elsewhere, what members did meanwhile is not this device's
    // to say any more: it does not ask for it.
    expect(server.activityReads, isEmpty);
    var entries = server.entriesOf(o.id);
    expect(receiver.ids, [for (final e in entries.skip(entries.length - 2)) 'record-${e.seq}']);
    expect(receiver.taken.last['action'], 'tracking.set');
    expect(receiver.taken.last['actor'], {'uid': _owner2, 'email': 'owner-2@example.com'});
    expect(o.laptop.kept, isEmpty);
    expect((await o.laptop.exporter.standing(o.id)).on, isFalse);

    // The owner who set it up steps down; what the device says last is not
    // taken, and it is over all the same.
    await second.service.setTracking(o.id, _activity);
    await o.laptop.service.refresh();
    key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    receiver.requests.clear();
    receiver.taken.clear();
    receiver.answer = (_) => const ExportDelivery.failed(ExportFailure.unreachable);
    await o.laptop.service.stepDown(o.id);
    expect(server.recordOf(o.id).eventExport, isNull);
    await o.laptop.exporter.rounds();
    expect(receiver.requests, hasLength(1), reason: 'tried once');
    entries = server.entriesOf(o.id);
    expect(_Receiver.eventsOf(to.format, receiver.requests.single.body).single['id'], 'record-${entries.last.seq}');
    expect(o.laptop.kept, isEmpty);
    receiver.answer = null;
    await o.laptop.exporter.rounds();
    expect(receiver.requests, hasLength(1), reason: 'and not again');
    final standing = await o.laptop.exporter.standing(o.id);
    expect((standing.isOwner, standing.on, standing.sendsHere), (false, false, false));
  });

  test('another device takes over: the first says what came before and stops, the second starts with the '
      'entry that names its key; no entry twice', () async {
    final o = await recording();
    final first = _Receiver();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, into: first);
    final key = await laptop.exporter.newKey();
    await laptop.exporter.setUp(o.id, to, key);
    final started = server.entriesOf(o.id).last.seq;
    await laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'before the handover');
    final before = server.activityRows[o.id]!.last.id;

    // The same owner's phone, with an address of its own.
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    var standing = await phone.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.record!.by, standing.destination), (true, false, _owner, null));
    await phone.exporter.round(o.id);
    expect(receiver.requests, isEmpty, reason: 'it holds no key: it sends nothing');
    final other = ExportDestination.of('https://siem.example.net/hook', ExportFormat.array)!;
    final key2 = await phone.exporter.newKey();
    await phone.exporter.setUp(o.id, other, key2);
    final taken = server.entriesOf(o.id).last.seq;
    expect(server.recordOf(o.id).eventExport!.keyText, key2.key);
    expect(receiver.requests.single.to.url.host, 'siem.example.net');
    expect(receiver.requests.single.body.startsWith('['), isTrue);
    expect(receiver.ids, ['record-$taken']);
    expect(await verifyExportEvent(receiver.taken.single, key: key2.publicKey), isTrue);
    // It starts with what members do from its set-up on.
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'after the handover');
    final after = server.activityRows[o.id]!.last.id;
    await phone.exporter.round(o.id);
    expect(receiver.ids, ['record-$taken', 'activity-$after']);

    // The laptop hears of it. It is not the one that sends any more (and
    // shows no address); it says the entry before the handover and what
    // members did until now, of which the phone said only what came after,
    // and is done.
    await laptop.service.refresh();
    standing = await laptop.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.destination, standing.status.sent), (true, false, null, 0));
    await laptop.exporter.rounds();
    expect(first.ids, ['record-$started', 'record-${started + 1}', 'activity-$before', 'activity-$after']);
    expect(taken, started + 2);
    expect(laptop.kept, isEmpty);
    standing = await laptop.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.destination), (true, false, null));
    for (final e in first.taken) {
      expect(await verifyExportEvent(e, key: key.publicKey), isTrue);
    }
    // From here on only the phone sends.
    await laptop.service.createCrate(o.id, 'Another', ownersOnly: true);
    await laptop.exporter.rounds();
    await phone.service.refresh();
    await phone.exporter.rounds();
    expect(first.ids, hasLength(4));
    expect(receiver.ids, ['record-$taken', 'activity-$after', 'record-${taken + 1}']);

    // Another owner sets it up on a device of theirs: theirs from then on.
    final second = device(_owner2, 'second-laptop', into: _Receiver());
    await join(laptop, second, o.id, FixedRoles.owner);
    // (Someone made an owner goes out with that role's English name.)
    await phone.service.refresh();
    await phone.exporter.rounds();
    final joined = receiver.taken.lastWhere((e) => e['action'] == 'member.add');
    expect(joined['message'], 'owner-1@example.com: Added owner-2@example.com as Owner');
    expect(joined['role'], {'id': 'owner', 'name': 'Owner'});
    expect(joined['target'], {'uid': _owner2, 'email': 'owner-2@example.com'});
    await second.exporter.setUp(o.id, to, await second.exporter.newKey());
    expect(server.recordOf(o.id).eventExport!.by, _owner2);
    await phone.service.refresh();
    await phone.exporter.rounds();
    expect(phone.kept, isEmpty);
    standing = await phone.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere, standing.record!.by), (true, false, _owner2));
    final all = [
      for (final id in [...first.ids, ...receiver.ids, ...second.receiver.ids])
        if (id.startsWith('record-')) id,
    ];
    expect(all.toSet(), hasLength(all.length), reason: 'no entry was said twice');
    expect(all, [for (var seq = started; seq <= server.entriesOf(o.id).last.seq; seq++) 'record-$seq']);

    // Someone else's entry that names a key is theirs, whoever holds that
    // key: the first owner sets it up again, and the other then writes an
    // entry naming that very key. The laptop holds it and is no longer the
    // one that sends: it says what came before that entry, and stops.
    final back = _Receiver();
    final again = device(_owner, 'laptop', restartOf: laptop, into: back);
    final mine = await again.exporter.newKey();
    await again.exporter.setUp(o.id, to, mine);
    final from = server.entriesOf(o.id).last.seq;
    await again.service.createCrate(o.id, 'Third', ownersOnly: true);
    await second.service.refresh();
    await second.service.change(o.id, RecordTypes.exportSet, {'on': true, 'key': mine.key});
    expect(server.recordOf(o.id).eventExport!.keyText, mine.key);
    expect(server.recordOf(o.id).eventExport!.by, _owner2);
    await again.service.refresh();
    standing = await again.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere), (true, false));
    await again.exporter.rounds();
    expect(back.ids, ['record-$from', 'record-${from + 1}']);
    expect(again.kept, isEmpty);

    // An owner whose device does not send turns it off: its pages hear of
    // it, and nothing is sent from there.
    final heard = again.changes;
    await again.exporter.turnOff(o.id);
    expect(server.recordOf(o.id).eventExport, isNull);
    expect(again.changes, heard + 1);
    expect(back.ids, hasLength(2));
  });

  test('the activity cannot be read just now: the record goes all the same, and nothing is said against the '
      'receiver', () async {
    final o = await recording();
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'deploy key');
    await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    server.failActivityReads = true;
    receiver.taken.clear();
    final told = o.laptop.changes;
    await o.laptop.exporter.round(o.id);
    expect(receiver.ids, ['record-${server.entriesOf(o.id).last.seq}']);
    expect((await o.laptop.exporter.standing(o.id)).status.failure, isNull);
    expect(o.laptop.changes, told + 1, reason: 'what went is told to the pages all the same');
    server.failActivityReads = false;
    await o.laptop.exporter.round(o.id);
    expect(receiver.ids.last, 'activity-${server.activityRows[o.id]!.last.id}');
    // A page that says there is more and brings nothing does not go round
    // for ever.
    server.activityPage = 0;
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'db password');
    final sent = receiver.taken.length;
    server.activityReads.clear();
    await o.laptop.exporter.round(o.id);
    expect(receiver.taken, hasLength(sent));
    expect(server.activityReads, hasLength(1), reason: 'asked once, not again and again');

    // A page that comes out of order sends no note twice: the device is as
    // far as the highest it sent.
    server.activityPage = 200;
    await o.laptop.exporter.round(o.id);
    for (var i = 0; i < 3; i++) {
      garbage(o.id, _alice);
    }
    final rows = server.activityRows[o.id]!;
    final [a, b, c] = rows.sublist(rows.length - 3);
    rows.replaceRange(rows.length - 3, rows.length, [c, a, b]);
    receiver.taken.clear();
    await o.laptop.exporter.round(o.id);
    await o.laptop.exporter.round(o.id);
    expect(receiver.ids, ['activity-${c.id}', 'activity-${a.id}', 'activity-${b.id}']);
    expect((await o.laptop.state(o.id, OrchardEventExporter.sentKey) as Map)['activity'], c.id);
  });

  test('where the Orchard is not on the device just now it waits, and goes on from where it noted it got; '
      'where this account is no longer in it, what was kept for it goes', () async {
    final o = await recording();
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'deploy key');
    await o.laptop.exporter.round(o.id);
    receiver.requests.clear();
    receiver.taken.clear();

    // The Orchard's database was dropped and is there again, empty (a
    // device taken out of the Orchard for a while): it waits.
    await o.laptop.service.databases.forget(o.id);
    await o.laptop.service.databases.open(o.id);
    await o.laptop.exporter.rounds();
    expect(receiver.requests, isEmpty);
    expect(o.laptop.kept, hasLength(3));
    // The record is back. How far it got went with the database, and the
    // note beside the key says it: it says nothing again, and goes on.
    await o.laptop.service.refresh();
    await o.laptop.exporter.rounds();
    expect(receiver.requests, isEmpty);
    await o.laptop.service.createCrate(o.id, 'Another', ownersOnly: true);
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'db password');
    await o.laptop.exporter.rounds();
    expect(receiver.ids,
        ['record-${server.entriesOf(o.id).last.seq}', 'activity-${server.activityRows[o.id]!.last.id}']);

    // The database is not there at all (dropped, and the next sync has not
    // brought it back yet): it waits, and a round makes none.
    await o.laptop.service.databases.forget(o.id);
    final told = o.laptop.changes;
    await o.laptop.exporter.rounds();
    expect(o.laptop.kept, hasLength(3));
    expect(o.laptop.storage.dbs.containsKey(o.id), isFalse);
    expect(o.laptop.changes, told);
    // (ZestSSH Cloud lists the Orchard for this account. What it listed
    // for one account says nothing of another.)
    expect(o.laptop.service.listedFor(_owner), {o.id});
    expect(o.laptop.service.listedFor(_owner2), isNull);
    // The same in a run that has not asked ZestSSH Cloud yet.
    final started = device(_owner, 'laptop', restartOf: o.laptop);
    expect(started.service.listedFor(_owner), isNull);
    await started.exporter.rounds();
    expect(started.kept, hasLength(3));
    expect(started.storage.dbs.containsKey(o.id), isFalse);

    // This account leaves the Orchard, from another device of its own. The
    // next look at ZestSSH Cloud no longer lists it, the Orchard goes from
    // this device, and with the next round what was kept to send its events.
    await o.laptop.service.refresh();
    final second = device(_owner2, 'second-laptop');
    await join(o.laptop, second, o.id, FixedRoles.owner);
    await o.laptop.exporter.rounds();
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    expect(phone.service.listedFor(_owner), {o.id});
    await phone.service.leaveOrchard(o.id);
    expect(phone.service.listedFor(_owner), isEmpty);
    receiver.requests.clear();
    await o.laptop.service.refresh();
    expect(o.laptop.service.listedFor(_owner), isEmpty);
    // Nothing checked here says this account is out: it stays, held, until
    // its person removes it.
    expect(o.laptop.storage.dbs.containsKey(o.id), isTrue);
    await o.laptop.service.removeUnlistedTeam(o.id);
    expect(o.laptop.storage.dbs.containsKey(o.id), isFalse);
    expect(o.laptop.kept, hasLength(3));
    final before = o.laptop.changes;
    await o.laptop.exporter.rounds();
    expect(o.laptop.kept, isEmpty);
    expect(o.laptop.changes, before + 1);
    expect(receiver.requests, isEmpty);
  });

  test('the address is changed on the device that sends, and nowhere else; a test event changes nothing',
      () async {
    final o = await recording();
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'before it was set up');
    // A test event before anything is set up, signed with the key to be.
    final key = await o.laptop.exporter.newKey();
    final before = server.entriesOf(o.id).length;
    var delivery = await o.laptop.exporter.sendTest(o.id, to, key);
    expect((delivery.ok, delivery.status), (true, 200));
    final test = receiver.taken.single;
    expect((test['type'], test['action'], test['message']),
        ('test', 'test', 'Test event from ZestSSH: nothing happened.'));
    expect((test['id'] as String).startsWith('test-'), isTrue);
    expect(test['actor'], {'uid': _owner, 'email': 'owner-1@example.com'});
    expect(test['orchard'], {'id': o.id, 'name': 'Acme'});
    expect(await verifyExportEvent(test, key: key.publicKey), isTrue);
    expect(server.entriesOf(o.id), hasLength(before));
    expect(o.laptop.kept, isEmpty);
    receiver.answer = (_) => const ExportDelivery.failed(ExportFailure.certificate);
    delivery = await o.laptop.exporter.sendTest(o.id, to, key);
    expect((delivery.ok, delivery.failure), (false, ExportFailure.certificate));
    receiver.answer = null;

    await o.laptop.exporter.setUp(o.id, to, key);
    final entries = server.entriesOf(o.id).length;
    final other = ExportDestination.of('https://siem.example.net/hook', ExportFormat.array,
        headerName: 'DD-API-KEY', headerValue: 'key-2')!;
    final told = o.laptop.changes;
    final asked = receiver.requests.length;
    await o.laptop.exporter.changeDestination(o.id, other);
    expect(receiver.requests, hasLength(asked), reason: 'nothing was waiting');
    expect(o.laptop.changes, told + 1, reason: 'the pages hear of the new address all the same');
    expect(server.entriesOf(o.id), hasLength(entries), reason: 'the record never held the address');
    expect((await o.laptop.exporter.standing(o.id)).destination!.toJson(), other.toJson());
    expect((await o.laptop.exporter.keyHere(o.id))!.key, key.key, reason: 'the same key');
    await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await o.laptop.exporter.round(o.id);
    final last = receiver.requests.last;
    expect((last.to.url.host, last.to.headers['DD-API-KEY'], last.to.format), ('siem.example.net', 'key-2', ExportFormat.array));
    expect(receiver.ids.last, 'record-${server.entriesOf(o.id).last.seq}');
    // Kept across a start of the app.
    final again = device(_owner, 'laptop', restartOf: o.laptop);
    expect((await again.exporter.standing(o.id)).destination!.toJson(), other.toJson());
    // A test event after it is set up changes nothing either.
    final sent = (await again.exporter.standing(o.id)).status.sent;
    expect((await again.exporter.sendTest(o.id, other, (await again.exporter.keyHere(o.id))!)).ok, isTrue);
    expect((await again.exporter.standing(o.id)).status.sent, sent);
    expect(server.entriesOf(o.id), hasLength(entries + 1));
    // What waits goes to the new address at once.
    await again.service.createCrate(o.id, 'Another', ownersOnly: true);
    await again.exporter.changeDestination(o.id, to);
    expect(receiver.requests.last.to.url.host, 'logs.example.com');
    expect(receiver.ids.last, 'record-${server.entriesOf(o.id).last.seq}');
    // Where activity starts is kept with the address: should the device
    // lose how far it got, nothing from before the set-up goes.
    await LocalStateStore(await again.db(o.id)).remove(OrchardEventExporter.sentKey);
    again.keychain.values.remove(again.noteKey(o.id));
    receiver.taken.clear();
    await device(_owner, 'laptop', restartOf: again).exporter.round(o.id);
    expect(receiver.ids, isNotEmpty);
    expect(receiver.ids.where((id) => id.startsWith('activity-')), isEmpty);

    // On a device that does not send there is no address to change.
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await expectLater(phone.exporter.changeDestination(o.id, other), throwsStateError);
    expect(phone.kept, isEmpty);
  });

  test('a change made on the device that sends, which ends its sending: what it had not sent goes first, '
      'what members did included', () async {
    final o = await recording();
    final second = device(_owner2, 'second-laptop');
    await join(o.laptop, second, o.id, FixedRoles.owner);

    // A change that leaves the sending as it is sends nothing ahead.
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'zero');
    final zero = server.activityRows[o.id]!.last.id;
    receiver.taken.clear();
    await o.laptop.service.setTracking(o.id, const RecordTracking(activity: true, history: true));
    expect(receiver.taken, isEmpty);

    // Set up again here, with another key: what was left goes first, signed
    // with the key it was to go with.
    final key2 = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key2);
    var last = server.entriesOf(o.id).last.seq;
    expect(receiver.ids, ['record-${last - 1}', 'activity-$zero', 'record-$last']);
    expect([for (final e in receiver.taken) e['key']], [key.key, key.key, key2.key]);
    for (final e in receiver.taken) {
      expect(await verifyExportEvent(e), isTrue);
    }

    // The team no longer records activity (and ZestSSH Cloud then keeps
    // none of what it had): what members did goes before the entry does.
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'one');
    final one = server.activityRows[o.id]!.last.id;
    receiver.taken.clear();
    await o.laptop.service.setTracking(o.id, RecordTracking.none);
    expect(receiver.ids, ['activity-$one']);
    expect(server.activityRows[o.id], isNull);
    await o.laptop.exporter.rounds();
    last = server.entriesOf(o.id).last.seq;
    expect(receiver.ids, ['activity-$one', 'record-$last']);
    expect(receiver.taken.last['action'], 'tracking.set');
    expect(o.laptop.kept, isEmpty);

    // The owner whose device sends steps down.
    await o.laptop.service.setTracking(o.id, _activity);
    await o.alice.service.refresh();
    await o.laptop.exporter.setUp(o.id, to, await o.laptop.exporter.newKey());
    await does(o.alice, o.id, ActivityKind.copy, o.crate, 'two');
    final two = server.activityRows[o.id]!.last.id;
    receiver.taken.clear();
    await o.laptop.service.stepDown(o.id);
    expect(receiver.ids, ['activity-$two']);
    await o.laptop.exporter.rounds();
    last = server.entriesOf(o.id).last.seq;
    expect(receiver.ids, ['activity-$two', 'record-$last']);
    expect((receiver.taken.last['action'], receiver.taken.last['change'], receiver.taken.last['message']),
        ('member.set', 'member_stepped_down', 'owner-1@example.com: Stepped down to Admin'));
    expect(o.laptop.kept, isEmpty);

    // Whatever comes of asking for what is left, the change goes on.
    await second.service.refresh();
    await second.exporter.setUp(o.id, to, await second.exporter.newKey());
    second.failFlush = true;
    await second.exporter.turnOff(o.id);
    expect(server.recordOf(o.id).eventExport, isNull);
  });

  test('the owner whose device sends leaves the Orchard: that they left is the last thing it says, before '
      'the Orchard goes from the device', () async {
    final o = await recording();
    final second = device(_owner2, 'second-laptop');
    await join(o.laptop, second, o.id, FixedRoles.owner);
    await o.laptop.service.refresh();
    expect(o.laptop.service.listedFor(_owner), {o.id});
    final key = await o.laptop.exporter.newKey();
    await o.laptop.exporter.setUp(o.id, to, key);
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'three');
    final three = server.activityRows[o.id]!.last.id;
    receiver.taken.clear();
    receiver.requests.clear();

    // Someone whose device does not send leaves: nothing is sent from there.
    await o.alice.service.leaveOrchard(o.id);
    expect(receiver.requests, isEmpty);
    expect(o.alice.storage.dbs.containsKey(o.id), isFalse);

    await o.laptop.service.leaveOrchard(o.id);
    expect(server.recordOf(o.id).eventExport, isNull);
    final last = server.entriesOf(o.id).last.seq;
    expect(receiver.ids, ['record-${last - 1}', 'activity-$three', 'record-$last']);
    final [hers, _, left] = receiver.taken;
    expect((hers['action'], hers['change'], hers['message']),
        ('member.remove', 'member_left', 'alice@example.com: Left the team'));
    expect((left['action'], left['change'], left['message']),
        ('member.remove', 'member_left', 'owner-1@example.com: Left the team'));
    expect(left['actor'], {'uid': _owner, 'email': 'owner-1@example.com'});
    expect(left.containsKey('target'), isFalse);
    expect(await verifyExportEvent(left, key: key.publicKey), isTrue);
    expect(o.laptop.kept, isEmpty);
    expect(o.laptop.storage.dbs.containsKey(o.id), isFalse);
    expect(o.laptop.service.listedFor(_owner), isEmpty);
  });

  test('handed on: the device that sent says what members did until now, over as many rounds as it takes; '
      'a request that is not taken ends it', () async {
    final o = await recording();
    final first = _Receiver();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, into: first);
    await laptop.exporter.setUp(o.id, to, await laptop.exporter.newKey());
    for (var i = 0; i < 1050; i++) {
      garbage(o.id, _alice);
    }
    final rows = server.activityRows[o.id]!;
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await phone.exporter.setUp(o.id, to, await phone.exporter.newKey());
    await laptop.service.refresh();
    first.requests.clear();
    first.taken.clear();

    // A round makes its ten requests: it is not through, and goes on.
    await laptop.exporter.rounds();
    expect(first.requests, hasLength(OrchardEventExporter.maxRequests));
    expect(first.taken, hasLength(1000));
    expect(laptop.kept, hasLength(3));
    expect((jsonDecode(laptop.kept[laptop.noteKey(o.id)]!) as Map)['activity'], rows[rows.length - 51].id);
    final standing = await laptop.exporter.standing(o.id);
    expect((standing.on, standing.sendsHere), (true, false));
    await laptop.exporter.rounds();
    expect(first.requests, hasLength(11));
    expect(first.ids, [for (final r in rows.skip(rows.length - 1050)) 'activity-${r.id}']);
    expect(laptop.kept, isEmpty);
    expect(await laptop.state(o.id, OrchardEventExporter.sentKey), isNull);
    await laptop.exporter.rounds();
    expect(first.requests, hasLength(11));

    // The other way round, and a request is not taken: the device is
    // through all the same, and what it had left is not said.
    for (var i = 0; i < 250; i++) {
      garbage(o.id, _alice);
    }
    final back = device(_owner, 'laptop', restartOf: laptop, into: first);
    await back.exporter.setUp(o.id, to, await back.exporter.newKey());
    await phone.service.refresh();
    receiver.requests.clear();
    receiver.taken.clear();
    receiver.answer = (n) => n == 1 ? const ExportDelivery.failed(ExportFailure.unreachable) : null;
    await phone.exporter.rounds();
    expect(receiver.requests, hasLength(2));
    expect(receiver.taken, hasLength(100));
    expect(phone.kept, isEmpty);
    receiver.answer = null;
    await phone.exporter.rounds();
    expect(receiver.requests, hasLength(2));

    // And back again, with an entry of the record waiting as well: that
    // request is not taken, and what members did is not tried after it.
    await back.service.createCrate(o.id, 'Vault', ownersOnly: true);
    for (var i = 0; i < 3; i++) {
      garbage(o.id, _alice);
    }
    final again = device(_owner, 'phone', restartOf: phone);
    await again.exporter.setUp(o.id, to, await again.exporter.newKey());
    await back.service.refresh();
    first.requests.clear();
    first.taken.clear();
    first.answer = (_) => const ExportDelivery.failed(ExportFailure.refused, status: 500);
    server.activityReads.clear();
    await back.exporter.rounds();
    expect(first.requests, hasLength(1));
    expect(_Receiver.eventsOf(to.format, first.requests.single.body).single['action'], 'crate.add');
    expect(server.activityReads, isEmpty);
    expect(back.kept, isEmpty);
  });

  test('a device\'s last sending with more of the record left than a round takes goes on with the next round',
      () async {
    final o = await recording();
    final second = device(_owner2, 'second-laptop', into: _Receiver());
    await join(o.laptop, second, o.id, FixedRoles.owner);
    await o.laptop.exporter.setUp(o.id, to, await o.laptop.exporter.newKey());
    // Another owner changes the team a thousand times and then turns the
    // sending off, while this device is away.
    final more = (type: RecordTypes.trackingSet, body: const RecordTracking(activity: true, history: true).toBody());
    final less = (type: RecordTypes.trackingSet, body: _activity.toBody());
    for (var i = 0; i < 3; i++) {
      await second.service.changeAll(o.id, [for (var n = 0; n < 167; n++) ...[more, less]]);
    }
    await second.exporter.turnOff(o.id);
    await o.laptop.service.refresh();
    receiver.requests.clear();
    receiver.taken.clear();
    await o.laptop.exporter.rounds();
    expect(receiver.requests, hasLength(OrchardEventExporter.maxRequests));
    expect(receiver.taken, hasLength(1000));
    expect(o.laptop.kept, hasLength(3), reason: 'not through yet');
    await o.laptop.exporter.rounds();
    final last = server.entriesOf(o.id).last.seq;
    expect(receiver.ids, [for (var s = last - 1002; s <= last; s++) 'record-$s']);
    expect(receiver.taken.last['change'], 'export_off');
    expect(o.laptop.kept, isEmpty);
  });

  test('handed on, and ZestSSH Cloud cannot be asked what members did just now: the device asks again',
      () async {
    final o = await recording();
    final first = _Receiver();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, into: first);
    await laptop.exporter.setUp(o.id, to, await laptop.exporter.newKey());
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'one');
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await phone.exporter.setUp(o.id, to, await phone.exporter.newKey());
    await laptop.service.refresh();
    server.failActivityReads = true;
    final told = laptop.changes;
    await laptop.exporter.rounds();
    expect(first.ids, hasLength(1));
    expect(laptop.kept, hasLength(3));
    expect(laptop.changes, told, reason: 'nothing went, and nothing changed');
    server.failActivityReads = false;
    await laptop.exporter.rounds();
    expect(first.ids.last, 'activity-${server.activityRows[o.id]!.last.id}');
    expect(first.ids, hasLength(2));
    expect(laptop.kept, isEmpty);
  });

  for (final (why, change) in <(String, Future<void> Function(_Device phone, _Device second, String id))>[
    ('is no longer an owner', (phone, second, id) => phone.service.stepDown(id)),
    ('is no longer in the Orchard', (phone, second, id) => phone.service.leaveOrchard(id)),
    ('finds activity no longer recorded', (phone, second, id) => second.service.setTracking(id, RecordTracking.none)),
  ]) {
    test('handed on, and the account whose device sent $why: asked once and refused, the device is through',
        () async {
      final o = await recording();
      final first = _Receiver();
      final laptop = device(_owner, 'laptop', restartOf: o.laptop, into: first);
      await laptop.exporter.setUp(o.id, to, await laptop.exporter.newKey());
      final second = device(_owner2, 'second-laptop');
      await join(laptop, second, o.id, FixedRoles.owner);
      await laptop.exporter.rounds();
      await does(o.alice, o.id, ActivityKind.copy, o.crate, 'two');
      await second.exporter.setUp(o.id, to, await second.exporter.newKey());
      final phone = device(_owner, 'phone');
      await phone.service.refresh();
      // The laptop hears of the handover, and not of what comes after it.
      await laptop.service.refresh();
      await change(phone, second, o.id);
      first.taken.clear();
      server.activityReads.clear();
      await laptop.exporter.rounds();
      expect(server.activityReads, hasLength(1));
      expect(first.taken, isEmpty);
      expect(laptop.kept, isEmpty);
    });
  }

  test('handed on, then turned off and on again: what members did before the time it was off cannot be '
      'told from what they did during it, and is not said', () async {
    final o = await recording();
    final first = _Receiver();
    final laptop = device(_owner, 'laptop', restartOf: o.laptop, into: first);
    await laptop.exporter.setUp(o.id, to, await laptop.exporter.newKey());
    await does(o.alice, o.id, ActivityKind.reveal, o.crate, 'four');
    final phone = device(_owner, 'phone');
    await phone.service.refresh();
    await phone.exporter.setUp(o.id, to, await phone.exporter.newKey());
    await phone.exporter.turnOff(o.id);
    await phone.exporter.setUp(o.id, to, await phone.exporter.newKey());
    await laptop.service.refresh();
    first.requests.clear();
    server.activityReads.clear();
    await laptop.exporter.rounds();
    expect(server.activityReads, isEmpty);
    expect(first.requests, isEmpty);
    expect(laptop.kept, isEmpty);
  });

  test('names this device does not have: a Crate, an item and the Orchard go out without one, a role that is '
      'gone as Member, someone without an address by their id', () async {
    final o = await recording();
    await o.laptop.exporter.setUp(o.id, to, await o.laptop.exporter.newKey());
    receiver.taken.clear();
    final vault = await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    final temps = await o.laptop.service.saveRole(o.id, name: 'Temps', can: {}, crates: {});
    await o.laptop.service.dropRole(o.id, temps, o.member);
    await o.laptop.service.suspendMember(o.id, _alice);
    await o.laptop.service.resumeMember(o.id, _alice);
    await o.alice.service.refresh();
    // Notes as a device that trims nothing would send them, and one that
    // names the owner as the one who did it: alice holds the Orchard's key
    // and can seal what she likes, and ZestSSH Cloud says who sent it.
    final sealing = await (await o.alice.db(o.id)).customSelect(
      "SELECT secret, generation FROM space_keys WHERE scope = 'orchard' AND scope_id = ? "
      'ORDER BY generation DESC LIMIT 1',
      variables: [Variable(o.id)],
    ).getSingle();
    final generation = sealing.read<int>('generation');
    final at = DateTime.utc(2026, 10, 2, 8);
    for (final e in [
      ActivityEvent(
          uid: _alice, kind: ActivityKind.reveal, at: at, crateId: o.crate, itemKind: 'key', itemKey: 'k-1', name: '  '),
      ActivityEvent(
          uid: _alice, kind: ActivityKind.reveal, at: at, crateId: o.crate, itemKind: 'key', itemKey: 'k-1', name: ' db '),
      ActivityEvent(uid: _owner, kind: ActivityKind.export, at: at, crateId: o.crate),
    ]) {
      final sealed = await sealActivity(e.toJson(), sealing.read<Uint8List>('secret'),
          orchardId: o.id, generation: generation);
      await o.alice.server.sendActivity(o.id, [SealedActivity(keyGeneration: generation, sealed: sealed)]);
    }
    final db = await o.laptop.db(o.id);
    await db.customStatement('UPDATE orchard_crates SET name = NULL WHERE crate_id = ?', [vault]);
    await db.customStatement("UPDATE orchard_crates SET name = '  ' WHERE crate_id = ?", [o.crate]);
    await db.customStatement('UPDATE member_keys SET email = NULL WHERE uid = ?', [_alice]);
    await db.customStatement("UPDATE member_keys SET email = ' ' WHERE uid = ?", [_owner]);
    await db.customStatement("UPDATE orchard_info SET name = '  ' WHERE id = 1");
    await o.laptop.exporter.round(o.id);
    final [crate, added, dropped, suspended, _, blank, spaced, framed] = receiver.taken;
    expect(crate['message'], 'owner-1: Added the vault Unnamed vault');
    expect(crate['crate'], {'id': vault});
    expect(crate['actor'], {'uid': _owner});
    expect(crate['orchard'], {'id': o.id});
    expect(added['message'], 'owner-1: Added the role Member');
    expect(added['role'], {'id': temps});
    expect(dropped['message'], 'owner-1: Deleted a role');
    expect(dropped['role'], {'id': temps});
    expect(suspended['message'], 'owner-1: Suspended alice');
    expect(suspended['target'], {'uid': _alice});
    expect(blank['actor'], {'uid': _alice});
    expect(blank['message'], 'alice opened the secrets of An unnamed item');
    expect(blank['item'], {'kind': 'key', 'id': 'k-1'});
    expect(blank['crate'], {'id': o.crate});
    expect((blank['time'], blank['time_source']), ('2026-10-02T08:00:00.000Z', 'device'));
    // (A name is sent as it is.)
    expect(spaced['message'], 'alice opened the secrets of  db ');
    expect(spaced['item'], {'kind': 'key', 'id': 'k-1', 'name': ' db '});
    // A note that names someone other than the account that sent it goes
    // out as one that could not be read, from the account that sent it.
    expect(framed['action'], 'unreadable');
    expect(framed['actor'], {'uid': _alice});
    expect(framed['message'], 'A note of activity from alice could not be read.');
    expect(framed.containsKey('crate'), isFalse);
  });

  test('where nothing can be done nothing is thrown: the keys are not on the device, or the Orchard is closed',
      () async {
    final o = await recording();
    await o.laptop.exporter.setUp(o.id, to, await o.laptop.exporter.newKey());
    await o.laptop.service.createCrate(o.id, 'Vault', ownersOnly: true);
    receiver.requests.clear();

    // The account's keys are not ready (signed out, or locked): no round,
    // and the page reads as for someone who is no owner.
    o.laptop.keysReady = false;
    await o.laptop.exporter.round(o.id);
    await o.laptop.exporter.rounds();
    await o.laptop.exporter.flush(o.id);
    expect(receiver.requests, isEmpty);
    final standing = await o.laptop.exporter.standing(o.id);
    expect((standing.isOwner, standing.on, standing.sendsHere, standing.destination), (false, true, false, null));
    expect(await o.laptop.exporter.keyHere(o.id), isNull);
    final key = await o.laptop.exporter.newKey();
    await expectLater(o.laptop.exporter.sendTest(o.id, to, key), throwsA(isA<AccountKeysNotReady>()));
    await expectLater(o.laptop.exporter.setUp(o.id, to, key), throwsA(isA<AccountKeysNotReady>()));
    await expectLater(o.laptop.exporter.changeDestination(o.id, to), throwsA(isA<AccountKeysNotReady>()));
    expect(o.laptop.kept, hasLength(3), reason: 'nothing is forgotten for that');
    expect(receiver.requests, isEmpty);
    o.laptop.keysReady = true;

    // The Orchard is closed on this device (past its offline limit): its
    // database does not open, and the round ends quietly.
    await o.laptop.service.databases.closeOffline(o.id);
    await o.laptop.exporter.round(o.id);
    await o.laptop.exporter.rounds();
    expect(receiver.requests, isEmpty);
    expect(o.laptop.kept, hasLength(3));
    o.laptop.storage.dbs.remove(o.id);
  });

  test('what it takes to set it up: activity recorded, an owner, a recent sign-in; refused, nothing is kept',
      () async {
    final laptop = device(_owner, 'laptop');
    final id = await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final alice = device(_alice, 'alice-laptop');
    await join(laptop, alice, id, server.recordOf(id).roles.values.single.id);
    final key = await laptop.exporter.newKey();
    Matcher refusedWith(int status, String code) => throwsA(isA<OrchardServerException>()
        .having((e) => e.status, 'status', status)
        .having((e) => e.code, 'code', code));

    // No activity recorded: nothing to send on.
    var standing = await laptop.exporter.standing(id);
    expect((standing.isOwner, standing.activityOn, standing.on), (true, false, false));
    await expectLater(laptop.exporter.setUp(id, to, key), refusedWith(409, 'activity-off'));
    expect(laptop.kept, isEmpty);
    expect(server.recordOf(id).eventExport, isNull);
    await laptop.service.setTracking(id, _activity);
    await alice.service.refresh();

    // Not an owner.
    standing = await alice.exporter.standing(id);
    expect((standing.isOwner, standing.activityOn), (false, true));
    await expectLater(alice.exporter.setUp(id, to, await alice.exporter.newKey()), refusedWith(403, 'owners-only'));
    expect(alice.kept, isEmpty);
    await expectLater(alice.exporter.turnOff(id),
        throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'only owners set event export')));

    // A sign-in that is not recent: asked for one, and nothing is kept
    // until the record took it.
    server.requireRecentSignIn = true;
    await expectLater(
      laptop.exporter.setUp(id, to, key),
      throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in', isTrue)),
    );
    expect(laptop.kept, isEmpty);
    expect(server.recordOf(id).eventExport, isNull);
    expect(receiver.requests, isEmpty);
    server.requireRecentSignIn = false;
    await laptop.exporter.setUp(id, to, key);
    expect(server.recordOf(id).eventExport!.keyText, key.key);
    // Turning it off asks for one as well, and the device goes on sending
    // until it is off.
    server.requireRecentSignIn = true;
    await expectLater(
      laptop.exporter.turnOff(id),
      throwsA(isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in', isTrue)),
    );
    expect(laptop.kept, hasLength(3));
    expect(server.recordOf(id).eventExport, isNotNull);
  });
}

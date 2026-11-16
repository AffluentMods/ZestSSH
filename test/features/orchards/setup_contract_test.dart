import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'setup/setup_world.dart' show describeRecord, kLater, namesOf, secondsOf, setupFile, texts;

/// The setup file (3.0) against the REAL server routes on a real
/// Postgres. A file is applied with nothing but what the app does by hand
/// (record entries, invitations, item writes), so the server has no route
/// of its own for it; what is held here is that the plan and the server
/// agree: what the plan rehearsed on this device's copy of the record is
/// the record the server holds afterwards, the changes the server takes
/// only after a recent sign-in are the ones the plan says, and an offer the
/// plan calls refused is one the server refuses. Start the server:
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

class _Device {
  final storage = _MemoryStorage();

  /// How long ago this device's sign-in was, in seconds.
  var signedInAgo = 0;
  late final OrchardsApi server;
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;

  Future<void> sync(String orchardId) async {
    await coordinator.syncOne(orchardId);
  }

  Future<OrchardSnapshot> snapshot(String orchardId) => readSetupSnapshot(service, orchardId, sync: () => sync(orchardId));

  SetupActions actions(String orchardId) => OrchardSetupActions(service, orchardId, sync: () => sync(orchardId));
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
  String mail(CrateAuthor of) => '${of.uid}@example.com';

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
    final uid = 'setup-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  _Device device(CrateAuthor me) {
    final d = _Device();
    // A device that is in contact with the server, as one that applies a
    // file is: a Crate's own offline limit is measured from now.
    int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()),
        storage: d.storage,
        contact: DeviceContact(read: () => OrchardContact(lastContact: now(), latest: now()), now: now));
    d.server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid, ago: d.signedInAgo));
    d.service = OrchardService(server: d.server, databases: databases, author: () async => me);
    d.coordinator = OrchardSyncCoordinator(service: d.service, server: d.server, databases: databases);
    devices.add(d);
    return d;
  }

  /// [person] joins [orchardId] in [role], added by [by].
  Future<_Device> join(_Device by, CrateAuthor person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: mail(person), role: role);
    final d = device(person);
    await d.service.acceptInvite((await d.service.myInvites()).single.id);
    await by.service
        .confirmInvite(orchardId, (await by.service.invites(orchardId)).singleWhere((i) => i.email == mail(person)));
    await d.coordinator.syncAll();
    return d;
  }

  test('a setup file through the real routes: written as a file it changes nothing, a sign-in that is not recent '
      'stops it where the plan said, and what the plan rehearsed is the record the server holds', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final dave = await account('dave');
    final o = device(owner);
    final id = await o.service.createOrchard('Setup contract', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = (await o.service.roles(id)).single.id;
    final a = await join(o, alice, id, member);

    // As it is: written as a file, the file reads and changes nothing.
    var before = await o.snapshot(id);
    expect(before.reached, isTrue);
    final export = exportSetup(before);
    expect(export.leftOut, isEmpty);
    final written = readSetupFile(export.text);
    expect(written.problems, isEmpty);
    var plan = await planSetup(written.file!, before);
    expect(texts(plan.problems), isEmpty);
    expect(texts(plan.steps), isEmpty, reason: 'an Orchard written as a file is what the file says');

    final file = setupFile({
      'orchard': 'Setup contract',
      'rules': {'reauth_days': 30},
      'crates': [
        {'name': 'Lab', 'ask_again': true, 'allow': <String>[]},
        {
          'name': 'Production',
          'allow': ['sftp'],
          // Closed on a device that has been away for a day.
          'offline_hours': 24,
          // Everyone who may connect there may do so with nobody watching
          // while the server cannot be reached.
          'unwatched_away': true,
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11', 'group': 'Web', 'tags': ['prod', 'web']},
            {'name': 'web-2', 'address': '10.50.0.12', 'port': 2222, 'protocol': 'mosh'},
          ],
        },
      ],
      'roles': [
        {
          'name': 'Operators',
          'can': ['invite'],
          'crates': {'Production': 'edit', 'Lab': 'manage'},
        },
        {
          'name': 'Member',
          'crates': {'Production': 'connect'},
        },
      ],
      'members': [
        {'email': mail(alice), 'role': 'Operators'},
        {'email': mail(dave), 'role': 'Member', 'until': kLater},
      ],
    });
    plan = await planSetup(file, before);
    expect(texts(plan.problems), isEmpty);
    expect(plan.needsRecentSignIn, isTrue);
    final first = plan.steps.first;
    expect('$first', 'add crate Lab');
    expect(first.needsRecentSignIn, isFalse, reason: 'adding a Crate needs no recent sign-in');
    expect(plan.steps[1].needsRecentSignIn, isTrue, reason: 'what a Crate asks does: ${plan.steps[1]}');

    // A sign-in that is not recent: the server takes the Crate, and stops
    // at the first change the plan said needs one. Nothing after it is made.
    o.signedInAgo = 3 * 3600;
    final stopped = await applySetup(plan, before, o.actions(id));
    expect(stopped.complete, isFalse);
    expect(texts(stopped.done), ['add crate Lab']);
    expect(stopped.failed, same(plan.steps[1]));
    expect(stopped.error,
        isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'a recent sign-in is wanted', isTrue));
    expect(stopped.left, hasLength(plan.steps.length - 2));
    o.signedInAgo = 0;
    var held = await o.snapshot(id);
    expect([for (final c in held.crates) c.name], containsAll(['Production', 'Lab']));
    expect(held.record.roles, hasLength(1), reason: 'the role after it was not added');
    expect(await o.service.invites(id), isEmpty);

    // The same file again, signed in a moment ago: what is left is made, and
    // the record the server holds is the one the plan rehearsed.
    before = held;
    plan = await planSetup(file, before);
    expect(texts(plan.problems), isEmpty);
    expect(texts(plan.steps), isNot(contains('add crate Lab')));
    final done = await applySetup(plan, before, o.actions(id));
    expect(done.error, isNull);
    expect(done.complete, isTrue);
    expect(done.syncError, isNull);
    held = await o.snapshot(id);
    expect(describeRecord(held.record, namesOf(held)), describeRecord(plan.after, {...namesOf(before), ...plan.added}));
    // The server's own copy says the same as this device's.
    final entries = (await o.server.record(id, after: 0)).entries;
    expect(entries.last.seq, held.record.seq);
    // A Crate's own offline limit went through the real routes with the
    // rest: the server's record has it for Production, and for no other.
    final onServer = await OrchardRecord.replay(id, entries);
    expect({for (final c in held.crates) c.name: onServer.crates[c.id]!.offlineHours}, {'Production': 24, 'Lab': 0});
    expect(
        {for (final c in held.crates) c.name: onServer.crates[c.id]!.unwatchedAway}, {'Production': true, 'Lab': false});

    // The invitation is one the server keeps, with its end.
    final invite = (await o.service.invites(id)).single;
    expect(invite.email, mail(dave));
    expect(invite.role, member);
    expect(invite.endsAt, secondsOf(kLater));
    expect((await device(dave).service.myInvites()).single.orchardId, id);

    // The hosts reached ZestSSH Cloud: Alice, who works with Production, has them.
    final hers = await a.snapshot(id);
    expect([
      for (final h in hers.hosts) '${hers.crate(h.crateId)?.name}/${h.name} ${h.protocol} ${h.address}:${h.port}',
    ]..sort(), [
      'Production/web-1 ssh 10.50.0.11:22',
      'Production/web-2 mosh 10.50.0.12:2222',
    ]);
    expect(hers.record.members[alice.uid]!.role, isNot(member), reason: 'she is an Operator now');

    // And once more: there is nothing to change, for the owner and for her.
    plan = await planSetup(file, held);
    expect(texts(plan.problems), isEmpty);
    expect(texts(plan.steps), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('an offer the plan calls refused is one the server refuses, and one it lets through is taken', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final o = device(owner);
    final id = await o.service.createOrchard('Offers', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = (await o.service.roles(id)).single.id;
    final a = await join(o, alice, id, member);
    // Operators may invite, edit Production and use Lab; Vault is the owners'.
    var before = await o.snapshot(id);
    final plan = await planSetup(
        setupFile({
          'crates': [
            {'name': 'Lab'},
            {'name': 'Vault', 'owners_only': true},
          ],
          'roles': [
            {
              'name': 'Operators',
              'can': ['invite'],
              'crates': {'Production': 'edit', 'Lab': 'use'},
            },
            {
              'name': 'Member',
              'crates': {'Production': 'use'},
            },
          ],
          'members': [
            {'email': mail(alice), 'role': 'Operators'},
          ],
        }),
        before);
    expect(texts(plan.problems), isEmpty);
    expect((await applySetup(plan, before, o.actions(id))).complete, isTrue);
    before = await o.snapshot(id);
    final names = {for (final e in namesOf(before).entries) e.value: e.key};
    final operators = names['Operators']!;
    final production = names['Production']!;
    final lab = names['Lab']!;
    final vault = before.record.crates.values.singleWhere((c) => c.ownersOnly).id;
    await a.service.refresh();

    var offers = 0;
    Future<void> agree(
      String what,
      _Device by,
      CrateAuthor as,
      String role, {
      Map<String, Set<String>> grants = const {},
      int? endsAt,
      required bool taken,
    }) async {
      final record = (await by.snapshot(id)).record;
      final problem = offerProblem(record, as.uid, role, grants, endsAt);
      Object? refused;
      try {
        await by.service
            .invite(id, email: 'offer-${offers++}-${as.uid}@example.com', role: role, grants: grants, endsAt: endsAt);
      } on OrchardServerException catch (e) {
        refused = e;
      } on OrchardRecordRefused catch (e) {
        // (The app's own copy of the rules said no before the server was asked.)
        refused = e;
      }
      expect(problem == null, taken, reason: '$what: the plan says ${problem ?? 'nothing against it'}');
      expect(refused == null, taken, reason: '$what: the server says ${refused ?? 'nothing against it'}');
    }

    final later = secondsOf(kLater);
    // Someone who may invite, into roles below theirs, with no more than they have.
    await agree('an Operator invites a Member', a, alice, member, taken: true);
    await agree('with an end', a, alice, member, endsAt: later, taken: true);
    await agree('with a Crate more that she has herself', a, alice, member,
        grants: {lab: levelSwitches(CrateLevel.use)}, taken: true);
    await agree('into her own role', a, alice, operators, taken: false);
    await agree('as an admin', a, alice, FixedRoles.admin, taken: false);
    await agree('as an owner', a, alice, FixedRoles.owner, taken: false);
    await agree('with more of a Crate than she has', a, alice, member,
        grants: {production: levelSwitches(CrateLevel.manage)}, taken: false);
    await agree('with the owners\' Crate', a, alice, member, grants: {vault: levelSwitches(CrateLevel.use)}, taken: false);
    await agree('into a role there is none of', a, alice, '00000000-0000-4000-8000-00000000dead', taken: false);

    // An owner: anyone, but an owner does not end and needs no extra Crate.
    await agree('an owner invites an Operator', o, owner, operators, taken: true);
    await agree('an admin', o, owner, FixedRoles.admin, taken: true);
    await agree('an admin for a while', o, owner, FixedRoles.admin, endsAt: later, taken: true);
    await agree('an owner', o, owner, FixedRoles.owner, taken: true);
    await agree('an owner for a while', o, owner, FixedRoles.owner, endsAt: later, taken: false);
    await agree('an admin with a Crate more', o, owner, FixedRoles.admin,
        grants: {lab: levelSwitches(CrateLevel.use)}, taken: false);
    await agree('a Member with the owners\' Crate', o, owner, member,
        grants: {vault: levelSwitches(CrateLevel.use)}, taken: false);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

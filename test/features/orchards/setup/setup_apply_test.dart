import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';

import 'setup_world.dart';

// A setup file applied for real (3.0): the real Orchard service on
// each device, against the stand-in server that checks every entry with the
// record's rules and every key copy a change must bring.

/// Keeps what it was asked, and hands out ids in the order asked for.
class _Recorded implements SetupActions {
  final calls = <String>[];
  var _n = 0;

  /// Fails the call that starts with this.
  String? failAt;
  Object? syncFails;

  String _switches(Map<String, Set<String>>? byId) => byId == null
      ? '-'
      : '{${[for (final e in byId.entries) '${e.key}=${(e.value.toList()..sort()).join('+')}'].join(' ')}}';

  String _set(Set<String>? s) => s == null ? '-' : '[${(s.toList()..sort()).join('+')}]';

  T _did<T>(String call, T result) {
    if (failAt != null && call.startsWith(failAt!)) throw StateError('refused: $call');
    calls.add(call);
    return result;
  }

  @override
  Future<String> addCrate(String name, {required bool ownersOnly}) async =>
      _did('addCrate $name ownersOnly=$ownersOnly', 'crate-${++_n}');

  @override
  Future<void> setCrate(String crateId, CrateParts parts) async => _did(
      'setCrate $crateId open=${parts.open} allow=${_set(parts.allow)} askAgain=${parts.askAgain} '
      'logs=${parts.sessionLogs} watched=${parts.watched}',
      null);

  @override
  Future<String> addRole(String name, {required Set<String> can, required Map<String, Set<String>> crates}) async =>
      _did('addRole $name can=${_set(can)} crates=${_switches(crates)}', 'role-${++_n}');

  @override
  Future<void> setRole(String roleId, {Set<String>? can, Map<String, Set<String>>? crates}) async =>
      _did('setRole $roleId can=${_set(can)} crates=${_switches(crates)}', null);

  @override
  Future<void> orderRoles(List<String> roleIds) async => _did('orderRoles ${roleIds.join(' > ')}', null);

  @override
  Future<void> setRules(SetupRules parts) async => _did('setRules ${parts.toJson()}', null);

  @override
  Future<void> setRecords(SetupRecords parts) async => _did('setRecords ${parts.toJson()}', null);

  @override
  Future<void> setMember(String uid,
          {String? role, Map<String, Set<String>>? grants, Named<int?>? endsAt}) async =>
      _did('setMember $uid role=$role grants=${_switches(grants)} endsAt=$endsAt', null);

  @override
  Future<void> setLimit(String uid, String crateId, Set<String>? switches) async =>
      _did('setLimit $uid $crateId ${_set(switches)}', null);

  @override
  Future<void> invite(String email,
          {required String role, required Map<String, Set<String>> grants, int? endsAt}) async =>
      _did('invite $email role=$role grants=${_switches(grants)} endsAt=$endsAt', null);

  @override
  Future<String> addGroup(String crateId, String name) async => _did('addGroup $crateId $name', 'group-${++_n}');

  @override
  Future<void> addHost(String crateId,
          {required String name,
          required String address,
          required int port,
          required String protocol,
          String? keyId,
          List<String> accountIds = const [],
          String? groupId,
          required Set<String> tags}) async =>
      _did(
          'addHost $crateId $name $protocol $address:$port key=$keyId '
          '${accountIds.isEmpty ? '' : 'accounts=${accountIds.join('+')} '}group=$groupId tags=${_set(tags)}',
          null);

  @override
  Future<void> changeHost(String hostId,
          {String? address,
          int? port,
          String? protocol,
          Named<String?>? keyId,
          List<String>? accountIds,
          Named<String?>? groupId,
          Set<String>? tags}) async =>
      _did(
          'changeHost $hostId address=$address port=$port protocol=$protocol key=$keyId '
          '${accountIds == null ? '' : 'accounts=${accountIds.join('+')} '}group=$groupId tags=${_set(tags)}',
          null);

  @override
  Future<void> syncItems() async {
    final fails = syncFails;
    if (fails != null) throw fails;
    calls.add('syncItems');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  String email(String uid) => SetupWorld.emailOf(uid);

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
  });

  tearDown(() => world.stop());

  Future<SetupDevice> joined(String uid, String role, {Map<String, Set<String>> grants = const {}}) async {
    final d = world.device(uid);
    await world.join(owner, d, o.id, role, grants: grants);
    return d;
  }

  /// A team's whole setup, for an Orchard that has Production and Staging,
  /// the role Members, the key deploy, and Ada in it.
  Map<String, Object?> wholeFile() => {
        'orchard': 'Northwind Ops',
        'rules': {'reauth_days': 30, 'no_export': true},
        'records': {'history': true},
        'crates': [
          {
            'name': 'Production',
            'allow': ['sftp'],
            'ask_again': true,
            'session_logs': true,
            'hosts': [
              {'name': 'web-1', 'address': '10.50.0.11', 'key': 'deploy', 'group': 'Web', 'tags': ['prod', 'web']},
              {'name': 'web-2', 'address': '10.50.0.12', 'port': 2222, 'group': 'Web'},
            ],
          },
          {'name': 'Staging', 'watched': true},
          {'name': 'Vault', 'owners_only': true},
          {
            'name': 'Lab',
            'allow': <String>[],
            'hosts': [
              {'name': 'lab-1', 'address': '10.40.0.11', 'protocol': 'mosh'},
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
            'name': 'Members',
            'crates': {'Production': 'connect', 'Lab': 'use'},
          },
        ],
        'members': [
          {
            'email': email(SetupWorld.ada),
            'role': 'Operators',
            'crates': {'Staging': 'connect'},
            'until': kLater,
          },
          {'email': email(SetupWorld.lin), 'role': 'Members'},
        ],
      };

  const wholeSteps = [
    'crate Production: allow sftp ask again on session logs on',
    'crate Staging: watched on (allows nothing with it)',
    'add crate Vault (owners only)',
    'add crate Lab',
    'crate Lab: allow nothing',
    'add role Operators: can invite; Production="edit" Lab="manage"',
    'role Members: Production="connect" Lab="use"',
    'order roles: Operators > Members',
    'rules: {"no_export":true,"reauth_days":30}',
    'records: {"history":true}',
    'member ada@northwind.example: role Operators extra Staging="connect" until 2030-06-30T17:00:00Z',
    'invite lin@northwind.example as Members',
    'add group Web in Production',
    'add host web-1 in Production: ssh 10.50.0.11:22 key deploy group Web tags prod+web',
    'add host web-2 in Production: ssh 10.50.0.12:2222 group Web',
    'add host lab-1 in Lab: mosh 10.40.0.11:22',
  ];

  group('a whole file', () {
    test('is applied step by step; the record, the invitation and the hosts are what it says', () async {
      final ada = await joined(SetupWorld.ada, o.members);
      await owner.addKey(o.id, 'deploy', crateId: o.production);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(setupFile(wholeFile()), before);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), wholeSteps);
      expect(texts(plan.notes), ['memberNotInFile ${email(SetupWorld.owner)}']);

      final requests = world.server.appends.length;
      final seen = <String>[];
      final outcome = await applySetup(plan, before, owner.actions(o.id), onStep: (s, i) => seen.add('$i $s'));
      expect(outcome.error, isNull);
      expect(outcome.complete, isTrue);
      expect(outcome.failed, isNull);
      expect(outcome.left, isEmpty);
      expect(outcome.syncError, isNull);
      expect(texts(outcome.done), wholeSteps);
      expect(seen, [for (var i = 0; i < wholeSteps.length; i++) '$i ${wholeSteps[i]}']);

      // One request for each step that changes the record (a new Crate
      // goes in with its key, by its own request).
      expect(world.server.appends.skip(requests), [
        ['crate.set'],
        ['crate.set'],
        ['crate.set'],
        ['role.set'],
        ['role.set'],
        ['role.set'],
        ['rules.set'],
        ['tracking.set'],
        ['member.set'],
      ]);
      const record = [
        'crate Lab: allow=',
        'crate Production: allow=sftp ask-again logs',
        'crate Staging: allow= watched',
        'crate Vault: owners-only allow=forward+sftp',
        'role Operators (1000500): can=invite Lab="manage" Production="edit"',
        'role Members (1000): can= Lab="use" Production="connect"',
        'member ada: Operators extra Staging="connect" until 2030-06-30T17:00:00Z',
        'member owner-1: owner',
        'rules {"email_domains":[],"max_lock_minutes":0,"no_export":true,"offline_hours":0,"reauth_days":30,'
            '"require_2fa":false,"require_app_lock":false}',
        'records {"activity":false,"devices":false,"history":true,"ips":false}',
      ];
      expect(await world.record(owner, o.id), record);
      // What the plan rehearsed is what the record took, rank for rank.
      expect(describeRecord(plan.after, {...namesOf(before), ...plan.added}), record);

      expect(world.server.sentInvites.last.email, email(SetupWorld.lin));
      expect(world.server.sentInvites.last.role, o.members);
      expect(world.server.sentInvites.last.grants, isEmpty);
      expect(world.server.sentInvites.last.endsAt, isNull);

      const hosts = [
        'Lab/lab-1 10.40.0.11:22 mosh key=null group=null tags=',
        'Production/web-1 10.50.0.11:22 ssh key=deploy group=Web tags=prod+web',
        'Production/web-2 10.50.0.12:2222 ssh key=null group=Web tags=',
      ];
      expect(await owner.hosts(o.id), hosts);
      // They reached ZestSSH Cloud: Ada, who now works with both Crates, has them.
      expect(await ada.hosts(o.id), hosts);
    });

    test('applied again changes nothing and sends nothing', () async {
      await joined(SetupWorld.ada, o.members);
      await owner.addKey(o.id, 'deploy', crateId: o.production);
      expect((await owner.apply(o.id, wholeFile())).complete, isTrue);
      final requests = world.server.appends.length;
      final invites = world.server.sentInvites.length;
      final writes = world.server.writeCalls.length;
      final again = await owner.plan(o.id, wholeFile());
      expect(again.problems, isEmpty);
      expect(again.steps, isEmpty);
      expect(again.nothingToDo, isTrue);
      expect(texts(again.notes),
          ['invited ${email(SetupWorld.lin)}', 'memberNotInFile ${email(SetupWorld.owner)}']);
      final outcome = await owner.apply(o.id, wholeFile());
      expect(outcome.complete, isTrue);
      expect(outcome.done, isEmpty);
      expect(world.server.appends, hasLength(requests));
      expect(world.server.sentInvites, hasLength(invites));
      expect(world.server.writeCalls, hasLength(writes));
    });

    test('with something in its way is not applied at all', () async {
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      final now = await ada.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {'name': 'Lab'},
              {'name': 'Production', 'session_logs': true},
            ],
          }),
          now);
      expect(texts(plan.steps), ['add crate Lab']);
      expect(plan.canApply, isFalse);
      final actions = _Recorded();
      await expectLater(applySetup(plan, now, actions), throwsStateError);
      expect(actions.calls, isEmpty);
    });
  });

  group('the steps as they are handed on', () {
    test('each with what it names, and what an earlier step added by the id it got', () async {
      await joined(SetupWorld.ada, o.members);
      final deploy = await owner.addKey(o.id, 'deploy', crateId: o.production);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(setupFile(wholeFile()), before);
      final actions = _Recorded();
      final outcome = await applySetup(plan, before, actions);
      expect(outcome.complete, isTrue);
      final until = secondsOf(kLater);
      expect(actions.calls, [
        'setCrate ${o.production} open=false allow=[sftp] askAgain=true logs=true watched=null',
        'setCrate ${o.staging} open=false allow=- askAgain=null logs=null watched=true',
        'addCrate Vault ownersOnly=true',
        'addCrate Lab ownersOnly=false',
        'setCrate crate-2 open=false allow=[] askAgain=null logs=null watched=null',
        'addRole Operators can=[invite] crates={${o.production}=add+connect+delete+edit+forward+reveal+sftp '
            'crate-2=add+connect+delete+edit+forward+manage+reveal+sftp}',
        'setRole ${o.members} can=- crates={${o.production}=connect+forward+sftp '
            'crate-2=connect+forward+reveal+sftp}',
        'orderRoles role-3 > ${o.members}',
        'setRules {no_export: true, reauth_days: 30}',
        'setRecords {history: true}',
        'setMember ada role=role-3 grants={${o.staging}=connect+forward+sftp} endsAt=Named($until)',
        'invite ${email(SetupWorld.lin)} role=${o.members} grants={} endsAt=null',
        'addGroup ${o.production} Web',
        'addHost ${o.production} web-1 ssh 10.50.0.11:22 key=$deploy group=group-4 tags=[prod+web]',
        'addHost ${o.production} web-2 ssh 10.50.0.12:2222 key=null group=group-4 tags=[]',
        'addHost crate-2 lab-1 mosh 10.40.0.11:22 key=null group=null tags=[]',
        'syncItems',
      ]);
    });

    test('a host that changes is handed on with only what differs; no end and no key are said as none',
        () async {
      await joined(SetupWorld.ada, o.members);
      await owner.service.setMemberEndsAt(o.id, SetupWorld.ada, secondsOf(kLater));
      final deploy = await owner.addKey(o.id, 'deploy', crateId: o.production);
      final web = await owner.addGroup(o.id, 'Web', crateId: o.production);
      final h1 = await owner.addHost(o.id, 'web-1', crateId: o.production, keyId: deploy, groupId: web);
      final h2 = await owner.addHost(o.id, 'web-2', crateId: o.production);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {
                'name': 'Production',
                'hosts': [
                  {'name': 'web-1', 'key': null, 'group': null, 'tags': ['prod']},
                  {'name': 'web-2', 'address': '10.50.0.12', 'port': 2222, 'protocol': 'et', 'key': 'deploy', 'group': 'web'},
                ],
              },
            ],
            'members': [
              {'email': email(SetupWorld.ada), 'until': null},
            ],
          }),
          before);
      final actions = _Recorded();
      expect((await applySetup(plan, before, actions)).complete, isTrue);
      expect(actions.calls, [
        'setMember ada role=null grants=- endsAt=Named(null)',
        'changeHost $h1 address=null port=null protocol=null key=Named(null) group=Named(null) tags=[prod]',
        'changeHost $h2 address=10.50.0.12 port=2222 protocol=et key=Named($deploy) group=Named($web) tags=-',
        'syncItems',
      ]);
    });

    test('a group one host has added is the group the next host of that name goes into', () async {
      final h = await owner.addHost(o.id, 'web-1', crateId: o.production);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {
                'name': 'Production',
                'hosts': [
                  {'name': 'web-1', 'group': 'Edge'},
                  {'name': 'web-2', 'address': '10.50.0.12', 'group': 'EDGE'},
                ],
              },
            ],
          }),
          before);
      final actions = _Recorded();
      expect((await applySetup(plan, before, actions)).complete, isTrue);
      expect(actions.calls, [
        'addGroup ${o.production} Edge',
        'changeHost $h address=null port=null protocol=null key=null group=Named(group-1) tags=-',
        'addHost ${o.production} web-2 ssh 10.50.0.12:22 key=null group=group-1 tags=[]',
        'syncItems',
      ]);
    });

    test("a member's limits are handed on after the rest of them, each by its vault's id, one the file adds by the "
        'id it got', () async {
      await joined(SetupWorld.ada, o.members);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {'name': 'Lab'},
            ],
            'members': [
              {
                'email': email(SetupWorld.ada),
                'until': kLater,
                'limits': {
                  'Production': ['connect', 'reveal'],
                  'Lab': 'none',
                },
              },
            ],
          }),
          before);
      expect(plan.problems, isEmpty);
      final actions = _Recorded();
      expect((await applySetup(plan, before, actions)).complete, isTrue);
      expect(actions.calls, [
        'addCrate Lab ownersOnly=false',
        'setMember ada role=null grants=- endsAt=Named(${secondsOf(kLater)})',
        'setLimit ada ${o.production} [connect+reveal]',
        'setLimit ada crate-1 []',
      ]);
      // Lifted, it is handed on as none.
      final lift = SetupPlan(
          steps: [LimitMember(uid: SetupWorld.ada, email: email(SetupWorld.ada), crate: 'Staging', crateId: o.staging)],
          problems: const [],
          notes: const [],
          after: before.record);
      final lifted = _Recorded();
      expect((await applySetup(lift, before, lifted)).complete, isTrue);
      expect(lifted.calls, ['setLimit ada ${o.staging} -']);
    });

    test('nothing is synced where no host or group was written', () async {
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {'name': 'Lab'},
            ],
            'rules': {'no_export': true},
          }),
          before);
      final actions = _Recorded();
      expect((await applySetup(plan, before, actions)).complete, isTrue);
      expect(actions.calls, ['addCrate Lab ownersOnly=false', 'setRules {no_export: true}']);
    });

    test('the first step that fails stops it: what was done, what failed and what is left are said',
        () async {
      await joined(SetupWorld.ada, o.members);
      await owner.addKey(o.id, 'deploy', crateId: o.production);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(setupFile(wholeFile()), before);
      final actions = _Recorded()..failAt = 'addRole';
      final seen = <int>[];
      final outcome = await applySetup(plan, before, actions, onStep: (_, i) => seen.add(i));
      expect(outcome.complete, isFalse);
      expect(texts(outcome.done), wholeSteps.take(5));
      expect('${outcome.failed}', wholeSteps[5]);
      expect(outcome.error, isA<StateError>());
      expect(texts(outcome.left), wholeSteps.skip(6));
      expect(seen, [0, 1, 2, 3, 4, 5], reason: 'the steps after it were not started');
      expect(actions.calls, hasLength(5));
      expect(actions.calls, isNot(contains('syncItems')));
    });

    test('hosts that were written and did not sync are said, and the file counts as applied', () async {
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {
                'name': 'Production',
                'hosts': [
                  {'name': 'web-1', 'address': '10.50.0.11'},
                ],
              },
            ],
          }),
          before);
      final failure = StateError('offline');
      final outcome = await applySetup(plan, before, _Recorded()..syncFails = failure);
      expect(outcome.complete, isTrue);
      expect(outcome.done, hasLength(1));
      expect(outcome.syncError, same(failure));
    });

    test('a name nothing answers to any more fails that step, with the name', () async {
      final before = await owner.snapshot(o.id);
      SetupPlan planOf(List<SetupStep> steps) =>
          SetupPlan(steps: steps, problems: const [], notes: const [], after: before.record);
      Future<Object?> errorOf(SetupStep step) async {
        final outcome = await applySetup(planOf([step]), before, _Recorded());
        expect(outcome.failed, same(step));
        expect(outcome.done, isEmpty);
        return outcome.error;
      }

      Matcher gone(String name) => isA<SetupNameGone>().having((e) => e.name, 'name', name);
      expect(
          await errorOf(const CrateSettings(
              crate: 'Nowhere', parts: CrateParts(askAgain: true), allowsNothingWithWatching: false)),
          gone('Nowhere'));
      expect(await errorOf(const AddRole(name: 'R', can: {}, crates: {'Nowhere': {'connect'}})), gone('Nowhere'));
      expect(
          await errorOf(const ChangeMember(uid: SetupWorld.owner, email: 'x@northwind.example', role: 'Nobodies')),
          gone('Nobodies'));
      expect(await errorOf(const LimitMember(uid: SetupWorld.owner, email: 'x@northwind.example', crate: 'Nowhere')),
          gone('Nowhere'));
      expect(
          await errorOf(const Invite(email: 'x@northwind.example', role: 'Nobodies', crates: {}, again: false)),
          gone('Nobodies'));
      expect(await errorOf(const OrderRoles(order: ['Nobodies'], ids: [null])), gone('Nobodies'));
      expect(
          await errorOf(const AddHost(
              crate: 'Production', name: 'h', address: '10.50.0.11', port: 22, protocol: 'ssh', group: 'Nogroup')),
          gone('Nogroup'));
      expect(
          await errorOf(
              const ChangeHost(crate: 'Production', hostId: 'h', name: 'h', group: Named<String?>('Nogroup'))),
          gone('Nogroup'));
      expect('${const SetupNameGone('Nowhere')}', contains('Nowhere'));
      // A Crate two things are called on this device is no name to go by.
      await owner.service.renameCrate(o.id, o.staging, 'production');
      final twice = await owner.snapshot(o.id);
      final outcome = await applySetup(
          SetupPlan(steps: const [
            CrateSettings(crate: 'Production', parts: CrateParts(askAgain: true), allowsNothingWithWatching: false),
          ], problems: const [], notes: const [], after: twice.record),
          twice,
          _Recorded());
      expect(outcome.error, gone('Production'));
      // Nor is a group, where two in the host's own Crate are called the same.
      final twoGroups = before.change(groups: [
        SnapshotNamed(id: 'group-a', crateId: o.production, name: 'Web'),
        SnapshotNamed(id: 'group-b', crateId: o.production, name: 'web'),
      ]);
      final asked = _Recorded();
      final byGroup = await applySetup(
          planOf([
            const AddHost(
                crate: 'Production', name: 'h', address: '10.50.0.11', port: 22, protocol: 'ssh', group: 'Web'),
          ]),
          twoGroups,
          asked);
      expect(byGroup.error, gone('Web'));
      expect(asked.calls, isEmpty, reason: 'the host is not put into either');
      // One of that name in the host's own Crate is the one, whatever other Crates hold.
      final elsewhere = before.change(groups: [
        SnapshotNamed(id: 'group-a', crateId: o.production, name: 'Web'),
        SnapshotNamed(id: 'group-b', crateId: o.staging, name: 'Web'),
      ]);
      final found = _Recorded();
      await applySetup(
          planOf([
            const AddHost(
                crate: 'Staging', name: 'h', address: '10.30.0.11', port: 22, protocol: 'ssh', group: 'Web'),
          ]),
          elsewhere,
          found);
      expect(found.calls.first, 'addHost ${o.staging} h ssh 10.30.0.11:22 key=null group=group-b tags=[]');
    });
  });

  group('each kind of change, made for real', () {
    test('a Crate\'s settings are one entry; watching and what goes off with it are one too', () async {
      var requests = world.server.appends.length;
      expect(
          (await owner.apply(o.id, {
            'crates': [
              {'name': 'Production', 'allow': ['agent'], 'ask_again': true, 'session_logs': true},
            ],
          }))
              .complete,
          isTrue);
      expect(world.server.appends.skip(requests), [
        ['crate.set'],
      ]);
      expect((await world.record(owner, o.id)).first, 'crate Production: allow=agent ask-again logs');

      requests = world.server.appends.length;
      await owner.apply(o.id, {
        'crates': [
          {'name': 'Production', 'watched': true, 'ask_again': false},
        ],
      });
      expect(world.server.appends.skip(requests), [
        ['crate.set'],
      ]);
      expect((await world.record(owner, o.id)).first, 'crate Production: allow= logs watched');

      requests = world.server.appends.length;
      await owner.apply(o.id, {
        'crates': [
          {'name': 'Production', 'watched': false, 'allow': ['sftp', 'forward'], 'session_logs': false},
        ],
      });
      expect(world.server.appends.skip(requests), [
        ['crate.set'],
      ]);
      expect((await world.record(owner, o.id)).first, 'crate Production: allow=forward+sftp');
    });

    test('an owners-only Crate that is opened reaches the admins, with its key', () async {
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      expect((await ada.snapshot(o.id)).crates.where((c) => !c.open), hasLength(1));
      await owner.apply(o.id, {
        'crates': [
          {'name': 'Vault', 'owners_only': false},
        ],
      });
      expect(world.server.appends.last, ['crate.set']);
      final hers = await ada.snapshot(o.id);
      expect(hers.crates.map((c) => c.name), containsAll(['Production', 'Staging', 'Vault']));
    });

    test('a Crate a role gains reaches its members, with its key; one it loses leaves them', () async {
      final ada = await joined(SetupWorld.ada, o.members);
      expect((await ada.snapshot(o.id)).crates.where((c) => c.open).map((c) => c.name), ['Production']);
      await owner.apply(o.id, {
        'roles': [
          {
            'name': 'Members',
            'can': ['invite'],
            'crates': {'Staging': 'edit'},
          },
        ],
      });
      expect(world.server.appends.last, ['role.set']);
      expect((await ada.snapshot(o.id)).crates.where((c) => c.open).map((c) => c.name), ['Staging']);
      expect((await world.record(owner, o.id)).where((l) => l.startsWith('role')),
          ['role Members (1000): can=invite Staging="edit"']);
    });

    test('several roles out of place are put in order by one request', () async {
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final guests = await owner.service.saveRole(o.id, name: 'Guests', can: {}, crates: {});
      final requests = world.server.appends.length;
      await owner.apply(o.id, {
        'roles': [
          {'name': 'Guests'},
          {'name': 'Operators'},
          {'name': 'Members'},
        ],
      });
      expect(world.server.appends.skip(requests), [List.filled(6, 'role.set')]);
      expect(rolesHighestFirst(world.server.recordOf(o.id)), [guests, ops, o.members]);
      // One out of place is one entry.
      await owner.apply(o.id, {
        'roles': [
          {'name': 'Operators'},
          {'name': 'Guests'},
        ],
      });
      expect(world.server.appends.last, ['role.set']);
      expect(rolesHighestFirst(world.server.recordOf(o.id)), [ops, guests, o.members]);
    });

    test('a role the file adds between others is added and placed, and its members given it', () async {
      await joined(SetupWorld.ada, o.members);
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final outcome = await owner.apply(o.id, {
        'roles': [
          {
            'name': 'Leads',
            'can': ['invite', 'remove'],
            'crates': {'Staging': 'manage'},
          },
          {'name': 'Operators'},
        ],
        'members': [
          {'email': email(SetupWorld.ada), 'role': 'Leads'},
        ],
      });
      expect(outcome.complete, isTrue);
      final r = world.server.recordOf(o.id);
      final leads = r.members[SetupWorld.ada]!.role;
      expect(rolesHighestFirst(r), [o.members, leads, ops]);
      expect(r.roles[leads]!.can, {RoleCan.invite, RoleCan.remove});
      expect(r.roles[leads]!.crates, {o.staging: levelSwitches(CrateLevel.manage)});
      expect((await owner.service.roles(o.id)).map((v) => v.name), ['Members', 'Leads', 'Operators']);
    });

    test('rules and what the team records keep what the file does not name', () async {
      await owner.service.setRules(o.id, const RecordRules(reauthDays: 30));
      await owner.service.setTracking(o.id, const RecordTracking(history: true));
      await owner.apply(o.id, {
        'rules': {'no_export': true, 'email_domains': ['northwind.example']},
        'records': {'devices': true},
      });
      final r = world.server.recordOf(o.id);
      expect(r.rules.toBody(),
          const RecordRules(reauthDays: 30, noExport: true, emailDomains: {'northwind.example'}).toBody());
      expect(r.tracking, const RecordTracking(history: true, devices: true));
    });

    test('a member\'s role, extra Crates and end are one entry; made an admin, with the comparison', () async {
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final ada = await joined(SetupWorld.ada, o.members);
      var requests = world.server.appends.length;
      await owner.apply(o.id, {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'role': 'Operators',
            'crates': {'Staging': 'use'},
            'until': kLater,
          },
        ],
      });
      expect(world.server.appends.skip(requests), [
        ['member.set'],
      ]);
      var member = world.server.recordOf(o.id).members[SetupWorld.ada]!;
      expect(member.role, ops);
      expect(member.grants, {o.staging: levelSwitches(CrateLevel.use)});
      expect(member.endsAt, secondsOf(kLater));
      expect((await ada.snapshot(o.id)).crates.where((c) => c.open).map((c) => c.name), ['Staging']);

      // An admin: the record takes it only with the owner's comparison of
      // her keys, and her extra Crates end in the same entry.
      requests = world.server.appends.length;
      await owner.apply(o.id, {
        'members': [
          {'email': email(SetupWorld.ada), 'role': 'admin', 'until': null},
        ],
      });
      expect(world.server.appends.skip(requests), [
        ['member.set'],
      ]);
      member = world.server.recordOf(o.id).members[SetupWorld.ada]!;
      expect(member.role, FixedRoles.admin);
      expect(member.grants, isEmpty);
      expect(member.endsAt, isNull);
      expect((await ada.snapshot(o.id)).crates.where((c) => c.open).map((c) => c.name),
          unorderedEquals(['Production', 'Staging']));
    });

    test("a member's limits are entries of their own after their member.set, the very ones the member panel writes",
        () async {
      // A role made by hand: Use in Production takes extra access and a
      // limit there.
      final builders = await owner.service.saveRole(o.id,
          name: 'Builders', can: {}, crates: {o.production: {CrateSwitches.connect, CrateSwitches.add}});
      await joined(SetupWorld.ada, builders);
      final before = world.server.recordOf(o.id).copy();
      final requests = world.server.appends.length;
      final file = {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'crates': {'Production': 'use'},
            'limits': {'Production': 'use', 'Staging': 'none'},
          },
        ],
      };
      final outcome = await owner.apply(o.id, file);
      expect(outcome.complete, isTrue);
      expect(texts(outcome.done), [
        'member ${email(SetupWorld.ada)}: extra Production="use"',
        'member ${email(SetupWorld.ada)}: limit Production="use"',
        'member ${email(SetupWorld.ada)}: limit Staging="none"',
      ]);
      expect(world.server.appends.skip(requests), [
        ['member.set'],
        ['member.limit'],
        ['member.limit'],
      ]);
      final written = [
        for (final e in world.server.entriesOf(o.id).skip(before.seq)) '${e.type} ${e.bodyJson}',
      ];
      final panel = vaultPickChanges(before, SetupWorld.ada, {o.production: VaultPick.use, o.staging: VaultPick.none});
      expect(written, [for (final c in panel) '${c.type} ${canonicalJson(c.body)}']);
      final member = world.server.recordOf(o.id).members[SetupWorld.ada]!;
      expect(member.grants, {o.production: levelSwitches(CrateLevel.use)});
      expect(member.limits, {o.production: levelSwitches(CrateLevel.use), o.staging: <String>{}});
      expect(world.server.recordOf(o.id).switchesOf(SetupWorld.ada, o.production), levelSwitches(CrateLevel.use));

      // Applied again, nothing; an empty one lifts each, an entry apiece.
      expect((await owner.plan(o.id, file)).steps, isEmpty);
      final again = world.server.appends.length;
      expect(
          (await owner.apply(o.id, {
            'members': [
              {'email': email(SetupWorld.ada), 'limits': <String, Object?>{}},
            ],
          }))
              .complete,
          isTrue);
      expect(world.server.appends.skip(again), [
        ['member.limit'],
        ['member.limit'],
      ]);
      expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits, isEmpty);
    });

    test('No access takes a vault from the member; lifted, it reaches them again with its key', () async {
      final ada = await joined(SetupWorld.ada, o.members);
      Future<List<String?>> opens() async =>
          [for (final c in (await ada.snapshot(o.id)).crates) if (c.open) c.name];
      expect(await opens(), ['Production']);
      await owner.apply(o.id, {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'limits': {'Production': 'none'},
          },
        ],
      });
      expect(world.server.recordOf(o.id).switchesOf(SetupWorld.ada, o.production), isEmpty);
      expect(await opens(), isEmpty);
      await owner.apply(o.id, {
        'members': [
          {'email': email(SetupWorld.ada), 'limits': <String, Object?>{}},
        ],
      });
      expect(world.server.recordOf(o.id).switchesOf(SetupWorld.ada, o.production), levelSwitches(CrateLevel.use));
      expect(await opens(), ['Production']);
    });

    test("the first limit in a team is an owner's: the server refuses one from anyone else, and takes theirs after "
        'one', () async {
      final lin = await joined(SetupWorld.lin, FixedRoles.admin);
      await joined(SetupWorld.ada, o.members);
      final file = {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'limits': {'Production': 'connect'},
          },
        ],
      };
      final now = await lin.snapshot(o.id);
      expect(now.record.newKindsUsed, isFalse);
      final plan = await planSetup(setupFile(file), now);
      expect(plan.problems, isEmpty, reason: 'the record takes it; who goes first is the server\'s to say');
      final outcome = await applySetup(plan, now, lin.actions(o.id));
      expect(outcome.complete, isFalse);
      expect('${outcome.failed}', 'member ${email(SetupWorld.ada)}: limit Production="connect"');
      expect(outcome.error, isA<OrchardServerException>().having((e) => e.code, 'code', 'first-change-needs-owner'));
      expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits, isEmpty);
      // Once an owner has made one, the admin's goes through.
      await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.staging: VaultPick.none});
      expect((await lin.apply(o.id, file)).complete, isTrue);
      expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits, {o.production: levelSwitches(CrateLevel.connect)});
    });

    test('making someone an admin without having compared their keys is refused before anything is sent',
        () async {
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      await joined(SetupWorld.lin, o.members);
      await second.service.refresh();
      final requests = world.server.appends.length;
      await expectLater(second.service.setMemberParts(o.id, SetupWorld.lin, role: FixedRoles.admin),
          throwsA(isA<MemberNotCompared>()));
      expect(world.server.appends, hasLength(requests));
      // A part that makes nobody an owner or admin needs no comparing.
      await second.service.setMemberParts(o.id, SetupWorld.lin, endsAt: Named(secondsOf(kLater)));
      expect(world.server.recordOf(o.id).members[SetupWorld.lin]!.endsAt, secondsOf(kLater));
      // Nothing that differs is nothing sent.
      final after = world.server.appends.length;
      await second.service.setMemberParts(o.id, SetupWorld.lin, endsAt: Named(secondsOf(kLater)));
      await second.service.setCrateParts(o.id, o.production, const CrateParts(askAgain: false));
      await second.service.setRoleParts(o.id, o.members, can: {});
      await second.service.orderRoles(o.id, [o.members]);
      await second.service.setRuleParts(o.id, const SetupRules(noExport: false));
      await second.service.setRecordParts(o.id, const SetupRecords(history: false));
      expect(world.server.appends, hasLength(after));
    });

    test('an invitation goes out with what the file offers, and a changed offer replaces it', () async {
      final sent = world.server.sentInvites.length;
      await owner.apply(o.id, {
        'members': [
          {
            'email': email(SetupWorld.sam),
            'role': 'Members',
            'crates': {'Staging': 'use'},
            'until': kLater,
          },
        ],
      });
      expect(world.server.sentInvites, hasLength(sent + 1));
      var invite = (await owner.service.invites(o.id)).single;
      expect(invite.email, email(SetupWorld.sam));
      expect(invite.role, o.members);
      expect(invite.grants, {o.staging: levelSwitches(CrateLevel.use)});
      expect(invite.endsAt, secondsOf(kLater));
      await owner.apply(o.id, {
        'members': [
          {'email': email(SetupWorld.sam), 'role': 'admin'},
        ],
      });
      invite = (await owner.service.invites(o.id)).single;
      expect(invite.role, FixedRoles.admin);
      expect(invite.grants, isEmpty);
      expect(invite.endsAt, isNull);
    });

    test('a host is changed in place: its address, port, protocol, key, group and tags', () async {
      final deploy = await owner.addKey(o.id, 'deploy', crateId: o.production);
      await owner.addKey(o.id, 'backup', crateId: o.production);
      final web = await owner.addGroup(o.id, 'Web', crateId: o.production);
      await owner.addHost(o.id, 'web-1',
          crateId: o.production, address: '10.50.0.11', keyId: deploy, groupId: web, tags: {'old'});
      await owner.addHost(o.id, 'web-2', crateId: o.production, address: '10.50.0.12', keyId: deploy, groupId: web);
      await owner.sync(o.id);
      final outcome = await owner.apply(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {
                'name': 'web-1',
                'address': '10.50.0.99',
                'port': 2222,
                'protocol': 'mosh',
                'key': 'backup',
                'group': 'Edge',
                'tags': ['prod', 'web'],
              },
              {'name': 'web-2', 'key': null, 'group': null, 'tags': <String>[]},
            ],
          },
        ],
      });
      expect(outcome.complete, isTrue);
      expect(outcome.syncError, isNull);
      const hosts = [
        'Production/web-1 10.50.0.99:2222 mosh key=backup group=Edge tags=prod+web',
        'Production/web-2 10.50.0.12:22 ssh key=null group=null tags=',
      ];
      expect(await owner.hosts(o.id), hosts);
      // Another device has them the same.
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      expect(await second.hosts(o.id), hosts);
      // A host keeps what is not named: tags taken away stay away, the rest is as it was.
      await owner.apply(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'web-1', 'tags': ['prod']},
            ],
          },
        ],
      });
      expect((await owner.hosts(o.id)).first,
          'Production/web-1 10.50.0.99:2222 mosh key=backup group=Edge tags=prod');
    });

    test('a group is added in the Crate of the host that names it, not where new items go', () async {
      final outcome = await owner.apply(o.id, {
        'crates': [
          {
            'name': 'Staging',
            'hosts': [
              {'name': 'stage-1', 'address': '10.30.0.11', 'group': 'Bench'},
            ],
          },
        ],
      });
      expect(outcome.complete, isTrue);
      final now = await owner.snapshot(o.id);
      expect({for (final g in now.groups) g.name: g.crateId}, {'Bench': o.staging});
      expect(await owner.hosts(o.id), ['Staging/stage-1 10.30.0.11:22 ssh key=null group=Bench tags=']);
      // Another device finds the group there too.
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      expect({for (final g in (await second.snapshot(o.id)).groups) g.name: g.crateId}, {'Bench': o.staging});
    });

    test('a host that is written is marked with when: made then, and changed then', () async {
      final h = await owner.addHost(o.id, 'web-1', crateId: o.production, address: '10.50.0.11');
      final db = await owner.db(o.id);
      Future<(int, int)> times(String id) async {
        final row = await (db.select(db.connections)..where((c) => c.id.equals(id))).getSingle();
        return (row.createdAt.millisecondsSinceEpoch, row.updatedAt.millisecondsSinceEpoch);
      }

      final made = kSetupNow.millisecondsSinceEpoch;
      expect(await times(h), (made, made));
      final later = kSetupNow.add(const Duration(hours: 3));
      final actions = OrchardSetupActions(owner.service, o.id, clock: () => later, newId: world.newId);
      await actions.changeHost(h, port: 2222);
      expect(await times(h), (made, later.millisecondsSinceEpoch), reason: 'changed then; made when it was');
      await actions.addHost(o.production,
          name: 'web-2', address: '10.50.0.12', port: 22, protocol: 'ssh', tags: const {});
      final added = (await db.select(db.connections).get()).singleWhere((c) => c.label == 'web-2');
      expect(await times(added.id), (later.millisecondsSinceEpoch, later.millisecondsSinceEpoch));
    });
  });

  group('when a step fails for real', () {
    test('it stops there, says what was done, and the same file applied again goes on from there', () async {
      await joined(SetupWorld.ada, o.members);
      await owner.addKey(o.id, 'deploy', crateId: o.production);
      // The server wants a sign-in from the last few minutes for every
      // change to who may do what; adding a Crate needs none.
      world.server.requireRecentSignIn = true;
      final file = {
        'crates': [
          {'name': 'Lab', 'ask_again': true},
          {'name': 'Production', 'ask_again': true},
        ],
        'roles': [
          {'name': 'Operators'},
        ],
      };
      final first = await owner.apply(o.id, file);
      expect(first.complete, isFalse);
      expect(texts(first.done), ['add crate Lab']);
      expect('${first.failed}', 'crate Lab: ask again on');
      expect(first.error,
          isA<OrchardServerException>().having((e) => e.recentSignInRequired, 'recent sign-in required', isTrue));
      expect(texts(first.left),
          ['crate Production: ask again on', 'add role Operators: can nothing; no crates']);
      // The Crate that was added is there; nothing after it is.
      expect((await world.record(owner, o.id)).take(3),
          ['crate Lab: allow=forward+sftp', 'crate Production: allow=forward+sftp', 'crate Staging: allow=forward+sftp']);

      world.server.requireRecentSignIn = false;
      final plan = await owner.plan(o.id, file);
      expect(texts(plan.steps), [
        'crate Lab: ask again on',
        'crate Production: ask again on',
        'add role Operators: can nothing; no crates',
      ]);
      final second = await owner.apply(o.id, file);
      expect(second.complete, isTrue);
      expect((await owner.plan(o.id, file)).nothingToDo, isTrue);
      expect(world.server.recordOf(o.id).crates.length, 3, reason: 'the Crate was not added a second time');
    });

    test('hosts written while ZestSSH Cloud could not be reached go with the next sync', () async {
      final now = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'crates': [
              {
                'name': 'Production',
                'hosts': [
                  {'name': 'web-1', 'address': '10.50.0.11', 'group': 'Web'},
                ],
              },
            ],
          }),
          now);
      final outcome = await applySetup(
          plan, now, OrchardSetupActions(owner.service, o.id, sync: () async => throw StateError('offline')));
      expect(outcome.complete, isTrue);
      expect(outcome.syncError, isA<StateError>());
      const hosts = ['Production/web-1 10.50.0.11:22 ssh key=null group=Web tags='];
      expect(await owner.hosts(o.id), hosts);
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      expect(await second.hosts(o.id), hosts);
      // With nothing to sync with, the actions say nothing and write all the same.
      final quiet = OrchardSetupActions(owner.service, o.id);
      await quiet.syncItems();
      await quiet.addHost(o.production,
          name: 'web-2', address: '10.50.0.12', port: 22, protocol: 'ssh', tags: const {'a'});
      expect(await owner.hosts(o.id), [
        ...hosts,
        'Production/web-2 10.50.0.12:22 ssh key=null group=null tags=a',
      ]);
    });

    test('a host the Crate does not let this account write is refused by the Crate itself', () async {
      final lin = await joined(SetupWorld.lin, o.members);
      final actions = lin.actions(o.id);
      final refused = throwsA(predicate((e) => '$e'.contains('orchard-access'), 'refused by the Crate'));
      await expectLater(
          actions.addHost(o.production,
              name: 'web-1', address: '10.50.0.11', port: 22, protocol: 'ssh', tags: const {}),
          refused);
      await expectLater(actions.addGroup(o.production, 'Web'), refused);
      expect(await lin.hosts(o.id), isEmpty);
    });
  });
}

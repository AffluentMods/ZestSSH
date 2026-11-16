import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';

import 'setup_world.dart';

// An Orchard written as a setup file (3.0): what comes out reads,
// changes nothing where it came from, and never says less than is there.

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

  Future<SetupDevice> joined(String uid, String role,
      {Map<String, Set<String>> grants = const {}, int? endsAt}) async {
    final d = world.device(uid);
    await world.join(owner, d, o.id, role, grants: grants, endsAt: endsAt);
    return d;
  }

  /// The file [now] is written as: read back as a file is, and compared
  /// with [now] it changes nothing.
  Future<SetupExport> exported(OrchardSnapshot now) async {
    final export = exportSetup(now);
    final read = readSetupFile(export.text);
    expect(read.problems, isEmpty, reason: 'what is written reads');
    expect(writeSetupFile(read.file!), export.text, reason: 'and reads as itself');
    final plan = await planSetup(read.file!, now);
    expect(texts(plan.problems), isEmpty, reason: 'nothing stands in its way');
    expect(texts(plan.steps), isEmpty, reason: 'it changes nothing where it came from');
    return export;
  }

  test('a new Orchard is written with all of it named', () async {
    final export = await exported(await owner.snapshot(o.id));
    expect(export.leftOut, isEmpty);
    expect(export.text, '''
{
  "zestssh_setup": 1,
  "orchard": "Northwind Ops",
  "rules": {
    "require_2fa": false,
    "email_domains": [],
    "require_app_lock": false,
    "max_lock_minutes": 0,
    "no_export": false,
    "offline_hours": 0,
    "reauth_days": 0,
    "require_sso": false,
    "trusted_devices": false
  },
  "records": {
    "history": false,
    "activity": false,
    "devices": false,
    "ips": false
  },
  "crates": [
    {
      "name": "Production",
      "owners_only": false,
      "allow": [
        "forward",
        "sftp"
      ],
      "ask_again": false,
      "session_logs": false,
      "watched": false,
      "unwatched_away": false,
      "offline_hours": 0,
      "hosts": []
    },
    {
      "name": "Staging",
      "owners_only": false,
      "allow": [
        "forward",
        "sftp"
      ],
      "ask_again": false,
      "session_logs": false,
      "watched": false,
      "unwatched_away": false,
      "offline_hours": 0,
      "hosts": []
    }
  ],
  "roles": [
    {
      "name": "Members",
      "can": [],
      "crates": {
        "Production": "use"
      }
    }
  ],
  "members": [
    {
      "email": "owner-1@northwind.example",
      "role": "owner"
    }
  ]
}
''');
  });

  test('a team at work is written whole: settings, roles in order, members by seniority, hosts by name',
      () async {
    await owner.service.setRules(
        o.id, const RecordRules(reauthDays: 30, noExport: true, emailDomains: {'northwind.example'}));
    await owner.service.setTracking(o.id, const RecordTracking(history: true, devices: true));
    final vault = await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
    await owner.service.setCrateParts(o.id, o.production,
        const CrateParts(allow: {CrateSwitches.sftp, CrateSwitches.agent}, askAgain: true, sessionLogs: true));
    await owner.service.setCrateWatched(o.id, o.staging, true);
    final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {
      RoleCan.invite,
      RoleCan.remove,
    }, crates: {
      o.production: {...levelSwitches(CrateLevel.edit), CrateSwitches.agent},
      o.staging: {CrateSwitches.connect, CrateSwitches.reveal},
    });
    await owner.service.orderRoles(o.id, [ops, o.members]);
    await joined(SetupWorld.second, FixedRoles.owner);
    await joined(SetupWorld.sam, FixedRoles.admin, endsAt: secondsOf(kLater));
    await joined(SetupWorld.lin, o.members, grants: {o.staging: levelSwitches(CrateLevel.connect)});
    await joined(SetupWorld.ada, ops);
    // Someone invited is not a member yet: not in the file.
    await owner.service.invite(o.id, email: 'kai@northwind.example', role: o.members);

    final deploy = await owner.addKey(o.id, 'deploy', crateId: o.production);
    final web = await owner.addGroup(o.id, 'Web', crateId: o.production);
    await owner.addHost(o.id, 'web-2', crateId: o.production, address: '10.50.0.12', port: 2222, protocol: 'mosh');
    await owner.addHost(o.id, 'Web-1',
        crateId: o.production, address: '10.50.0.11', keyId: deploy, groupId: web, tags: {'web', 'prod'});
    await owner.addHost(o.id, 'safe-1', crateId: vault, address: '10.90.0.1', keyId: deploy);

    final now = await owner.snapshot(o.id);
    final export = await exported(now);
    expect(export.leftOut, isEmpty);
    final file = export.file;
    expect(file.orchard, 'Northwind Ops');
    expect(file.rules!.toJson(), SetupRules.of(now.record.rules).toJson());
    expect(file.rules!.reauthDays, 30);
    expect(file.rules!.emailDomains, {'northwind.example'});
    expect(file.records!.toJson(), {'history': true, 'activity': false, 'devices': true, 'ips': false});

    expect(file.crates!.map((c) => c.name), ['Production', 'Staging', 'Vault']);
    final production = file.crates![0];
    expect(production.toJson()..remove('hosts'), {
      'name': 'Production',
      'owners_only': false,
      'allow': ['agent', 'sftp'],
      'ask_again': true,
      'session_logs': true,
      'watched': false,
      'unwatched_away': false,
      'offline_hours': 0,
    });
    expect([for (final h in production.hosts!) h.toJson()], [
      {
        'name': 'Web-1',
        'address': '10.50.0.11',
        'port': 22,
        'protocol': 'ssh',
        'key': 'deploy',
        'group': 'Web',
        'tags': ['prod', 'web'],
      },
      {
        'name': 'web-2',
        'address': '10.50.0.12',
        'port': 2222,
        'protocol': 'mosh',
        'key': null,
        'group': null,
        'tags': <String>[],
      },
    ]);
    expect(file.crates![1].toJson(), {
      'name': 'Staging',
      'owners_only': false,
      'allow': <String>[],
      'ask_again': false,
      'session_logs': false,
      'watched': true,
      'unwatched_away': false,
      'offline_hours': 0,
      'hosts': <Object?>[],
    });
    expect(file.crates![2].ownersOnly, isTrue);
    // A key of another Crate is the one key of that name: it is named.
    expect(file.crates![2].hosts!.single.toJson()['key'], 'deploy');

    expect([for (final r in file.roles!) r.toJson()], [
      {
        'name': 'Operators',
        'can': ['invite', 'remove'],
        'crates': {
          'Production': 'edit+agent',
          'Staging': ['connect', 'reveal'],
        },
      },
      {
        'name': 'Members',
        'can': <String>[],
        'crates': {'Production': 'use'},
      },
    ]);
    // Owners, then admins, then by role, highest first; by address among equals.
    expect([for (final m in file.members!) m.toJson()], [
      {'email': email(SetupWorld.owner), 'role': 'owner'},
      {'email': email(SetupWorld.second), 'role': 'owner'},
      {'email': email(SetupWorld.sam), 'role': 'admin', 'until': kLater},
      {'email': email(SetupWorld.ada), 'role': 'Operators'},
      {
        'email': email(SetupWorld.lin),
        'role': 'Members',
        'crates': {'Staging': 'connect'},
      },
    ]);
    // No extra Crates and no end are not said: a file that says them holds
    // a member to them.
    expect(file.members![3].crates, isNull);
    expect(file.members![3].until, isNull);
    expect(file.members![2].until, Named<int?>(secondsOf(kLater)));
  });

  test('what an account cannot open is left out, and a part that reaches it is not written at all', () async {
    // Lin opens Production; Staging is closed to them. Their role gives
    // something there to others, and Ada holds an extra Crate there.
    final builders = await owner.service.saveRole(o.id,
        name: 'Builders', can: {}, crates: {o.production: levelSwitches(CrateLevel.use)});
    final wide = await owner.service.saveRole(o.id, name: 'Wide', can: {}, crates: {
      o.production: levelSwitches(CrateLevel.use),
      o.staging: levelSwitches(CrateLevel.use),
    });
    await joined(SetupWorld.ada, builders, grants: {o.staging: levelSwitches(CrateLevel.edit)});
    await joined(SetupWorld.sam, wide);
    final lin = await joined(SetupWorld.lin, builders);
    await owner.addHost(o.id, 'stage-1', crateId: o.staging);
    await owner.sync(o.id);
    final now = await lin.snapshot(o.id);
    final export = await exported(now);
    expect(texts(export.leftOut), [
      'closedCrates 1',
      'partsNotWritten Wide,${email(SetupWorld.ada)}',
    ]);
    expect(export.file.crates!.map((c) => c.name), ['Production']);
    final roles = {for (final r in export.file.roles!) r.name: r};
    expect(roles.keys, ['Members', 'Builders', 'Wide']);
    expect(roles['Builders']!.crates, {'Production': levelSwitches(CrateLevel.use)});
    expect(roles['Wide']!.crates, isNull, reason: 'half of what it gives would read as all of it');
    expect(roles['Wide']!.toJson().containsKey('crates'), isFalse);
    expect(roles['Wide']!.can, isEmpty);
    final members = {for (final m in export.file.members!) m.email: m};
    expect(members[email(SetupWorld.ada)]!.role, 'Builders');
    expect(members[email(SetupWorld.ada)]!.crates, isNull);
    expect(members[email(SetupWorld.ada)]!.toJson().containsKey('crates'), isFalse);
    expect(members[email(SetupWorld.sam)]!.role, 'Wide');
    expect(members[email(SetupWorld.lin)]!.toJson(), {'email': email(SetupWorld.lin), 'role': 'Builders'});
    // The same Orchard from an owner's device has all of it.
    final whole = await exported(await owner.snapshot(o.id));
    expect(whole.leftOut, isEmpty);
    expect(whole.file.crates!.map((c) => c.name), ['Production', 'Staging']);
    expect({for (final r in whole.file.roles!) r.name: r}['Wide']!.crates, hasLength(2));
    expect({for (final m in whole.file.members!) m.email: m}[email(SetupWorld.ada)]!.crates,
        {'Staging': levelSwitches(CrateLevel.edit)});
    expect(builders, isNot(wide));
  });

  test("a member's limits are written beside their extra vaults, by name, No access as none; such a file is "
      'version 2, reads back as itself, and changes nothing', () async {
    final builders = await owner.service.saveRole(o.id,
        name: 'Builders', can: {}, crates: {o.production: {CrateSwitches.connect, CrateSwitches.add}});
    await joined(SetupWorld.ada, builders);
    await joined(SetupWorld.lin, o.members);
    // A role made by hand set to Use: extra access and a limit in one vault.
    await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.production: VaultPick.use});
    // Lin: Staging taken away first, then held to Connect in Production.
    await owner.service.setVaultAccess(o.id, SetupWorld.lin, {o.staging: VaultPick.none});
    await owner.service.setVaultAccess(o.id, SetupWorld.lin, {o.production: VaultPick.connect});
    final export = await exported(await owner.snapshot(o.id));
    expect(export.leftOut, isEmpty);
    expect(export.file.version, kSetupFileLimitsVersion);
    expect(export.text, startsWith('{\n  "zestssh_setup": 2,'));
    final members = {for (final m in export.file.members!) m.email: m.toJson()};
    expect(members[email(SetupWorld.ada)], {
      'email': email(SetupWorld.ada),
      'role': 'Builders',
      'crates': {'Production': 'use'},
      'limits': {'Production': 'use'},
    });
    expect(members[email(SetupWorld.lin)], {
      'email': email(SetupWorld.lin),
      'role': 'Members',
      'limits': {'Production': 'connect', 'Staging': 'none'},
    });
    expect((members[email(SetupWorld.lin)]!['limits'] as Map).keys, ['Production', 'Staging'],
        reason: 'by name, as everything in the file, not in the order they were set');
    expect(members[email(SetupWorld.owner)], {'email': email(SetupWorld.owner), 'role': 'owner'});
    // Limits beside the extra access in the text, as a file has them.
    expect(export.text, contains('"crates": {\n        "Production": "use"\n      },\n      "limits": {'));

    // All of them put back to the role: the file is version 1 again.
    await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.production: VaultPick.fromRole});
    await owner.service.setVaultAccess(o.id, SetupWorld.lin, {o.production: VaultPick.fromRole, o.staging: VaultPick.fromRole});
    final plain = await exported(await owner.snapshot(o.id));
    expect(plain.text, startsWith('{\n  "zestssh_setup": 1,'));
    expect(plain.text, isNot(contains('"limits"')));
  });

  test('limits that reach a vault this account cannot open are not written at all, and that is said', () async {
    final builders = await owner.service.saveRole(o.id,
        name: 'Builders', can: {}, crates: {o.production: levelSwitches(CrateLevel.use)});
    await joined(SetupWorld.ada, builders);
    final lin = await joined(SetupWorld.lin, builders);
    // Ada is held in Production, which Lin opens, and in Staging, which Lin
    // does not.
    await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.production: VaultPick.connect, o.staging: VaultPick.none});
    final export = await exported(await lin.snapshot(o.id));
    expect(texts(export.leftOut), ['closedCrates 1', 'partsNotWritten ${email(SetupWorld.ada)}']);
    final ada = {for (final m in export.file.members!) m.email: m}[email(SetupWorld.ada)]!;
    expect(ada.limits, isNull, reason: 'half of them would read as all of them');
    expect(ada.toJson(), {'email': email(SetupWorld.ada), 'role': 'Builders'});
    expect(export.file.version, kSetupFileFirstVersion);
    // From the owner's device, all of them.
    final whole = await exported(await owner.snapshot(o.id));
    expect(whole.leftOut, isEmpty);
    expect({for (final m in whole.file.members!) m.email: m}[email(SetupWorld.ada)]!.limits, {
      'Production': levelSwitches(CrateLevel.connect),
      'Staging': <String>{},
    });
  });

  test('a name that stands for more than one thing names neither', () async {
    await owner.service.renameCrate(o.id, o.staging, 'production');
    final lab = await owner.service.createCrate(o.id, 'Lab');
    await owner.service.saveRole(o.id, name: 'MEMBERS', can: {}, crates: {});
    final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {
      lab: levelSwitches(CrateLevel.use),
      o.staging: levelSwitches(CrateLevel.use),
    });
    await joined(SetupWorld.ada, o.members);
    await joined(SetupWorld.lin, ops, grants: {o.production: levelSwitches(CrateLevel.use)});
    await owner.addHost(o.id, 'web-1', crateId: lab, address: '10.40.0.11');
    await owner.addHost(o.id, 'WEB-1', crateId: lab, address: '10.40.0.12');
    await owner.addHost(o.id, 'web-2', crateId: lab, address: '10.40.0.13');
    final export = await exported(await owner.snapshot(o.id));
    // Each way the name is written, once; then the parts, in the file's order.
    expect(texts(export.leftOut), [
      'sharedNames Production,production,WEB-1,web-1,Members,MEMBERS',
      'partsNotWritten Operators,${email(SetupWorld.ada)},${email(SetupWorld.lin)}',
    ]);
    expect(export.file.crates!.map((c) => c.name), ['Lab']);
    expect(export.file.crates!.single.hosts!.map((h) => h.name), ['web-2']);
    expect(export.file.roles!.map((r) => r.name), ['Operators']);
    expect(export.file.roles!.single.crates, isNull);
    final members = {for (final m in export.file.members!) m.email: m};
    // A member of a role the file cannot name is in it without a role.
    expect(members[email(SetupWorld.ada)]!.toJson(), {'email': email(SetupWorld.ada)});
    expect(members[email(SetupWorld.lin)]!.toJson(), {'email': email(SetupWorld.lin), 'role': 'Operators'});
  });

  test('a role called like one of the Orchard\'s own two is left out, and its members are in without a role',
      () async {
    final admins = await owner.service.saveRole(o.id, name: 'Admin', can: {}, crates: {});
    await owner.service.saveRole(o.id, name: 'owner', can: {}, crates: {});
    await joined(SetupWorld.ada, admins);
    await joined(SetupWorld.lin, FixedRoles.admin);
    final export = await exported(await owner.snapshot(o.id));
    expect(texts(export.leftOut), ['rolesLikeOwn Admin,owner', 'partsNotWritten ${email(SetupWorld.ada)}']);
    expect(export.file.roles!.map((r) => r.name), ['Members']);
    final members = {for (final m in export.file.members!) m.email: m};
    expect(members[email(SetupWorld.ada)]!.role, isNull);
    expect(members[email(SetupWorld.lin)]!.role, 'admin');
  });

  test('names, hosts and keys a file cannot carry are left out or not said', () async {
    final tab = String.fromCharCode(9);
    final turn = String.fromCharCode(0x202e);
    final first = await owner.addKey(o.id, 'deploy', crateId: o.production);
    await owner.addKey(o.id, 'DEPLOY', crateId: o.production);
    final odd = await owner.addKey(o.id, 'ba${tab}ckup', crateId: o.production);
    final group = await owner.addGroup(o.id, 'We${turn}b', crateId: o.production);
    await owner.addHost(o.id, 'fine', crateId: o.production, address: '10.50.0.10');
    await owner.addHost(o.id, 'web${turn}1', crateId: o.production, address: '10.50.0.11');
    await owner.addHost(o.id, 'two words', crateId: o.production, address: '10.50.0.12 10.50.0.13');
    await owner.addHost(o.id, 'console', crateId: o.production, protocol: 'serial');
    await owner.addHost(o.id, 'shell', crateId: o.production, protocol: 'localShell');
    await owner.addHost(o.id, 'a-shared-key', crateId: o.production, address: '10.50.0.14', keyId: first);
    await owner.addHost(o.id, 'an-odd-key', crateId: o.production, address: '10.50.0.15', keyId: odd);
    await owner.addHost(o.id, 'an-odd-group', crateId: o.production, address: '10.50.0.16', groupId: group);
    await owner.addHost(o.id, 'port-0', crateId: o.production, address: '10.50.0.17', port: 0);
    final export = await exported(await owner.snapshot(o.id));
    expect(texts(export.leftOut), [
      'unwritableNames 2',
      'otherHosts 2',
      'partsNotWritten a-shared-key,an-odd-group,an-odd-key,port-0',
    ]);
    final hosts = {for (final h in export.file.crates!.first.hosts!) h.name: h.toJson()};
    expect(hosts.keys, ['a-shared-key', 'an-odd-group', 'an-odd-key', 'fine', 'port-0']);
    expect(hosts['fine'], {
      'name': 'fine',
      'address': '10.50.0.10',
      'port': 22,
      'protocol': 'ssh',
      'key': null,
      'group': null,
      'tags': <String>[],
    });
    // Not said, so that applying the file leaves it as it is.
    expect(hosts['a-shared-key']!.containsKey('key'), isFalse);
    expect(hosts['a-shared-key']!.containsKey('group'), isTrue);
    expect(hosts['a-shared-key']!['group'], isNull);
    expect(hosts['an-odd-key']!.containsKey('key'), isFalse);
    expect(hosts['an-odd-group']!.containsKey('group'), isFalse);
    expect(hosts['port-0']!.containsKey('port'), isFalse);
    expect(hosts['port-0']!['protocol'], 'ssh');
  });

  test('a host that is SFTP only is written as one, and is no host the file leaves out', () async {
    await owner.addHost(o.id, 'files-01', crateId: o.production, address: '192.0.2.20', port: 2222, protocol: 'sftp');
    final export = await exported(await owner.snapshot(o.id));
    expect(export.leftOut, isEmpty);
    expect([for (final h in export.file.crates!.first.hosts!) h.toJson()], [
      {
        'name': 'files-01',
        'address': '192.0.2.20',
        'port': 2222,
        'protocol': 'sftp',
        'key': null,
        'group': null,
        'tags': <String>[],
      },
    ]);
  });

  test('an Orchard, a Crate or a role with a name a file cannot carry is not named in it', () async {
    final tab = String.fromCharCode(9);
    final turn = String.fromCharCode(0x202e);
    await joined(SetupWorld.ada, o.members);
    final now = await owner.snapshot(o.id);
    final strange = now.change(
      name: 'North${turn}wind',
      crates: [
        for (final c in now.crates) c.id == o.staging ? SnapshotCrate(id: c.id, name: 'Sta${tab}ging') : c,
      ],
      roles: [SnapshotRole(id: o.members, name: 'x' * 51)],
    );
    final export = await exported(strange);
    expect(texts(export.leftOut), ['unwritableNames 2', 'partsNotWritten ${email(SetupWorld.ada)}']);
    expect(export.file.orchard, isNull, reason: 'a file that names no Orchard is for any');
    expect(export.file.crates!.map((c) => c.name), ['Production']);
    expect(export.file.roles, isEmpty);
    expect(export.text, isNot(contains('orchard')));
    // Names with spaces at the ends are written without them.
    final spaced = now.change(
      name: '  Northwind Ops ',
      crates: [
        for (final c in now.crates) SnapshotCrate(id: c.id, name: ' ${c.name}  '),
      ],
      roles: [SnapshotRole(id: o.members, name: ' Members ')],
    );
    final trimmed = await exported(spaced);
    expect(trimmed.leftOut, isEmpty);
    expect(trimmed.file.orchard, 'Northwind Ops');
    expect(trimmed.file.crates!.map((c) => c.name), ['Production', 'Staging']);
    expect(trimmed.file.roles!.single.name, 'Members');
    expect(trimmed.file.roles!.single.crates!.keys, ['Production']);
  });

  test('roles whose names cannot be read, and members without an address, are counted and left out',
      () async {
    await joined(SetupWorld.ada, o.members);
    final now = await owner.snapshot(o.id);
    final blind = now.change(
      roles: [SnapshotRole(id: o.members)],
      members: [
        for (final m in now.members)
          m.uid == SetupWorld.owner ? SnapshotMember(uid: m.uid) : m,
      ],
    );
    final export = await exported(blind);
    expect(texts(export.leftOut), [
      'unreadRoles 1',
      'partsNotWritten ${email(SetupWorld.ada)}',
      'membersWithoutAddress 1',
    ]);
    expect(export.file.roles, isEmpty);
    expect([for (final m in export.file.members!) m.toJson()], [
      {'email': email(SetupWorld.ada)},
    ]);
    // An address ZestSSH Cloud would not take is no address to name someone by.
    final odd = now.change(members: [
      for (final m in now.members)
        m.uid == SetupWorld.ada ? SnapshotMember(uid: m.uid, email: 'ada at northwind') : m,
    ]);
    expect(texts((await exported(odd)).leftOut), ['membersWithoutAddress 1']);
    // Someone removed is not a member any more.
    await owner.service.removeMember(o.id, SetupWorld.ada);
    final after = await exported(await owner.snapshot(o.id));
    expect(after.file.members!.map((m) => m.email), [email(SetupWorld.owner)]);
    expect(after.leftOut, isEmpty);
  });

  test('a key or a group is named only where its name leads back to it', () async {
    final lab = await owner.service.createCrate(o.id, 'Lab');
    final prodKey = await owner.addKey(o.id, 'deploy', crateId: o.production);
    final stageKey = await owner.addKey(o.id, 'deploy', crateId: o.staging);
    final only = await owner.addKey(o.id, 'backup', crateId: o.staging);
    final g1 = await owner.addGroup(o.id, 'Web', crateId: o.production);
    final g2 = await owner.addGroup(o.id, 'Web', crateId: o.staging);
    // In its own Crate: the key of that name there.
    await owner.addHost(o.id, 'a', crateId: o.production, keyId: prodKey, groupId: g1);
    await owner.addHost(o.id, 'b', crateId: o.staging, keyId: stageKey, groupId: g2);
    // From another Crate: the one key of that name is named...
    await owner.addHost(o.id, 'c', crateId: o.production, keyId: only);
    // ...a name its own Crate gives to another key is not, and one two
    // other Crates share is not either.
    await owner.addHost(o.id, 'd', crateId: o.production, keyId: stageKey, groupId: g2);
    await owner.addHost(o.id, 'e', crateId: lab, keyId: prodKey, groupId: g1);
    final export = await exported(await owner.snapshot(o.id));
    expect(texts(export.leftOut), ['partsNotWritten e,d']);
    final hosts = {
      for (final c in export.file.crates!)
        for (final h in c.hosts!) h.name: h,
    };
    expect(hosts['a']!.key, const Named<String?>('deploy'));
    expect(hosts['a']!.group, const Named<String?>('Web'));
    expect(hosts['b']!.key, const Named<String?>('deploy'));
    expect(hosts['b']!.group, const Named<String?>('Web'));
    expect(hosts['c']!.key, const Named<String?>('backup'));
    expect(hosts['c']!.group, const Named<String?>(null));
    expect(hosts['d']!.key, isNull);
    expect(hosts['d']!.group, isNull);
    expect(hosts['e']!.key, isNull);
    expect(hosts['e']!.group, isNull);
  });

  test('names stand in the order people read them, capitals or not', () async {
    await owner.service.createCrate(o.id, 'alpha lab');
    await owner.addHost(o.id, 'beta', crateId: o.production, address: '10.50.0.12');
    await owner.addHost(o.id, 'Alpha', crateId: o.production, address: '10.50.0.11');
    await owner.addHost(o.id, 'alpha-2', crateId: o.production, address: '10.50.0.13');
    await owner.addHost(o.id, 'Gamma', crateId: o.production, address: '10.50.0.14');
    final export = await exported(await owner.snapshot(o.id));
    expect(export.leftOut, isEmpty);
    expect(export.file.crates!.map((c) => c.name), ['alpha lab', 'Production', 'Staging']);
    expect(export.file.crates![1].hosts!.map((h) => h.name), ['Alpha', 'alpha-2', 'beta', 'Gamma']);
  });

  test('a name two things are called in the very same letters is said once', () async {
    final lab = await owner.service.createCrate(o.id, 'Lab');
    final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
    final now = await owner.snapshot(o.id);
    SnapshotHost host(String id) =>
        SnapshotHost(id: id, crateId: lab, name: 'web-1', address: '10.40.0.11', port: 22, protocol: 'ssh');
    final twins = now.change(
      crates: [
        for (final c in now.crates) c.id == o.staging ? SnapshotCrate(id: c.id, name: 'Production') : c,
      ],
      roles: [SnapshotRole(id: o.members, name: 'Members'), SnapshotRole(id: ops, name: 'Members')],
      hosts: [host('host-a'), host('host-b')],
    );
    final export = await exported(twins);
    expect(texts(export.leftOut), ['sharedNames Production,web-1,Members']);
    expect(export.file.crates!.map((c) => c.name), ['Lab']);
    expect(export.file.crates!.single.hosts, isEmpty);
    expect(export.file.roles, isEmpty);
  });

  test('each setting of a Crate is written as itself', () async {
    await owner.service.setCrateParts(o.id, o.production, const CrateParts(askAgain: true));
    await owner.service.setCrateParts(o.id, o.staging, const CrateParts(sessionLogs: true, allow: {}));
    await owner.service.setCrateOfflineLimit(o.id, o.staging, 72);
    await owner.service.setCrateUnwatchedAway(o.id, o.staging, true);
    final export = await exported(await owner.snapshot(o.id));
    expect(export.file.crates![0].toJson()..remove('hosts'), {
      'name': 'Production',
      'owners_only': false,
      'allow': ['forward', 'sftp'],
      'ask_again': true,
      'session_logs': false,
      'watched': false,
      'unwatched_away': false,
      'offline_hours': 0,
    });
    expect(export.file.crates![1].toJson()..remove('hosts'), {
      'name': 'Staging',
      'owners_only': false,
      'allow': <String>[],
      'ask_again': false,
      'session_logs': true,
      'watched': false,
      'unwatched_away': true,
      'offline_hours': 72,
    });
  });

  test('a host is written with as much of it as a file carries, and not at all without an address it carries',
      () async {
    final turn = String.fromCharCode(0x202e);
    var n = 0;
    SnapshotHost host(String name, {String? address, int port = 22, Set<String> tags = const {}}) => SnapshotHost(
          id: 'host-${++n}',
          crateId: o.production,
          name: name,
          address: address ?? '10.50.0.${n + 10}',
          port: port,
          protocol: 'ssh',
          tags: tags,
        );
    final now = await owner.snapshot(o.id);
    final odd = now.change(hosts: [
      host('no-address', address: ''),
      host('odd-address', address: '10.20${turn}0.11'),
      host('long-address', address: 'a' * (kSetupMaxItemName + 1)),
      host('longest-address', address: 'a' * kSetupMaxItemName),
      host('port-1', port: 1),
      host('port-max', port: 65535),
      host('port-over', port: 65536),
      host('tags-max', tags: {for (var i = 0; i < kSetupMaxTags; i++) 'tag-$i'}),
      host('tags-over', tags: {for (var i = 0; i <= kSetupMaxTags; i++) 'tag-$i'}),
      host('tag-capitals', tags: {'prod', 'Web'}),
    ]);
    final export = await exported(odd);
    expect(texts(export.leftOut), ['unwritableNames 3', 'partsNotWritten port-over,tag-capitals,tags-over']);
    final hosts = {for (final h in export.file.crates!.first.hosts!) h.name: h.toJson()};
    expect(hosts.keys,
        ['longest-address', 'port-1', 'port-max', 'port-over', 'tag-capitals', 'tags-max', 'tags-over']);
    expect(hosts['port-1']!['port'], 1);
    expect(hosts['port-max']!['port'], 65535);
    expect(hosts['port-over']!.containsKey('port'), isFalse);
    expect(hosts['tags-max']!['tags'], hasLength(kSetupMaxTags));
    expect(hosts['tags-over']!.containsKey('tags'), isFalse);
    expect(hosts['tag-capitals']!.containsKey('tags'), isFalse);
  });

  test('members: who was removed is not written, an address is in small letters, equals go by address',
      () async {
    // From the second owner's device: this account is listed first there,
    // and is not the first of the owners by address.
    final second = await joined(SetupWorld.second, FixedRoles.owner);
    await joined(SetupWorld.ada, o.members);
    await joined(SetupWorld.lin, o.members);
    await owner.service.removeMember(o.id, SetupWorld.lin);
    final now = await second.snapshot(o.id);
    expect(now.members.map((m) => m.uid), [SetupWorld.second, SetupWorld.owner, SetupWorld.ada]);
    final loud = now.change(members: [
      for (final m in now.members)
        m.uid == SetupWorld.ada ? SnapshotMember(uid: m.uid, email: ' Ada@Northwind.EXAMPLE ') : m,
      // Still listed on this device, as the record no longer has them.
      SnapshotMember(uid: SetupWorld.lin, email: email(SetupWorld.lin)),
    ]);
    final export = await exported(loud);
    expect(export.leftOut, isEmpty);
    expect([for (final m in export.file.members!) m.toJson()], [
      {'email': email(SetupWorld.owner), 'role': 'owner'},
      {'email': email(SetupWorld.second), 'role': 'owner'},
      {'email': email(SetupWorld.ada), 'role': 'Members'},
    ]);
  });

  test('an Orchard with more in it than a file holds is not written as a file that does not read', () async {
    final now = await owner.snapshot(o.id);
    List<SnapshotHost> hosts(int count) => [
          for (var i = 0; i < count; i++)
            SnapshotHost(
              id: 'host-$i',
              crateId: o.production,
              name: 'web-$i',
              address: '10.50.${i ~/ 250}.${i % 250 + 1}',
              port: 22,
              protocol: 'ssh',
            ),
        ];
    expect(() => exportSetup(now.change(hosts: hosts(kSetupMaxHosts + 1))), throwsStateError);
    // As many as a file holds are written.
    final fits = exportSetup(now.change(hosts: hosts(kSetupMaxHosts)));
    expect(fits.file.crates!.first.hosts, hasLength(kSetupMaxHosts));
    expect(readSetupFile(fits.text).ok, isTrue);
  });

  test('what is left out is said in one order, each kind once', () {
    expect('${const SetupLeftOut(SetupLeftOutKind.closedCrates, count: 2)}', 'closedCrates 2');
    expect('${const SetupLeftOut(SetupLeftOutKind.sharedNames, names: ['a', 'b'])}', 'sharedNames a,b');
    expect(SetupLeftOutKind.values.map((k) => k.name), [
      'closedCrates',
      'sharedNames',
      'unwritableNames',
      'otherHosts',
      'unreadRoles',
      'rolesLikeOwn',
      'partsNotWritten',
      'membersWithoutAddress',
    ]);
  });
}

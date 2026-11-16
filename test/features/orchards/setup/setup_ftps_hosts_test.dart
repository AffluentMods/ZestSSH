import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'setup_world.dart';

// FTPS hosts in a setup file (3.4.1): `ftps` (explicit TLS, port 21 by
// default) and `ftps-implicit` (TLS from the first byte, port 990), named
// with their address, port and login (a key's name, as an SSH host names
// its own) like any host. A file that names one is written as version 3, so
// an app from before it says the file is for a newer app; a file without
// one stays version 1 or 2. Exports write them; a file adds and changes
// them under the team's rules; a team's host never turns from FTPS into
// another kind, or back.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
    await owner.addKey(o.id, 'files-login', crateId: o.production);
  });

  tearDown(() => world.stop());

  Map<String, Object?> hostsOf(String crate, List<Map<String, Object?>> list) => {
        'crates': [
          {'name': crate, 'hosts': list},
        ],
      };

  final both = hostsOf('Production', [
    {'name': 'files-1', 'address': 'files1.northwind.example', 'protocol': 'ftps', 'key': 'files-login'},
    {
      'name': 'files-2',
      'address': 'files2.northwind.example',
      'protocol': 'FTPS-Implicit',
      'key': 'files-login',
      'tags': ['backup'],
    },
  ]);

  Future<SetupDevice> joined(String uid, String role) async {
    final d = world.device(uid);
    await world.join(owner, d, o.id, role);
    return d;
  }

  group('in the file', () {
    test('both kinds are read in small letters and written back as they are', () {
      final hosts = setupFile(both).crates!.single.hosts!;
      expect(hosts.map((h) => h.protocol), ['ftps', 'ftps-implicit']);
      expect(hosts[1].toJson(), {
        'name': 'files-2',
        'address': 'files2.northwind.example',
        'protocol': 'ftps-implicit',
        'key': 'files-login',
        'tags': ['backup'],
      });
      expect(setupStoredProtocol('ftps-implicit'), 'ftpsImplicit');
      expect(setupStoredProtocol('ftps'), 'ftps');
      expect(setupProtocolWord('ftpsImplicit'), 'ftps-implicit');
      expect(setupProtocolWord('ftps'), 'ftps');
      expect(setupProtocolWord('ftps-implicit'), isNull, reason: 'not a stored protocol');
      expect(setupProtocolWord('serial'), isNull);
      expect(setupProtocolWord('localShell'), isNull);
    });

    test('a file with an FTPS host is version 3; one without stays 1 or 2, which older apps read', () {
      final file = setupFile(both);
      expect(file.version, 3);
      expect(kSetupFileVersion, 3);
      expect(writeSetupFile(file), startsWith('{\n  "zestssh_setup": 3,'));
      // SSH hosts alone, and limits: as before.
      expect(setupFile(hostsOf('Production', [{'name': 'web-1', 'protocol': 'sftp'}])).version, 1);
      expect(
          setupFile({
            ...both,
            'members': [
              {
                'email': 'ada@northwind.example',
                'limits': {'Production': 'connect'},
              },
            ],
          }).version,
          3,
          reason: 'the newest a file needs');
      expect(
          setupFile({
            'members': [
              {
                'email': 'ada@northwind.example',
                'limits': {'Production': 'connect'},
              },
            ],
          }).version,
          kSetupFileLimitsVersion);
    });

    test('an app from before FTPS (version 2) refuses a file of version 3 as written for a newer app, and says so',
        () {
      // What this app says of a file one version past its own is what the
      // apps of version 2 say of a file with an FTPS host.
      final read = readSetupFile('{"zestssh_setup": ${kSetupFileVersion + 1}, "crates": []}');
      expect(texts(read.problems), ['newerVersion zestssh_setup ${kSetupFileVersion + 1}']);
      expect(setupFileProblemWords(read.problems.single, l10n),
          'It was written for a newer ZestSSH (setup file version ${kSetupFileVersion + 1}). Update the app to use it.');
    });
  });

  group('applied and exported', () {
    test('both kinds round trip: added with their default ports and login, exported as written, read back into '
        'another team as the same hosts', () async {
      final plan = await owner.plan(o.id, both);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add host files-1 in Production: ftps files1.northwind.example:21 key files-login',
        'add host files-2 in Production: ftps-implicit files2.northwind.example:990 key files-login tags backup',
      ]);
      final outcome = await owner.apply(o.id, both);
      expect(outcome.complete, isTrue);
      expect(outcome.syncError, isNull);
      expect(await owner.hosts(o.id), [
        'Production/files-1 files1.northwind.example:21 ftps key=files-login group=null tags=',
        'Production/files-2 files2.northwind.example:990 ftpsImplicit key=files-login group=null tags=backup',
      ]);

      // A member who opens the vault gets them through ZestSSH Cloud.
      final lin = await joined(SetupWorld.lin, o.members);
      expect((await lin.hosts(o.id)).map((h) => h.split(' ').take(3).join(' ')), [
        'Production/files-1 files1.northwind.example:21 ftps',
        'Production/files-2 files2.northwind.example:990 ftpsImplicit',
      ]);

      // Exported: both named, the file version 3; compared with the team it
      // came from it changes nothing.
      final now = await owner.snapshot(o.id);
      final export = exportSetup(now);
      expect(export.leftOut, isEmpty);
      expect(export.file.version, 3);
      final read = readSetupFile(export.text);
      expect(read.problems, isEmpty);
      expect(writeSetupFile(read.file!), export.text);
      final again = await planSetup(read.file!, now);
      expect(texts(again.problems), isEmpty);
      expect(texts(again.steps), isEmpty);
      final production = read.file!.crates!.singleWhere((c) => c.name == 'Production');
      expect([for (final h in production.hosts!) h.toJson()], [
        {
          'name': 'files-1',
          'address': 'files1.northwind.example',
          'port': 21,
          'protocol': 'ftps',
          'key': 'files-login',
          'group': null,
          'tags': <String>[],
        },
        {
          'name': 'files-2',
          'address': 'files2.northwind.example',
          'port': 990,
          'protocol': 'ftps-implicit',
          'key': 'files-login',
          'group': null,
          'tags': ['backup'],
        },
      ]);

      // Read into another team of the owner's, whose vault has a login of
      // that name: the same two hosts.
      final other = await world.orchard(owner, name: 'Second Team');
      await owner.addKey(other.id, 'files-login', crateId: other.production);
      final body = (jsonDecode(export.text) as Map<String, Object?>)..remove('orchard');
      final members = body.remove('members');
      expect(members, isNotNull);
      body.remove(kSetupFileMarker);
      await owner.apply(other.id, {
        'crates': [
          {'name': 'Production', 'hosts': (body['crates']! as List).cast<Map<String, Object?>>().first['hosts']},
        ],
      });
      expect(await owner.hosts(other.id), [
        'Production/files-1 files1.northwind.example:21 ftps key=files-login group=null tags=',
        'Production/files-2 files2.northwind.example:990 ftpsImplicit key=files-login group=null tags=backup',
      ]);
    });

    test('an FTPS host may change between explicit and implicit, and its port, address and login', () async {
      await owner.addKey(o.id, 'other-login', crateId: o.production);
      await owner.apply(o.id, both);
      final change = hostsOf('Production', [
        {'name': 'files-1', 'protocol': 'ftps-implicit', 'port': 990, 'key': 'other-login'},
        {'name': 'files-2', 'protocol': 'ftps', 'address': 'files3.northwind.example'},
      ]);
      final plan = await owner.plan(o.id, change);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'host files-1 in Production: port 990 protocol ftps-implicit key other-login',
        'host files-2 in Production: address files3.northwind.example protocol ftps',
      ]);
      await owner.apply(o.id, change);
      expect(await owner.hosts(o.id), [
        'Production/files-1 files1.northwind.example:990 ftpsImplicit key=other-login group=null tags=',
        'Production/files-2 files3.northwind.example:990 ftps key=files-login group=null tags=backup',
      ]);
    });
  });

  group('a kind never changes', () {
    test('a file that makes an FTPS host SSH, or an SSH host FTPS, is a problem, and nothing of it is applied',
        () async {
      await owner.addHost(o.id, 'files-1', crateId: o.production, protocol: 'ftpsImplicit', port: 990);
      await owner.addHost(o.id, 'web-1', crateId: o.production, address: '10.50.0.11');
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'files-1', 'protocol': 'ssh'},
            {'name': 'web-1', 'protocol': 'ftps'},
            {'name': 'web-2', 'address': '10.50.0.12'},
          ]));
      expect(texts(plan.problems), ['ftpsHost files-1 [Production]', 'notFtpsHost web-1 [Production]']);
      expect(plan.canApply, isFalse);
      expect(
          setupProblemWords(plan.problems[1], l10n),
          contains('is not an FTPS host, and a setup file cannot make it one'));
      // SFTP only is not FTPS either way.
      final sftp = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'files-1', 'protocol': 'sftp'},
            {'name': 'web-1', 'protocol': 'ftps-implicit'},
          ]));
      expect(texts(sftp.problems), ['ftpsHost files-1 [Production]', 'notFtpsHost web-1 [Production]']);
      expect(await owner.hosts(o.id), [
        'Production/files-1 192.0.2.10:990 ftpsImplicit key=null group=null tags=',
        'Production/web-1 10.50.0.11:22 ssh key=null group=null tags=',
      ]);
    });
  });

  group('roles', () {
    test('only someone who may add hosts to the vault adds an FTPS host, and only an editor changes one', () async {
      await owner.apply(o.id, both);
      final add = hostsOf('Production', [
        {'name': 'files-9', 'address': 'files9.northwind.example', 'protocol': 'ftps'},
      ]);
      final edit = hostsOf('Production', [
        {'name': 'files-1', 'port': 2121},
      ]);
      // Members use the vault: neither.
      final lin = await joined(SetupWorld.lin, o.members);
      expect(texts((await lin.plan(o.id, add)).problems), ['cannotAddHosts Production']);
      expect(texts((await lin.plan(o.id, edit)).problems), ['cannotEditHosts Production']);
      // Editors change hosts and add none.
      final editors = await owner.service.saveRole(o.id, name: 'Editors', can: {}, crates: {
        o.production: {CrateSwitches.connect, CrateSwitches.edit},
      });
      final ada = await joined(SetupWorld.ada, editors);
      expect(texts((await ada.plan(o.id, add)).problems), ['cannotAddHosts Production']);
      final edits = await ada.plan(o.id, edit);
      expect(edits.problems, isEmpty);
      expect(texts(edits.steps), ['host files-1 in Production: port 2121']);
      // An admin adds one.
      final sam = await joined(SetupWorld.sam, FixedRoles.admin);
      final adds = await sam.plan(o.id, add);
      expect(adds.problems, isEmpty);
      expect(texts(adds.steps), ['add host files-9 in Production: ftps files9.northwind.example:21']);
      expect((await sam.apply(o.id, add)).complete, isTrue);
      expect((await sam.hosts(o.id)).where((h) => h.startsWith('Production/files-9')).single,
          'Production/files-9 files9.northwind.example:21 ftps key=null group=null tags=');
    });
  });
}

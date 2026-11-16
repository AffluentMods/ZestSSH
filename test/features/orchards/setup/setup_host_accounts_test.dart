import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

import 'setup_world.dart';

// A host's other accounts in a setup file (3.0, accounts per host):
// "accounts", the names of the keys it can also be signed in with, in their
// order, beside its "key". Found as its key is (in its own Crate, else the
// only one of that name in the Orchard); planned only where they differ;
// applied with the host; written by an export; said in the plan's words.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;
  late String deploy, backup, root, web;

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
    deploy = await owner.addKey(o.id, 'deploy', crateId: o.production);
    backup = await owner.addKey(o.id, 'backup', crateId: o.production);
    root = await owner.addKey(o.id, 'root', crateId: o.staging);
    web = await owner.addHost(o.id, 'web-1', crateId: o.production, address: '10.50.0.11', keyId: deploy);
  });

  tearDown(() => world.stop());

  Map<String, Object?> hosts(List<Map<String, Object?>> list) => {
        'crates': [
          {'name': 'Production', 'hosts': list},
        ],
      };

  /// The other accounts of the host [id], in their order.
  Future<List<String>> accountsOf(String id) async => (await owner.db(o.id)).hostAccountsDao.otherAccountsOf(id);

  group('in the file', () {
    List<String> wrong(Map<String, Object?> body) =>
        [for (final p in readSetupFile(jsonEncode({kSetupFileMarker: 1, ...body})).problems) '$p'];

    test('read in their order, written back the same; each name once, and so many at most', () {
      final file = setupFile(hosts([
        {
          'name': 'web-1',
          'accounts': ['backup', 'root'],
        },
        {'name': 'db-1', 'accounts': <String>[]},
        {'name': 'db-2'},
      ]));
      final read = file.crates!.single.hosts!;
      expect(read[0].accounts, ['backup', 'root']);
      expect(read[1].accounts, isEmpty);
      expect(read[2].accounts, isNull, reason: 'not named: left as it is');
      expect(read[0].toJson()['accounts'], ['backup', 'root']);
      expect(read[2].toJson().containsKey('accounts'), isFalse);

      expect(
          wrong(hosts([
            {
              'name': 'web-1',
              'accounts': ['backup', 'Backup'],
            },
          ])),
          ['duplicate crates[0].hosts[0].accounts[1] Backup']);
      expect(
          wrong(hosts([
            {'name': 'web-1', 'accounts': List.filled(kSetupMaxAccounts + 1, 'backup')},
          ])).first,
          startsWith('tooMany crates[0].hosts[0].accounts'));
      expect(
          wrong(hosts([
            {
              'name': 'web-1',
              'accounts': ['backup', 7],
            },
          ])).single,
          startsWith('wrongKind crates[0].hosts[0].accounts[1]'));
    });
  });

  group('in the plan', () {
    test("a new host's, found as its key is; its own key no other account, a name repeated once", () async {
      final plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-2',
              'address': '10.50.0.12',
              'key': 'deploy',
              'accounts': ['backup', 'DEPLOY', 'root'],
            },
          ]));
      expect(plan.problems, isEmpty);
      final step = plan.steps.single as AddHost;
      expect(step.accounts, ['backup', 'root']);
      expect(step.accountIds, [backup, root], reason: 'root is the only one of that name, in Staging');
      expect('$step', 'add host web-2 in Production: ssh 10.50.0.12:22 key deploy accounts backup+root');
    });

    test("a host's that differ are a change of them alone, and the same are none", () async {
      var plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'accounts': ['root', 'backup'],
            },
          ]));
      var step = plan.steps.single as ChangeHost;
      expect(step.accounts, ['root', 'backup']);
      expect(step.accountIds, [root, backup]);
      expect('$step', 'host web-1 in Production: accounts root+backup');

      await (await owner.db(o.id)).hostAccountsDao.setOtherAccounts(web, [root, backup]);
      plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'accounts': ['root', 'backup'],
            },
          ]));
      expect(plan.steps, isEmpty, reason: 'as the file says');
      plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'accounts': ['backup', 'root'],
            },
          ]));
      expect((plan.steps.single as ChangeHost).accountIds, [backup, root], reason: 'their order is theirs');
      plan = await owner.plan(
          o.id,
          hosts([
            {'name': 'web-1', 'accounts': <String>[]},
          ]));
      step = plan.steps.single as ChangeHost;
      expect(step.accounts, isEmpty);
      expect(step.accountIds, isEmpty);
      expect('$step', 'host web-1 in Production: no accounts');
      plan = await owner.plan(
          o.id,
          hosts([
            {'name': 'web-1'},
          ]));
      expect(plan.steps, isEmpty, reason: 'not named: left as it is');
    });

    test('one that is no key, or one two keys are called, stands in the way of the host', () async {
      await owner.addKey(o.id, 'twice', crateId: o.production);
      await owner.addKey(o.id, 'Twice', crateId: o.production);
      final plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'accounts': ['nobody'],
            },
            {
              'name': 'web-2',
              'address': '10.50.0.12',
              'accounts': ['twice'],
            },
          ]));
      expect(texts(plan.problems), ['noSuchKey nobody [web-1]', 'ambiguousKey twice [web-2]']);
      expect(plan.steps, isEmpty);
    });

    test("the host's own key, changed in the same file, is no other account of it", () async {
      final plan = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'key': 'backup',
              'accounts': ['backup', 'deploy'],
            },
          ]));
      final step = plan.steps.single as ChangeHost;
      expect(step.keyId, backup);
      expect(step.accountIds, [deploy]);

      // Not named in the file: the key it has is its own.
      final kept = await owner.plan(
          o.id,
          hosts([
            {
              'name': 'web-1',
              'accounts': ['deploy', 'backup'],
            },
          ]));
      expect((kept.steps.single as ChangeHost).accountIds, [backup]);
    });

    test('said in its words', () async {
      const add = AddHost(
          crate: 'Production', name: 'web-2', address: '10.50.0.12', port: 22, protocol: 'ssh', accounts: ['backup', 'root']);
      expect(setupStepWords(add, l10n).details, contains(l10n.setupDetailAccounts('backup, root')));
      const none = AddHost(crate: 'Production', name: 'web-2', address: '10.50.0.12', port: 22, protocol: 'ssh');
      expect(setupStepWords(none, l10n).details, ['ssh 10.50.0.12:22'], reason: 'none: nothing said');
      const change = ChangeHost(crate: 'Production', hostId: 'h', name: 'web-1', accounts: []);
      expect(setupStepWords(change, l10n).details, [l10n.setupDetailNoAccounts]);
      const changed = ChangeHost(crate: 'Production', hostId: 'h', name: 'web-1', accounts: ['root']);
      expect(setupStepWords(changed, l10n).details, [l10n.setupDetailAccounts('root')]);
    });
  });

  group('applied', () {
    test('a new host gets them, and a host there has them made what the file says', () async {
      final outcome = await owner.apply(
          o.id,
          hosts([
            {
              'name': 'web-2',
              'address': '10.50.0.12',
              'key': 'deploy',
              'accounts': ['root', 'backup'],
            },
            {
              'name': 'web-1',
              'accounts': ['backup'],
            },
          ]));
      expect(outcome.failed, isNull, reason: '${outcome.error}');
      final db = await owner.db(o.id);
      final added = (await db.connectionsDao.getAll()).firstWhere((c) => c.label == 'web-2');
      expect(await accountsOf(added.id), [root, backup]);
      expect(await accountsOf(web), [backup]);

      await owner.apply(
          o.id,
          hosts([
            {'name': 'web-1', 'accounts': <String>[]},
          ]));
      expect(await accountsOf(web), isEmpty);
    });
  });

  group('exported', () {
    test("a host's other accounts by their keys' names, in their order; none, not said", () async {
      await (await owner.db(o.id)).hostAccountsDao.setOtherAccounts(web, [root, backup]);
      await owner.addHost(o.id, 'db-1', crateId: o.production, address: '10.50.0.21', keyId: deploy);
      final written = exportSetup(await owner.snapshot(o.id));
      final crate = written.file.crates!.firstWhere((c) => c.name == 'Production');
      final byName = {for (final h in crate.hosts!) h.name: h};
      expect(byName['web-1']!.accounts, ['root', 'backup']);
      expect(byName['db-1']!.accounts, isNull);
      // Read back, it plans nothing.
      final plan = await owner.plan(o.id, jsonDecode(jsonEncode(written.file.toJson())) as Map<String, Object?>);
      expect(plan.steps.whereType<ChangeHost>(), isEmpty);
    });
  });
}

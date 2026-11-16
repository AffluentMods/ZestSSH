import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart' show kMemberEndMaxSeconds;
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;

import 'setup_world.dart';

// What a setup file would change in an Orchard (3.0): the steps,
// what stands in their way and what the file leaves alone. Every Orchard
// here is a real one on the stand-in server, read from a device as the app
// reads it; where one thing a plan depends on cannot be brought about that
// way, the snapshot is changed by hand.

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

  /// A device of [uid], who joined as [role].
  Future<SetupDevice> joined(String uid, String role, {Map<String, Set<String>> grants = const {}}) async {
    final d = world.device(uid);
    await world.join(owner, d, o.id, role, grants: grants);
    return d;
  }

  group('which Orchard a file is for', () {
    test('a file for another Orchard is not looked at any further', () async {
      final plan = await owner.plan(o.id, {
        'orchard': 'Acme',
        'crates': [
          {'name': 'Lab'},
        ],
        'members': [
          {'email': email(SetupWorld.owner), 'role': 'admin'},
        ],
      });
      expect(texts(plan.problems), ['otherOrchard Acme [Northwind Ops]']);
      expect(plan.steps, isEmpty);
      expect(plan.notes, isEmpty);
      expect(plan.canApply, isFalse);
      expect(plan.nothingToDo, isFalse);
    });

    test('a file that names this one, however it is written, or names none, is', () async {
      for (final body in [
        {'orchard': ' northwind OPS '},
        <String, Object?>{},
      ]) {
        final plan = await owner.plan(o.id, body);
        expect(plan.problems, isEmpty);
        expect(plan.steps, isEmpty);
        expect(plan.notes, isEmpty);
        expect(plan.canApply, isTrue);
        expect(plan.nothingToDo, isTrue);
        expect(plan.needsRecentSignIn, isFalse);
      }
    });

    test('when ZestSSH Cloud was not reached, the plan says what it was made from', () async {
      final now = (await owner.snapshot(o.id)).change(reached: false);
      final plan = await planSetup(setupFile({'crates': <Object?>[]}), now);
      expect(texts(plan.notes).first, 'notReached');
      expect(texts((await owner.plan(o.id, {'crates': <Object?>[]})).notes), isNot(contains('notReached')));
    });
  });

  group('Crates', () {
    test('one that is there is found by its name, however it is written, and only what differs is a step',
        () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': ' PRODUCTION ', 'allow': ['forward', 'sftp'], 'ask_again': false, 'owners_only': false},
          {'name': 'staging', 'allow': ['sftp'], 'ask_again': true, 'session_logs': true, 'watched': false},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['crate Staging: allow sftp ask again on session logs on']);
      expect(plan.notes, isEmpty);
      expect(plan.needsRecentSignIn, isTrue);
      expect(plan.added, isEmpty);
      final step = plan.steps.single as CrateSettings;
      expect(step.crate, 'Staging');
      expect(step.parts.open, isFalse);
      expect(step.parts.allow, {CrateSwitches.sftp});
      expect(step.parts.askAgain, isTrue);
      expect(step.parts.sessionLogs, isTrue);
      expect(step.parts.watched, isNull);
      expect(step.allowsNothingWithWatching, isFalse);
      // The rehearsed record has it.
      final after = plan.after.crates[o.staging]!;
      expect(after.allow, {CrateSwitches.sftp});
      expect(after.confirmReveal, isTrue);
      expect(after.sessionLogs, isTrue);
      expect(world.server.recordOf(o.id).crates[o.staging]!.sessionLogs, isFalse, reason: 'nothing was sent');
    });

    test('one that is not there is added, and then set from what a new Crate starts with', () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Lab', 'allow': <String>[], 'ask_again': true},
          // What a new Crate allows anyway is no step.
          {'name': 'Depot', 'allow': ['sftp', 'forward'], 'ask_again': false, 'watched': false},
          {'name': 'Vault', 'owners_only': true},
          {'name': 'Open', 'owners_only': false},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add crate Lab',
        'crate Lab: allow nothing ask again on',
        'add crate Depot',
        'add crate Vault (owners only)',
        'add crate Open',
      ]);
      expect(plan.added.values, ['Lab', 'Depot', 'Vault', 'Open']);
      expect(plan.steps.first.needsRecentSignIn, isFalse);
      expect(plan.steps[1].needsRecentSignIn, isTrue);
      expect(plan.needsRecentSignIn, isTrue);
      // The rehearsed record holds them as they would be.
      final byName = {for (final e in plan.added.entries) e.value: plan.after.crates[e.key]!};
      expect(byName['Lab']!.allow, isEmpty);
      expect(byName['Lab']!.confirmReveal, isTrue);
      expect(byName['Depot']!.allow, kDefaultCrateAllow);
      expect(byName['Vault']!.ownersOnly, isTrue);
      expect(byName['Open']!.ownersOnly, isFalse);
      expect(texts(plan.notes), ['crateNotInFile Production', 'crateNotInFile Staging']);
      // Adding alone asks for no recent sign-in.
      final adds = await owner.plan(o.id, {
        'crates': [
          {'name': 'Lab'},
        ],
      });
      expect(texts(adds.steps), ['add crate Lab']);
      expect(adds.needsRecentSignIn, isFalse);
    });

    test('watching says what goes off with it; a watched Crate named as allowing something is refused',
        () async {
      final on = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'watched': true},
          {'name': 'Staging', 'watched': true, 'allow': <String>[]},
        ],
      });
      expect(on.problems, isEmpty);
      expect(texts(on.steps), [
        'crate Production: watched on (allows nothing with it)',
        'crate Staging: allow nothing watched on',
      ]);
      expect((on.steps.first as CrateSettings).allowsNothingWithWatching, isTrue);
      expect((on.steps.first as CrateSettings).parts.allow, isNull);
      expect((on.steps.last as CrateSettings).allowsNothingWithWatching, isFalse);
      expect(on.after.crates[o.production]!.allow, isEmpty);

      await owner.service.setCrateWatched(o.id, o.production, true);
      // Watched already: named as watched is nothing; another setting is its own step.
      final more = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'watched': true, 'ask_again': true},
        ],
      });
      expect(texts(more.steps), ['crate Production: ask again on']);
      final allows = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'allow': ['sftp']},
        ],
      });
      expect(texts(allows.problems),
          ['refused (a watched Crate allows the terminal only) <crate Production: allow sftp>']);
      expect(allows.steps, isEmpty);
      // No longer watched and allowing something again is one step.
      final off = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'watched': false, 'allow': ['sftp']},
        ],
      });
      expect(off.problems, isEmpty);
      expect(texts(off.steps), ['crate Production: allow sftp watched off']);
    });

    test('an owners-only Crate can be opened by a file, and never closed by one', () async {
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final open = await owner.plan(o.id, {
        'crates': [
          {'name': 'Vault', 'owners_only': false},
        ],
      });
      expect(open.problems, isEmpty);
      expect(texts(open.steps), ['crate Vault: open to admins and roles']);
      expect((open.steps.single as CrateSettings).parts.open, isTrue);
      final same = await owner.plan(o.id, {
        'crates': [
          {'name': 'Vault', 'owners_only': true},
          {'name': 'Production', 'owners_only': false},
        ],
      });
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      final close = await owner.plan(o.id, {
        'crates': [
          {'name': 'Production', 'owners_only': true, 'ask_again': true},
        ],
      });
      expect(texts(close.problems), ['cannotCloseCrate Production']);
      expect(close.canApply, isFalse);
    });

    test('two Crates of one name: the file cannot say which, and says so once', () async {
      await owner.service.renameCrate(o.id, o.staging, 'PRODUCTION');
      final plan = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'ask_again': true,
            'hosts': [
              {'name': 'web-1', 'address': '10.50.0.11'},
            ],
          },
        ],
        'roles': [
          {
            'name': 'Members',
            'crates': {'Production': 'connect'},
          },
        ],
      });
      expect(texts(plan.problems), ['ambiguousCrate Production']);
      expect(plan.steps, isEmpty);
      // With nothing said of Crates, whatever names it says so.
      final named = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Members',
            'crates': {'production': 'connect'},
          },
        ],
        'members': [
          {
            'email': email(SetupWorld.owner),
            'crates': {'Production': 'use'},
          },
        ],
      });
      expect(texts(named.problems), [
        'ambiguousCrate production [Members]',
        'ambiguousCrate Production [${email(SetupWorld.owner)}]',
      ]);
    });

    test('a Crate this account cannot open may be the one the file means: it is not added on a guess',
        () async {
      // Lin's role opens Production and may add Crates; Staging is closed to it.
      final builders = await owner.service.saveRole(o.id,
          name: 'Builders', can: {RoleCan.createCrates}, crates: {o.production: levelSwitches(CrateLevel.use)});
      final lin = await joined(SetupWorld.lin, builders);
      final now = await lin.snapshot(o.id);
      expect(now.crates.where((c) => !c.open).map((c) => c.id), [o.staging]);
      final plan = await lin.plan(o.id, {
        'crates': [
          {
            'name': 'Lab',
            'hosts': [
              {'name': 'web-1', 'address': '10.50.0.11'},
            ],
          },
        ],
        'members': [
          {
            'email': email(SetupWorld.lin),
            'crates': {'Lab': 'use'},
          },
        ],
      });
      // Said once: what names the Crate after that is passed over.
      expect(texts(plan.problems), ['crateMayExist Lab 1']);
      expect(plan.steps, isEmpty);
      expect(texts(plan.notes), [
        'crateNotInFile Production',
        'cratesClosed 1',
        'memberNotInFile ${email(SetupWorld.owner)}',
      ]);
      // An owners-only Crate is closed to everyone but owners, who open
      // every Crate: Staging cannot be one, so the record is asked, and
      // only owners add one.
      final safe = await lin.plan(o.id, {
        'crates': [
          {'name': 'Safe', 'owners_only': true},
        ],
      });
      expect(texts(safe.problems), ['refused (not allowed to add that Crate) <add crate Safe (owners only)>']);
      expect(safe.added, isEmpty);
    });

    test('a Crate the record refuses to add is said once: what names it after that is passed over',
        () async {
      final lin = await joined(SetupWorld.lin, o.members);
      final plan = await lin.plan(o.id, {
        'crates': [
          {
            'name': 'Safe',
            'owners_only': true,
            'hosts': [
              {'name': 'safe-1', 'address': '10.50.0.11'},
            ],
          },
        ],
        'roles': [
          {
            'name': 'Members',
            'crates': {'Production': 'use', 'Safe': 'use'},
          },
        ],
        'members': [
          {
            'email': email(SetupWorld.lin),
            'crates': {'Safe': 'use'},
          },
        ],
      });
      expect(texts(plan.problems), ['refused (not allowed to add that Crate) <add crate Safe (owners only)>']);
      expect(plan.steps, isEmpty);
      expect(plan.added, isEmpty);
    });

    test('what is named of a Crate as it is stands in no step, whatever else of it differs', () async {
      Future<String> step(Map<String, Object?> parts) async {
        final plan = await owner.plan(o.id, {
          'crates': [
            {'name': 'Staging', ...parts},
          ],
        });
        expect(plan.problems, isEmpty);
        return '${plan.steps.single}';
      }

      const asItIs = <String, Object?>{
        'allow': ['forward', 'sftp'],
        'ask_again': false,
        'session_logs': false,
        'watched': false,
        'unwatched_away': false,
        'offline_hours': 0,
        'owners_only': false,
      };
      expect((await owner.plan(o.id, {
        'crates': [
          {'name': 'Staging', ...asItIs},
        ],
      }))
          .steps, isEmpty);
      expect(await step({...asItIs, 'ask_again': true}), 'crate Staging: ask again on');
      expect(await step({...asItIs, 'session_logs': true}), 'crate Staging: session logs on');
      expect(await step({...asItIs, 'allow': ['sftp']}), 'crate Staging: allow sftp');
      expect(await step({...asItIs, 'allow': <String>[]}), 'crate Staging: allow nothing');
      // Who connects with nobody watching while ZestSSH Cloud cannot be
      // reached: everyone who may connect there, and owners alone again
      // where it was everyone; named as it is, no part of a step.
      expect(await step({...asItIs, 'unwatched_away': true}), 'crate Staging: everyone with the service away');
      expect(await step({'unwatched_away': true}), 'crate Staging: everyone with the service away');
      await owner.service.setCrateUnwatchedAway(o.id, o.staging, true);
      expect(await step({...asItIs}), 'crate Staging: owners alone with the service away');
      expect(await step({...asItIs, 'unwatched_away': true, 'ask_again': true}), 'crate Staging: ask again on');
      final awayPlan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Staging', 'unwatched_away': false},
        ],
      });
      expect((awayPlan.steps.single as CrateSettings).parts.unwatchedAway, isFalse);
      expect(awayPlan.after.crates[o.staging]!.unwatchedAway, isFalse);
      expect(world.server.recordOf(o.id).crates[o.staging]!.unwatchedAway, isTrue, reason: 'a plan sends nothing');
      await owner.service.setCrateUnwatchedAway(o.id, o.staging, false);
      // Its own offline limit: set, and taken off where it has one.
      expect(await step({...asItIs, 'offline_hours': 24}), 'crate Staging: offline limit 24 h');
      expect(await step({'offline_hours': 8}), 'crate Staging: offline limit 8 h');
      await owner.service.setCrateOfflineLimit(o.id, o.staging, 24);
      expect(await step({...asItIs}), 'crate Staging: no offline limit');
      expect((await owner.plan(o.id, {
        'crates': [
          {'name': 'Staging', ...asItIs, 'offline_hours': 24},
        ],
      }))
          .steps, isEmpty, reason: 'named as it is now');
      // Named as it is beside something that differs, it is no part of the
      // step.
      expect(await step({...asItIs, 'offline_hours': 24, 'ask_again': true}), 'crate Staging: ask again on');
      // The rehearsed record has what the plan would write, and nothing was
      // sent for it.
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Staging', 'offline_hours': 72},
        ],
      });
      expect((plan.steps.single as CrateSettings).parts.offlineHours, 72);
      expect(plan.after.crates[o.staging]!.offlineHours, 72);
      expect(world.server.recordOf(o.id).crates[o.staging]!.offlineHours, 24);
      expect(plan.needsRecentSignIn, isTrue);
    });

    test('an admin adds a Crate with an owners-only one around, and cannot tell an owners-only one apart',
        () async {
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      final plan = await ada.plan(o.id, {
        'crates': [
          {'name': 'Lab'},
          {'name': 'Production'},
          {'name': 'Staging'},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['add crate Lab']);
      expect(texts(plan.notes), ['cratesClosed 1']);
      final safe = await ada.plan(o.id, {
        'crates': [
          {'name': 'Safe', 'owners_only': true},
        ],
      });
      expect(texts(safe.problems), ['crateMayExist Safe 1']);
    });

    test('an Orchard holds no more Crates than it may', () async {
      final now = await owner.snapshot(o.id);
      final full = now.record.copy();
      for (var i = full.crates.length; i < 200; i++) {
        full.crates['crate-$i'] = RecordCrate(id: 'crate-$i', ownersOnly: false, allow: {});
      }
      expect(full.crates, hasLength(200));
      final file = setupFile({
        'crates': [
          {'name': 'Lab'},
          {'name': 'Production', 'ask_again': true},
        ],
      });
      final plan = await planSetup(file, now.change(record: full));
      expect(texts(plan.problems), ['tooManyCrates Lab 200']);
      // One short of full, it goes in.
      full.crates.remove('crate-199');
      final room = await planSetup(file, now.change(record: full));
      expect(room.problems, isEmpty);
      expect(texts(room.steps), ['add crate Lab', 'crate Production: ask again on']);
    });

    test('what is the owners\' to set is refused to an admin, in the record\'s own words', () async {
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      Future<List<String>> problems(Map<String, Object?> crate) async =>
          texts((await ada.plan(o.id, {
            'crates': [
              {'name': 'Production', ...crate},
            ],
          }))
              .problems);
      expect(await problems({'session_logs': true}),
          ['refused (only owners set session logs) <crate Production: session logs on>']);
      expect(await problems({'watched': true}),
          ['refused (only owners set watched sessions) <crate Production: watched on (allows nothing with it)>']);
      expect(await problems({'unwatched_away': true}), [
        'refused (only owners set watched sessions) <crate Production: everyone with the service away>',
      ]);
      expect(await problems({'offline_hours': 24}),
          ["refused (only owners set a Crate's offline limit) <crate Production: offline limit 24 h>"]);
      // What someone who manages the Crate may set, an admin may.
      final plan = await ada.plan(o.id, {
        'crates': [
          {'name': 'Production', 'allow': ['sftp'], 'ask_again': true},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['crate Production: allow sftp ask again on']);
      // A step the record refuses leaves the rehearsed record as it was.
      final refused = await ada.plan(o.id, {
        'crates': [
          {'name': 'Production', 'session_logs': true, 'ask_again': true},
        ],
      });
      expect(refused.steps, isEmpty);
      expect(refused.after.crates[o.production]!.confirmReveal, isFalse);
      expect(refused.after.seq, world.server.recordOf(o.id).seq);
    });

    test('Crates the file does not name are listed and left; with nothing said of Crates, nothing is listed',
        () async {
      final some = await owner.plan(o.id, {
        'crates': [
          {'name': 'Staging'},
        ],
      });
      expect(some.steps, isEmpty);
      expect(texts(some.notes), ['crateNotInFile Production']);
      final none = await owner.plan(o.id, {'crates': <Object?>[]});
      expect(texts(none.notes), ['crateNotInFile Production', 'crateNotInFile Staging']);
      expect(none.nothingToDo, isTrue);
      expect((await owner.plan(o.id, {'rules': <String, Object?>{}})).notes, isEmpty);
    });
  });

  group('roles', () {
    test('one that is not there is added with what it gives, in Crates the file adds too', () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Lab'},
        ],
        'roles': [
          {'name': 'Members'},
          {
            'name': 'Operators',
            'can': ['invite', 'remove'],
            'crates': {'production': 'edit', 'Lab': 'manage+agent'},
          },
          {'name': 'Guests'},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add crate Lab',
        'add role Operators: can invite+remove; Production="edit" Lab="manage+agent"',
        'add role Guests: can nothing; no crates',
      ]);
      expect(plan.added.values, ['Lab', 'Operators', 'Guests']);
      final step = plan.steps[1] as AddRole;
      expect(step.name, 'Operators');
      expect(step.can, {RoleCan.invite, RoleCan.remove});
      expect(step.crates, {
        'Production': levelSwitches(CrateLevel.edit),
        'Lab': {...levelSwitches(CrateLevel.manage), CrateSwitches.agent},
      });
      expect(step.needsRecentSignIn, isTrue);
      // Below every other, in the file's order: nothing to put in order.
      expect(rolesHighestFirst(plan.after).map((id) => plan.added[id] ?? id),
          [o.members, 'Operators', 'Guests']);
      // The rehearsed record holds the role as it would be made: what it
      // may do in the Orchard, and what it gives.
      final lab = plan.added.entries.singleWhere((e) => e.value == 'Lab').key;
      final made = plan.after.roles[plan.added.entries.singleWhere((e) => e.value == 'Operators').key]!;
      expect(made.can, {RoleCan.invite, RoleCan.remove});
      expect(made.crates, {
        o.production: levelSwitches(CrateLevel.edit),
        lab: {...levelSwitches(CrateLevel.manage), CrateSwitches.agent},
      });
    });

    test('one that is there changes in what differs, and only that', () async {
      final ops = await owner.service.saveRole(o.id,
          name: 'Operators', can: {RoleCan.invite}, crates: {o.staging: levelSwitches(CrateLevel.edit)});
      final same = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'members',
            'can': <String>[],
            'crates': {'Production': 'use'},
          },
          {
            'name': 'OPERATORS',
            'can': ['invite'],
            'crates': {'Staging': 'edit'},
          },
        ],
      });
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      expect(same.notes, isEmpty);

      final can = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Operators',
            'can': ['invite', 'change_roles'],
            'crates': {'Staging': 'edit'},
          },
        ],
      });
      expect(texts(can.steps), ['role Operators: can change_roles+invite']);
      final step = can.steps.single as ChangeRole;
      expect(step.roleId, ops);
      expect(step.name, 'Operators');
      expect(step.crates, isNull);
      expect(texts(can.notes), ['roleNotInFile Members']);

      final gives = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Operators',
            'crates': {'Staging': 'edit', 'Production': 'connect'},
          },
        ],
      });
      expect(texts(gives.steps), ['role Operators: Staging="edit" Production="connect"']);
      expect((gives.steps.single as ChangeRole).can, isNull);
      expect(gives.steps.single.needsRecentSignIn, isTrue);
      expect(gives.needsRecentSignIn, isTrue);
      // What it may do, named as it is beside Crates that differ, is no part of the step.
      final both = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Operators',
            'can': ['invite'],
            'crates': {'Staging': 'edit', 'Production': 'connect'},
          },
        ],
      });
      expect(texts(both.steps), ['role Operators: Staging="edit" Production="connect"']);
      expect((both.steps.single as ChangeRole).can, isNull);
      // Named as nothing at all: the role gives nothing and may do nothing.
      final bare = await owner.plan(o.id, {
        'roles': [
          {'name': 'Operators', 'can': <String>[], 'crates': <String, Object?>{}},
        ],
      });
      expect(texts(bare.steps), ['role Operators: can nothing no crates']);
      expect(bare.after.roles[ops]!.crates, isEmpty);
      expect(bare.after.roles[ops]!.can, isEmpty);
    });

    test('the roles the file names take its order; one it adds stands no higher than it says', () async {
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final guests = await owner.service.saveRole(o.id, name: 'Guests', can: {}, crates: {});
      expect(rolesHighestFirst(world.server.recordOf(o.id)), [o.members, ops, guests]);
      // As they stand: nothing.
      expect(
          (await owner.plan(o.id, {
            'roles': [
              {'name': 'Members'},
              {'name': 'Guests'},
            ],
          }))
              .steps,
          isEmpty);
      // Two change places; the one not named keeps its own.
      final swap = await owner.plan(o.id, {
        'roles': [
          {'name': 'Guests'},
          {'name': 'Members'},
        ],
      });
      expect(swap.problems, isEmpty);
      expect(texts(swap.steps), ['order roles: Guests > Operators > Members']);
      final step = swap.steps.single as OrderRoles;
      expect(step.order, ['Guests', 'Operators', 'Members']);
      expect(step.ids, [guests, ops, o.members]);
      expect(step.needsRecentSignIn, isTrue);
      expect(rolesHighestFirst(swap.after), [guests, ops, o.members]);
      // A new one named first stands just above the next; named last, below all.
      final added = await owner.plan(o.id, {
        'roles': [
          {'name': 'Leads'},
          {'name': 'Operators'},
          {'name': 'Interns'},
        ],
      });
      expect(texts(added.steps), [
        'add role Leads: can nothing; no crates',
        'add role Interns: can nothing; no crates',
        'order roles: Members > Leads > Operators > Guests > Interns',
      ]);
      expect((added.steps.last as OrderRoles).ids, [o.members, null, ops, guests, null]);
      expect(rolesHighestFirst(added.after).map((id) => added.added[id] ?? id),
          [o.members, 'Leads', ops, guests, 'Interns']);
      // A role that is there has its place in the file's order, also where
      // something else is wrong with what the file says of it.
      final wrong = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Guests',
            'crates': {'Nowhere': 'use'},
          },
          {'name': 'Members'},
        ],
      });
      expect(texts(wrong.problems), ['noSuchCrate Nowhere [Guests]']);
      expect(texts(wrong.steps), ['order roles: Guests > Operators > Members']);
    });

    test('two roles of one name, a name that cannot be read, and too many of them', () async {
      await owner.service.saveRole(o.id, name: 'members', can: {}, crates: {});
      final plan = await owner.plan(o.id, {
        'roles': [
          {'name': 'Members', 'can': ['invite']},
        ],
        'members': [
          {'email': email(SetupWorld.sam), 'role': 'Members'},
        ],
      });
      // Said once; the member who names it is passed over.
      expect(texts(plan.problems), ['ambiguousRole Members']);
      final byMember = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.sam), 'role': 'Members'},
        ],
      });
      expect(texts(byMember.problems), ['ambiguousRole Members [${email(SetupWorld.sam)}]']);

      final now = await owner.snapshot(o.id);
      final file = setupFile({
        'roles': [
          {'name': 'Operators'},
        ],
      });
      // A role whose name this device cannot read may be the one meant.
      final unread = now.change(roles: [SnapshotRole(id: now.roles.first.id), now.roles.last]);
      expect(texts((await planSetup(file, unread)).problems), ['roleMayExist Operators 1']);
      // Thirty roles is all an Orchard holds.
      final full = now.record.copy();
      final first = full.roles.values.first;
      for (var i = full.roles.length; i < kMaxOrchardRoles; i++) {
        full.roles['role-$i'] = RecordRole(
            id: 'role-$i', rank: 10 + i, nameEnc: first.nameEnc, nameGeneration: 1, can: {}, crates: {});
      }
      expect(texts((await planSetup(file, now.change(record: full))).problems), ['tooManyRoles Operators 30']);
      full.roles.remove('role-29');
      final room = await planSetup(file, now.change(record: full));
      expect(room.problems, isEmpty);
      expect(texts(room.steps), ['add role Operators: can nothing; no crates']);
    });

    test('a role names Crates there are, and never an owners-only one', () async {
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final nowhere = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Operators',
            'crates': {'Nowhere': 'use', 'Production': 'use', 'Elsewhere': 'use'},
          },
          {
            'name': 'Members',
            'crates': {'Nowhere': 'use'},
          },
        ],
        'members': [
          // The role could not be added: said above, not again here.
          {'email': email(SetupWorld.sam), 'role': 'Operators'},
        ],
      });
      expect(texts(nowhere.problems), [
        'noSuchCrate Nowhere [Operators]',
        'noSuchCrate Elsewhere [Operators]',
        'noSuchCrate Nowhere [Members]',
      ]);
      expect(nowhere.steps, isEmpty);
      final vault = await owner.plan(o.id, {
        'roles': [
          {
            'name': 'Members',
            'crates': {'Vault': 'use'},
          },
          {
            'name': 'Operators',
            'crates': {'Vault': 'connect'},
          },
        ],
      });
      expect(texts(vault.problems), [
        'refused (no such Crate, or owners-only) <role Members: Vault="use">',
        'refused (no such Crate, or owners-only) <add role Operators: can nothing; Vault="connect">',
      ]);
      expect(vault.added, isEmpty);
    });

    test('only owners change roles', () async {
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      final plan = await ada.plan(o.id, {
        'roles': [
          {'name': 'Members', 'can': ['invite']},
          {'name': 'Operators'},
        ],
      });
      expect(texts(plan.problems), [
        'refused (only owners change roles) <role Members: can invite>',
        'refused (only owners change roles) <add role Operators: can nothing; no crates>',
      ]);
    });

    test('someone who would gain a Crate has keys this device trusts, or the step is not made', () async {
      await joined(SetupWorld.ada, o.members);
      final now = await owner.snapshot(o.id);
      expect(now.member(SetupWorld.ada)!.keysTrusted, isTrue);
      final file = setupFile({
        'roles': [
          {
            'name': 'Members',
            'crates': {'Production': 'use', 'Staging': 'connect'},
          },
        ],
      });
      final fine = await planSetup(file, now);
      expect(fine.problems, isEmpty);
      expect(fine.steps, hasLength(1));
      final stopped = now.change(members: [
        for (final m in now.members)
          m.uid == SetupWorld.ada ? SnapshotMember(uid: m.uid, email: m.email, keysTrusted: false) : m,
      ]);
      final plan = await planSetup(file, stopped);
      expect(texts(plan.problems), [
        'keysNotTrusted ${email(SetupWorld.ada)} <role Members: Production="use" Staging="connect">',
      ]);
      expect(plan.steps, isEmpty);
      expect(plan.after.roles[o.members]!.crates.keys, [o.production], reason: 'the record stays as it was');
      // Taking a Crate away from them seals nothing to anyone.
      final less = await planSetup(
          setupFile({
            'roles': [
              {'name': 'Members', 'crates': <String, Object?>{}},
            ],
          }),
          stopped);
      expect(less.problems, isEmpty);
      expect(texts(less.steps), ['role Members: no crates']);
      // Someone this device never heard of at all is not trusted either.
      final unknown = now.change(members: [
        for (final m in now.members)
          if (m.uid != SetupWorld.ada) m,
      ]);
      expect(texts((await planSetup(file, unknown)).problems),
          ['keysNotTrusted ${SetupWorld.ada} <role Members: Production="use" Staging="connect">']);
    });
  });

  group('the rules and what the team records', () {
    test('only the rules that differ are a step, with all of them as they will be', () async {
      await owner.service.setRules(o.id, const RecordRules(reauthDays: 30, requireAppLock: true));
      final plan = await owner.plan(o.id, {
        'rules': {
          'reauth_days': 30,
          'require_app_lock': true,
          'no_export': true,
          'max_lock_minutes': 15,
          'email_domains': ['northwind.example'],
          'offline_hours': 72,
          'require_2fa': true,
        },
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'rules: {"require_2fa":true,"email_domains":["northwind.example"],"max_lock_minutes":15,'
            '"no_export":true,"offline_hours":72}',
      ]);
      final step = plan.steps.single as SetRules;
      expect(step.parts.reauthDays, isNull);
      expect(step.parts.requireAppLock, isNull);
      expect(step.parts.requireSso, isNull);
      expect(step.parts.trustedDevices, isNull);
      expect(
          step.rules.toBody(),
          const RecordRules(
            require2fa: true,
            emailDomains: {'northwind.example'},
            requireAppLock: true,
            maxLockMinutes: 15,
            noExport: true,
            offlineHours: 72,
            reauthDays: 30,
          ).toBody());
      expect(plan.after.rules.toBody(), step.rules.toBody());
      expect(step.needsRecentSignIn, isTrue);
      // As they are: nothing.
      expect((await owner.plan(o.id, {'rules': {'reauth_days': 30, 'require_app_lock': true}})).steps, isEmpty);
      // Each rule by itself is seen to differ.
      for (final rule in <String, Object>{
        'require_2fa': true,
        'require_app_lock': false,
        'max_lock_minutes': 5,
        'no_export': true,
        'offline_hours': 1,
        'reauth_days': 31,
        'require_sso': true,
      }.entries) {
        final one = await owner.plan(o.id, {
          'rules': {rule.key: rule.value},
        });
        expect((one.steps.single as SetRules).parts.toJson(), {rule.key: rule.value}, reason: rule.key);
      }
    });

    test('sign in again in days or hours is one rule: naming one sets the other to 0', () async {
      (int, int) reauth(RecordRules r) => (r.reauthDays, r.reauthHours);
      Future<SetRules?> step(Map<String, Object?> rules) async {
        final plan = await owner.plan(o.id, {'rules': rules});
        expect(plan.problems, isEmpty);
        return plan.steps.isEmpty ? null : plan.steps.single as SetRules;
      }

      await owner.service.setRules(o.id, const RecordRules(reauthDays: 30));
      // Hours alone: the days go.
      var s = (await step({'reauth_hours': 8}))!;
      expect(s.parts.toJson(), {'reauth_hours': 8});
      expect(reauth(s.rules), (0, 8));
      // Both: both, the shorter holding.
      s = (await step({'reauth_days': 1, 'reauth_hours': 4}))!;
      expect(s.parts.toJson(), {'reauth_days': 1, 'reauth_hours': 4});
      expect(s.rules.reauthSeconds, 4 * 3600);
      // As it is, the days alone saying no hours: nothing.
      expect(await step({'reauth_days': 30}), isNull);
      expect(await step({'reauth_days': 30, 'reauth_hours': 0}), isNull);

      await owner.service.setRules(o.id, const RecordRules(reauthDays: 30, reauthHours: 8));
      expect(await step({'reauth_days': 30, 'reauth_hours': 8}), isNull);
      // The days alone take the hours away.
      s = (await step({'reauth_days': 30}))!;
      expect(s.parts.toJson(), {'reauth_days': 30});
      expect(reauth(s.rules), (30, 0));
      // No hours and no days: off.
      s = (await step({'reauth_hours': 0}))!;
      expect(s.parts.toJson(), {'reauth_days': 0});
      expect(reauth(s.rules), (0, 0));
    });

    test('a rule named as it is stands in no step, whatever other rule differs', () async {
      final now = await owner.snapshot(o.id);
      final ruled = now.record.copy()
        ..rules = const RecordRules(
          require2fa: true,
          emailDomains: {'northwind.example'},
          requireAppLock: true,
          maxLockMinutes: 15,
          noExport: true,
          offlineHours: 72,
          reauthDays: 30,
        );
      const asTheyAre = <String, Object?>{
        'require_2fa': true,
        'email_domains': ['northwind.example'],
        'require_app_lock': true,
        'max_lock_minutes': 15,
        'no_export': true,
        'offline_hours': 72,
        'reauth_days': 30,
        'require_sso': false,
        'trusted_devices': false,
      };
      Future<SetupPlan> plan(Map<String, Object?> rules) =>
          planSetup(setupFile({'rules': rules}), now.change(record: ruled));
      expect((await plan(asTheyAre)).steps, isEmpty);
      // One rule differs at a time: it alone is the step.
      for (final rule in <String, Object>{
        'require_2fa': false,
        'email_domains': ['northwind.example', 'northwind.test'],
        'require_app_lock': false,
        'max_lock_minutes': 5,
        'no_export': false,
        'offline_hours': 24,
        'reauth_days': 7,
        // The two about remote screens (4.0), which the file above does not name.
        'screens_ssh_only': true,
        'screens_lock_redirections': true,
      }.entries) {
        final one = await plan({...asTheyAre, rule.key: rule.value});
        final step = [...one.steps, ...one.problems.map((p) => p.step)].whereType<SetRules>().single;
        expect(step.parts.toJson(), {rule.key: rule.value}, reason: rule.key);
      }
    });

    test('address domains that leave out the account applying them are not set', () async {
      final out = await owner.plan(o.id, {
        'rules': {
          'email_domains': ['elsewhere.example'],
          'no_export': true,
        },
      });
      expect(texts(out.problems), [
        'rulesLeaveYouOut northwind.example <rules: {"email_domains":["elsewhere.example"],"no_export":true}>',
      ]);
      expect(out.steps, isEmpty);
      expect(out.after.rules.noExport, isFalse);
      final within = await owner.plan(o.id, {
        'rules': {
          'email_domains': ['elsewhere.example', 'northwind.example'],
        },
      });
      expect(within.problems, isEmpty);
      expect(within.steps, hasLength(1));
      // Any address again is everyone's.
      await owner.service.setRules(o.id, const RecordRules(emailDomains: {'northwind.example'}));
      final any = await owner.plan(o.id, {
        'rules': {'email_domains': <String>[]},
      });
      expect(any.problems, isEmpty);
      expect(texts(any.steps), ['rules: {"email_domains":[]}']);
      // Domains that stay as they are say nothing of anyone.
      final now = (await owner.snapshot(o.id)).change(myEmail: 'owner@elsewhere.example');
      final other = await planSetup(
          setupFile({
            'rules': {
              'email_domains': ['northwind.example'],
              'no_export': true,
            },
          }),
          now);
      expect(other.problems, isEmpty);
      // An account whose address this device does not know is left out by any domain.
      final blind = OrchardSnapshot(
          orchardId: now.orchardId, name: now.name, me: now.me, record: now.record, now: now.now, crates: now.crates);
      final plan = await planSetup(
          setupFile({
            'rules': {
              'email_domains': ['elsewhere.example'],
            },
          }),
          blind);
      expect(texts(plan.problems), ['rulesLeaveYouOut <rules: {"email_domains":["elsewhere.example"]}>']);
    });

    test('address domains that leave members out say who, as the server would hold them back; an end date from the same file makes a guest', () async {
      await joined(SetupWorld.ada, o.members);
      await joined(SetupWorld.sam, o.members);
      final now = await owner.snapshot(o.id);
      final outside = now.change(members: [
        for (final m in now.members)
          m.uid == SetupWorld.owner
              ? m
              : SnapshotMember(uid: m.uid, email: '${m.uid}@partner.example', compared: m.compared, keysTrusted: m.keysTrusted),
      ]);
      Iterable<String> said(SetupPlan plan) =>
          texts(plan.notes).where((n) => n.startsWith(SetupNoteKind.outsideDomains.name));
      const rules = {
        'email_domains': ['northwind.example'],
      };
      var plan = await planSetup(setupFile({'rules': rules}), outside);
      expect(plan.problems, isEmpty);
      expect(said(plan), ['outsideDomains ada@partner.example,sam@partner.example']);

      plan = await planSetup(
          setupFile({
            'rules': rules,
            'members': [
              {'email': 'sam@partner.example', 'until': kLater},
            ],
          }),
          outside);
      expect(plan.problems, isEmpty);
      expect(said(plan), ['outsideDomains ada@partner.example']);

      // A list everyone is on, none at all, and a list that does not change.
      plan = await planSetup(
          setupFile({
            'rules': {
              'email_domains': ['northwind.example', 'partner.example'],
            },
          }),
          outside);
      expect(said(plan), isEmpty);
      plan = await planSetup(
          setupFile({
            'rules': {'email_domains': <String>[]},
          }),
          outside);
      expect(said(plan), isEmpty);
      await owner.service.setRules(o.id, const RecordRules(emailDomains: {'northwind.example'}));
      plan = await planSetup(setupFile({'rules': rules}), (await owner.snapshot(o.id)).change(members: outside.members));
      expect(plan.steps, isEmpty);
      expect(said(plan), isEmpty);
    });

    test('a guest no owner dated is named as well: their date lets them in once the list is applied', () async {
      final leads = await owner.service.saveRole(o.id, name: 'Leads', can: {RoleCan.changeRoles}, crates: {
        o.production: {CrateSwitches.connect, CrateSwitches.manage},
      });
      await owner.service.orderRoles(o.id, [leads, o.members]);
      final lead = await joined(SetupWorld.ada, leads);
      await joined(SetupWorld.sam, o.members);
      await joined(SetupWorld.lin, o.members);
      final until = (await owner.snapshot(o.id)).now + 3600;
      await lead.service.refresh();
      await lead.service.setMemberEndsAt(o.id, SetupWorld.sam, until);
      await owner.service.refresh();
      await owner.service.setMemberEndsAt(o.id, SetupWorld.lin, until);
      final now = await owner.snapshot(o.id);
      final outside = now.change(members: [
        for (final m in now.members)
          m.uid == SetupWorld.owner || m.uid == SetupWorld.ada
              ? m
              : SnapshotMember(uid: m.uid, email: '${m.uid}@partner.example', compared: m.compared, keysTrusted: m.keysTrusted),
      ]);
      Iterable<String> said(SetupPlan plan) => texts(plan.notes).where((n) => n.startsWith('outsideDomains'));
      const rules = {
        'email_domains': ['northwind.example'],
      };
      // Sam's date is the lead's; Lin's an owner's: decided on.
      var plan = await planSetup(setupFile({'rules': rules}), outside);
      expect(said(plan), ['outsideDomainsUnseen sam@partner.example']);

      // The file gives Sam one: an owner's now.
      plan = await planSetup(
          setupFile({
            'rules': rules,
            'members': [
              {'email': 'sam@partner.example', 'until': kLater},
            ],
          }),
          outside);
      expect(said(plan), isEmpty);

      // No list: nobody is outside one.
      plan = await planSetup(
          setupFile({
            'rules': {'email_domains': <String>[]},
          }),
          outside);
      expect(said(plan), isEmpty);
    });

    group('an end date outside the domains, or too far away, is refused here: the server would, part way through applying', () {
      Future<String> later(OrchardSnapshot now) async => setupTimeOf(now.now + 30 * 24 * 60 * 60);

      test('no end date for a guest of the rules\' domains', () async {
        await joined(SetupWorld.ada, o.members);
        final now = await owner.snapshot(o.id);
        await owner.service.setMemberEndsAt(o.id, SetupWorld.ada, now.now + 3600);
        final plan = await owner.plan(o.id, {
          'rules': {
            'email_domains': ['elsewhere.example', 'northwind.example'],
          },
        });
        expect(plan.problems, isEmpty);
        final outside = (await owner.snapshot(o.id)).change(members: [
          for (final m in (await owner.snapshot(o.id)).members)
            m.uid == SetupWorld.ada
                ? SnapshotMember(uid: m.uid, email: 'ada@partner.example', compared: m.compared, keysTrusted: m.keysTrusted)
                : m,
        ]);
        final refused = await planSetup(
            setupFile({
              'rules': {
                'email_domains': ['northwind.example'],
              },
              'members': [
                {'email': 'ada@partner.example', 'until': null},
              ],
            }),
            outside);
        expect(texts(refused.problems), ['guestNeedsEnd ada@partner.example']);
        expect(refused.canApply, isFalse);
        // A date for them instead: nothing in the way.
        final dated = await planSetup(
            setupFile({
              'rules': {
                'email_domains': ['northwind.example'],
              },
              'members': [
                {'email': 'ada@partner.example', 'until': await later(outside)},
              ],
            }),
            outside);
        expect(dated.problems, isEmpty);
      });

      test('no end date outside the domains the team proved, for a member and for an invitation', () async {
        await joined(SetupWorld.ada, o.members);
        final now = await owner.snapshot(o.id);
        await owner.service.setMemberEndsAt(o.id, SetupWorld.ada, now.now + 3600);
        final proven = (await owner.snapshot(o.id)).change(provenDomains: {'elsewhere.example'});
        final plan = await planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.ada), 'until': null},
                {'email': email(SetupWorld.sam), 'role': 'Members', 'until': null},
                {'email': email(SetupWorld.lin), 'role': 'Members'},
              ],
            }),
            proven);
        expect(texts(plan.problems), [
          'guestNeedsEnd ${email(SetupWorld.ada)}',
          'guestNeedsEnd ${email(SetupWorld.sam)}',
          'guestNeedsEnd ${email(SetupWorld.lin)}',
        ]);
        // Inside what was proved, as before.
        final inside = (await owner.snapshot(o.id)).change(provenDomains: {'northwind.example'});
        final fine = await planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.ada), 'until': null},
                {'email': email(SetupWorld.sam), 'role': 'Members', 'until': null},
              ],
            }),
            inside);
        expect(fine.problems, isEmpty);
      });

      test('a file that leaves a date as it is asks nothing of it', () async {
        await joined(SetupWorld.ada, o.members);
        // Held back and with no date: nothing moves, so nothing is refused.
        final proven = (await owner.snapshot(o.id)).change(provenDomains: {'elsewhere.example'});
        final plan = await planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.ada), 'until': null},
              ],
            }),
            proven);
        expect(plan.problems, isEmpty);
        expect(plan.steps, isEmpty);
      });

      test('below an owner: nobody outside the domains is invited, and no date of theirs moved', () async {
        final leads = await owner.service.saveRole(o.id, name: 'Leads', can: {RoleCan.changeRoles, RoleCan.invite}, crates: {
          o.production: {CrateSwitches.connect, CrateSwitches.manage},
        });
        await owner.service.orderRoles(o.id, [leads, o.members]);
        final lead = await joined(SetupWorld.ada, leads);
        await joined(SetupWorld.sam, o.members);
        final proven = (await lead.snapshot(o.id)).change(provenDomains: {'elsewhere.example'});
        final refused = await planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.sam), 'until': kLater},
                {'email': email(SetupWorld.lin), 'role': 'Members', 'until': kLater},
              ],
            }),
            proven);
        expect(texts(refused.problems),
            ['guestOwnersOnly ${email(SetupWorld.sam)}', 'guestOwnersOnly ${email(SetupWorld.lin)}']);
        // Inside what was proved, as before.
        final inside = (await lead.snapshot(o.id)).change(provenDomains: {'northwind.example'});
        final fine = await planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.sam), 'until': kLater},
              ],
            }),
            inside);
        expect(fine.problems, isEmpty);
      });

      test('at most five years away, for a member and for an invitation', () async {
        await joined(SetupWorld.ada, o.members);
        final now = await owner.snapshot(o.id);
        Future<SetupPlan> at(int seconds) => planSetup(
            setupFile({
              'members': [
                {'email': email(SetupWorld.ada), 'until': setupTimeOf(seconds)},
                {'email': email(SetupWorld.sam), 'role': 'Members', 'until': setupTimeOf(seconds)},
              ],
            }),
            now);
        expect(texts((await at(now.now + kMemberEndMaxSeconds + 1)).problems),
            ['untilTooFar ${email(SetupWorld.ada)}', 'untilTooFar ${email(SetupWorld.sam)}']);
        expect((await at(now.now + kMemberEndMaxSeconds)).problems, isEmpty);
      });
    });

    test('rules the record refuses are said in its words', () async {
      final timeout = await owner.plan(o.id, {
        'rules': {'max_lock_minutes': 15},
      });
      expect(texts(timeout.problems),
          ['refused (a lock timeout needs the app lock) <rules: {"max_lock_minutes":15}>']);
      final devices = await owner.plan(o.id, {
        'rules': {'trusted_devices': true},
      });
      expect(texts(devices.problems),
          ['refused (two approved devices among the owners first) <rules: {"trusted_devices":true}>']);
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      final admin = await ada.plan(o.id, {
        'rules': {'no_export': true},
        'records': {'history': true},
      });
      expect(texts(admin.problems), [
        'refused (only owners set the rules) <rules: {"no_export":true}>',
        'refused (only owners set what the team records) <records: {"history":true}>',
      ]);
    });

    test('rules this device does not meet are set, with a word about it', () async {
      final file = setupFile({
        'rules': {'require_app_lock': true, 'max_lock_minutes': 15},
      });
      Future<List<String>> notes({bool? on, int? minutes}) async {
        final base = await owner.snapshot(o.id, lock: on == null ? null : (on: on, minutes: minutes ?? 0));
        final plan = await planSetup(file, base);
        expect(plan.problems, isEmpty);
        expect(plan.steps, hasLength(1));
        return texts(plan.notes);
      }

      expect(await notes(on: false), ['thisDeviceRules']);
      expect(await notes(on: true, minutes: 30), ['thisDeviceRules']);
      expect(await notes(on: true, minutes: 15), isEmpty);
      expect(await notes(on: true, minutes: 5), isEmpty);
      // Where the lock could not be read, nothing is said of it.
      expect(await notes(), isEmpty);
      // Rules that ask nothing of a device say nothing either.
      final plan = await planSetup(setupFile({'rules': {'no_export': true}}),
          await owner.snapshot(o.id, lock: (on: false, minutes: 0)));
      expect(plan.notes, isEmpty);
    });

    test('only what differs of what the team records is a step', () async {
      await owner.service.setTracking(o.id, const RecordTracking(history: true));
      final plan = await owner.plan(o.id, {
        'records': {'history': true, 'activity': true, 'devices': false, 'ips': true},
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['records: {"activity":true,"ips":true}']);
      final step = plan.steps.single as SetRecords;
      expect(step.tracking, const RecordTracking(history: true, activity: true, ips: true));
      expect(step.endsEventExport, isFalse);
      expect(step.needsRecentSignIn, isTrue);
      expect(plan.after.tracking, step.tracking);
      expect((await owner.plan(o.id, {'records': {'history': true}})).steps, isEmpty);
      for (final field in ['activity', 'devices', 'ips']) {
        final one = await owner.plan(o.id, {
          'records': {field: true},
        });
        expect((one.steps.single as SetRecords).parts.toJson(), {field: true}, reason: field);
      }
      expect(
          ((await owner.plan(o.id, {'records': {'history': false}})).steps.single as SetRecords).parts.toJson(),
          {'history': false});
      // Each named as it is beside one that differs: that one alone is the step.
      const asItIs = <String, Object?>{'history': true, 'activity': false, 'devices': false, 'ips': false};
      expect((await owner.plan(o.id, {'records': asItIs})).steps, isEmpty);
      for (final field in <String, bool>{'history': false, 'activity': true, 'devices': true, 'ips': true}.entries) {
        final one = await owner.plan(o.id, {
          'records': {...asItIs, field.key: field.value},
        });
        expect((one.steps.single as SetRecords).parts.toJson(), {field.key: field.value}, reason: field.key);
      }
    });

    test('activity going off while events are sent on says that sending ends with it', () async {
      final now = await owner.snapshot(o.id);
      final sending = now.record.copy()
        ..tracking = const RecordTracking(activity: true, history: true)
        ..eventExport = RecordExport(key: Uint8List(32), by: SetupWorld.owner);
      final off = await planSetup(setupFile({'records': {'activity': false}}), now.change(record: sending));
      expect(texts(off.steps), ['records: {"activity":false} (ends event export)']);
      expect((off.steps.single as SetRecords).endsEventExport, isTrue);
      expect(off.after.eventExport, isNull);
      // Something else going off does not end it.
      final other = await planSetup(setupFile({'records': {'history': false}}), now.change(record: sending));
      expect(texts(other.steps), ['records: {"history":false}']);
      // Nor does activity going off where nothing is sent on.
      final quiet = now.record.copy()..tracking = const RecordTracking(activity: true);
      final plain = await planSetup(setupFile({'records': {'activity': false}}), now.change(record: quiet));
      expect((plain.steps.single as SetRecords).endsEventExport, isFalse);
    });
  });

  group('members', () {
    test('someone who is a member changes in what differs: role, extra Crates, when access ends', () async {
      final ops = await owner.service.saveRole(o.id,
          name: 'Operators', can: {}, crates: {o.production: levelSwitches(CrateLevel.edit)});
      await joined(SetupWorld.ada, o.members);
      final same = await owner.plan(o.id, {
        'members': [
          {'email': ' ADA@northwind.example ', 'role': 'members', 'crates': <String, Object?>{}, 'until': null},
        ],
      });
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      expect(texts(same.notes), ['memberNotInFile ${email(SetupWorld.owner)}']);

      final plan = await owner.plan(o.id, {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'role': 'Operators',
            'crates': {'Staging': 'use'},
            'until': kLater,
          },
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps),
          ['member ${email(SetupWorld.ada)}: role Operators extra Staging="use" until $kLater']);
      final step = plan.steps.single as ChangeMember;
      expect(step.uid, SetupWorld.ada);
      expect(step.role, 'Operators');
      expect(step.roleId, ops);
      expect(step.crates, {'Staging': levelSwitches(CrateLevel.use)});
      expect(step.until!.value, secondsOf(kLater));
      expect(step.dropsExtraCrates, isFalse);
      expect(step.needsRecentSignIn, isTrue);
      final after = plan.after.members[SetupWorld.ada]!;
      expect(after.role, ops);
      expect(after.grants, {o.staging: levelSwitches(CrateLevel.use)});
      expect(after.endsAt, secondsOf(kLater));

      // Each by itself.
      Future<String> one(Map<String, Object?> parts) async {
        final p = await owner.plan(o.id, {
          'members': [
            {'email': email(SetupWorld.ada), ...parts},
          ],
        });
        expect(p.problems, isEmpty);
        return '${p.steps.single}';
      }

      expect(await one({'role': 'Operators'}), 'member ${email(SetupWorld.ada)}: role Operators');
      expect(await one({'crates': {'Staging': 'connect'}}),
          'member ${email(SetupWorld.ada)}: extra Staging="connect"');
      expect(await one({'until': kLater}), 'member ${email(SetupWorld.ada)}: until $kLater');
      // What is named as it is beside something that differs is no part of the step.
      expect(await one({'role': 'Members', 'crates': {'Staging': 'connect'}, 'until': null}),
          'member ${email(SetupWorld.ada)}: extra Staging="connect"');
      expect(await one({'role': 'Operators', 'crates': <String, Object?>{}, 'until': null}),
          'member ${email(SetupWorld.ada)}: role Operators');
      await owner.service.setMemberEndsAt(o.id, SetupWorld.ada, secondsOf(kLater));
      expect(await one({'until': null}), 'member ${email(SetupWorld.ada)}: no end');
      expect(await one({'until': '2031-01-01T00:00:00Z'}),
          'member ${email(SetupWorld.ada)}: until 2031-01-01T00:00:00Z');
      expect(await one({'role': 'Operators', 'until': kLater}), 'member ${email(SetupWorld.ada)}: role Operators');
      await owner.service.setMemberGrants(o.id, SetupWorld.ada, {o.staging: levelSwitches(CrateLevel.use)});
      expect(await one({'role': 'Operators', 'crates': {'Staging': 'use'}}),
          'member ${email(SetupWorld.ada)}: role Operators');
    });

    test('a member is found by their address, however this device holds it', () async {
      await joined(SetupWorld.ada, o.members);
      final now = await owner.snapshot(o.id);
      final loud = now.change(members: [
        for (final m in now.members)
          m.uid == SetupWorld.ada
              ? SnapshotMember(
                  uid: m.uid,
                  email: ' Ada@Northwind.EXAMPLE ',
                  compared: m.compared,
                  keysTrusted: m.keysTrusted,
                )
              : m,
      ]);
      final plan = await planSetup(
          setupFile({
            'members': [
              {'email': email(SetupWorld.ada), 'until': kLater},
            ],
          }),
          loud);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['member ${email(SetupWorld.ada)}: until $kLater']);
      expect(texts(plan.notes), ['memberNotInFile ${email(SetupWorld.owner)}']);
    });

    test('someone who was removed is invited as anyone else is, not changed', () async {
      await joined(SetupWorld.ada, o.members);
      await owner.service.removeMember(o.id, SetupWorld.ada);
      final now = await owner.snapshot(o.id);
      expect(now.member(SetupWorld.ada), isNull, reason: 'a snapshot lists who was not removed');
      expect(now.record.members[SetupWorld.ada]!.status, MemberStatus.removed);
      final file = setupFile({
        'members': [
          {'email': email(SetupWorld.ada), 'role': 'Members'},
        ],
      });
      final plan = await planSetup(file, now);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['invite ${email(SetupWorld.ada)} as Members']);
      // Where this device still lists them, the record is what counts.
      final listed = now.change(members: [
        ...now.members,
        SnapshotMember(uid: SetupWorld.ada, email: email(SetupWorld.ada)),
      ]);
      final still = await planSetup(file, listed);
      expect(still.problems, isEmpty);
      expect(texts(still.steps), ['invite ${email(SetupWorld.ada)} as Members']);
    });

    test('a role a file adds is one its members can be given in the same file', () async {
      await joined(SetupWorld.ada, o.members);
      final plan = await owner.plan(o.id, {
        'roles': [
          {'name': 'Operators'},
        ],
        'members': [
          {'email': email(SetupWorld.ada), 'role': 'operators'},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add role Operators: can nothing; no crates',
        'member ${email(SetupWorld.ada)}: role Operators',
      ]);
      final step = plan.steps.last as ChangeMember;
      expect(step.roleId, isNull, reason: 'it gets its id when it is made');
      expect(plan.added[plan.after.members[SetupWorld.ada]!.role], 'Operators');
    });

    test('made an owner or admin only by someone who compared their keys, and their extra Crates end',
        () async {
      // The second owner never compared Lin's keys; the first one did.
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      await joined(SetupWorld.lin, o.members, grants: {o.staging: levelSwitches(CrateLevel.use)});
      final file = {
        'members': [
          {'email': email(SetupWorld.lin), 'role': 'admin'},
        ],
      };
      final not = await second.plan(o.id, file);
      expect(texts(not.problems),
          ['compareFirst ${email(SetupWorld.lin)} <member ${email(SetupWorld.lin)}: role admin (extra crates end)>']);
      expect(not.steps, isEmpty);
      final plan = await owner.plan(o.id, file);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['member ${email(SetupWorld.lin)}: role admin (extra crates end)']);
      final step = plan.steps.single as ChangeMember;
      expect(step.role, 'admin');
      expect(step.roleId, 'admin');
      expect(step.dropsExtraCrates, isTrue);
      expect(step.crates, isNull);
      expect(plan.after.members[SetupWorld.lin]!.grants, isEmpty);
      // Once the second owner compared them, it may.
      await second.service.verifyMember(o.id, SetupWorld.lin);
      expect((await second.plan(o.id, file)).problems, isEmpty);
      // An owner, the same; and a role below needs no comparing.
      final toOwner = await second.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.lin), 'role': 'Owner'},
        ],
      });
      expect(texts(toOwner.steps), ['member ${email(SetupWorld.lin)}: role owner (extra crates end)']);
      // Named with extra Crates as well, the record refuses it.
      final both = await owner.plan(o.id, {
        'members': [
          {
            'email': email(SetupWorld.lin),
            'role': 'admin',
            'crates': {'Production': 'use'},
          },
        ],
      });
      expect(texts(both.problems), [
        'refused (owners and admins need no extra Crate) '
            '<member ${email(SetupWorld.lin)}: role admin extra Production="use">',
      ]);
    });

    test('nobody changes their own membership by a file, nor an owner\'s', () async {
      final second = await joined(SetupWorld.second, FixedRoles.owner);
      final own = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.owner), 'role': 'admin'},
        ],
      });
      expect(texts(own.problems), ['ownMembership ${email(SetupWorld.owner)}']);
      expect(own.steps, isEmpty);
      // Named as they are, there is nothing in the way.
      final same = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.owner), 'role': 'owner', 'crates': <String, Object?>{}, 'until': null},
        ],
      });
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      // Owners are equals.
      final other = await second.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.owner), 'role': 'admin'},
        ],
      });
      expect(texts(other.problems),
          ['refused (only people below you) <member ${email(SetupWorld.owner)}: role admin>']);
      final ends = await second.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.owner), 'until': kLater},
        ],
      });
      expect(texts(ends.problems),
          ['refused (only people below you) <member ${email(SetupWorld.owner)}: until $kLater>']);
    });

    test('access never ends at a time that has passed, and names of roles and Crates must be there',
        () async {
      await joined(SetupWorld.ada, o.members);
      final plan = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.ada), 'until': kPassed},
          {'email': email(SetupWorld.sam), 'role': 'Members', 'until': kPassed},
          {'email': email(SetupWorld.lin), 'role': 'Nobodies'},
          {
            'email': email(SetupWorld.second),
            'role': 'Members',
            'crates': {'Nowhere': 'use'},
          },
        ],
      });
      expect(texts(plan.problems), [
        'untilPassed ${email(SetupWorld.ada)}',
        'untilPassed ${email(SetupWorld.sam)}',
        'noSuchRole Nobodies [${email(SetupWorld.lin)}]',
        'noSuchCrate Nowhere [${email(SetupWorld.second)}]',
      ]);
      expect(plan.steps, isEmpty);
      // The very moment the snapshot was taken has passed; the next second has not.
      final now = await owner.snapshot(o.id);
      Future<SetupPlan> at(int seconds) => planSetup(
          setupFile({
            'members': [
              {'email': email(SetupWorld.ada), 'until': setupTimeOf(seconds)},
            ],
          }),
          now);
      expect(texts((await at(now.now)).problems), ['untilPassed ${email(SetupWorld.ada)}']);
      expect((await at(now.now + 1)).problems, isEmpty);
    });

    test('what someone below an owner may give is the record\'s to say', () async {
      // Leads may change roles and manage Production without revealing; they use Staging.
      final leads = await owner.service.saveRole(o.id, name: 'Leads', can: {
        RoleCan.changeRoles,
      }, crates: {
        o.production: {CrateSwitches.connect, CrateSwitches.manage},
        o.staging: levelSwitches(CrateLevel.use),
      });
      await owner.service.orderRoles(o.id, [leads, o.members]);
      final ada = await joined(SetupWorld.ada, leads);
      await joined(SetupWorld.lin, o.members);
      Future<List<String>> problems(Map<String, Object?> parts) async => texts((await ada.plan(o.id, {
            'members': [
              {'email': email(SetupWorld.lin), ...parts},
            ],
          }))
              .problems);
      expect(await problems({'crates': {'Staging': 'connect'}}), [
        'refused (giving a Crate needs manage on it) <member ${email(SetupWorld.lin)}: extra Staging="connect">',
      ]);
      // (Lin uses Production through their role; to change things there is more than Ada has.)
      expect(await problems({'crates': {'Production': 'edit'}}), [
        'refused (hands out more than they have) <member ${email(SetupWorld.lin)}: extra Production="edit">',
      ]);
      expect(await problems({'role': 'Leads'}), [
        'refused (not allowed to give that role) <member ${email(SetupWorld.lin)}: role Leads>',
      ]);
      expect(await problems({'role': 'admin'}), isNotEmpty);
      // What they have themselves, they give.
      expect(await problems({'crates': {'Production': ['connect']}}), isEmpty);
    });
  });

  group("a member's limits", () {
    test('each vault whose limit differs is a step of its own: held to a level, taken away, lifted', () async {
      await joined(SetupWorld.ada, o.members);
      final file = {
        'members': [
          {
            'email': email(SetupWorld.ada),
            'limits': {'Production': 'connect', 'Staging': 'none'},
          },
        ],
      };
      final plan = await owner.plan(o.id, file);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'member ${email(SetupWorld.ada)}: limit Production="connect"',
        'member ${email(SetupWorld.ada)}: limit Staging="none"',
      ]);
      final first = plan.steps.first as LimitMember;
      expect(first.uid, SetupWorld.ada);
      expect(first.email, email(SetupWorld.ada));
      expect(first.crate, 'Production');
      expect(first.crateId, o.production);
      expect(first.switches, levelSwitches(CrateLevel.connect));
      expect(first.needsRecentSignIn, isTrue);
      expect((plan.steps.last as LimitMember).switches, isEmpty);
      expect(plan.writesNewKinds, isTrue);
      expect(plan.needsRecentSignIn, isTrue);
      expect(plan.after.members[SetupWorld.ada]!.limits,
          {o.production: levelSwitches(CrateLevel.connect), o.staging: <String>{}});
      expect(plan.after.switchesOf(SetupWorld.ada, o.production), levelSwitches(CrateLevel.connect));
      expect(plan.after.newKindsUsed, isTrue);

      // Set so by hand (the member panel), the same file is nothing to do,
      // and one that does not name limits leaves them.
      await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.production: VaultPick.connect, o.staging: VaultPick.none});
      final same = await owner.plan(o.id, file);
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      expect(same.writesNewKinds, isFalse);
      expect(
          (await owner.plan(o.id, {
            'members': [
              {'email': email(SetupWorld.ada), 'role': 'Members'},
            ],
          }))
              .steps,
          isEmpty);
      Future<List<String>> steps(Map<String, Object?> limits) async {
        final p = await owner.plan(o.id, {
          'members': [
            {'email': email(SetupWorld.ada), 'limits': limits},
          ],
        });
        expect(p.problems, isEmpty);
        return texts(p.steps);
      }

      // Named, they are all of them: an empty one lifts each, one that
      // leaves one out lifts that one, and another level is a step.
      expect(await steps({}), [
        'member ${email(SetupWorld.ada)}: no limit in Production',
        'member ${email(SetupWorld.ada)}: no limit in Staging',
      ]);
      expect(await steps({'Production': 'connect'}), ['member ${email(SetupWorld.ada)}: no limit in Staging']);
      expect(await steps({'Staging': 'none', 'Production': ['connect', 'reveal']}), [
        'member ${email(SetupWorld.ada)}: limit Production=["connect","reveal"]',
      ]);
      final lifted = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.ada), 'limits': <String, Object?>{}},
        ],
      });
      expect((lifted.steps.first as LimitMember).switches, isNull);
      expect(lifted.after.members[SetupWorld.ada]!.limits, isEmpty);
      expect(lifted.after.switchesOf(SetupWorld.ada, o.production), levelSwitches(CrateLevel.use));
    });

    test('a vault named both as extra access and as a limit is a role made by hand: extra access first, then the '
        'limit, as the member panel writes them', () async {
      final builders = await owner.service.saveRole(o.id,
          name: 'Builders', can: {}, crates: {o.production: {CrateSwitches.connect, CrateSwitches.add}});
      await joined(SetupWorld.ada, builders);
      final before = await owner.snapshot(o.id);
      final plan = await planSetup(
          setupFile({
            'members': [
              {
                'email': email(SetupWorld.ada),
                'crates': {'Production': 'use'},
                'limits': {'Production': 'use'},
              },
            ],
          }),
          before);
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'member ${email(SetupWorld.ada)}: extra Production="use"',
        'member ${email(SetupWorld.ada)}: limit Production="use"',
      ]);
      expect(plan.after.switchesOf(SetupWorld.ada, o.production), levelSwitches(CrateLevel.use));
      // Exactly what the member panel writes when Use is picked there.
      final panel = vaultPickChanges(before.record, SetupWorld.ada, {o.production: VaultPick.use});
      expect(panel.map((c) => c.type), [RecordTypes.memberSet, RecordTypes.memberLimit]);
      final picked = vaultRecordAfter(before.record, SetupWorld.ada, {o.production: VaultPick.use}).members[SetupWorld.ada]!;
      expect(plan.after.members[SetupWorld.ada]!.grants, picked.grants);
      expect(plan.after.members[SetupWorld.ada]!.limits, picked.limits);
    });

    test('refused as the record refuses them: an owner or admin, as they are or as the file makes them, an '
        'owners-only vault, a vault there is not, and oneself', () async {
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      await joined(SetupWorld.second, FixedRoles.owner);
      await joined(SetupWorld.ada, o.members);
      await joined(SetupWorld.lin, FixedRoles.admin);
      Future<List<String>> problems(Map<String, Object?> member) async => texts((await owner.plan(o.id, {
            'members': [member],
          }))
              .problems);
      final ada = email(SetupWorld.ada), lin = email(SetupWorld.lin);
      expect(
          await problems({
            'email': lin,
            'limits': {'Production': 'connect'},
          }),
          ['refused (owners and admins have no limits) <member $lin: limit Production="connect">']);
      expect(
          await problems({
            'email': email(SetupWorld.second),
            'limits': {'Staging': 'none'},
          }),
          ['refused (owners and admins have no limits) <member ${email(SetupWorld.second)}: limit Staging="none">']);
      // Made an admin by the file: the role is the file's, and limits it
      // names come after it.
      final made = await owner.plan(o.id, {
        'members': [
          {
            'email': ada,
            'role': 'admin',
            'limits': {'Production': 'connect'},
          },
        ],
      });
      expect(texts(made.problems), ['refused (owners and admins have no limits) <member $ada: limit Production="connect">']);
      expect(texts(made.steps), ['member $ada: role admin']);
      expect(
          await problems({
            'email': ada,
            'limits': {'Vault': 'connect'},
          }),
          ['refused (no such Crate, or owners-only) <member $ada: limit Vault="connect">']);
      expect(
          await problems({
            'email': ada,
            'limits': {'Nowhere': 'connect', 'Production': 'connect'},
          }),
          ['noSuchCrate Nowhere [$ada]']);
      expect(
          await problems({
            'email': email(SetupWorld.owner),
            'limits': {'Production': 'connect'},
          }),
          ['ownMembership ${email(SetupWorld.owner)}']);
      // Named as they are, there is nothing in the way.
      for (final who in [lin, email(SetupWorld.owner), email(SetupWorld.second)]) {
        expect(await problems({'email': who, 'limits': <String, Object?>{}}), isEmpty, reason: who);
      }
    });

    test('made an owner or admin, their limits end in the same entry, and the step says so', () async {
      await joined(SetupWorld.ada, o.members);
      await joined(SetupWorld.lin, o.members);
      await owner.service.setVaultAccess(o.id, SetupWorld.ada, {o.production: VaultPick.connect});
      for (final limits in [<String, Object?>{}, null]) {
        final plan = await owner.plan(o.id, {
          'members': [
            {'email': email(SetupWorld.ada), 'role': 'admin', 'limits': ?limits},
          ],
        });
        expect(plan.problems, isEmpty, reason: '$limits');
        expect(texts(plan.steps), ['member ${email(SetupWorld.ada)}: role admin (limits end)'], reason: '$limits');
        expect((plan.steps.single as ChangeMember).dropsLimits, isTrue);
        expect(plan.after.members[SetupWorld.ada]!.limits, isEmpty);
        expect(plan.writesNewKinds, isFalse, reason: 'a member.set, and no limit of its own');
      }
      // Someone without any: nothing said of them.
      final lin = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.lin), 'role': 'admin'},
        ],
      });
      expect(texts(lin.steps), ['member ${email(SetupWorld.lin)}: role admin']);
    });

    test('what someone below an owner may limit is the record\'s to say: a vault they manage, and lifting gives '
        'back only what they have themselves', () async {
      // Leads manage Production with nothing more there; they use Staging.
      final leads = await owner.service.saveRole(o.id, name: 'Leads', can: {}, crates: {
        o.production: {CrateSwitches.connect, CrateSwitches.manage},
        o.staging: levelSwitches(CrateLevel.use),
      });
      await owner.service.orderRoles(o.id, [leads, o.members]);
      final ada = await joined(SetupWorld.ada, leads);
      await joined(SetupWorld.lin, o.members);
      Future<List<String>> problems(Map<String, Object?> limits) async => texts((await ada.plan(o.id, {
            'members': [
              {'email': email(SetupWorld.lin), 'limits': limits},
            ],
          }))
              .problems);
      final lin = email(SetupWorld.lin);
      expect(await problems({'Production': 'connect'}), isEmpty);
      expect(await problems({'Staging': 'connect'}),
          ['refused (limiting a Crate needs manage on it) <member $lin: limit Staging="connect">']);
      // An owner took Production away from Lin: lifting that would give
      // Lin back the use of it, which is more than Ada has there.
      await owner.service.setVaultAccess(o.id, SetupWorld.lin, {o.production: VaultPick.none});
      expect(await problems({}), ['refused (hands out more than they have) <member $lin: no limit in Production>']);
      // Up to what she has, she may.
      expect(await problems({'Production': ['connect']}), isEmpty);
    });

    test('someone who is not a member yet is never named with limits: an invitation carries none', () async {
      final plan = await owner.plan(o.id, {
        'members': [
          {
            'email': email(SetupWorld.sam),
            'role': 'Members',
            'limits': {'Production': 'connect'},
          },
          {'email': email(SetupWorld.lin), 'role': 'Members', 'limits': <String, Object?>{}},
        ],
      });
      expect(texts(plan.problems), ['limitsNeedMember ${email(SetupWorld.sam)}']);
      expect(texts(plan.steps), ['invite ${email(SetupWorld.lin)} as Members']);
      // A vault there is not is said as for anyone.
      final nowhere = await owner.plan(o.id, {
        'members': [
          {
            'email': email(SetupWorld.sam),
            'role': 'Members',
            'limits': {'Nowhere': 'none'},
          },
        ],
      });
      expect(texts(nowhere.problems), ['noSuchCrate Nowhere [${email(SetupWorld.sam)}]']);
    });

    test('while ZestSSH Cloud does not take new kinds of entry, a limit stands in the way, and the rest is planned',
        () async {
      await joined(SetupWorld.ada, o.members);
      world.server.newRecordKinds = false;
      addTearDown(() => newRecordKindsOn.value = true);
      final now = await owner.snapshot(o.id);
      expect(now.newKindsOn, isFalse, reason: 'as the list of Orchards said');
      final file = setupFile({
        'members': [
          {
            'email': email(SetupWorld.ada),
            'until': kLater,
            'limits': {'Production': 'connect'},
          },
        ],
      });
      final plan = await planSetup(file, now);
      expect(texts(plan.problems), ['notYet <member ${email(SetupWorld.ada)}: limit Production="connect">']);
      expect(texts(plan.steps), ['member ${email(SetupWorld.ada)}: until $kLater']);
      expect(plan.canApply, isFalse);
      expect(plan.after.members[SetupWorld.ada]!.limits, isEmpty, reason: 'not rehearsed as made');
      // Limits that change nothing are no step, and nothing in the way.
      final none = await planSetup(
          setupFile({
            'members': [
              {'email': email(SetupWorld.ada), 'limits': <String, Object?>{}},
            ],
          }),
          now);
      expect(none.problems, isEmpty);
      expect(none.steps, isEmpty);
      // Turned on, the same file is planned in full.
      final on = await planSetup(file, now.change(newKindsOn: true));
      expect(on.problems, isEmpty);
      expect(texts(on.steps), [
        'member ${email(SetupWorld.ada)}: until $kLater',
        'member ${email(SetupWorld.ada)}: limit Production="connect"',
      ]);
      world.server.newRecordKinds = true;
      expect((await owner.snapshot(o.id)).newKindsOn, isTrue);
    });

    test('a vault the file adds can be named in limits; the step finds it by its name', () async {
      await joined(SetupWorld.ada, o.members);
      final plan = await owner.plan(o.id, {
        'crates': [
          {'name': 'Lab'},
        ],
        'members': [
          {
            'email': email(SetupWorld.ada),
            'limits': {'Lab': 'none'},
          },
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['add crate Lab', 'member ${email(SetupWorld.ada)}: limit Lab="none"']);
      final step = plan.steps.last as LimitMember;
      expect(step.crate, 'Lab');
      expect(step.crateId, isNull, reason: 'it gets its id when it is made');
    });
  });

  group('invitations', () {
    test('someone who is not a member is invited, with the role, the extra Crates and the end the file names',
        () async {
      final plan = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.sam), 'role': 'Members'},
          {
            'email': email(SetupWorld.lin),
            'role': 'members',
            'crates': {'Staging': 'use'},
            'until': kLater,
          },
          {'email': email(SetupWorld.ada), 'role': 'Admin'},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'invite ${email(SetupWorld.sam)} as Members',
        'invite ${email(SetupWorld.lin)} as Members extra Staging="use" until $kLater',
        'invite ${email(SetupWorld.ada)} as admin',
      ]);
      final step = plan.steps[1] as Invite;
      expect(step.role, 'Members');
      expect(step.roleId, o.members);
      expect(step.crates, {'Staging': levelSwitches(CrateLevel.use)});
      expect(step.until, secondsOf(kLater));
      expect(step.again, isFalse);
      expect(step.needsRecentSignIn, isFalse);
      expect((plan.steps.last as Invite).roleId, 'admin');
      expect(plan.needsRecentSignIn, isFalse);
      // Nothing of an invitation is in the record.
      expect(plan.after.seq, world.server.recordOf(o.id).seq);
    });

    test('an invitation that waits with this very offer is left; with another, or run out, it is replaced',
        () async {
      await owner.service.invite(o.id, email: email(SetupWorld.sam), role: o.members);
      await owner.service.invite(o.id,
          email: email(SetupWorld.lin),
          role: o.members,
          grants: {o.staging: levelSwitches(CrateLevel.use)},
          endsAt: secondsOf(kLater));
      Map<String, Object?> file({Object? samRole = 'Members', Object? linCrates, Object? linUntil = kLater}) => {
            'members': [
              {'email': email(SetupWorld.owner)},
              {'email': email(SetupWorld.sam), 'role': samRole},
              {
                'email': email(SetupWorld.lin),
                'role': 'Members',
                'crates': linCrates ?? {'Staging': 'use'},
                'until': linUntil,
              },
            ],
          };
      final same = await owner.plan(o.id, file());
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      expect(texts(same.notes), ['invited ${email(SetupWorld.sam)}', 'invited ${email(SetupWorld.lin)}']);
      // Another role, other Crates, another end, or no end: each is another offer.
      expect(texts((await owner.plan(o.id, file(samRole: 'admin'))).steps),
          ['invite again ${email(SetupWorld.sam)} as admin']);
      expect(texts((await owner.plan(o.id, file(linCrates: {'Staging': 'connect'}))).steps),
          ['invite again ${email(SetupWorld.lin)} as Members extra Staging="connect" until $kLater']);
      expect(texts((await owner.plan(o.id, file(linCrates: <String, Object?>{}))).steps),
          ['invite again ${email(SetupWorld.lin)} as Members until $kLater']);
      expect(texts((await owner.plan(o.id, file(linUntil: '2031-01-01T00:00:00Z'))).steps),
          ['invite again ${email(SetupWorld.lin)} as Members extra Staging="use" until 2031-01-01T00:00:00Z']);
      final open = await owner.plan(o.id, file(linUntil: null));
      expect(texts(open.steps), ['invite again ${email(SetupWorld.lin)} as Members extra Staging="use"']);
      expect((open.steps.single as Invite).again, isTrue);
      // Accepted: someone compares their keys and confirms.
      final invites = await owner.service.invites(o.id);
      world.server.acceptAs(o.id, invites.firstWhere((i) => i.email == email(SetupWorld.sam)).id, SetupWorld.sam);
      expect(texts((await owner.plan(o.id, file())).notes),
          ['acceptedWaiting ${email(SetupWorld.sam)}', 'invited ${email(SetupWorld.lin)}']);
      // Run out: asked again.
      world.server.lapse(o.id, invites.firstWhere((i) => i.email == email(SetupWorld.lin)).id);
      final lapsed = await owner.plan(o.id, file());
      expect(texts(lapsed.steps),
          ['invite again ${email(SetupWorld.lin)} as Members extra Staging="use" until $kLater']);
      expect(texts(lapsed.notes), ['acceptedWaiting ${email(SetupWorld.sam)}']);
    });

    test('an invitation needs a role, a time to come, and someone who may invite', () async {
      final ada = await joined(SetupWorld.ada, o.members);
      final plan = await owner.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.sam)},
          {'email': email(SetupWorld.lin), 'role': 'Members', 'until': kPassed},
        ],
      });
      expect(texts(plan.problems), [
        'inviteNeedsRole ${email(SetupWorld.sam)}',
        'untilPassed ${email(SetupWorld.lin)}',
      ]);
      // Ada's role cannot invite: she cannot see who is invited either.
      expect((await ada.snapshot(o.id)).invites, isNull);
      final hers = await ada.plan(o.id, {
        'members': [
          {'email': email(SetupWorld.sam), 'role': 'Members'},
          {'email': email(SetupWorld.lin)},
        ],
      });
      expect(texts(hers.problems), [
        'cannotInvite ${email(SetupWorld.sam)}',
        'cannotInvite ${email(SetupWorld.lin)}',
      ]);
      // Were the invitations read to her all the same, she is told the same:
      // that she may not invite, before anything about the offer.
      final seen = await planSetup(
          setupFile({
            'members': [
              {'email': email(SetupWorld.sam), 'role': 'Members'},
              {'email': email(SetupWorld.lin)},
            ],
          }),
          (await ada.snapshot(o.id)).change(invites: const []));
      expect(texts(seen.problems), [
        'cannotInvite ${email(SetupWorld.sam)}',
        'cannotInvite ${email(SetupWorld.lin)}',
      ]);
      // Where the invitations could not be read, nobody is invited on top of one.
      final blind = (await owner.snapshot(o.id)).change(noInvites: true);
      final unread = await planSetup(
          setupFile({
            'members': [
              {'email': email(SetupWorld.sam), 'role': 'Members'},
            ],
          }),
          blind);
      expect(texts(unread.problems), ['cannotInvite ${email(SetupWorld.sam)}']);
    });

    test('what an invitation offers is checked as the record will check the member it adds', () async {
      final ada = await joined(SetupWorld.ada, FixedRoles.admin);
      Future<List<String>> problems(SetupDevice by, Map<String, Object?> member) async =>
          texts((await by.plan(o.id, {
            'members': [
              {'email': email(SetupWorld.sam), ...member},
            ],
          }))
              .problems);
      expect(await problems(ada, {'role': 'admin'}),
          ['refused (only owners add owners and admins) <invite ${email(SetupWorld.sam)} as admin>']);
      expect(await problems(owner, {'role': 'owner', 'until': kLater}),
          ['refused (owners do not end) <invite ${email(SetupWorld.sam)} as owner until $kLater>']);
      expect(await problems(owner, {'role': 'admin', 'crates': {'Staging': 'use'}}), [
        'refused (owners and admins need no extra Crate) '
            '<invite ${email(SetupWorld.sam)} as admin extra Staging="use">',
      ]);
      await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      expect(await problems(owner, {'role': 'Members', 'crates': {'Vault': 'use'}}), [
        'refused (no such Crate, or owners-only) <invite ${email(SetupWorld.sam)} as Members extra Vault="use">',
      ]);
      // What an admin may offer.
      expect(await problems(ada, {'role': 'Members', 'crates': {'Staging': 'manage'}, 'until': kLater}), isEmpty);
    });

    test('an address outside the Orchard\'s domains could never join', () async {
      await owner.service.setRules(o.id, const RecordRules(emailDomains: {'northwind.example'}));
      final plan = await owner.plan(o.id, {
        'members': [
          {'email': 'kai@elsewhere.example', 'role': 'Members'},
          {'email': email(SetupWorld.sam), 'role': 'Members'},
        ],
      });
      expect(texts(plan.problems),
          ['inviteeOutsideDomains kai@elsewhere.example <invite kai@elsewhere.example as Members>']);
      expect(texts(plan.steps), ['invite ${email(SetupWorld.sam)} as Members']);
      // The domains the same file sets count: taken away, anyone may be invited.
      final any = await owner.plan(o.id, {
        'rules': {'email_domains': <String>[]},
        'members': [
          {'email': 'kai@elsewhere.example', 'role': 'Members'},
        ],
      });
      expect(any.problems, isEmpty);
      expect(texts(any.steps), ['rules: {"email_domains":[]}', 'invite kai@elsewhere.example as Members']);
    });

    test('more invitations than one account sends in an hour are said to take more than one run', () async {
      Map<String, Object?> file(int n) => {
            'members': [
              for (var i = 0; i < n; i++) {'email': 'member$i@northwind.example', 'role': 'Members'},
            ],
          };
      final many = await owner.plan(o.id, file(kInvitationsPerHour + 1));
      expect(many.problems, isEmpty);
      expect(many.steps, hasLength(31));
      expect(texts(many.notes), ['manyInvitations 31', 'memberNotInFile ${email(SetupWorld.owner)}']);
      final few = await owner.plan(o.id, file(kInvitationsPerHour));
      expect(few.steps, hasLength(30));
      expect(texts(few.notes), ['memberNotInFile ${email(SetupWorld.owner)}']);
    });

    test('members and invitations the file does not name are listed and left', () async {
      await joined(SetupWorld.ada, o.members);
      await owner.service.invite(o.id, email: email(SetupWorld.sam), role: o.members);
      await owner.service.invite(o.id, email: email(SetupWorld.lin), role: o.members);
      world.server.lapse(o.id, (await owner.service.invites(o.id)).firstWhere((i) => i.email == email(SetupWorld.lin)).id);
      final plan = await owner.plan(o.id, {'members': <Object?>[]});
      expect(plan.steps, isEmpty);
      expect(texts(plan.notes), [
        'memberNotInFile ${email(SetupWorld.owner)}',
        'memberNotInFile ${email(SetupWorld.ada)}',
        // One that ran out is no longer waiting.
        'invitationNotInFile ${email(SetupWorld.sam)}',
      ]);
      expect((await owner.plan(o.id, {'crates': <Object?>[]})).notes.where((n) => '$n'.contains('@')), isEmpty);
    });
  });

  group('hosts', () {
    late String deployProd, deployStaging, backup, web;
    late String webGroup;

    setUp(() async {
      deployProd = await owner.addKey(o.id, 'deploy', crateId: o.production);
      deployStaging = await owner.addKey(o.id, 'Deploy', crateId: o.staging);
      backup = await owner.addKey(o.id, 'backup', crateId: o.staging);
      webGroup = await owner.addGroup(o.id, 'Web', crateId: o.production);
      web = await owner.addHost(o.id, 'web-1',
          crateId: o.production, address: '10.50.0.11', keyId: deployProd, groupId: webGroup, tags: {'prod'});
    });

    Map<String, Object?> hostsOf(String crate, List<Map<String, Object?>> hosts) => {
          'crates': [
            {'name': crate, 'hosts': hosts},
          ],
        };

    test('a host that is there as the file says is no step; one that is not is added in its Crate', () async {
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {
              'name': ' WEB-1 ',
              'address': '10.50.0.11',
              'port': 22,
              'protocol': 'ssh',
              'key': 'deploy',
              'group': 'web',
              'tags': ['prod'],
            },
            {
              'name': 'web-2',
              'address': '10.50.0.12',
              'port': 2222,
              'protocol': 'mosh',
              'key': 'deploy',
              'group': 'Web',
              'tags': ['prod', 'web'],
            },
            {'name': 'db-1', 'address': 'db-1.northwind.example'},
          ]));
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add host web-2 in Production: mosh 10.50.0.12:2222 key deploy group Web tags prod+web',
        'add host db-1 in Production: ssh db-1.northwind.example:22',
      ]);
      final step = plan.steps.first as AddHost;
      expect(step.crate, 'Production');
      expect(step.keyId, deployProd);
      expect(step.group, 'Web');
      expect(step.tags, {'prod', 'web'});
      expect(step.needsRecentSignIn, isFalse);
      final bare = plan.steps.last as AddHost;
      expect(bare.port, 22);
      expect(bare.protocol, 'ssh');
      expect(bare.key, isNull);
      expect(bare.keyId, isNull);
      expect(bare.group, isNull);
      expect(bare.tags, isEmpty);
      expect(texts(plan.notes), ['crateNotInFile Staging']);
      expect(plan.needsRecentSignIn, isFalse);
    });

    test('a key is the one of that name in the host\'s own Crate, else the only one in the Orchard', () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'a', 'address': '10.50.0.21', 'key': 'DEPLOY'},
              // Only Staging has one called that.
              {'name': 'b', 'address': '10.50.0.22', 'key': 'backup'},
            ],
          },
          {
            'name': 'Staging',
            'hosts': [
              {'name': 'c', 'address': '10.50.0.23', 'key': 'deploy'},
            ],
          },
        ],
      });
      expect(plan.problems, isEmpty);
      expect([for (final s in plan.steps) (s as AddHost).keyId], [deployProd, backup, deployStaging]);
      expect([for (final s in plan.steps) (s as AddHost).key], ['DEPLOY', 'backup', 'deploy']);
    });

    test('a key nobody has, a name two keys share, and a key of a watched Crate used elsewhere', () async {
      final lab = await owner.service.createCrate(o.id, 'Lab');
      await owner.addKey(o.id, 'shared', crateId: o.staging);
      await owner.addKey(o.id, 'shared', crateId: lab);
      await owner.addKey(o.id, 'twice', crateId: o.production);
      await owner.addKey(o.id, 'Twice', crateId: o.production);
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'a', 'address': '10.50.0.21', 'key': 'nobody'},
            {'name': 'b', 'address': '10.50.0.22', 'key': 'shared'},
            {'name': 'c', 'address': '10.50.0.23', 'key': 'twice'},
            {'name': 'web-1', 'key': 'nobody'},
          ]));
      expect(texts(plan.problems), [
        'noSuchKey nobody [a]',
        'ambiguousKey shared [b]',
        'ambiguousKey twice [c]',
        'noSuchKey nobody [web-1]',
      ]);
      expect(plan.steps, isEmpty);
      // In its own Crate, a name another Crate has too tells.
      final own = await owner.plan(
          o.id,
          hostsOf('Lab', [
            {'name': 'd', 'address': '10.50.0.24', 'key': 'shared'},
          ]));
      expect(own.problems, isEmpty);

      // A watched Crate's key signs in only to that Crate's hosts.
      await owner.service.setCrateWatched(o.id, o.staging, true);
      final watched = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'b', 'address': '10.50.0.22', 'key': 'backup'},
            ],
          },
          {
            'name': 'Staging',
            'hosts': [
              {'name': 'c', 'address': '10.50.0.23', 'key': 'backup'},
            ],
          },
        ],
      });
      expect(texts(watched.problems), ['watchedKeyElsewhere backup [b]']);
      expect(texts(watched.steps), ['add host c in Staging: ssh 10.50.0.23:22 key backup']);
    });

    test('a key of a Crate the same file makes watched is held to that Crate as well', () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'b', 'address': '10.50.0.22', 'key': 'backup'},
            ],
          },
          {'name': 'Staging', 'watched': true},
        ],
      });
      expect(texts(plan.problems), ['watchedKeyElsewhere backup [b]']);
    });

    test('a group that is not there is added once, before the first host that names it', () async {
      final plan = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'db-1', 'address': '10.50.0.31', 'group': 'Databases'},
              {'name': 'db-2', 'address': '10.50.0.32', 'group': 'databases'},
              {'name': 'web-2', 'address': '10.50.0.12', 'group': 'Web'},
              {'name': 'web-1', 'group': 'Databases'},
            ],
          },
          {
            'name': 'Staging',
            'hosts': [
              // The one group of that name in the Orchard, in another Crate.
              {'name': 'web-s', 'address': '10.30.0.11', 'group': 'Web'},
              {'name': 'db-s', 'address': '10.30.0.31', 'group': 'Databases'},
            ],
          },
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add group Databases in Production',
        'add host db-1 in Production: ssh 10.50.0.31:22 group Databases',
        'add host db-2 in Production: ssh 10.50.0.32:22 group databases',
        'add host web-2 in Production: ssh 10.50.0.12:22 group Web',
        'host web-1 in Production: group Databases',
        'add host web-s in Staging: ssh 10.30.0.11:22 group Web',
        'add group Databases in Staging',
        'add host db-s in Staging: ssh 10.30.0.31:22 group Databases',
      ]);
      expect(plan.steps.first.needsRecentSignIn, isFalse);
      expect((plan.steps.first as AddGroup).crate, 'Production');
      expect((plan.steps.first as AddGroup).name, 'Databases');
    });

    test("an FTPS host keeps its kind (3.4): a file that gives it a protocol says so, and changes nothing", () async {
      await owner.addHost(o.id, 'files-1', crateId: o.production, protocol: 'ftps', port: 21);
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'files-1', 'protocol': 'sftp'},
          ]));
      expect(texts(plan.problems), ['ftpsHost files-1 [Production]']);
      expect(plan.steps, isEmpty);
      // Its other parts change as any host's do.
      final port = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'files-1', 'port': 2121},
          ]));
      expect(port.problems, isEmpty);
      expect('${port.steps.single}', 'host files-1 in Production: port 2121');
    });

    test('two groups of one name do not tell which is meant', () async {
      await owner.addGroup(o.id, 'web', crateId: o.production);
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-2', 'address': '10.50.0.12', 'group': 'Web'},
            {'name': 'web-1'},
          ]));
      expect(texts(plan.problems), ['ambiguousGroup Web [web-2]']);
      expect(plan.steps, isEmpty);
    });

    test('a host that is there changes in what differs, each thing by itself', () async {
      Future<SetupStep> one(Map<String, Object?> parts) async {
        final plan = await owner.plan(
            o.id,
            hostsOf('Production', [
              {'name': 'web-1', ...parts},
            ]));
        expect(plan.problems, isEmpty);
        return plan.steps.last;
      }

      expect('${await one({'address': '10.50.0.99'})}', 'host web-1 in Production: address 10.50.0.99');
      expect('${await one({'port': 2222})}', 'host web-1 in Production: port 2222');
      expect('${await one({'protocol': 'mosh'})}', 'host web-1 in Production: protocol mosh');
      // A host made SFTP only (files, no terminal).
      expect('${await one({'protocol': 'sftp'})}', 'host web-1 in Production: protocol sftp');
      expect('${await one({'key': 'backup'})}', 'host web-1 in Production: key backup');
      expect('${await one({'key': null})}', 'host web-1 in Production: no key');
      expect('${await one({'group': null})}', 'host web-1 in Production: no group');
      expect('${await one({'tags': ['prod', 'web']})}', 'host web-1 in Production: tags prod+web');
      expect('${await one({'tags': <String>[]})}', 'host web-1 in Production: tags nothing');
      final step = await one({'key': 'backup', 'address': '10.50.0.99'}) as ChangeHost;
      expect(step.hostId, web);
      expect(step.name, 'web-1');
      expect(step.keyId, backup);
      expect(step.key!.value, 'backup');
      expect(step.port, isNull);
      expect(step.protocol, isNull);
      expect(step.group, isNull);
      expect(step.tags, isNull);
      expect(step.needsRecentSignIn, isFalse);
      expect(((await one({'key': null})) as ChangeHost).keyId, isNull);
      // A new group for it is added first.
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'group': 'Edge'},
          ]));
      expect(texts(plan.steps), ['add group Edge in Production', 'host web-1 in Production: group Edge']);
      // All of it at once.
      expect(
          '${await one({
                'address': '10.50.0.99',
                'port': 2222,
                'protocol': 'et',
                'key': null,
                'group': null,
                'tags': <String>[],
              })}',
          'host web-1 in Production: address 10.50.0.99 port 2222 protocol et no key no group tags nothing');
      // A host with no key or group named as none: nothing.
      await owner.addHost(o.id, 'bare', crateId: o.production);
      final none = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'bare', 'key': null, 'group': null, 'tags': <String>[]},
            {'name': 'web-1'},
          ]));
      expect(none.steps, isEmpty);
    });

    test('a new host needs an address; two hosts of one name do not tell which is meant', () async {
      await owner.addHost(o.id, 'WEB-1', crateId: o.production, address: '10.50.0.50');
      final plan = await owner.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'port': 2222},
            {'name': 'web-9', 'port': 2222},
          ]));
      expect(texts(plan.problems), ['ambiguousHost web-1 [Production]', 'hostNeedsAddress web-9 [Production]']);
      expect(plan.steps, isEmpty);
    });

    test('hosts are written only where this account may add and change them, said once for a Crate', () async {
      // What the owner wrote on their device reaches the others through ZestSSH Cloud.
      await owner.addHost(o.id, 'db-1', crateId: o.production, address: '10.50.0.21');
      await owner.sync(o.id);
      final lin = await joined(SetupWorld.lin, o.members);
      final plan = await lin.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'port': 2222},
            {'name': 'web-1b', 'address': '10.50.0.13'},
            {'name': 'db-1', 'port': 2222},
            {'name': 'web-2', 'address': '10.50.0.12'},
            {'name': 'web-3', 'address': '10.50.0.13', 'group': 'New'},
          ]));
      expect(texts(plan.problems), ['cannotEditHosts Production', 'cannotAddHosts Production']);
      expect(plan.steps, isEmpty);
      // Named as they are, nothing stands in the way of someone who only uses the Crate.
      final same = await lin.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'address': '10.50.0.11', 'key': 'deploy', 'group': 'Web'},
          ]));
      expect(same.problems, isEmpty);
      expect(same.steps, isEmpty);
      // Someone who may edit and not add changes a host, and adds no group for it.
      final editors = await owner.service.saveRole(o.id, name: 'Editors', can: {}, crates: {
        o.production: {CrateSwitches.connect, CrateSwitches.edit},
      });
      final ada = await joined(SetupWorld.ada, editors);
      final edits = await ada.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'port': 2222},
          ]));
      expect(edits.problems, isEmpty);
      expect(texts(edits.steps), ['host web-1 in Production: port 2222']);
      final grouped = await ada.plan(
          o.id,
          hostsOf('Production', [
            {'name': 'web-1', 'group': 'New'},
          ]));
      expect(texts(grouped.problems), ['cannotAddHosts Production']);
      expect(grouped.steps, isEmpty);
    });

    test('a host is looked for in its own Crate: one of that name in another Crate is another host',
        () async {
      // web-1 is in Production. Named in Staging, it is one to add there.
      final plan = await owner.plan(
          o.id,
          hostsOf('Staging', [
            {'name': 'web-1', 'address': '10.30.0.11'},
          ]));
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), ['add host web-1 in Staging: ssh 10.30.0.11:22']);
      // And once both Crates have one of that name, neither is taken for the other.
      await owner.addHost(o.id, 'web-1', crateId: o.staging, address: '10.30.0.11');
      final both = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Production',
            'hosts': [
              {'name': 'web-1', 'port': 2222},
            ],
          },
          {
            'name': 'Staging',
            'hosts': [
              {'name': 'web-1', 'address': '10.30.0.12'},
            ],
          },
        ],
      });
      expect(both.problems, isEmpty);
      expect(texts(both.steps), [
        'host web-1 in Production: port 2222',
        'host web-1 in Staging: address 10.30.0.12',
      ]);
      expect((both.steps.first as ChangeHost).hostId, web);
    });

    test('hosts in a Crate the file adds go in after it; hosts it does not name are listed and left',
        () async {
      await owner.addHost(o.id, 'zeta', crateId: o.production);
      await owner.addHost(o.id, 'Alpha', crateId: o.production);
      await owner.addHost(o.id, 'stage-1', crateId: o.staging);
      final plan = await owner.plan(o.id, {
        'crates': [
          {
            'name': 'Lab',
            'hosts': [
              {'name': 'lab-1', 'address': '10.40.0.11', 'group': 'Bench'},
            ],
          },
          {'name': 'Production', 'hosts': <Object?>[]},
          // Nothing said of Staging's hosts: nothing listed.
          {'name': 'Staging'},
        ],
        'roles': [
          {'name': 'Members'},
        ],
      });
      expect(plan.problems, isEmpty);
      expect(texts(plan.steps), [
        'add crate Lab',
        'add group Bench in Lab',
        'add host lab-1 in Lab: ssh 10.40.0.11:22 group Bench',
      ]);
      expect(texts(plan.notes), ['hostsNotInFile Production Alpha,web-1,zeta']);
    });
  });

  group('which steps ZestSSH Cloud takes only after a recent sign-in', () {
    test('every change to who is in the Orchard and what they may do; adding and writing are not', () {
      const changes = <SetupStep>[
        CrateSettings(crate: 'Lab', parts: CrateParts(askAgain: true), allowsNothingWithWatching: false),
        AddRole(name: 'Operators', can: {}, crates: {}),
        ChangeRole(roleId: 'role-1', name: 'Operators', can: {}),
        OrderRoles(order: ['Operators'], ids: ['role-1']),
        SetRules(parts: SetupRules(noExport: true), rules: RecordRules(noExport: true)),
        SetRecords(
            parts: SetupRecords(activity: true), tracking: RecordTracking(activity: true), endsEventExport: false),
        ChangeMember(uid: 'ada', email: 'ada@northwind.example', role: 'Operators'),
      ];
      const additions = <SetupStep>[
        AddCrate(name: 'Lab', ownersOnly: false),
        AddCrate(name: 'Vault', ownersOnly: true),
        Invite(email: 'sam@northwind.example', role: 'Operators', crates: {}, again: false),
        AddGroup(crate: 'Lab', name: 'Bench'),
        AddHost(crate: 'Lab', name: 'lab-1', address: '192.0.2.10', port: 22, protocol: 'ssh'),
        ChangeHost(crate: 'Lab', hostId: 'host-1', name: 'lab-1', port: 2222),
      ];
      for (final step in changes) {
        expect(step.needsRecentSignIn, isTrue, reason: '$step');
      }
      for (final step in additions) {
        expect(step.needsRecentSignIn, isFalse, reason: '$step');
      }
    });
  });

  group('what an invitation may offer', () {
    test('is refused in the record\'s words, for each reason it has', () async {
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {
        RoleCan.invite,
      }, crates: {
        o.production: {CrateSwitches.connect},
      });
      await owner.service.orderRoles(o.id, [ops, o.members]);
      final vault = await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      await joined(SetupWorld.ada, FixedRoles.admin);
      await joined(SetupWorld.lin, ops);
      await joined(SetupWorld.sam, o.members);
      final r = world.server.recordOf(o.id);
      const none = <String, Set<String>>{};
      // Owners offer anything the record has.
      expect(offerProblem(r, SetupWorld.owner, FixedRoles.owner, none, null), isNull);
      expect(offerProblem(r, SetupWorld.owner, FixedRoles.admin, none, 5), isNull);
      expect(offerProblem(r, SetupWorld.owner, ops, {o.staging: levelSwitches(CrateLevel.manage)}, 5), isNull);
      expect(offerProblem(r, SetupWorld.owner, 'nobody', none, null), 'no such role');
      expect(offerProblem(r, SetupWorld.owner, ops, {'nowhere': {CrateSwitches.connect}}, null),
          'no such Crate, or owners-only');
      expect(offerProblem(r, SetupWorld.owner, ops, {vault: {CrateSwitches.connect}}, null),
          'no such Crate, or owners-only');
      expect(offerProblem(r, SetupWorld.owner, FixedRoles.admin, {o.staging: {CrateSwitches.connect}}, null),
          'owners and admins need no extra Crate');
      expect(offerProblem(r, SetupWorld.owner, FixedRoles.owner, none, 5), 'owners do not end');
      // Admins: anyone below them.
      expect(offerProblem(r, SetupWorld.ada, FixedRoles.admin, none, null), 'only owners add owners and admins');
      expect(offerProblem(r, SetupWorld.ada, FixedRoles.owner, none, null), 'only owners add owners and admins');
      expect(offerProblem(r, SetupWorld.ada, ops, {o.staging: levelSwitches(CrateLevel.manage)}, null), isNull);
      // A role that may invite: into a role below its own, with what it has itself.
      expect(offerProblem(r, SetupWorld.lin, o.members, none, null), 'hands out more than they have',
          reason: 'Members reveal in Production; Operators only connect there');
      expect(offerProblem(r, SetupWorld.lin, ops, none, null), 'not allowed to add someone in that role',
          reason: 'its own rank');
      // A role that may not invite.
      expect(offerProblem(r, SetupWorld.sam, o.members, none, null), 'not allowed to add someone in that role');
      // Someone who is not in the Orchard offers nothing.
      expect(offerProblem(r, 'stranger', o.members, none, null), 'not allowed to add someone in that role');
      // The record is not touched by asking.
      expect(r.members.containsKey('-offer-'), isFalse);
      // A role below with nothing more than the inviter has goes through.
      final bare = await owner.service.saveRole(o.id, name: 'Bare', can: {}, crates: {});
      final next = world.server.recordOf(o.id);
      expect(offerProblem(next, SetupWorld.lin, bare, none, 5), isNull);
      expect(offerProblem(next, SetupWorld.lin, bare, {o.production: {CrateSwitches.connect}}, null), isNull);
      expect(offerProblem(next, SetupWorld.lin, bare, {o.production: levelSwitches(CrateLevel.use)}, null),
          'hands out more than they have');
      // Standing above a role is not enough: Members stand above Bare and
      // have all it has, and may not invite.
      expect(next.rankOf(SetupWorld.sam), greaterThan(next.rankOfRole(bare)));
      expect(offerProblem(next, SetupWorld.sam, bare, none, null), 'not allowed to add someone in that role');
    });

    test('the domain of an address is what follows its last @', () {
      expect(addressDomainOf('ada@Northwind.Example'), 'northwind.example');
      expect(addressDomainOf('"a@b"@northwind.example'), 'northwind.example');
      expect(addressDomainOf('nobody'), '');
      expect(addressDomainOf(''), '');
      expect(addressDomainOf(null), '');
    });
  });
}

/// A time as a file writes it.
String setupTimeOf(int seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  return '${t.toIso8601String().substring(0, 19)}Z';
}

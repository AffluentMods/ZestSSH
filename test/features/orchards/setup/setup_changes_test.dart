import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';

import 'setup_world.dart';

// Changing an Orchard part by part (3.0): the entries that put
// what is named over a record as it stands. Built here from a real record,
// and where it matters put to the record's own rules.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  /// The Orchard's record as the server has it.
  OrchardRecord record() => world.server.recordOf(o.id);

  setUpAll(SetupWorld.makeKeys);

  setUp(() async {
    world = SetupWorld();
    await world.start();
    owner = world.device(SetupWorld.owner);
    o = await world.orchard(owner);
  });

  tearDown(() => world.stop());

  group('the order of roles', () {
    test('the roles named take their order in the places they hold; the rest keep theirs', () {
      expect(roleOrderWith(['a', 'b', 'c', 'd'], ['c', 'a']), ['c', 'b', 'a', 'd']);
      expect(roleOrderWith(['a', 'b', 'c', 'd'], ['d', 'c', 'b', 'a']), ['d', 'c', 'b', 'a']);
      expect(roleOrderWith(['a', 'b', 'c', 'd'], ['d', 'b']), ['a', 'd', 'c', 'b']);
      // As they stand already.
      expect(roleOrderWith(['a', 'b', 'c', 'd'], ['a', 'c', 'd']), ['a', 'b', 'c', 'd']);
      // One named, or none, moves nothing.
      expect(roleOrderWith(['a', 'b', 'c'], ['c']), ['a', 'b', 'c']);
      expect(roleOrderWith(['a', 'b', 'c'], const []), ['a', 'b', 'c']);
      // A role that is not there is passed over.
      expect(roleOrderWith(['a', 'b'], ['x', 'b', 'a']), ['b', 'a']);
      expect(roleOrderWith(const [], ['a']), isEmpty);
      // What is given is left as it was.
      final current = ['a', 'b', 'c'];
      roleOrderWith(current, ['c', 'a']);
      expect(current, ['a', 'b', 'c']);
    });

    test('a role the file adds stands just above the one named after it, and no higher', () {
      // Roles that were there: as the roles named take their places.
      expect(roleOrderFor(['a', 'b', 'c'], ['c', 'a'], const {}), ['c', 'b', 'a']);
      expect(roleOrderFor(['a', 'b', 'c'], const [], const {}), ['a', 'b', 'c']);
      // A new one (at the bottom, where it was added) named first: above
      // the role named after it, and that role keeps its place over the
      // one the file does not name.
      expect(roleOrderFor(['a', 'b', 'n'], ['n', 'a'], {'n'}), ['n', 'a', 'b']);
      expect(roleOrderFor(['a', 'b', 'n'], ['n', 'b'], {'n'}), ['a', 'n', 'b']);
      // Named last: it stays below every role, the unnamed one too.
      expect(roleOrderFor(['a', 'b', 'n'], ['a', 'n'], {'n'}), ['a', 'b', 'n']);
      expect(roleOrderFor(['a', 'b', 'n'], ['n'], {'n'}), ['a', 'b', 'n']);
      // Two new ones at the end keep the file's order at the bottom.
      expect(roleOrderFor(['a', 'b', 'n', 'm'], ['a', 'm', 'n'], {'n', 'm'}), ['a', 'b', 'm', 'n']);
      expect(roleOrderFor(['a', 'b', 'n', 'm'], ['a', 'n', 'm'], {'n', 'm'}), ['a', 'b', 'n', 'm']);
      // One above a role that was there, one below everything.
      expect(roleOrderFor(['a', 'b', 'n', 'm'], ['n', 'b', 'm'], {'n', 'm'}), ['a', 'n', 'b', 'm']);
      // Two new ones in a row above a role that was there.
      expect(roleOrderFor(['a', 'b', 'n', 'm'], ['m', 'n', 'a'], {'n', 'm'}), ['m', 'n', 'a', 'b']);
      // With the roles that were there changing places as well.
      expect(roleOrderFor(['a', 'b', 'c', 'n'], ['c', 'n', 'a'], {'n'}), ['c', 'b', 'n', 'a']);
      // Only new roles in an Orchard that had none.
      expect(roleOrderFor(['n', 'm'], ['m', 'n'], {'n', 'm'}), ['m', 'n']);
      // A new role the order does not name stays at the bottom.
      expect(roleOrderFor(['a', 'b', 'n'], ['b', 'a'], {'n'}), ['b', 'a', 'n']);
      // Every role is in what comes out, once.
      for (final named in [
        ['n', 'a'],
        ['a', 'n'],
        ['m', 'c', 'n', 'a'],
        <String>[],
      ]) {
        final out = roleOrderFor(['a', 'b', 'c', 'n', 'm'], named, {'n', 'm'});
        expect(out.toSet(), {'a', 'b', 'c', 'n', 'm'}, reason: '$named');
        expect(out, hasLength(5), reason: '$named');
      }
    });

    /// A copy of the record with only the roles [ranks] (id to rank).
    OrchardRecord withRoles(Map<String, int> ranks) {
      final r = record().copy();
      final first = r.roles.values.first;
      r.roles.clear();
      for (final e in ranks.entries) {
        r.roles[e.key] = RecordRole(
            id: e.key, rank: e.value, nameEnc: first.nameEnc, nameGeneration: first.nameGeneration, can: {}, crates: {});
      }
      r.members[SetupWorld.owner]!.role = FixedRoles.owner;
      return r;
    }

    Map<String, int> ranksOf(OrchardRecord r) => {for (final id in rolesHighestFirst(r)) id: r.roles[id]!.rank};

    test('roles that stand in the order named already are left alone', () {
      final r = withRoles({'a': 4000, 'b': 3000, 'c': 2000, 'd': 1000});
      expect(roleOrderChange(r, ['a', 'b', 'c', 'd']), isEmpty);
      expect(roleOrderChange(r, ['a', 'c']), isEmpty);
      expect(roleOrderChange(r, ['b']), isEmpty);
      expect(roleOrderChange(r, const []), isEmpty);
      expect(roleOrderChange(r, ['x', 'b', 'd']), isEmpty);
    });

    test('one role out of place moves by itself, to a rank between its new neighbours', () async {
      final r = withRoles({'a': 4000, 'b': 3000, 'c': 2000, 'd': 1000});
      // d goes between a and b.
      final changes = roleOrderChange(r, ['a', 'd', 'b', 'c']);
      expect(changes.map((c) => c.type), [RecordTypes.roleSet]);
      expect(changes.single.body['id'], 'd');
      expect(changes.single.body['rank'], 3500);
      expect(ranksOf(await after(r, SetupWorld.owner, changes)), {'a': 4000, 'd': 3500, 'b': 3000, 'c': 2000});
      // To the top: between the highest rank a role may have and the first.
      final top = roleOrderChange(r, ['c', 'a', 'b', 'd']);
      expect(top.single.body['id'], 'c');
      expect(top.single.body['rank'], 4000 + (maxCustomRank + 1 - 4000) ~/ 2);
      expect(rolesHighestFirst(await after(r, SetupWorld.owner, top)), ['c', 'a', 'b', 'd']);
      // To the bottom: between the last and nothing.
      final bottom = roleOrderChange(r, ['b', 'c', 'd', 'a']);
      expect(bottom.single.body['id'], 'a');
      expect(bottom.single.body['rank'], 500);
      expect(rolesHighestFirst(await after(r, SetupWorld.owner, bottom)), ['b', 'c', 'd', 'a']);
      // Two neighbours changing places is one of them moving.
      final swap = roleOrderChange(r, ['b', 'a']);
      expect(swap, hasLength(1));
      expect(rolesHighestFirst(await after(r, SetupWorld.owner, swap)), ['b', 'a', 'c', 'd']);
    });

    test('one role with no room between its new neighbours has every role numbered again', () async {
      final r = withRoles({'a': 3, 'b': 2, 'c': 1});
      final changes = roleOrderChange(r, ['a', 'c', 'b']);
      expect(changes.length, greaterThan(1));
      final next = await after(r, SetupWorld.owner, changes);
      expect(ranksOf(next), {'a': 3000, 'c': 2000, 'b': 1000});
    });

    test('more than one out of place: every role is numbered again, and no two share a rank on the way',
        () async {
      final r = withRoles({'a': 4000, 'b': 3000, 'c': 2000, 'd': 1000});
      final changes = roleOrderChange(r, ['d', 'c', 'b', 'a']);
      // Each role once to a rank nobody holds or will hold, then once to its own.
      expect(changes, hasLength(8));
      expect(changes.map((c) => c.type).toSet(), {RecordTypes.roleSet});
      expect([for (final c in changes.take(4)) c.body['id']], ['d', 'c', 'b', 'a']);
      expect([for (final c in changes.take(4)) c.body['rank']],
          [maxCustomRank, maxCustomRank - 1, maxCustomRank - 2, maxCustomRank - 3]);
      expect([for (final c in changes.skip(4)) c.body['id']], ['d', 'c', 'b', 'a']);
      expect([for (final c in changes.skip(4)) c.body['rank']], [4000, 3000, 2000, 1000]);
      // The record takes every entry in turn (two roles at one rank, it refuses).
      expect(ranksOf(await after(r, SetupWorld.owner, changes)), {'d': 4000, 'c': 3000, 'b': 2000, 'a': 1000});
      // With a role that is not named: it keeps its place.
      final some = roleOrderChange(r, ['d', 'c', 'a']);
      expect(rolesHighestFirst(await after(r, SetupWorld.owner, some)), ['d', 'b', 'c', 'a']);
    });

    test('the ranks on the way are ones no role holds, wherever the roles stand', () async {
      // At the very top, where the ranks to step aside to are looked for.
      final r = withRoles({'a': maxCustomRank, 'b': maxCustomRank - 1, 'c': maxCustomRank - 2});
      final changes = roleOrderChange(r, ['c', 'b', 'a']);
      expect([for (final c in changes.take(3)) c.body['rank']],
          [maxCustomRank - 3, maxCustomRank - 4, maxCustomRank - 5]);
      expect(ranksOf(await after(r, SetupWorld.owner, changes)), {'c': 3000, 'b': 2000, 'a': 1000});
      // And where they stand on the very ranks they are going to.
      final s = withRoles({'a': 1000, 'b': 2000, 'c': 3000, 'd': 4000});
      final back = roleOrderChange(s, ['a', 'b', 'c', 'd']);
      expect(ranksOf(await after(s, SetupWorld.owner, back)), {'a': 4000, 'b': 3000, 'c': 2000, 'd': 1000});
    });

    test('a role keeps its name and what it gives when it is numbered again', () async {
      final ops = await owner.service
          .saveRole(o.id, name: 'Operators', can: {RoleCan.invite}, crates: {o.staging: levelSwitches(CrateLevel.edit)});
      final guests = await owner.service.saveRole(o.id, name: 'Guests', can: {}, crates: {});
      final before = record();
      final changes = roleOrderChange(before, [guests, ops, o.members]);
      final next = await after(before, SetupWorld.owner, changes);
      expect(rolesHighestFirst(next), [guests, ops, o.members]);
      for (final id in [guests, ops, o.members]) {
        expect(next.roles[id]!.nameEnc, before.roles[id]!.nameEnc);
        expect(next.roles[id]!.nameGeneration, before.roles[id]!.nameGeneration);
        expect(next.roles[id]!.can, before.roles[id]!.can);
        expect(next.roles[id]!.crates, before.roles[id]!.crates);
      }
    });
  });

  group("a Crate's settings", () {
    test('nothing named, or named as it is: nothing is written', () {
      final r = record();
      expect(crateSettingsChange(r, o.production, const CrateParts()), isEmpty);
      expect(
        crateSettingsChange(
          r,
          o.production,
          const CrateParts(
            // (Not owners-only: there is nothing to open.)
            open: true,
            allow: {CrateSwitches.sftp, CrateSwitches.forward},
            askAgain: false,
            sessionLogs: false,
            watched: false,
            unwatchedAway: false,
            offlineHours: 0,
          ),
        ),
        isEmpty,
      );
    });

    test('each setting by itself is the only thing in the entry', () async {
      final r = record();
      Map<String, Object?> body(CrateParts parts) => crateSettingsChange(r, o.production, parts).single.body;
      expect(crateSettingsChange(r, o.production, const CrateParts(askAgain: true)).single.type, RecordTypes.crateSet);
      expect(body(const CrateParts(allow: {CrateSwitches.agent})), {
        'id': o.production,
        'allow': ['agent'],
      });
      expect(body(const CrateParts(allow: {})), {'id': o.production, 'allow': <String>[]});
      expect(body(const CrateParts(allow: {CrateSwitches.sftp, CrateSwitches.agent, CrateSwitches.forward})), {
        'id': o.production,
        'allow': ['agent', 'forward', 'sftp'],
      });
      expect(body(const CrateParts(askAgain: true)), {'id': o.production, 'confirm_reveal': true});
      expect(body(const CrateParts(sessionLogs: true)), {'id': o.production, 'session_logs': true});
      expect(body(const CrateParts(offlineHours: 24)), {'id': o.production, 'offline_hours': 24});
      expect(body(const CrateParts(unwatchedAway: true)), {'id': o.production, 'unwatched_away': true});
      // Every one of them the record takes from an owner.
      for (final parts in const [
        CrateParts(allow: {CrateSwitches.agent}),
        CrateParts(askAgain: true),
        CrateParts(sessionLogs: true),
        CrateParts(offlineHours: 24),
        CrateParts(unwatchedAway: true),
      ]) {
        await after(r, SetupWorld.owner, crateSettingsChange(r, o.production, parts));
      }
    });

    test('turning a setting off again is written too', () async {
      var r = await after(
          record(),
          SetupWorld.owner,
          crateSettingsChange(record(), o.production, const CrateParts(askAgain: true, sessionLogs: true, allow: {})));
      expect(r.crates[o.production]!.confirmReveal, isTrue);
      expect(r.crates[o.production]!.sessionLogs, isTrue);
      final off = crateSettingsChange(r, o.production, const CrateParts(askAgain: false, sessionLogs: false));
      expect(off.single.body, {'id': o.production, 'confirm_reveal': false, 'session_logs': false});
      r = await after(r, SetupWorld.owner, off);
      expect(r.crates[o.production]!.confirmReveal, isFalse);
      expect(r.crates[o.production]!.sessionLogs, isFalse);
      expect(r.crates[o.production]!.allow, isEmpty);
    });

    test('who connects with nobody watching is let to everyone and left to owners again, and named as it is '
        'writes nothing', () async {
      var r = await after(
          record(), SetupWorld.owner, crateSettingsChange(record(), o.production, const CrateParts(unwatchedAway: true)));
      expect(r.crates[o.production]!.unwatchedAway, isTrue);
      expect(r.crates[o.staging]!.unwatchedAway, isFalse, reason: 'the Crate named, and no other');
      expect(crateSettingsChange(r, o.production, const CrateParts(unwatchedAway: true)), isEmpty);
      // Beside another setting, each is in the entry once.
      final both = crateSettingsChange(r, o.production, const CrateParts(unwatchedAway: false, askAgain: true));
      expect(both.single.body, {'id': o.production, 'confirm_reveal': true, 'unwatched_away': false});
      r = await after(r, SetupWorld.owner, both);
      expect(r.crates[o.production]!.unwatchedAway, isFalse);
      expect(r.crates[o.production]!.confirmReveal, isTrue);
      expect(crateSettingsChange(r, o.production, const CrateParts(unwatchedAway: false)), isEmpty);
    });

    test("a Crate's own offline limit is set, changed and taken off, and named as it is writes nothing", () async {
      var r = await after(
          record(), SetupWorld.owner, crateSettingsChange(record(), o.production, const CrateParts(offlineHours: 24)));
      expect(r.crates[o.production]!.offlineHours, 24);
      expect(r.crates[o.staging]!.offlineHours, 0, reason: 'the Crate named, and no other');
      expect(crateSettingsChange(r, o.production, const CrateParts(offlineHours: 24)), isEmpty);
      // Beside another setting, each is in the entry once.
      final both = crateSettingsChange(r, o.production, const CrateParts(offlineHours: 72, askAgain: true));
      expect(both.single.body, {'id': o.production, 'confirm_reveal': true, 'offline_hours': 72});
      r = await after(r, SetupWorld.owner, both);
      expect(r.crates[o.production]!.offlineHours, 72);
      // None: 0 is written, since that is what takes it off.
      final off = crateSettingsChange(r, o.production, const CrateParts(offlineHours: 0));
      expect(off.single.body, {'id': o.production, 'offline_hours': 0});
      r = await after(r, SetupWorld.owner, off);
      expect(r.crates[o.production]!.offlineHours, 0);
      expect(r.crates[o.production]!.confirmReveal, isTrue, reason: 'what was not named stays');
      // More than a year is for the record to refuse.
      await expectLater(
          after(r, SetupWorld.owner, crateSettingsChange(r, o.production, const CrateParts(offlineHours: 8761))),
          throwsA(isA<RecordRejected>().having((e) => e.reason, 'reason', 'rule out of range')));
    });

    test('an owners-only Crate is opened; one that is open has nothing to open', () async {
      final vault = await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final r = record();
      final open = crateSettingsChange(r, vault, const CrateParts(open: true));
      expect(open.single.body, {'id': vault, 'owners_only': false});
      expect((await after(r, SetupWorld.owner, open)).crates[vault]!.ownersOnly, isFalse);
      expect(crateSettingsChange(r, vault, const CrateParts()), isEmpty);
      expect(crateSettingsChange(r, o.production, const CrateParts(open: true)), isEmpty);
    });

    test('watching takes what the Crate allowed away in the same entry, when that is not named', () async {
      final r = record();
      final on = crateSettingsChange(r, o.production, const CrateParts(watched: true));
      expect(on.single.body, {'id': o.production, 'allow': <String>[], 'watched': true});
      final watched = await after(r, SetupWorld.owner, on);
      expect(watched.crates[o.production]!.watched, isTrue);
      expect(watched.crates[o.production]!.allow, isEmpty);
      // Named as nothing, it says the same.
      expect(crateSettingsChange(r, o.production, const CrateParts(watched: true, allow: {})).single.body,
          {'id': o.production, 'allow': <String>[], 'watched': true});
      // A Crate that allows nothing has nothing to take away.
      final bare = await after(r, SetupWorld.owner, crateSettingsChange(r, o.production, const CrateParts(allow: {})));
      expect(crateSettingsChange(bare, o.production, const CrateParts(watched: true)).single.body,
          {'id': o.production, 'watched': true});
      // While it is watched, another setting leaves what it allows alone.
      expect(crateSettingsChange(watched, o.production, const CrateParts(askAgain: true)).single.body,
          {'id': o.production, 'confirm_reveal': true});
      expect(crateSettingsChange(watched, o.production, const CrateParts(watched: true)), isEmpty);
    });

    test('named as allowing something while watched, the entry says so and the record refuses it', () async {
      final r = record();
      final both = crateSettingsChange(r, o.production, const CrateParts(watched: true, allow: {CrateSwitches.sftp}));
      expect(both.single.body, {
        'id': o.production,
        'allow': ['sftp'],
        'watched': true,
      });
      await expectLater(after(r, SetupWorld.owner, both),
          throwsA(isA<RecordRejected>().having((e) => e.reason, 'reason', 'a watched Crate allows the terminal only')));
      final watched =
          await after(r, SetupWorld.owner, crateSettingsChange(r, o.production, const CrateParts(watched: true)));
      final allow = crateSettingsChange(watched, o.production, const CrateParts(allow: {CrateSwitches.sftp}));
      expect(allow.single.body, {
        'id': o.production,
        'allow': ['sftp'],
      });
      await expectLater(after(watched, SetupWorld.owner, allow), throwsA(isA<RecordRejected>()));
    });

    test('no longer watched, and allowing something again, is one entry', () async {
      final r = record();
      final watched =
          await after(r, SetupWorld.owner, crateSettingsChange(r, o.production, const CrateParts(watched: true)));
      final off = crateSettingsChange(
          watched, o.production, const CrateParts(watched: false, allow: {CrateSwitches.sftp, CrateSwitches.forward}));
      expect(off.single.body, {
        'id': o.production,
        'allow': ['forward', 'sftp'],
        'watched': false,
      });
      final next = await after(watched, SetupWorld.owner, off);
      expect(next.crates[o.production]!.watched, isFalse);
      expect(next.crates[o.production]!.allow, kDefaultCrateAllow);
      // Not watched any more, with nothing said of what it allows: that stays nothing.
      expect(crateSettingsChange(watched, o.production, const CrateParts(watched: false)).single.body,
          {'id': o.production, 'watched': false});
    });

    test('everything at once is one entry', () async {
      final vault = await owner.service.createCrate(o.id, 'Vault', ownersOnly: true);
      final r = record();
      final all = crateSettingsChange(
          r, vault, const CrateParts(open: true, allow: {}, askAgain: true, sessionLogs: true, watched: true));
      expect(all.single.body, {
        'id': vault,
        'owners_only': false,
        'allow': <String>[],
        'confirm_reveal': true,
        'session_logs': true,
        'watched': true,
      });
      final next = await after(r, SetupWorld.owner, all);
      expect(describeRecord(next, {vault: 'Vault'}).where((l) => l.startsWith('crate Vault')),
          ['crate Vault: allow= ask-again logs watched']);
    });

    test('a Crate the record does not have is said, not passed over', () {
      expect(
          () => crateSettingsChange(record(), 'no-such-crate', const CrateParts(askAgain: true)),
          throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'no such Crate')));
    });
  });

  group('a role', () {
    test('gets what is named of what it may do and what it gives; the rest, its name and its rank stay', () async {
      final r = record();
      final role = r.roles[o.members]!;
      expect(rolePartsChange(r, o.members), isEmpty);
      // As it is, in whatever order it is said.
      expect(
        rolePartsChange(r, o.members, can: {}, crates: {
          o.production: {CrateSwitches.reveal, CrateSwitches.forward, CrateSwitches.sftp, CrateSwitches.connect},
        }),
        isEmpty,
      );

      final can = rolePartsChange(r, o.members, can: {RoleCan.invite, RoleCan.createCrates});
      expect(can.single.type, RecordTypes.roleSet);
      expect(can.single.body, {
        'id': o.members,
        'rank': role.rank,
        'name_enc': role.nameEnc,
        'name_gen': role.nameGeneration,
        'can': ['create_crates', 'invite'],
        'crates': {
          o.production: ['connect', 'forward', 'reveal', 'sftp'],
        },
      });

      final gives = rolePartsChange(r, o.members, crates: {
        o.staging: {CrateSwitches.connect},
      });
      expect(gives.single.body, {
        'id': o.members,
        'rank': role.rank,
        'name_enc': role.nameEnc,
        'name_gen': role.nameGeneration,
        'can': <String>[],
        'crates': {
          o.staging: ['connect'],
        },
      });
      final next = await after(r, SetupWorld.owner, gives);
      expect(next.roles[o.members]!.crates, {
        o.staging: {CrateSwitches.connect},
      });

      // Named as nothing, it gives nothing; one switch more is a change.
      expect(rolePartsChange(r, o.members, crates: {}).single.body['crates'], <String, Object?>{});
      expect(
        rolePartsChange(r, o.members, crates: {
          o.production: {...levelSwitches(CrateLevel.use), CrateSwitches.agent},
        }).single.body['crates'],
        {
          o.production: ['agent', 'connect', 'forward', 'reveal', 'sftp'],
        },
      );
      // The same Crates with other switches in one of them is a change too.
      expect(
        rolePartsChange(r, o.members, crates: {
          o.production: levelSwitches(CrateLevel.connect),
        }),
        hasLength(1),
      );
      // Both at once.
      final both = rolePartsChange(r, o.members, can: {RoleCan.remove}, crates: {});
      expect(both.single.body['can'], ['remove']);
      expect(both.single.body['crates'], <String, Object?>{});
    });

    test('that the record does not have is said', () {
      expect(() => rolePartsChange(record(), 'no-such-role', can: {}),
          throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'no such role')));
    });
  });

  group('a member', () {
    late SetupDevice ada;

    setUp(() async {
      ada = world.device(SetupWorld.ada);
      await world.join(owner, ada, o.id, o.members,
          grants: {o.staging: levelSwitches(CrateLevel.use)}, endsAt: secondsOf(kLater));
    });

    test('nothing named, or named as they are: nothing is written', () {
      final r = record();
      expect(memberPartsBody(r, SetupWorld.ada), isNull);
      expect(
        memberPartsBody(r, SetupWorld.ada,
            role: o.members,
            grants: {o.staging: levelSwitches(CrateLevel.use)},
            endsAt: Named(secondsOf(kLater))),
        isNull,
      );
    });

    test('each part by itself is the only thing in the entry', () async {
      final r = record();
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final withOps = record();
      expect(memberPartsBody(withOps, SetupWorld.ada, role: ops), {'uid': SetupWorld.ada, 'role': ops});
      expect(
        memberPartsBody(r, SetupWorld.ada, grants: {o.staging: levelSwitches(CrateLevel.edit)}),
        {
          'uid': SetupWorld.ada,
          'grants': {
            o.staging: ['add', 'connect', 'delete', 'edit', 'forward', 'reveal', 'sftp'],
          },
        },
      );
      expect(memberPartsBody(r, SetupWorld.ada, grants: {}), {'uid': SetupWorld.ada, 'grants': <String, Object?>{}});
      final other = secondsOf('2031-01-01T00:00:00Z');
      expect(memberPartsBody(r, SetupWorld.ada, endsAt: Named(other)), {'uid': SetupWorld.ada, 'ends_at': other});
      // Named as none: 0 is how an entry says "no end".
      expect(memberPartsBody(r, SetupWorld.ada, endsAt: const Named(null)), {'uid': SetupWorld.ada, 'ends_at': 0});
      final open = await after(r, SetupWorld.owner, [
        (type: RecordTypes.memberSet, body: memberPartsBody(r, SetupWorld.ada, endsAt: const Named(null))!),
      ]);
      expect(open.members[SetupWorld.ada]!.endsAt, isNull);
      // Someone whose access does not end, named as none: nothing to write.
      expect(memberPartsBody(open, SetupWorld.ada, endsAt: const Named(null)), isNull);
    });

    test('all three at once are one entry, which the record takes', () async {
      final ops = await owner.service.saveRole(o.id, name: 'Operators', can: {}, crates: {});
      final r = record();
      final body = memberPartsBody(r, SetupWorld.ada,
          role: ops, grants: {o.production: levelSwitches(CrateLevel.connect)}, endsAt: const Named(null))!;
      expect(body, {
        'uid': SetupWorld.ada,
        'role': ops,
        'grants': {
          o.production: ['connect', 'forward', 'sftp'],
        },
        'ends_at': 0,
      });
      final next = await after(r, SetupWorld.owner, [(type: RecordTypes.memberSet, body: body)]);
      final member = next.members[SetupWorld.ada]!;
      expect(member.role, ops);
      expect(member.grants, {o.production: levelSwitches(CrateLevel.connect)});
      expect(member.endsAt, isNull);
    });

    test('made an admin, their extra Crates end with it; made an owner, their end date too', () {
      final r = record();
      expect(memberPartsBody(r, SetupWorld.ada, role: FixedRoles.admin),
          {'uid': SetupWorld.ada, 'role': 'admin', 'grants': <String, Object?>{}});
      expect(memberPartsBody(r, SetupWorld.ada, role: FixedRoles.owner),
          {'uid': SetupWorld.ada, 'role': 'owner', 'grants': <String, Object?>{}, 'ends_at': 0});
      // What is named is written as named, for the record to refuse.
      expect(
        memberPartsBody(r, SetupWorld.ada,
            role: FixedRoles.admin, grants: {o.staging: levelSwitches(CrateLevel.connect)}),
        {
          'uid': SetupWorld.ada,
          'role': 'admin',
          'grants': {
            o.staging: ['connect', 'forward', 'sftp'],
          },
        },
      );
      final later = secondsOf('2031-01-01T00:00:00Z');
      expect(memberPartsBody(r, SetupWorld.ada, role: FixedRoles.owner, endsAt: Named(later)),
          {'uid': SetupWorld.ada, 'role': 'owner', 'grants': <String, Object?>{}, 'ends_at': later});
      // An admin keeps their end date.
      expect(memberPartsBody(r, SetupWorld.ada, role: FixedRoles.admin)!.containsKey('ends_at'), isFalse);
    });

    test('someone the record does not have, or who was removed, is said', () async {
      expect(() => memberPartsBody(record(), 'nobody', role: FixedRoles.admin),
          throwsA(isA<OrchardRecordRefused>().having((e) => e.reason, 'reason', 'not a member')));
      await owner.service.removeMember(o.id, SetupWorld.ada);
      expect(record().members[SetupWorld.ada]!.status, MemberStatus.removed);
      expect(() => memberPartsBody(record(), SetupWorld.ada, role: FixedRoles.admin),
          throwsA(isA<OrchardRecordRefused>()));
    });
  });

  group('the rules and what the team records', () {
    test('nothing named, or named as it is: nothing is written', () {
      final r = record();
      expect(rulesPartsChange(r, const SetupRules()), isEmpty);
      expect(rulesPartsChange(r, SetupRules.of(r.rules)), isEmpty);
      expect(recordsPartsChange(r, const SetupRecords()), isEmpty);
      expect(recordsPartsChange(r, SetupRecords.of(r.tracking)), isEmpty);
    });

    test('what is named goes over the rules as they stand, and all of them are written', () async {
      final r = record();
      final first = rulesPartsChange(r, const SetupRules(reauthDays: 30, noExport: true));
      expect(first.single.type, RecordTypes.rulesSet);
      // (As this version writes a rules.set: the two rules about remote screens always named.)
      expect(first.single.body, const RecordRules(reauthDays: 30, noExport: true).toSetBody());
      final next = await after(r, SetupWorld.owner, first);
      // Another rule later: the two from before stay.
      final second = rulesPartsChange(next, const SetupRules(emailDomains: {'northwind.example'}, reauthDays: 30));
      expect(second.single.body,
          const RecordRules(reauthDays: 30, noExport: true, emailDomains: {'northwind.example'}).toSetBody());
      expect((await after(next, SetupWorld.owner, second)).rules.emailDomains, {'northwind.example'});
      // Named as it is now: nothing.
      expect(rulesPartsChange(next, const SetupRules(reauthDays: 30)), isEmpty);
      expect(rulesPartsChange(next, const SetupRules(noExport: false)).single.body,
          const RecordRules(reauthDays: 30).toSetBody());
    });

    test('what is named goes over what the team records, all four written', () async {
      final r = record();
      final first = recordsPartsChange(r, const SetupRecords(history: true, devices: true));
      expect(first.single.type, RecordTypes.trackingSet);
      expect(first.single.body, {'activity': false, 'devices': true, 'history': true, 'ips': false});
      final next = await after(r, SetupWorld.owner, first);
      expect(recordsPartsChange(next, const SetupRecords(history: true)), isEmpty);
      expect(recordsPartsChange(next, const SetupRecords(devices: false, ips: true)).single.body,
          {'activity': false, 'devices': false, 'history': true, 'ips': true});
    });
  });
}

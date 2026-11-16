import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_actions.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../helpers/record_commits.dart';

/// The Members screen's menus (3.0) offer exactly what the
/// Orchard's rules accept: for every pair of people in an Orchard with
/// owners, an admin, ranked roles, extra Crates, a suspension and an end
/// date, each action is offered if and only if the record takes the entry
/// it makes.

const _orchard = '11111111-1111-4111-8111-111111111111';
const _crateA = '22222222-2222-4222-8222-222222222222';
const _crateB = '33333333-3333-4333-8333-333333333333';
const _crateS = '44444444-4444-4444-8444-444444444444';
const _lead = '55555555-5555-4555-8555-555555555555';
const _member = '66666666-6666-4666-8666-666666666666';
const _guest = '77777777-7777-4777-8777-777777777777';
const _wide = '88888888-8888-4888-8888-888888888888';

Map<String, Object?> _role(String id, int rank, Map<String, CrateLevel> crates, {List<String> can = const []}) => {
      'id': id,
      'rank': rank,
      'name_enc': base64Encode(utf8.encode('sealed-$id')),
      'name_gen': 1,
      'can': [...can]..sort(),
      'crates': {for (final e in crates.entries) e.key: switchList(levelSwitches(e.value))},
    };

void main() {
  late OrchardRecord state;
  final keys = <String, AccountKeys>{};

  Future<RecordEntry> sign(String by, String type, Map<String, Object?> body) => signRecordEntry(keys[by]!,
      orchardId: _orchard, seq: state.seq + 1, prev: state.head, type: type, body: body, by: by);

  Future<void> add(String by, String type, Map<String, Object?> body) async =>
      state.append(await sign(by, type, body));

  /// Whether the record takes [type] with [body] from [by] as it stands.
  Future<bool> accepted(String by, String type, Map<String, Object?> body) async {
    try {
      await state.copy().append(await sign(by, type, body));
      return true;
    } on RecordRejected {
      return false;
    }
  }

  Future<Map<String, Object?>> joining(String uid, String role,
          {Map<String, CrateLevel>? grants, int? endsAt}) async =>
      {
        ...recordKeysBody(await keys[uid]!.publish(uid)),
        'uid': uid,
        'role': role,
        if (grants != null) 'grants': {for (final e in grants.entries) e.key: switchList(levelSwitches(e.value))},
        'ends_at': ?endsAt,
      };

  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  const people = ['owner1', 'owner2', 'admin', 'lead', 'member', 'guest', 'wide', 'susp', 'ender'];

  setUpAll(() async {
    for (final uid in people) {
      keys[uid] = await AccountKeys.generate();
    }
    state = OrchardRecord(_orchard);
    await add('owner1', RecordTypes.create, {
      'owner': {...recordKeysBody(await keys['owner1']!.publish('owner1')), 'uid': 'owner1'},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _crateA, 'owners_only': false, 'allow': switchList(kDefaultCrateAllow), 'key_commit': testCommit(_crateA)},
      'roles': [
        _role(_lead, 500, {_crateA: CrateLevel.manage},
            can: [RoleCan.invite, RoleCan.remove, RoleCan.changeRoles]),
        _role(_member, 300, {_crateA: CrateLevel.use}),
        _role(_guest, 100, {_crateA: CrateLevel.connect}),
      ],
    });
    await add('owner1', RecordTypes.crateAdd, {'id': _crateB, 'owners_only': false, 'allow': const <String>[], 'key_commit': testCommit(_crateB)});
    await add('owner1', RecordTypes.crateAdd, {'id': _crateS, 'owners_only': true, 'allow': const <String>[], 'key_commit': testCommit(_crateS)});
    // A role the lead may not hand out: it opens Crate B, which the lead
    // cannot open.
    await add('owner1', RecordTypes.roleSet, _role(_wide, 200, {_crateB: CrateLevel.edit}));
    await add('owner1', RecordTypes.memberAdd, await joining('owner2', FixedRoles.owner));
    await add('owner1', RecordTypes.memberAdd, await joining('admin', FixedRoles.admin));
    await add('owner1', RecordTypes.memberAdd, await joining('lead', _lead));
    await add('owner1', RecordTypes.memberAdd,
        await joining('member', _member, grants: {_crateB: CrateLevel.edit}));
    await add('owner1', RecordTypes.memberAdd, await joining('guest', _guest));
    await add('owner1', RecordTypes.memberAdd, await joining('wide', _wide));
    await add('owner1', RecordTypes.memberAdd, await joining('susp', _member));
    await add('owner1', RecordTypes.memberSuspend, {'uid': 'susp'});
    await add('owner1', RecordTypes.memberAdd, await joining('ender', _guest, endsAt: now + 86400 * 30));
  });

  test('every action a menu offers is one the record accepts, and nothing more', () async {
    const roles = [FixedRoles.admin, _lead, _member, _guest, _wide];
    var checked = 0;
    for (final me in people) {
      if (!state.isActive(me)) continue;
      for (final uid in people) {
        final a = MemberActions.of(state, me, uid);
        final why = '$me about $uid';
        if (uid == me) {
          expect(a.any, isFalse, reason: why);
          final self = selfActions(state, me);
          expect(self.stepDown,
              await accepted(me, RecordTypes.memberSet, {'uid': me, 'role': FixedRoles.admin}), reason: why);
          expect(self.leave, await accepted(me, RecordTypes.memberRemove, {'uid': me}), reason: why);
          continue;
        }
        for (final r in roles) {
          expect(a.roles.contains(r), await accepted(me, RecordTypes.memberSet, roleChangeBody(state, uid, r)),
              reason: '$why: the role $r');
          checked++;
        }
        final owner = await accepted(me, RecordTypes.memberSet, roleChangeBody(state, uid, FixedRoles.owner));
        if (state.isActive(uid)) {
          expect(a.makeOwner, owner, reason: '$why: make owner');
        } else {
          expect(a.makeOwner, isFalse, reason: '$why: only an active member becomes an owner');
        }
        expect(a.endDate, await accepted(me, RecordTypes.memberSet, {'uid': uid, 'ends_at': now + 86400}),
            reason: '$why: end date');
        expect(a.suspend, await accepted(me, RecordTypes.memberSuspend, {'uid': uid}), reason: '$why: suspend');
        expect(a.resume, await accepted(me, RecordTypes.memberResume, {'uid': uid}), reason: '$why: resume');
        expect(a.remove, await accepted(me, RecordTypes.memberRemove, {'uid': uid}), reason: '$why: remove');
        final had = {
          for (final g in state.members[uid]!.grants.entries) g.key: switchList(g.value),
        };
        for (final c in [_crateA, _crateB]) {
          final give = await accepted(me, RecordTypes.memberSet, {
            'uid': uid,
            'grants': {...had, c: switchList(levelSwitches(CrateLevel.connect))},
          });
          final offered = a.grants && MemberActions.manages(state, me).contains(c);
          expect(offered, give, reason: '$why: an extra Crate $c');
        }
        checked += 6;
      }
    }
    expect(checked, greaterThan(300), reason: 'the whole matrix ran');
  });

  test('the menus in words: who may do what', () {
    // Owners are equals: neither changes the other, but either may step down.
    expect(MemberActions.of(state, 'owner1', 'owner2').any, isFalse);
    expect(selfActions(state, 'owner1'), (stepDown: true, leave: true));
    // The lead manages people below them, with the roles below their own,
    // and never hands out Crate B, which they cannot open.
    final lead = MemberActions.of(state, 'lead', 'guest');
    expect(lead.roles, [_member, _guest]);
    expect(lead.suspend && lead.remove && lead.endDate && lead.grants, isTrue);
    expect(lead.makeOwner, isFalse);
    expect(MemberActions.of(state, 'lead', 'admin').any, isFalse);
    // An admin gives no one Admin or ownership.
    final admin = MemberActions.of(state, 'admin', 'member');
    expect(admin.roles, [_lead, _member, _wide, _guest], reason: 'highest rank first');
    expect(admin.makeOwner, isFalse);
    // A member with no rights over others has no menu, and may leave.
    expect(MemberActions.of(state, 'member', 'guest').any, isFalse);
    expect(selfActions(state, 'member'), (stepDown: false, leave: true));
    // A suspended member is resumed, not suspended again.
    final susp = MemberActions.of(state, 'owner1', 'susp');
    expect((susp.suspend, susp.resume, susp.makeOwner), (false, true, false));
  });

  test('a member whose end date has passed has nothing to leave: ZestSSH Cloud no longer counts them a member', () {
    final ended = state.copy();
    ended.members['member']!.endsAt = 1790000000;
    expect(selfActions(ended, 'member', nowSeconds: 1789999999), (stepDown: false, leave: true), reason: 'before it');
    expect(selfActions(ended, 'member', nowSeconds: 1790000000), (stepDown: false, leave: false), reason: 'at it');
    expect(selfActions(ended, 'member', nowSeconds: 1790000001), (stepDown: false, leave: false));
    // By this device's clock when none is given: that date is long past.
    ended.members['member']!.endsAt = 1000;
    expect(selfActions(ended, 'member'), (stepDown: false, leave: false));
    // Someone else's end date changes nothing for this account.
    expect(selfActions(ended, 'owner1'), (stepDown: true, leave: true));
  });

  test('the last owner can neither leave nor step down', () async {
    final solo = OrchardRecord(_orchard);
    final e = await signRecordEntry(keys['owner1']!,
        orchardId: _orchard,
        seq: 1,
        prev: const [],
        type: RecordTypes.create,
        by: 'owner1',
        body: {
          'owner': {...recordKeysBody(await keys['owner1']!.publish('owner1')), 'uid': 'owner1'},
          'key_commit': testCommit('orchard'),
          'crate': {'id': _crateA, 'owners_only': false, 'allow': const <String>[], 'key_commit': testCommit(_crateA)},
          'roles': const <Object?>[],
        });
    await solo.append(e);
    expect(selfActions(solo, 'owner1'), (stepDown: false, leave: false));
  });

  test('a role change body clears what the new role cannot have', () {
    expect(roleChangeBody(state, 'member', FixedRoles.admin),
        {'uid': 'member', 'role': FixedRoles.admin, 'grants': const <String, Object?>{}});
    expect(roleChangeBody(state, 'ender', FixedRoles.owner), {'uid': 'ender', 'role': FixedRoles.owner, 'ends_at': 0});
    expect(roleChangeBody(state, 'guest', _member), {'uid': 'guest', 'role': _member});
  });
}

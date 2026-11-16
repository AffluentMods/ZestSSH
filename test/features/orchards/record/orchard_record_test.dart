import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../../helpers/record_commits.dart';

/// The Orchard's record (3.0): the chain holds together, bodies
/// sign the same bytes everywhere, and each kind of change is accepted only
/// from someone whose role allows it, handing out no more than they have.

const _orchard = '11111111-1111-4111-8111-111111111111';
const _crateA = '22222222-2222-4222-8222-222222222222';
const _crateB = '33333333-3333-4333-8333-333333333333';
const _crateSecret = '44444444-4444-4444-8444-444444444444';
const _member = '55555555-5555-4555-8555-555555555555';
const _guest = '66666666-6666-4666-8666-666666666666';
const _lead = '77777777-7777-4777-8777-777777777777';

class _Acct {
  _Acct(this.uid, this.keys);

  final String uid;
  AccountKeys keys;

  Future<PublishedAccountKeys> pub() => keys.publish(uid);
}

/// A device with a signing key of its own (trusted devices).
class _Device {
  _Device(this._pair, this.bytes);

  final SimpleKeyPair _pair;
  final Uint8List bytes;

  String get key => base64Encode(bytes);

  Future<List<int>> sign(List<int> message) async => (await Ed25519().sign(message, keyPair: _pair)).bytes;

  static Future<_Device> make() async {
    final pair = await Ed25519().newKeyPair();
    return _Device(pair, Uint8List.fromList((await pair.extractPublicKey()).bytes));
  }
}

class _Chain {
  final state = OrchardRecord(_orchard);
  final entries = <RecordEntry>[];

  Future<RecordEntry> sign(_Acct who, String type, Map<String, Object?> body, {int? seq, List<int>? prev}) =>
      signRecordEntry(who.keys,
          orchardId: _orchard,
          seq: seq ?? state.seq + 1,
          prev: prev ?? state.head,
          type: type,
          body: body,
          by: who.uid);

  Future<RecordEntry> add(_Acct who, String type, Map<String, Object?> body) async {
    final e = await sign(who, type, body);
    await state.append(e);
    entries.add(e);
    return e;
  }

  Future<void> refused(_Acct who, String type, Map<String, Object?> body, String reason) async {
    final seq = state.seq;
    final snapshot = _describe(state);
    final e = await sign(who, type, body);
    await expectLater(
      state.append(e),
      throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', contains(reason))),
      reason: '$type by ${who.uid}',
    );
    expect(state.seq, seq, reason: 'nothing applied');
    expect(_describe(state), snapshot, reason: 'nothing changed');
  }
}

String _describe(OrchardRecord r) => jsonEncode({
      'members': {
        for (final m in r.members.values)
          m.uid: [m.role, m.status.name, m.endsAt, m.keys.keys.toList(), {for (final g in m.grants.entries) g.key: switchList(g.value)}],
      },
      'roles': {for (final x in r.roles.values) x.id: [x.rank, switchList(x.can), {for (final c in x.crates.entries) c.key: switchList(c.value)}]},
      'crates': {
        for (final c in r.crates.values)
          c.id: [c.ownersOnly, switchList(c.allow), c.offlineHours, c.generation, c.watched, c.unwatchedAway],
      },
    });

Map<String, Object?> _role(String id, int rank, Map<String, CrateLevel> crates, {List<String> can = const []}) => {
      'id': id,
      'rank': rank,
      'name_enc': base64Encode(utf8.encode('sealed-$id')),
      'name_gen': 1,
      'can': [...can]..sort(),
      'crates': {for (final e in crates.entries) e.key: switchList(levelSwitches(e.value))},
    };

Future<Map<String, Object?>> _memberBody(_Acct who, String role,
        {Map<String, CrateLevel>? grants, int? endsAt}) async =>
    {
      ...recordKeysBody(await who.pub()),
      'uid': who.uid,
      'role': role,
      if (grants != null) 'grants': {for (final e in grants.entries) e.key: switchList(levelSwitches(e.value))},
      'ends_at': ?endsAt,
    };

Future<Map<String, Object?>> _createBody(_Acct owner) async => {
      'owner': {...recordKeysBody(await owner.pub()), 'uid': owner.uid},
      'key_commit': testCommit('orchard'),
      'crate': {'id': _crateA, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_crateA)},
      'roles': [
        _role(_member, 200, {_crateA: CrateLevel.edit}),
        _role(_guest, 100, {_crateA: CrateLevel.connect}),
      ],
    };

void main() {
  late _Acct owner, owner2, admin, lead, alice, bob, mallory;

  setUp(() async {
    owner = _Acct('uid-owner', await AccountKeys.generate());
    owner2 = _Acct('uid-owner2', await AccountKeys.generate());
    admin = _Acct('uid-admin', await AccountKeys.generate());
    lead = _Acct('uid-lead', await AccountKeys.generate());
    alice = _Acct('uid-alice', await AccountKeys.generate());
    bob = _Acct('uid-bob', await AccountKeys.generate());
    mallory = _Acct('uid-mallory', await AccountKeys.generate());
  });

  /// An Orchard with a second Crate, an admin, a lead role that can invite
  /// and change roles, and Alice as a member.
  Future<_Chain> team() async {
    final c = _Chain();
    await c.add(owner, RecordTypes.create, await _createBody(owner));
    await c.add(owner, RecordTypes.crateAdd, {'id': _crateB, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(_crateB)});
    await c.add(owner, RecordTypes.roleSet,
        _role(_lead, 500, {_crateA: CrateLevel.manage, _crateB: CrateLevel.edit}, can: [RoleCan.invite, RoleCan.changeRoles]));
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(admin, FixedRoles.admin));
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(lead, _lead));
    await c.add(admin, RecordTypes.memberAdd, await _memberBody(alice, _member));
    return c;
  }

  test('create starts the record: the owner, the first Crate and the two starting roles', () async {
    final c = _Chain();
    await c.add(owner, RecordTypes.create, await _createBody(owner));
    final s = c.state;
    expect(s.seq, 1);
    expect(s.owners, [owner.uid]);
    expect(s.crates.keys, [_crateA]);
    expect(s.roles.keys.toSet(), {_member, _guest});
    expect(s.switchesOf(owner.uid, _crateA), CrateSwitches.all.difference({CrateSwitches.agent}),
        reason: 'everything the Crate allows (it does not allow agent forwarding)');
    expect(s.entitlements(), {
      owner.uid: {'orchard', _crateA},
    });
    expect(s.keysOf(owner.uid, 1)!.fingerprint, (await owner.pub()).fingerprint);
    // Only once, and only first.
    await c.refused(owner, RecordTypes.create, await _createBody(owner), 'create comes first');
    final other = _Chain();
    await expectLater(
        other.state.append(await other.sign(owner, RecordTypes.crateAdd, {'id': _crateB, 'owners_only': false, 'allow': [], 'key_commit': testCommit(_crateB)})),
        throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', contains('must start with create'))));
    // Signed by the owner it names, with the keys it names.
    final forged = _Chain();
    await expectLater(forged.state.append(await forged.sign(mallory, RecordTypes.create, await _createBody(owner))),
        throwsA(isA<RecordRejected>()));
    // Nor may the owner put someone else down as its author.
    final misnamed = await signRecordEntry(owner.keys,
        orchardId: _orchard, seq: 1, prev: const [], type: RecordTypes.create, body: await _createBody(owner), by: alice.uid);
    await expectLater(OrchardRecord(_orchard).append(misnamed),
        throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', contains('signed by the owner'))));
  });

  test('the chain: order, links and signatures; a refused entry changes nothing', () async {
    final c = await team();
    final body = {'id': '88888888-8888-4888-8888-888888888888', 'owners_only': false, 'allow': [], 'key_commit': testCommit('8888')};
    // Out of order, and not following the entry before.
    final skip = await c.sign(owner, RecordTypes.crateAdd, body, seq: c.state.seq + 2);
    await expectLater(c.state.append(skip), throwsA(isA<RecordRejected>().having((x) => x.reason, 'r', 'out of order')));
    final fork = await c.sign(owner, RecordTypes.crateAdd, body, prev: c.entries[2].hash(_orchard));
    await expectLater(c.state.append(fork), throwsA(isA<RecordRejected>().having((x) => x.reason, 'r', contains('does not follow'))));
    // A changed body, a changed author, a signature from other keys.
    final good = await c.sign(owner, RecordTypes.crateAdd, body);
    final tampered = RecordEntry(
      seq: good.seq,
      prev: good.prev,
      type: good.type,
      bodyJson: good.bodyJson.replaceFirst('false', 'true'),
      by: good.by,
      byKeyVersion: good.byKeyVersion,
      signature: good.signature,
    );
    await expectLater(c.state.append(tampered), throwsA(isA<RecordRejected>().having((x) => x.reason, 'r', 'bad signature')));
    final impostor = await signRecordEntry(mallory.keys,
        orchardId: _orchard, seq: c.state.seq + 1, prev: c.state.head, type: RecordTypes.crateAdd, body: body, by: owner.uid);
    await expectLater(c.state.append(impostor), throwsA(isA<RecordRejected>().having((x) => x.reason, 'r', 'bad signature')));
    // Another Orchard's entry does not fit.
    final elsewhere = await signRecordEntry(owner.keys,
        orchardId: '99999999-9999-4999-8999-999999999999', seq: c.state.seq + 1, prev: c.state.head,
        type: RecordTypes.crateAdd, body: body, by: owner.uid);
    await expectLater(c.state.append(elsewhere), throwsA(isA<RecordRejected>()));
    await c.state.append(good);
    // The whole chain replays to the same state on a fresh device.
    c.entries.add(good);
    final again = await OrchardRecord.replay(_orchard, c.entries);
    expect(_describe(again), _describe(c.state));
    expect(again.head, c.state.head);
  });

  test('a body is canonical JSON of plain ASCII strings, whole numbers and flags', () {
    expect(bodyProblem('{"a":1,"b":"x"}'), isNull);
    expect(bodyProblem('{"b":1,"a":2}'), 'body is not canonical');
    expect(bodyProblem('{"a": 1}'), 'body is not canonical');
    expect(bodyProblem('{"a":1.5}'), 'unsupported value');
    expect(bodyProblem('{"a":-1}'), 'number out of range');
    expect(bodyProblem('{"a":null}'), 'unsupported value');
    expect(bodyProblem(r'{"a":"x\"y"}'), 'unsafe string');
    expect(bodyProblem(r'{"a":"x\\y"}'), 'unsafe string');
    expect(bodyProblem(r'{"a":"x\ny"}'), 'unsafe string');
    expect(bodyProblem('{"a":"café"}'), 'unsafe string');
    expect(bodyProblem('[1]'), 'body is not an object');
    expect(bodyProblem('{"a":'), 'body is not JSON');
    expect(bodyProblem('{"a":"${'x' * (kMaxRecordBody + 1)}"}'), 'body too large');
  });

  test('roles and switches: owners everywhere, admins on every Crate but owners-only, the rest by role', () async {
    final c = await team();
    await c.add(owner, RecordTypes.crateAdd, {'id': _crateSecret, 'owners_only': true, 'allow': [], 'key_commit': testCommit(_crateSecret)});
    final s = c.state;
    expect(s.switchesOf(owner.uid, _crateSecret), contains(CrateSwitches.manage));
    expect(s.switchesOf(admin.uid, _crateSecret), isEmpty, reason: 'owners-only');
    expect(s.switchesOf(admin.uid, _crateB), contains(CrateSwitches.manage));
    expect(levelOf(s.switchesOf(alice.uid, _crateA)), CrateLevel.edit);
    expect(s.switchesOf(alice.uid, _crateB), isEmpty, reason: 'the member role only has Crate A');
    expect(levelOf(s.switchesOf(lead.uid, _crateB)), CrateLevel.edit);
    expect(s.entitlements()[alice.uid], {'orchard', _crateA});
    expect(s.entitlements()[admin.uid], {'orchard', _crateA, _crateB});
    expect(s.entitlements()[owner.uid], {'orchard', _crateA, _crateB, _crateSecret});
    // A Crate's settings cap SFTP, forwarding and agent forwarding for all.
    await c.add(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': []});
    expect(c.state.switchesOf(alice.uid, _crateA), isNot(contains(CrateSwitches.sftp)));
    expect(c.state.switchesOf(owner.uid, _crateA), isNot(contains(CrateSwitches.forward)));
    expect(levelOf(c.state.switchesOf(alice.uid, _crateA)), CrateLevel.edit, reason: 'the level is unchanged');
    // Only owners change roles; ranks are distinct; roles never reach
    // owners-only Crates; the fixed roles cannot be redefined.
    await c.refused(admin, RecordTypes.roleSet, _role(_guest, 101, {_crateA: CrateLevel.use}), 'only owners change roles');
    await c.refused(owner, RecordTypes.roleSet, _role(_guest, 200, {_crateA: CrateLevel.use}), 'share a rank');
    await c.refused(owner, RecordTypes.roleSet, _role(_guest, 100, {_crateSecret: CrateLevel.use}), 'owners-only');
    await c.refused(owner, RecordTypes.roleSet, _role(FixedRoles.admin, 150, {}), 'fixed');
    await c.refused(owner, RecordTypes.roleSet, _role(_guest, kAdminRank, {}), 'rank out of range');
    final noConnect = _role(_guest, 100, {})..['crates'] = {_crateA: [CrateSwitches.reveal]};
    await c.refused(owner, RecordTypes.roleSet, noConnect, 'malformed crates');
    final unsorted = _role(_guest, 100, {})..['crates'] = {_crateA: [CrateSwitches.sftp, CrateSwitches.connect]};
    await c.refused(owner, RecordTypes.roleSet, unsorted, 'malformed crates');
    // An edit that widens a role reaches its members at once.
    await c.add(owner, RecordTypes.roleSet, _role(_member, 200, {_crateA: CrateLevel.edit, _crateB: CrateLevel.use}));
    expect(levelOf(c.state.switchesOf(alice.uid, _crateB)), CrateLevel.use);
  });

  test('adding people: owners add owners and admins; a role that invites adds below itself, handing out only what it has',
      () async {
    final c = await team();
    // A member cannot invite; nobody can add someone twice.
    await c.refused(alice, RecordTypes.memberAdd, await _memberBody(bob, _guest), 'not allowed');
    await c.refused(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest), 'already a member');
    // Only owners add owners and admins.
    await c.refused(admin, RecordTypes.memberAdd, await _memberBody(bob, FixedRoles.admin), 'only owners');
    await c.refused(lead, RecordTypes.memberAdd, await _memberBody(bob, FixedRoles.owner), 'only owners');
    // The lead invites below its own rank...
    await c.refused(lead, RecordTypes.memberAdd, await _memberBody(bob, _lead), 'not allowed');
    // ...and hands out no more than it holds: it has Edit on Crate B, so an
    // extra Crate B at Manage is refused, at Edit accepted.
    await c.refused(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest, grants: {_crateB: CrateLevel.manage}),
        'more than they have');
    await c.add(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest, grants: {_crateB: CrateLevel.edit}, endsAt: 1893456000));
    final b = c.state.members[bob.uid]!;
    expect(b.endsAt, 1893456000);
    expect(levelOf(c.state.switchesOf(bob.uid, _crateA)), CrateLevel.connect);
    expect(levelOf(c.state.switchesOf(bob.uid, _crateB)), CrateLevel.edit, reason: 'the extra Crate');
    // Keys must sign for the account named.
    final forged = await _memberBody(mallory, _guest)..['uid'] = 'uid-carol';
    await c.refused(owner, RecordTypes.memberAdd, forged, 'do not sign for uid-carol');
    // An extra Crate that does not exist, or is owners-only.
    await c.add(owner, RecordTypes.crateAdd, {'id': _crateSecret, 'owners_only': true, 'allow': [], 'key_commit': testCommit(_crateSecret)});
    await c.refused(owner, RecordTypes.memberAdd, await _memberBody(mallory, _guest, grants: {_crateSecret: CrateLevel.use}),
        'owners-only');
    await c.refused(owner, RecordTypes.memberAdd, await _memberBody(mallory, FixedRoles.admin, grants: {_crateA: CrateLevel.use}),
        'need no extra Crate');
    await c.refused(owner, RecordTypes.memberAdd, await _memberBody(mallory, FixedRoles.owner, endsAt: 1893456000),
        'owners do not end');
  });

  test('whose an end date is: an owner\'s, or not, as whoever signed the entry that gave it, and it is said by nothing else', () async {
    final c = await team();
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(bob, _guest, endsAt: 1893456000));
    expect(c.state.members[bob.uid]!.endsFromOwner, isTrue, reason: 'an owner added them with it');
    await c.add(lead, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 1893456000});
    expect(c.state.members[alice.uid]!.endsAt, 1893456000);
    expect(c.state.members[alice.uid]!.endsFromOwner, isFalse, reason: 'someone below an owner gave it');
    // The same date signed again by an owner: theirs from then on.
    await c.add(owner, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 1893456000});
    expect(c.state.members[alice.uid]!.endsAt, 1893456000);
    expect(c.state.members[alice.uid]!.endsFromOwner, isTrue);
    // Another change of theirs leaves it as it is, and a copy keeps it.
    await c.add(lead, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    expect(c.state.members[alice.uid]!.endsFromOwner, isTrue);
    expect(c.state.copy().members[alice.uid]!.endsFromOwner, isTrue);
    // Moved by another: no longer an owner's; taken away: nobody's.
    await c.add(lead, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 1893456001});
    expect(c.state.members[alice.uid]!.endsFromOwner, isFalse);
    await c.add(owner, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 0});
    expect(c.state.members[alice.uid]!.endsAt, isNull);
    expect(c.state.members[alice.uid]!.endsFromOwner, isFalse);
    // No date when they came: nobody's.
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(mallory, _guest));
    expect(c.state.members[mallory.uid]!.endsFromOwner, isFalse);
  });

  test('changing people: only those below you, with the right to; an owner steps down only while another stays',
      () async {
    final c = await team();
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    // The lead may move Alice (below it) to Guest; a member may not; nobody
    // changes someone at or above their own rank.
    await c.refused(alice, RecordTypes.memberSet, {'uid': lead.uid, 'role': _guest}, 'only people below you');
    await c.refused(lead, RecordTypes.memberSet, {'uid': admin.uid, 'role': _guest}, 'only people below you');
    await c.refused(admin, RecordTypes.memberSet, {'uid': owner.uid, 'role': _guest}, 'only people below you');
    await c.refused(owner, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.admin}, 'only people below you');
    await c.refused(lead, RecordTypes.memberSet, {'uid': alice.uid, 'role': _lead}, 'not allowed to give that role');
    await c.add(lead, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    expect(levelOf(c.state.switchesOf(alice.uid, _crateA)), CrateLevel.connect);
    // Giving an extra Crate needs manage on it: the lead manages A, not B.
    await c.refused(lead, RecordTypes.memberSet, {
      'uid': alice.uid,
      'grants': {_crateB: switchList(levelSwitches(CrateLevel.use))},
    }, 'needs manage');
    await c.add(lead, RecordTypes.memberSet, {
      'uid': alice.uid,
      'grants': {_crateA: switchList(levelSwitches(CrateLevel.use))},
    });
    expect(levelOf(c.state.switchesOf(alice.uid, _crateA)), CrateLevel.use);
    // Only owners make admins and owners.
    await c.refused(admin, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin}, 'only owners');
    await c.add(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin, 'grants': <String, Object?>{}});
    expect(c.state.members[alice.uid]!.role, FixedRoles.admin);
    // Stepping down: never your own role otherwise, and never the last owner.
    await c.refused(lead, RecordTypes.memberSet, {'uid': lead.uid, 'role': _member}, 'your own role');
    await c.add(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    expect(c.state.owners, [owner2.uid]);
    await c.refused(owner2, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.admin}, 'your own role');
    // Ownership passes back in one step.
    await c.add(owner2, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.owner});
    expect(c.state.owners.toSet(), {owner.uid, owner2.uid});
  });

  test('Crates: who may add them, a creator below Admin manages its own, owners-only only by owners and only at first',
      () async {
    final c = await team();
    const mine = '99999999-9999-4999-8999-999999999999';
    await c.refused(alice, RecordTypes.crateAdd, {'id': mine, 'owners_only': false, 'allow': [], 'key_commit': testCommit(mine)}, 'not allowed');
    await c.refused(admin, RecordTypes.crateAdd, {'id': mine, 'owners_only': true, 'allow': [], 'key_commit': testCommit(mine)}, 'not allowed');
    await c.refused(owner, RecordTypes.crateAdd, {'id': _crateA, 'owners_only': false, 'allow': [], 'key_commit': testCommit(_crateA)}, 'exists');
    await c.add(owner, RecordTypes.roleSet,
        _role(_lead, 500, {_crateA: CrateLevel.manage, _crateB: CrateLevel.edit},
            can: [RoleCan.changeRoles, RoleCan.createCrates, RoleCan.invite]));
    await c.add(lead, RecordTypes.crateAdd, {'id': mine, 'owners_only': false, 'allow': [], 'key_commit': testCommit(mine)});
    expect(levelOf(c.state.switchesOf(lead.uid, mine)), CrateLevel.manage);
    expect(c.state.switchesOf(admin.uid, mine), isNotEmpty, reason: 'admins open every Crate but owners-only');
    expect(c.state.switchesOf(alice.uid, mine), isEmpty);
    // Settings need manage; owners-only is only ever lifted.
    await c.refused(alice, RecordTypes.crateSet, {'id': _crateA, 'allow': []}, 'needs manage');
    await c.add(lead, RecordTypes.crateSet, {'id': mine, 'allow': [CrateSwitches.sftp]});
    await c.refused(admin, RecordTypes.crateSet, {'id': mine, 'owners_only': false}, 'only owners');
    await c.refused(owner, RecordTypes.crateSet, {'id': mine, 'owners_only': true}, 'set when the Crate is added');
    await c.add(owner, RecordTypes.crateAdd, {'id': _crateSecret, 'owners_only': true, 'allow': [], 'key_commit': testCommit(_crateSecret)});
    await c.add(owner, RecordTypes.crateSet, {'id': _crateSecret, 'owners_only': false});
    expect(c.state.switchesOf(admin.uid, _crateSecret), isNotEmpty);
    await c.refused(owner, RecordTypes.crateSet, {'id': _crateA}, 'nothing to change');
  });

  test('new keys: the next version, vouched for by the previous keys and signed with the new; old keys sign no more',
      () async {
    final c = await team();
    final next = await AccountKeys.generate(version: 2);
    final published = await next.publish(alice.uid);
    final body = {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))};
    // Signed with the old keys: refused.
    await c.refused(alice, RecordTypes.memberKeys, body, 'signed with them');
    // Not vouched for by the old keys: refused.
    final unvouched = {...recordKeysBody(published), 'endorsement': base64Encode(Uint8List(64))};
    final newAlice = _Acct(alice.uid, next);
    await c.refused(newAlice, RecordTypes.memberKeys, unvouched, 'did not vouch');
    // Skipping a version, even vouched for by the current keys: refused.
    final far = await AccountKeys.generate(version: 3);
    final farPublished = await far.publish(alice.uid);
    final jump = {
      ...recordKeysBody(farPublished),
      'endorsement': base64Encode(await alice.keys.sign(accountKeysEndorsementMessage(1, farPublished))),
    };
    await c.refused(_Acct(alice.uid, far), RecordTypes.memberKeys, jump, 'must be the next version');
    await c.add(newAlice, RecordTypes.memberKeys, body);
    expect(c.state.members[alice.uid]!.currentKeys.version, 2);
    expect(c.state.keysOf(alice.uid, 1), isNotNull, reason: 'earlier versions stay, for earlier entries');
    // From now on Alice signs with the new keys only.
    final old = alice;
    await c.refused(old, RecordTypes.memberRemove, {'uid': alice.uid}, 'current keys');
    await c.add(newAlice, RecordTypes.memberRemove, {'uid': alice.uid});
    expect(c.state.members[alice.uid]!.status, MemberStatus.removed);
  });

  test('suspend, resume and remove: below you, with the right to; a member may leave; an Orchard keeps an owner',
      () async {
    final c = await team();
    await c.refused(lead, RecordTypes.memberSuspend, {'uid': alice.uid}, 'only people below you');
    await c.add(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    expect(c.state.entitlements().containsKey(alice.uid), isFalse, reason: 'a suspended member holds nothing');
    expect(c.state.switchesOf(alice.uid, _crateA), isEmpty);
    await c.refused(alice, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest}, 'not an active member');
    await c.refused(admin, RecordTypes.memberSuspend, {'uid': alice.uid}, 'not active');
    await c.add(admin, RecordTypes.memberResume, {'uid': alice.uid});
    expect(c.state.switchesOf(alice.uid, _crateA), isNotEmpty);
    await c.add(alice, RecordTypes.memberRemove, {'uid': alice.uid});
    expect(c.state.members[alice.uid]!.status, MemberStatus.removed);
    await c.refused(admin, RecordTypes.memberResume, {'uid': alice.uid}, 'not a member');
    // Someone removed can be added again, with the keys they have now.
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest));
    expect(c.state.members[alice.uid]!.status, MemberStatus.active);
    await c.refused(owner, RecordTypes.memberRemove, {'uid': owner.uid}, 'keeps an owner');
    await c.refused(admin, RecordTypes.memberRemove, {'uid': owner.uid}, 'only people below you');
  });

  test('a suspended member still records new keys, and nothing else; someone removed cannot', () async {
    final c = await team();
    await c.add(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    final next = await AccountKeys.generate(version: 2);
    final published = await next.publish(alice.uid);
    final newAlice = _Acct(alice.uid, next);
    await c.add(newAlice, RecordTypes.memberKeys,
        {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))});
    expect(c.state.members[alice.uid]!.currentKeys.version, 2);
    expect(c.state.members[alice.uid]!.status, MemberStatus.suspended, reason: 'new keys do not resume anyone');
    expect(c.state.entitlements().containsKey(alice.uid), isFalse);
    await c.refused(newAlice, RecordTypes.memberRemove, {'uid': alice.uid}, 'not an active member');
    await c.add(admin, RecordTypes.memberRemove, {'uid': alice.uid});
    final third = await AccountKeys.generate(version: 3);
    final thirdPublished = await third.publish(alice.uid);
    await c.refused(_Acct(alice.uid, third), RecordTypes.memberKeys,
        {...recordKeysBody(thirdPublished), 'endorsement': base64Encode(await next.endorse(thirdPublished))}, 'not a member');
  });

  test("format 2: owners and admins only with their promoter's signed comparison of their keys", () async {
    Future<String> compared(_Acct by, _Acct subject) async => base64Encode(await signMemberVerification(by.keys,
        verifierUid: by.uid, orchardId: _orchard, subject: await subject.pub()));
    final c = _Chain();
    await c.add(owner, RecordTypes.create, {...await _createBody(owner), 'format': 2});
    expect(c.state.format, 2);

    // Adding an admin: the statement, by the author, over the keys added.
    await c.refused(owner, RecordTypes.memberAdd, await _memberBody(admin, FixedRoles.admin), 'malformed verified');
    await c.refused(owner, RecordTypes.memberAdd,
        {...await _memberBody(admin, FixedRoles.admin), 'verified': await compared(owner, mallory)}, 'without comparing');
    await c.refused(owner, RecordTypes.memberAdd,
        {...await _memberBody(admin, FixedRoles.admin), 'verified': await compared(alice, admin)}, 'without comparing');
    await c.add(owner, RecordTypes.memberAdd,
        {...await _memberBody(admin, FixedRoles.admin), 'verified': await compared(owner, admin)});
    expect(c.state.members[admin.uid]!.role, FixedRoles.admin);

    // Anyone else joins as before.
    await c.add(owner, RecordTypes.memberAdd, await _memberBody(alice, _member));

    // Promoting Alice: the statement over her keys as the record holds them.
    await c.refused(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin}, 'malformed verified');
    await c.refused(owner, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(owner, bob)}, 'without comparing');
    await c.add(owner, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(owner, alice)});
    // Admin to owner is a promotion too.
    await c.refused(owner, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.owner}, 'malformed verified');
    await c.add(owner, RecordTypes.memberSet,
        {'uid': admin.uid, 'role': FixedRoles.owner, 'verified': await compared(owner, admin)});
    // An owner stepping down to admin, or a lower role, needs none.
    await c.add(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    await c.add(admin, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    expect(c.state.owners, [admin.uid]);
    expect(c.state.members[alice.uid]!.role, _guest);

    // What this device checked when it arrived replays as before.
    final replayed = await OrchardRecord.replay(_orchard, c.entries, trusted: true);
    expect(replayed.format, 2);
    expect(_describe(replayed), _describe(c.state));
    // A newer format than this app reads is refused.
    final newer = _Chain();
    await newer.refused(owner, RecordTypes.create, {...await _createBody(owner), 'format': 3}, 'record format');
  });

  test('dropping a role moves its members', () async {
    final c = await team();
    await c.refused(admin, RecordTypes.roleDrop, {'id': _member, 'move_to': _guest}, 'only owners');
    await c.refused(owner, RecordTypes.roleDrop, {'id': _member, 'move_to': _member}, 'no such role');
    await c.add(owner, RecordTypes.roleDrop, {'id': _member, 'move_to': _guest});
    expect(c.state.members[alice.uid]!.role, _guest);
    expect(c.state.roles.containsKey(_member), isFalse);
  });

  test('the shared vector: the same entry, the same bytes, the same hash as the server', () async {
    final keys = await AccountKeys.fromSeeds(
      encryptionSeed: List<int>.filled(32, 0x21),
      signingSeed: List<int>.filled(32, 0x23),
      version: 1,
      createdAt: 1790000900,
    );
    final ownerV = _Acct('uid-vector-owner', keys);
    final entry = await signRecordEntry(keys,
        orchardId: _orchard,
        seq: 1,
        prev: const [],
        type: RecordTypes.create,
        body: await _createBody(ownerV),
        by: ownerV.uid);
    final message = entry.signedMessage(_orchard);
    final state = OrchardRecord(_orchard);
    await state.append(entry);
    // The server's test (test/orchard_record_lib.test.js) checks the same bytes.
    expect(entry.bodyJson.length, 1025);
    expect(message.length, 1140);
    expect(_hex(sha(message)), 'd7de7010fd6f333bfc2873051d844f87268ce319257c83fc1c69b9e19842b736');
    expect(base64Encode(entry.signature),
        'eMPNhgLk3u+P0s2o6e1qof4KFDOSGO77ez9ht1El9EnFAtapfDjDQWakyz45kBRsGfh95a9XQD2OmVklyXijDg==');
    expect(_hex(entry.hash(_orchard)), 'b97b9b040f979769b4de557d03b3e8924d8afac752b13a229cf6e22bf5ee890f');
  });

  group('trusted devices', () {
    /// A device.trust or device.revoke body about [which] of [uid], made on
    /// [via], which signs it (or carrying [sig] instead).
    Future<Map<String, Object?>> device(_Chain c, String type, String uid, _Device which, _Device via,
            {List<int>? sig}) async =>
        {
          'uid': uid,
          'device': which.key,
          'via': via.key,
          'sig': base64Encode(sig ??
              await via.sign(deviceEntryMessage(
                  orchardId: _orchard, type: type, uid: uid, device: which.bytes, prev: c.state.head))),
        };
    const trust = RecordTypes.deviceTrust;
    const revoke = RecordTypes.deviceRevoke;

    test('what a device signs: the label, the Orchard, the kind of entry, the member, the device and the entry before', () {
      List<int> lp(List<int> b) => [b.length >> 24 & 255, b.length >> 16 & 255, b.length >> 8 & 255, b.length & 255, ...b];
      final deviceKey = List<int>.filled(32, 0x11);
      final prev = List<int>.filled(32, 0x22);
      final message = deviceEntryMessage(
          orchardId: _orchard, type: trust, uid: 'uid-vector', device: deviceKey, prev: prev);
      expect(message, [
        ...lp(utf8.encode('zestssh.orchard-device.v1')),
        ...lp(utf8.encode(_orchard)),
        ...lp(utf8.encode('device.trust')),
        ...lp(utf8.encode('uid-vector')),
        ...lp(deviceKey),
        ...lp(prev),
      ]);
      expect(kDeviceEntryLabel, 'zestssh.orchard-device.v1');
      // The server's test (test/orchard_record_lib.test.js) checks the same bytes.
      expect(message.length, 171);
      expect(_hex(sha(message)), '458cd3642df692bb9873bd6a2a2397fa1eae2352632642b5f18729466fa38d26');
      // Every part counts.
      final others = [
        deviceEntryMessage(orchardId: _crateA, type: trust, uid: 'uid-vector', device: deviceKey, prev: prev),
        deviceEntryMessage(orchardId: _orchard, type: revoke, uid: 'uid-vector', device: deviceKey, prev: prev),
        deviceEntryMessage(orchardId: _orchard, type: trust, uid: 'uid-other', device: deviceKey, prev: prev),
        deviceEntryMessage(orchardId: _orchard, type: trust, uid: 'uid-vector', device: prev, prev: prev),
        deviceEntryMessage(orchardId: _orchard, type: trust, uid: 'uid-vector', device: deviceKey, prev: deviceKey),
      ];
      expect({for (final o in [message, ...others]) _hex(o)}, hasLength(6));
    });

    test('the rule as the rules carry it: written only when on, read back, and counted as a rule', () {
      expect(RecordRules.none.trustedDevices, isFalse);
      expect(RecordRules.none.toBody().containsKey('trusted_devices'), isFalse);
      const on = RecordRules(trustedDevices: true);
      expect(on.toBody()['trusted_devices'], true);
      expect(on.isNone, isFalse);
      expect(RecordRules.fromStored(on.toBody()).trustedDevices, isTrue);
      expect(RecordRules.fromStored(RecordRules.none.toBody()).trustedDevices, isFalse);
      expect(RecordRules.fromStored({...on.toBody(), 'trusted_devices': 'yes'}).trustedDevices, isFalse);
      // Changing another rule leaves it as it is; it changes when named.
      expect(on.copyWith(noExport: true).trustedDevices, isTrue);
      expect(on.copyWith(noExport: true).noExport, isTrue);
      expect(on.copyWith(trustedDevices: false).isNone, isTrue);
      expect(RecordRules.none.copyWith(trustedDevices: true).trustedDevices, isTrue);
    });

    test('whose devices the record lists: by member, while they are in the Orchard; the owners between them', () async {
      final c = await team();
      final ownerD1 = await _Device.make();
      final ownerD2 = await _Device.make();
      final adminD = await _Device.make();
      final aliceD = await _Device.make();
      expect(c.state.ownerDevices, 0);
      expect(c.state.devicesOf(owner.uid), isEmpty);
      await c.add(owner, trust, await device(c, trust, owner.uid, ownerD1, ownerD1));
      await c.add(owner, trust, await device(c, trust, owner.uid, ownerD2, ownerD1));
      await c.add(owner, trust, await device(c, trust, admin.uid, adminD, ownerD2));
      await c.add(admin, trust, await device(c, trust, alice.uid, aliceD, adminD));
      expect(c.state.devicesOf(owner.uid), {ownerD1.key, ownerD2.key});
      expect(c.state.devicesOf(admin.uid), {adminD.key});
      expect(c.state.devicesOf(alice.uid), {aliceD.key});
      expect(c.state.devicesOf(lead.uid), isEmpty);
      expect(c.state.devicesOf('uid-nobody'), isEmpty);
      // Only the owners' count for the rule.
      expect(c.state.ownerDevices, 2);
      // What is handed out is a copy: changing it changes nothing in the record.
      c.state.devicesOf(alice.uid).add('made-up');
      expect(c.state.devicesOf(alice.uid), {aliceD.key});
      // A copy of the record has its own devices.
      final copy = c.state.copy();
      copy.members[alice.uid]!.devices.clear();
      expect(c.state.devicesOf(alice.uid), {aliceD.key});
      expect(copy.devicesOf(alice.uid), isEmpty);
      // Suspended, her devices are still hers; removed, she has none.
      await c.add(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
      expect(c.state.devicesOf(alice.uid), {aliceD.key});
      await c.add(admin, RecordTypes.memberRemove, {'uid': alice.uid});
      expect(c.state.devicesOf(alice.uid), isEmpty);
      // Taken back, a device is no longer listed.
      await c.add(owner, revoke, await device(c, revoke, owner.uid, ownerD2, ownerD1));
      expect(c.state.devicesOf(owner.uid), {ownerD1.key});
      expect(c.state.ownerDevices, 1);
    });

    test('a refused entry leaves the devices as they were', () async {
      final c = await team();
      final ownerD1 = await _Device.make();
      final ownerD2 = await _Device.make();
      await c.add(owner, trust, await device(c, trust, owner.uid, ownerD1, ownerD1));
      await c.add(owner, trust, await device(c, trust, owner.uid, ownerD2, ownerD1));
      await c.add(owner, RecordTypes.rulesSet, {
        'email_domains': <String>[],
        'max_lock_minutes': 0,
        'no_export': false,
        'offline_hours': 0,
        'reauth_days': 0,
        'require_2fa': false,
        'require_app_lock': false,
        'trusted_devices': true,
      });
      await c.add(owner, revoke, await device(c, revoke, owner.uid, ownerD2, ownerD1));
      // The last one: refused only after the entry was applied to a copy.
      await c.refused(owner, revoke, await device(c, revoke, owner.uid, ownerD1, ownerD1), 'would leave no owner');
      expect(c.state.devicesOf(owner.uid), {ownerD1.key});
      expect(c.state.rules.trustedDevices, isTrue);
    });

    test('entries read back from this device are not verified again, and still follow every other rule', () async {
      final c = await team();
      final ownerD1 = await _Device.make();
      final aliceD = await _Device.make();
      await c.add(owner, trust, await device(c, trust, owner.uid, ownerD1, ownerD1));
      // An entry whose device signature does not hold: refused when it
      // arrives.
      final unsigned = await c.sign(owner, trust, await device(c, trust, alice.uid, aliceD, ownerD1, sig: List<int>.filled(64, 7)));
      await expectLater(c.state.append(unsigned),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'bad device signature')));
      await expectLater(OrchardRecord.replay(_orchard, [...c.entries, unsigned]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'bad device signature')));
      // Read back as one this device checked before, its signatures are not
      // checked again.
      final replayed = await OrchardRecord.replay(_orchard, [...c.entries, unsigned], trusted: true);
      expect(replayed.devicesOf(alice.uid), {aliceD.key});
      // The rules are: a device that is not approved approves nothing.
      final stray = await _Device.make();
      final fromStray = await c.sign(owner, trust, await device(c, trust, alice.uid, aliceD, stray));
      await expectLater(OrchardRecord.replay(_orchard, [...c.entries, fromStray], trusted: true),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'not from an approved device')));
      // Taking one back likewise.
      await c.add(owner, trust, await device(c, trust, alice.uid, aliceD, ownerD1));
      final unsignedRevoke =
          await c.sign(owner, revoke, await device(c, revoke, alice.uid, aliceD, ownerD1, sig: List<int>.filled(64, 7)));
      await expectLater(c.state.append(unsignedRevoke),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'bad device signature')));
      final again = await OrchardRecord.replay(_orchard, [...c.entries, unsignedRevoke], trusted: true);
      expect(again.devicesOf(alice.uid), isEmpty);
    });
  });

  group('event export', () {
    const t = RecordTypes.exportSet;
    const activity = <String, Object?>{'history': false, 'activity': true, 'devices': false, 'ips': false};
    final key = Uint8List.fromList(List<int>.filled(32, 0x61));
    final key2 = Uint8List.fromList(List<int>.filled(32, 0x62));
    Map<String, Object?> on(Uint8List k) => {'on': true, 'key': base64Encode(k)};

    /// The team with a second owner, recording activity.
    Future<_Chain> recording() async {
      final c = await team();
      await c.add(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
      await c.add(owner, RecordTypes.trackingSet, activity);
      return c;
    }

    test('as the record holds it: nothing while it is off; on, the key and who set it up', () async {
      final c = await recording();
      expect(OrchardRecord(_orchard).eventExport, isNull);
      expect(c.state.eventExport, isNull);
      await c.add(owner, t, on(key));
      expect(c.state.eventExport!.key, key);
      expect(c.state.eventExport!.keyText, 'YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=');
      expect(c.state.eventExport!.by, owner.uid);
      // A copy says the same, and a change to the copy is not one to the
      // record.
      final copy = c.state.copy();
      expect(copy.eventExport!.key, key);
      expect(copy.eventExport!.by, owner.uid);
      await copy.append(await c.sign(owner2, t, on(key2)));
      expect(copy.eventExport!.key, key2);
      expect(copy.eventExport!.by, owner2.uid);
      expect(c.state.eventExport!.key, key);
      expect(c.state.eventExport!.by, owner.uid);
      // Off, it is nothing again.
      await c.add(owner2, t, {'on': false});
      expect(c.state.eventExport, isNull);
    });

    test('a refused entry leaves it as it was', () async {
      final c = await recording();
      await c.add(owner, t, on(key));
      Future<void> stillOn() async {
        expect(c.state.eventExport!.key, key);
        expect(c.state.eventExport!.by, owner.uid);
      }

      // Refused for what it says.
      await c.refused(owner, t, {'on': false, 'key': base64Encode(key)}, 'malformed export');
      await c.refused(owner, t, {...on(key2), 'to': 'https://logs.example.com'}, 'malformed export');
      await c.refused(admin, t, {'on': false}, 'only owners set event export');
      await c.refused(admin, RecordTypes.trackingSet,
          {'history': false, 'activity': false, 'devices': false, 'ips': false}, 'only owners set what the team records');
      await stillOn();
      // Refused only after it was applied to a copy: with approved devices
      // only, the owner who set it up and holds the only approved
      // devices cannot step down, and it stays theirs.
      final d1 = await _Device.make();
      final d2 = await _Device.make();
      Future<Map<String, Object?>> trust(_Device which) async => {
            'uid': owner.uid,
            'device': which.key,
            'via': d1.key,
            'sig': base64Encode(await d1.sign(deviceEntryMessage(
                orchardId: _orchard,
                type: RecordTypes.deviceTrust,
                uid: owner.uid,
                device: which.bytes,
                prev: c.state.head))),
          };
      await c.add(owner, RecordTypes.deviceTrust, await trust(d1));
      await c.add(owner, RecordTypes.deviceTrust, await trust(d2));
      await c.add(owner, RecordTypes.rulesSet, {
        'email_domains': <String>[],
        'max_lock_minutes': 0,
        'no_export': false,
        'offline_hours': 0,
        'reauth_days': 0,
        'require_2fa': false,
        'require_app_lock': false,
        'trusted_devices': true,
      });
      await c.refused(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin},
          'would leave no owner with an approved device');
      await stillOn();
      expect(c.state.isOwner(owner.uid), isTrue);
    });

    test('entries read back from this device say the same', () async {
      final c = await recording();
      Future<RecordExport?> readBack([List<RecordEntry> more = const []]) async =>
          (await OrchardRecord.replay(_orchard, [...c.entries, ...more], trusted: true)).eventExport;
      expect(await readBack(), isNull);
      await c.add(owner2, t, on(key2));
      expect((await readBack())!.key, key2);
      expect((await readBack())!.by, owner2.uid);
      // The rules hold whether or not signatures are checked again.
      await c.add(owner, RecordTypes.trackingSet,
          {'history': true, 'activity': false, 'devices': false, 'ips': false});
      expect(await readBack(), isNull);
      await expectLater(readBack([await c.sign(owner, t, on(key))]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'event export needs activity recorded')));
      // The owner who set it up leaves: read back, it is over as well.
      await c.add(owner, RecordTypes.trackingSet, activity);
      await c.add(owner2, t, on(key2));
      await c.add(owner2, RecordTypes.memberRemove, {'uid': owner2.uid});
      expect(c.state.eventExport, isNull);
      expect(await readBack(), isNull);
    });
  });

  group('watched sessions', () {
    const t = RecordTypes.crateSet;
    const terminalOnly = 'a watched Crate allows the terminal only';
    const beyond = {CrateSwitches.sftp, CrateSwitches.forward, CrateSwitches.agent};

    test('as the record holds it: not watched until an owner says so, and then the terminal only', () async {
      final c = await team();
      expect(c.state.crates[_crateA]!.watched, isFalse);
      expect(c.state.crates[_crateB]!.watched, isFalse);
      // The lead manages the first Crate: everything it allows.
      expect(c.state.switchesOf(lead.uid, _crateA).intersection(beyond), {CrateSwitches.sftp, CrateSwitches.forward});
      await c.add(owner, t, {'id': _crateA, 'watched': true, 'allow': <String>[]});
      expect(c.state.crates[_crateA]!.watched, isTrue);
      expect(c.state.crates[_crateA]!.allow, isEmpty);
      expect(c.state.crates[_crateB]!.watched, isFalse, reason: 'one Crate at a time');
      // Nobody's access goes beyond the terminal there, an owner's included;
      // everything else is as it was, and whoever manages it still does.
      for (final who in [owner, admin, lead]) {
        expect(c.state.switchesOf(who.uid, _crateA).intersection(beyond), isEmpty, reason: who.uid);
        expect(c.state.switchesOf(who.uid, _crateA), contains(CrateSwitches.manage), reason: who.uid);
        expect(c.state.switchesOf(who.uid, _crateA), contains(CrateSwitches.connect), reason: who.uid);
      }
      expect(c.state.switchesOf(owner.uid, _crateB).intersection(beyond), {CrateSwitches.sftp, CrateSwitches.forward});
      // A copy says the same, and a change to the copy is not one to the
      // record.
      final copy = c.state.copy();
      expect(copy.crates[_crateA]!.watched, isTrue);
      await copy.append(await c.sign(owner, t, {'id': _crateA, 'watched': false}));
      expect(copy.crates[_crateA]!.watched, isFalse);
      expect(c.state.crates[_crateA]!.watched, isTrue);
      // Off again; what it allows comes back only when someone says so.
      await c.add(owner, t, {'id': _crateA, 'watched': false});
      expect(c.state.crates[_crateA]!.watched, isFalse);
      expect(c.state.crates[_crateA]!.allow, isEmpty);
      await c.add(lead, t, {'id': _crateA, 'allow': ['sftp']});
      expect(c.state.crates[_crateA]!.allow, {CrateSwitches.sftp});
    });

    test('a refused entry leaves the Crate as it was', () async {
      final c = await team();
      Future<void> asItWas({required bool watched, required Set<String> allow}) async {
        expect(c.state.crates[_crateA]!.watched, watched);
        expect(c.state.crates[_crateA]!.allow, allow);
      }

      // Not watched: nothing of an entry that is refused stays, not even
      // what it had already changed when it was refused.
      await c.refused(owner, t, {'id': _crateA, 'watched': true}, terminalOnly);
      await c.refused(owner, t, {'id': _crateA, 'watched': true, 'allow': ['sftp']}, terminalOnly);
      await c.refused(admin, t, {'id': _crateA, 'watched': true, 'allow': <String>[]}, 'only owners set watched sessions');
      await c.refused(owner, t, {'id': _crateA, 'watched': 1, 'allow': <String>[]}, 'malformed watched');
      await asItWas(watched: false, allow: {CrateSwitches.forward, CrateSwitches.sftp});

      // Watched: allowing more is refused, whoever asks and whatever else
      // the entry changes; so is turning it off by someone who is no owner.
      await c.add(owner, t, {'id': _crateA, 'watched': true, 'allow': <String>[]});
      await c.refused(lead, t, {'id': _crateA, 'allow': ['sftp']}, terminalOnly);
      await c.refused(owner, t, {'id': _crateA, 'allow': ['agent'], 'confirm_reveal': true}, terminalOnly);
      await c.refused(lead, t, {'id': _crateA, 'watched': false, 'allow': ['sftp']}, 'only owners set watched sessions');
      await asItWas(watched: true, allow: {});
      expect(c.state.crates[_crateA]!.confirmReveal, isFalse);
      // The other settings still change.
      await c.add(lead, t, {'id': _crateA, 'confirm_reveal': true});
      await c.add(owner, t, {'id': _crateA, 'session_logs': true});
      await asItWas(watched: true, allow: {});
      expect(c.state.crates[_crateA]!.confirmReveal, isTrue);
      expect(c.state.crates[_crateA]!.sessionLogs, isTrue);
    });

    test('entries read back from this device say the same', () async {
      final c = await team();
      Future<RecordCrate> readBack([List<RecordEntry> more = const []]) async =>
          (await OrchardRecord.replay(_orchard, [...c.entries, ...more], trusted: true)).crates[_crateA]!;
      expect((await readBack()).watched, isFalse);
      await c.add(owner, t, {'id': _crateA, 'watched': true, 'allow': <String>[]});
      expect((await readBack()).watched, isTrue);
      expect((await readBack()).allow, isEmpty);
      // The rules hold whether or not signatures are checked again.
      await expectLater(readBack([await c.sign(lead, t, {'id': _crateA, 'allow': ['sftp']})]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', terminalOnly)));
      await expectLater(readBack([await c.sign(admin, t, {'id': _crateA, 'watched': false})]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'only owners set watched sessions')));
      await c.add(owner, t, {'id': _crateA, 'watched': false, 'allow': ['forward', 'sftp']});
      expect((await readBack()).watched, isFalse);
      expect((await readBack()).allow, {CrateSwitches.forward, CrateSwitches.sftp});
    });
  });

  // 3.0: how long a device may stay away from ZestSSH
  // Cloud before one Crate closes on it. The record says what it is; the
  // devices keep to it.
  group("a Crate's offline limit", () {
    const t = RecordTypes.crateSet;
    const ownersOnly = "only owners set a Crate's offline limit";
    int limit(_Chain c, String crate) => c.state.crates[crate]!.offlineHours;

    test('as the record holds it: none until an owner sets one, each Crate its own', () async {
      final c = await team();
      expect(limit(c, _crateA), 0);
      expect(limit(c, _crateB), 0);
      final before = {
        for (final who in [owner, admin, lead, alice]) who.uid: c.state.switchesOf(who.uid, _crateA),
      };
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 24});
      expect(limit(c, _crateA), 24);
      expect(limit(c, _crateB), 0, reason: 'one Crate at a time');
      // Nothing else of the Crate changes, and nobody's access does: the
      // limit is the devices' to keep, the record only says what it is.
      expect(c.state.crates[_crateA]!.allow, {CrateSwitches.forward, CrateSwitches.sftp});
      expect(c.state.crates[_crateA]!.watched, isFalse);
      expect(c.state.crates[_crateA]!.confirmReveal, isFalse);
      expect(c.state.crates[_crateA]!.ownersOnly, isFalse);
      for (final who in [owner, admin, lead, alice]) {
        expect(c.state.switchesOf(who.uid, _crateA), before[who.uid], reason: who.uid);
      }
      // It is no rule of the Orchard: those are as they were.
      expect(c.state.rules.offlineHours, 0);
      // A copy says the same, and a change to the copy is not one to the
      // record.
      final copy = c.state.copy();
      expect(copy.crates[_crateA]!.offlineHours, 24);
      await copy.append(await c.sign(owner, t, {'id': _crateA, 'offline_hours': 72}));
      expect(copy.crates[_crateA]!.offlineHours, 72);
      expect(limit(c, _crateA), 24);
      // Changed, and with another setting in the same entry.
      await c.add(owner, t, {'id': _crateA, 'confirm_reveal': true, 'offline_hours': 72});
      expect(limit(c, _crateA), 72);
      expect(c.state.crates[_crateA]!.confirmReveal, isTrue);
      // A year is the most, as for the Orchard's own limit, and it is
      // allowed; one hour is the least there is.
      await c.add(owner, t, {'id': _crateB, 'offline_hours': 8760});
      expect(limit(c, _crateB), 8760);
      await c.add(owner, t, {'id': _crateB, 'offline_hours': 1});
      expect(limit(c, _crateB), 1);
      expect(limit(c, _crateA), 72);
      // A setting that says nothing of the limit leaves it.
      await c.add(lead, t, {'id': _crateA, 'allow': ['sftp']});
      await c.add(owner, t, {'id': _crateA, 'session_logs': true});
      expect(limit(c, _crateA), 72);
      // Taken off again: 0 is none.
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 0});
      expect(limit(c, _crateA), 0);
      expect(limit(c, _crateB), 1);
      // The Orchard's own limit is another thing and does not touch it.
      await c.add(owner, RecordTypes.rulesSet, {
        'email_domains': <String>[],
        'max_lock_minutes': 0,
        'no_export': false,
        'offline_hours': 168,
        'reauth_days': 0,
        'require_2fa': false,
        'require_app_lock': false,
        'trusted_devices': false,
      });
      expect(c.state.rules.offlineHours, 168);
      expect(limit(c, _crateA), 0);
      expect(limit(c, _crateB), 1);
      // A Crate added later has none.
      await c.add(owner, RecordTypes.crateAdd,
          {'id': _crateSecret, 'owners_only': true, 'allow': <String>[], 'key_commit': testCommit(_crateSecret)});
      expect(limit(c, _crateSecret), 0);
    });

    test('a refused entry leaves the Crate as it was', () async {
      final c = await team();
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 24});
      // Only an owner: not an admin, not whoever manages the Crate, not a
      // member; and whoever is no owner is told that, whatever the number.
      for (final who in [admin, lead, alice]) {
        await c.refused(who, t, {'id': _crateA, 'offline_hours': 72}, ownersOnly);
        await c.refused(who, t, {'id': _crateA, 'offline_hours': 0}, ownersOnly);
        await c.refused(who, t, {'id': _crateA, 'offline_hours': 99999}, ownersOnly);
      }
      // More than a year, by one hour and by a lot.
      await c.refused(owner, t, {'id': _crateA, 'offline_hours': 8761}, 'rule out of range');
      await c.refused(owner, t, {'id': _crateA, 'offline_hours': 9007199254740991}, 'rule out of range');
      // What is no whole number is no limit, whoever sends it.
      for (final bad in <Object?>['24', true, <int>[24], {'hours': 24}]) {
        await c.refused(owner, t, {'id': _crateA, 'offline_hours': bad}, 'malformed offline_hours');
        await c.refused(admin, t, {'id': _crateA, 'offline_hours': bad}, 'malformed offline_hours');
      }
      // A Crate that is not there.
      await c.refused(owner, t, {'id': _crateSecret, 'offline_hours': 24}, 'no such Crate');
      // Nothing of an entry that is refused stays, not even what it had
      // already changed when it was refused: the lead may set what the
      // Crate asks again for, and the same entry with a limit sets neither.
      await c.refused(lead, t, {'id': _crateA, 'confirm_reveal': true, 'offline_hours': 72}, ownersOnly);
      await c.refused(owner, t, {'id': _crateA, 'session_logs': true, 'offline_hours': 8761}, 'rule out of range');
      expect(limit(c, _crateA), 24);
      expect(c.state.crates[_crateA]!.confirmReveal, isFalse);
      expect(c.state.crates[_crateA]!.sessionLogs, isFalse);
      // An entry that names the Crate and nothing to change is still
      // refused, and a limit alone is something to change, the same one
      // again included.
      await c.refused(owner, t, {'id': _crateA}, 'nothing to change');
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 24});
      expect(limit(c, _crateA), 24);
      // A watched Crate keeps its own rule beside it.
      await c.refused(owner, t, {'id': _crateA, 'watched': true, 'offline_hours': 48},
          'a watched Crate allows the terminal only');
      expect(limit(c, _crateA), 24);
      await c.add(owner, t, {'id': _crateA, 'watched': true, 'allow': <String>[], 'offline_hours': 48});
      expect(limit(c, _crateA), 48);
      expect(c.state.crates[_crateA]!.watched, isTrue);
    });

    test('entries read back from this device say the same', () async {
      final c = await team();
      Future<RecordCrate> readBack([List<RecordEntry> more = const []]) async =>
          (await OrchardRecord.replay(_orchard, [...c.entries, ...more], trusted: true)).crates[_crateA]!;
      expect((await readBack()).offlineHours, 0);
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 24});
      expect((await readBack()).offlineHours, 24);
      // The rules hold whether or not signatures are checked again.
      await expectLater(readBack([await c.sign(admin, t, {'id': _crateA, 'offline_hours': 0})]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', ownersOnly)));
      await expectLater(readBack([await c.sign(owner, t, {'id': _crateA, 'offline_hours': 8761})]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'rule out of range')));
      await c.add(owner, t, {'id': _crateA, 'offline_hours': 0});
      expect((await readBack()).offlineHours, 0);
    });

    test('an owner who is one no longer sets none, and one who became one does', () async {
      final c = await team();
      await c.add(owner, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.owner});
      await c.add(admin, t, {'id': _crateA, 'offline_hours': 24});
      expect(limit(c, _crateA), 24);
      await c.add(admin, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.admin});
      await c.refused(admin, t, {'id': _crateA, 'offline_hours': 0}, ownersOnly);
      expect(limit(c, _crateA), 24);
    });
  });

  // 3.0: watched Crates while ZestSSH Cloud cannot be
  // reached. Nobody can be asked to watch then. A Crate's setting says
  // whether members, and not only owners, may connect without a watcher;
  // and whoever did reports it in an entry of its own, which any active
  // member may write and which changes nothing. The record says what was
  // set and what was reported; the devices keep to it.
  group('watched Crates while ZestSSH Cloud cannot be reached', () {
    const set = RecordTypes.crateSet;
    const told = RecordTypes.sessionUnwatched;
    const ownersOnly = 'only owners set watched sessions';
    bool away(_Chain c, String crate) => c.state.crates[crate]!.unwatchedAway;
    String sealed(int bytes) => base64Encode(List<int>.filled(bytes, 9));
    Map<String, Object?> report(Object? crate, [Map<String, Object?> more = const {}]) =>
        {'crate': crate, 'at': 1791504000, 'gen': 1, 'sealed': sealed(120), ...more};
    Map<String, Object?> without(Map<String, Object?> body, String key) => {...body}..remove(key);

    test('who else may connect without a watcher, as the record holds it: owners alone until an owner says '
        'otherwise', () async {
      final c = await team();
      expect(away(c, _crateA), isFalse);
      expect(away(c, _crateB), isFalse);
      final before = {
        for (final who in [owner, admin, lead, alice]) who.uid: c.state.switchesOf(who.uid, _crateA),
      };
      // It is set whether or not the Crate's sessions are watched: it says
      // what goes for them while they are.
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': true});
      expect(away(c, _crateA), isTrue);
      expect(away(c, _crateB), isFalse, reason: 'one Crate at a time');
      // Nothing else of the Crate changes, and nobody's access does.
      expect(c.state.crates[_crateA]!.allow, {CrateSwitches.forward, CrateSwitches.sftp});
      expect(c.state.crates[_crateA]!.watched, isFalse);
      expect(c.state.crates[_crateA]!.confirmReveal, isFalse);
      expect(c.state.crates[_crateA]!.offlineHours, 0);
      for (final who in [owner, admin, lead, alice]) {
        expect(c.state.switchesOf(who.uid, _crateA), before[who.uid], reason: who.uid);
      }
      // A copy says the same, and a change to the copy is not one to the
      // record.
      final copy = c.state.copy();
      expect(copy.crates[_crateA]!.unwatchedAway, isTrue);
      await copy.append(await c.sign(owner, set, {'id': _crateA, 'unwatched_away': false}));
      expect(copy.crates[_crateA]!.unwatchedAway, isFalse);
      expect(away(c, _crateA), isTrue);
      // With watching turned on in the same entry, and off again: it stays
      // as set.
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': false});
      await c.add(owner, set, {'id': _crateA, 'watched': true, 'allow': <String>[], 'unwatched_away': true});
      expect(c.state.crates[_crateA]!.watched, isTrue);
      expect(away(c, _crateA), isTrue);
      await c.add(owner, set, {'id': _crateA, 'watched': false});
      expect(away(c, _crateA), isTrue, reason: 'what was set is kept for when its sessions are watched again');
      // A setting that says nothing of it leaves it.
      await c.add(lead, set, {'id': _crateA, 'confirm_reveal': true});
      await c.add(owner, set, {'id': _crateA, 'offline_hours': 24});
      expect(away(c, _crateA), isTrue);
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': false});
      expect(away(c, _crateA), isFalse);
      // A Crate added later starts with owners alone.
      await c.add(owner, RecordTypes.crateAdd,
          {'id': _crateSecret, 'owners_only': true, 'allow': <String>[], 'key_commit': testCommit(_crateSecret)});
      expect(away(c, _crateSecret), isFalse);
    });

    test('only an owner says who else may, and a refused entry leaves the Crate as it was', () async {
      final c = await team();
      // Not an admin, not whoever manages the Crate, not a member:
      // whichever way they would set it.
      for (final who in [admin, lead, alice]) {
        await c.refused(who, set, {'id': _crateA, 'unwatched_away': true}, ownersOnly);
        await c.refused(who, set, {'id': _crateA, 'unwatched_away': false}, ownersOnly);
      }
      // What is no yes or no is no setting, whoever sends it.
      for (final bad in <Object?>['true', 1, 0, <bool>[true], {'on': true}]) {
        await c.refused(owner, set, {'id': _crateA, 'unwatched_away': bad}, 'malformed unwatched_away');
        await c.refused(admin, set, {'id': _crateA, 'unwatched_away': bad}, 'malformed unwatched_away');
      }
      // A Crate that is not there.
      await c.refused(owner, set, {'id': _crateSecret, 'unwatched_away': true}, 'no such Crate');
      // Nothing of a refused entry stays: the lead may set what the Crate
      // asks again for, and the same entry with this in it sets neither.
      await c.refused(lead, set, {'id': _crateA, 'confirm_reveal': true, 'unwatched_away': true}, ownersOnly);
      expect(c.state.crates[_crateA]!.confirmReveal, isFalse);
      expect(away(c, _crateA), isFalse);
      // It is something to change by itself, the same value again included;
      // an entry that names the Crate and nothing else is still refused.
      await c.refused(owner, set, {'id': _crateA}, 'nothing to change');
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': false});
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': true});
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': true});
      expect(away(c, _crateA), isTrue);
      // A watched Crate still allows the terminal only, whatever else an
      // entry sets.
      await c.add(owner, set, {'id': _crateA, 'watched': true, 'allow': <String>[]});
      await c.refused(owner, set, {'id': _crateA, 'allow': ['sftp'], 'unwatched_away': false},
          'a watched Crate allows the terminal only');
      expect(away(c, _crateA), isTrue);
    });

    test('an owner who is one no longer sets it no more, and one who became one does', () async {
      final c = await team();
      await c.add(owner, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.owner});
      await c.add(admin, set, {'id': _crateA, 'unwatched_away': true});
      expect(away(c, _crateA), isTrue);
      await c.add(admin, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.admin});
      await c.refused(admin, set, {'id': _crateA, 'unwatched_away': false}, ownersOnly);
      expect(away(c, _crateA), isTrue);
    });

    test('a session without a watcher is reported by whoever connected, and changes nothing', () async {
      final c = await team();
      // Anyone who is an active member, whatever they may open now, for a
      // Crate whose sessions are watched or not: what they could open when
      // they connected may have ended since, and the Crate may be watched
      // no more. (alice opens nothing in the second Crate.)
      expect(c.state.switchesOf(alice.uid, _crateB), isEmpty);
      for (final who in [owner, admin, lead, alice]) {
        for (final crate in [_crateA, _crateB]) {
          final before = _describe(c.state);
          final seq = c.state.seq;
          await c.add(who, told, report(crate));
          expect(c.state.seq, seq + 1, reason: 'it is in the record');
          expect(_describe(c.state), before, reason: 'and changes nothing in it');
        }
      }
      await c.add(owner, set, {'id': _crateA, 'watched': true, 'allow': <String>[]});
      await c.add(alice, told, report(_crateA));
      // The earliest and the latest time there is, the least and the most
      // that is sealed.
      await c.add(alice, told, report(_crateA, {'at': 1}));
      await c.add(alice, told, report(_crateA, {'at': 0xffffffff}));
      await c.add(alice, told, report(_crateA, {'sealed': sealed(1)}));
      await c.add(alice, told, report(_crateA, {'sealed': sealed(kMaxUnwatchedSealed)}));
      expect(sealed(kMaxUnwatchedSealed).length, 2048, reason: 'which fills the longest text an entry holds');
      // Sealed with any key the Crate has had: after a new one, the old
      // and the new.
      await c.add(lead, RecordTypes.keyRotate, {'crate': _crateA, 'generation': 2, 'key_commit': testCommit('a2')});
      await c.add(alice, told, report(_crateA, {'gen': 1}));
      await c.add(alice, told, report(_crateA, {'gen': 2}));
      // The same report twice is two entries: the record does not read them.
      final again = c.state.seq;
      await c.add(alice, told, report(_crateA));
      await c.add(alice, told, report(_crateA));
      expect(c.state.seq, again + 2);
    });

    test('a report that is not one is refused, by what is wrong with it first', () async {
      final c = await team();
      Future<void> no(Map<String, Object?> body, String reason) => c.refused(alice, told, body, reason);
      // Nothing it does not know.
      await no(report(_crateA, {'host': 'web-01'}), 'malformed session');
      await no(report(_crateA, {'reason': 'a restore'}), 'malformed session');
      await no(report(_crateA, {'uid': owner.uid}), 'malformed session');
      // The Crate: an id, of a Crate there is.
      for (final bad in <Object?>[7, '', 'not an id!', true, <String>[_crateA]]) {
        await no(report(bad), 'malformed crate');
      }
      await no(without(report(_crateA), 'crate'), 'malformed crate');
      await no(report(_crateSecret), 'no such Crate');
      // The time: seconds that fit 32 bits, and not nought.
      for (final bad in <Object?>['1791504000', true, <int>[1], 0, 0x100000000, 9007199254740991]) {
        await no(report(_crateA, {'at': bad}), 'malformed at');
      }
      await no(without(report(_crateA), 'at'), 'malformed at');
      // The key it is sealed with: one the Crate has had.
      for (final bad in <Object?>['1', true, <int>[1], 0, 2, 99]) {
        await no(report(_crateA, {'gen': bad}), 'malformed gen');
      }
      await no(without(report(_crateA), 'gen'), 'malformed gen');
      await c.add(owner, RecordTypes.keyRotate, {'crate': _crateB, 'generation': 2, 'key_commit': testCommit('b2')});
      await no(report(_crateA, {'gen': 2}), 'malformed gen');
      await c.add(alice, told, report(_crateB, {'gen': 2}));
      await no(report(_crateB, {'gen': 3}), 'malformed gen');
      // What is sealed: base64 as base64 spells it, of 1 to 1536 bytes.
      for (final bad in <Object?>[
        '', 7, true, <String>['AAAA'], sealed(kMaxUnwatchedSealed + 1), 'AA', 'AB==', 'A===', 'AAA*', ' AAAA', 'AAAA AAAA', //
      ]) {
        await no(report(_crateA, {'sealed': bad}), 'malformed sealed');
      }
      // (Two spellings this app's own decoder would read, which base64 does
      // not write: its letters for addresses, and a padding written as in
      // one. The server's decoder reads other things: see its test.)
      await no(report(_crateA, {'sealed': 'AA-_'}), 'malformed sealed');
      await no(report(_crateA, {'sealed': 'AA%3D%3D'}), 'malformed sealed');
      await no(without(report(_crateA), 'sealed'), 'malformed sealed');
      // (What no entry may hold at all, a number that is not whole or
      // nothing where a value goes, this app does not sign in the first
      // place; the server's own test has those refused.)
      // Several things wrong: the first in this order is what is said.
      await no({...report(_crateSecret), 'host': 'web-01'}, 'malformed session');
      await no(report(_crateSecret, {'at': 0}), 'no such Crate');
      await no(report('not an id!', {'at': 0}), 'malformed crate');
      await no(report(_crateA, {'at': 0, 'gen': 0}), 'malformed at');
      await no(report(_crateA, {'gen': 0, 'sealed': ''}), 'malformed gen');
    });

    test('only someone who is in the Orchard now reports, under the keys they have now', () async {
      final c = await team();
      await c.refused(mallory, told, report(_crateA), 'not an active member');
      await c.add(owner, RecordTypes.memberSuspend, {'uid': alice.uid});
      await c.refused(alice, told, report(_crateA), 'not an active member');
      await c.add(owner, RecordTypes.memberResume, {'uid': alice.uid});
      await c.add(alice, told, report(_crateA));
      await c.add(owner, RecordTypes.memberAdd, await _memberBody(bob, _guest));
      await c.add(owner, RecordTypes.memberRemove, {'uid': bob.uid});
      await c.refused(bob, told, report(_crateA), 'not an active member');
      // Signed by someone else in their name: the signature is theirs or it
      // is none.
      await c.refused(_Acct(alice.uid, owner.keys), told, report(_crateA), 'bad signature');
    });

    test('entries read back from this device say the same', () async {
      final c = await team();
      Future<OrchardRecord> readBack([List<RecordEntry> more = const []]) =>
          OrchardRecord.replay(_orchard, [...c.entries, ...more], trusted: true);
      expect((await readBack()).crates[_crateA]!.unwatchedAway, isFalse);
      await c.add(owner, set, {'id': _crateA, 'unwatched_away': true});
      await c.add(alice, told, report(_crateA));
      final back = await readBack();
      expect(back.crates[_crateA]!.unwatchedAway, isTrue);
      expect(back.seq, c.state.seq);
      expect(back.head, c.state.head);
      // The rules hold whether or not signatures are checked again.
      await expectLater(readBack([await c.sign(admin, set, {'id': _crateA, 'unwatched_away': false})]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', ownersOnly)));
      await expectLater(readBack([await c.sign(alice, told, report(_crateA, {'gen': 2}))]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'malformed gen')));
      await expectLater(readBack([await c.sign(alice, told, report(_crateSecret))]),
          throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'no such Crate')));
    });
  });
}

List<int> sha(List<int> bytes) => sha256.convert(bytes).bytes;

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

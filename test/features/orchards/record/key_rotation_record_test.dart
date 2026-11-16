import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Key generations in the Orchard's record (3.0): who may make the
/// next generation of the Orchard's key or a Crate's, and the commitment to
/// each generation that the entry making it carries, so a device can tell a
/// key a copy holds is the one its maker made, whoever sealed the copy.

const _orchard = '11111111-1111-4111-8111-111111111111';
const _crateA = '22222222-2222-4222-8222-222222222222';
const _crateB = '33333333-3333-4333-8333-333333333333';
const _member = '55555555-5555-4555-8555-555555555555';

class _Acct {
  _Acct(this.uid, this.keys);

  final String uid;
  final AccountKeys keys;
}

Map<String, Object?> _role(String id, int rank, Map<String, CrateLevel> crates) => {
      'id': id,
      'rank': rank,
      'name_enc': base64Encode(utf8.encode('sealed-$id')),
      'name_gen': 1,
      'can': const <String>[],
      'crates': {for (final e in crates.entries) e.key: switchList(levelSwitches(e.value))},
    };

void main() {
  late _Acct owner;
  late _Acct admin;
  late _Acct alice;
  late _Acct manager;

  setUpAll(() async {
    Future<_Acct> acct(String uid) async => _Acct(uid, await AccountKeys.generate());
    owner = await acct('owner');
    admin = await acct('admin');
    alice = await acct('alice');
    manager = await acct('manager');
  });

  /// The real keys each generation was made with, by scope and generation.
  late Map<String, Map<int, Uint8List>> made;
  late OrchardRecord state;

  Future<String> commitFor(String scope, int generation) async {
    final key = newSpaceKey();
    (made[scope] ??= {})[generation] = key;
    return base64Encode(await keyCommitment(key,
        orchardId: _orchard, crateId: scope == kOrchardScope ? null : scope, generation: generation));
  }

  Future<RecordEntry> sign(_Acct who, String type, Map<String, Object?> body) => signRecordEntry(who.keys,
      orchardId: _orchard, seq: state.seq + 1, prev: state.head, type: type, body: body, by: who.uid);

  Future<RecordEntry> add(_Acct who, String type, Map<String, Object?> body) async {
    final e = await sign(who, type, body);
    await state.append(e);
    return e;
  }

  Future<String> refused(_Acct who, String type, Map<String, Object?> body) async {
    try {
      await state.copy().append(await sign(who, type, body));
      return 'accepted';
    } on RecordRejected catch (x) {
      return x.reason;
    }
  }

  Future<Map<String, Object?>> joining(_Acct who, String role, {Map<String, CrateLevel>? grants}) async => {
        ...recordKeysBody(await who.keys.publish(who.uid)),
        'uid': who.uid,
        'role': role,
        if (grants != null) 'grants': {for (final e in grants.entries) e.key: switchList(levelSwitches(e.value))},
      };

  setUp(() async {
    made = {};
    state = OrchardRecord(_orchard);
    await add(owner, RecordTypes.create, {
      'owner': {...recordKeysBody(await owner.keys.publish(owner.uid)), 'uid': owner.uid},
      'key_commit': await commitFor(kOrchardScope, 1),
      'crate': {
        'id': _crateA,
        'owners_only': false,
        'allow': ['forward', 'sftp'],
        'key_commit': await commitFor(_crateA, 1),
      },
      'roles': [_role(_member, 100, {_crateA: CrateLevel.use})],
    });
    await add(owner, RecordTypes.crateAdd,
        {'id': _crateB, 'owners_only': false, 'allow': const <String>[], 'key_commit': await commitFor(_crateB, 1)});
    await add(owner, RecordTypes.memberAdd, await joining(admin, FixedRoles.admin));
    await add(owner, RecordTypes.memberAdd, await joining(alice, _member));
    await add(owner, RecordTypes.memberAdd, await joining(manager, _member, grants: {_crateB: CrateLevel.manage}));
  });

  /// Whether [key] opens as generation [generation] of [scope] by the record.
  Future<bool> opens(Uint8List key, String scope, int generation) => keyMatchesCommitment(
      key, state.keyCommitOf(scope, generation),
      orchardId: _orchard, crateId: scope == kOrchardScope ? null : scope, generation: generation);

  test('every key starts at generation 1, and each rotation is the next one', () async {
    expect((state.orchardGeneration, state.generationOf(kOrchardScope)), (1, 1));
    expect(state.generationOf(_crateA), 1);
    expect(state.generationOf(_crateB), 1);
    expect(state.generationOf('no-such-crate'), 0);

    await add(admin, RecordTypes.keyRotate, {'generation': 2, 'key_commit': await commitFor(kOrchardScope, 2)});
    await add(manager, RecordTypes.keyRotate,
        {'crate': _crateB, 'generation': 2, 'key_commit': await commitFor(_crateB, 2)});
    await add(owner, RecordTypes.keyRotate,
        {'crate': _crateA, 'generation': 2, 'key_commit': await commitFor(_crateA, 2)});
    expect((state.orchardGeneration, state.generationOf(_crateA), state.generationOf(_crateB)), (2, 2, 2));
    // A copy of the record keeps them, and every commitment.
    final copy = state.copy();
    expect(copy.generationOf(_crateB), 2);
    for (final scope in [kOrchardScope, _crateA, _crateB]) {
      for (final g in [1, 2]) {
        expect(copy.keyCommitOf(scope, g), state.keyCommitOf(scope, g), reason: '$scope $g');
        expect(copy.keyCommitOf(scope, g), isNotNull, reason: '$scope $g');
      }
      expect(copy.keyCommitOf(scope, 3), isNull);
    }
  });

  test('who may make the next generation, and only the next, with its commitment', () async {
    final c = await commitFor(kOrchardScope, 2);
    expect(await refused(alice, RecordTypes.keyRotate, {'generation': 2, 'key_commit': c}),
        'only owners and admins replace the Orchard key');
    expect(await refused(manager, RecordTypes.keyRotate, {'generation': 2, 'key_commit': c}),
        'only owners and admins replace the Orchard key', reason: 'Manage on a Crate is not the Orchard');
    expect(await refused(alice, RecordTypes.keyRotate, {'crate': _crateA, 'generation': 2, 'key_commit': c}),
        'replacing a Crate key needs manage');
    expect(await refused(manager, RecordTypes.keyRotate, {'crate': _crateA, 'generation': 2, 'key_commit': c}),
        'replacing a Crate key needs manage', reason: 'manages B, not A');
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 3, 'key_commit': c}), 'not the next generation');
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 1, 'key_commit': c}), 'not the next generation');
    expect(await refused(owner, RecordTypes.keyRotate, {'crate': _crateB, 'generation': 3, 'key_commit': c}),
        'not the next generation');
    expect(
        await refused(owner, RecordTypes.keyRotate,
            {'crate': '99999999-9999-4999-8999-999999999999', 'generation': 2, 'key_commit': c}),
        'no such Crate');
    expect(await refused(owner, RecordTypes.keyRotate, {'crate': _crateB, 'key_commit': c}), 'malformed generation');
    // The commitment: present, 32 bytes, spelled the one way base64 spells
    // them (a spelling one side reads and the other refuses would split the
    // record between the server and the devices).
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 2}), 'malformed key_commit');
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 2, 'key_commit': base64Encode(List.filled(31, 7))}),
        'malformed key_commit');
    final canonical = base64Encode(List.filled(32, 0));
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 2, 'key_commit': '${canonical.substring(0, 42)}B='}),
        'malformed key_commit', reason: 'stray bits after the last byte');
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 2, 'key_commit': canonical.substring(0, 43)}),
        'malformed key_commit', reason: 'no padding');
    expect(await refused(owner, RecordTypes.keyRotate, {'generation': 2, 'key_commit': canonical}), 'accepted');
    // Suspended, an admin rotates nothing.
    await add(owner, RecordTypes.memberSuspend, {'uid': admin.uid});
    expect(await refused(admin, RecordTypes.keyRotate, {'generation': 2, 'key_commit': c}), 'not an active member');
  });

  test('the Orchard and every Crate carry the commitment of their first key', () async {
    final noCommit = await signRecordEntry(owner.keys,
        orchardId: _orchard,
        seq: 1,
        prev: const [],
        type: RecordTypes.create,
        by: owner.uid,
        body: {
          'owner': {...recordKeysBody(await owner.keys.publish(owner.uid)), 'uid': owner.uid},
          'crate': {'id': _crateA, 'owners_only': false, 'allow': const <String>[], 'key_commit': await commitFor(_crateA, 1)},
          'roles': const <Object?>[],
        });
    await expectLater(OrchardRecord(_orchard).append(noCommit),
        throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'malformed key_commit')));
    final noCrateCommit = await signRecordEntry(owner.keys,
        orchardId: _orchard,
        seq: 1,
        prev: const [],
        type: RecordTypes.create,
        by: owner.uid,
        body: {
          'owner': {...recordKeysBody(await owner.keys.publish(owner.uid)), 'uid': owner.uid},
          'key_commit': await commitFor(kOrchardScope, 1),
          'crate': {'id': _crateA, 'owners_only': false, 'allow': const <String>[]},
          'roles': const <Object?>[],
        });
    await expectLater(OrchardRecord(_orchard).append(noCrateCommit),
        throwsA(isA<RecordRejected>().having((x) => x.reason, 'reason', 'malformed key_commit')));
    expect(
        await refused(owner, RecordTypes.crateAdd,
            {'id': '44444444-4444-4444-8444-444444444444', 'owners_only': false, 'allow': const <String>[]}),
        'malformed key_commit');
  });

  test('a key opens only as the generation its maker committed to', () async {
    for (final scope in [kOrchardScope, _crateA, _crateB]) {
      expect(await opens(made[scope]![1]!, scope, 1), isTrue, reason: scope);
    }
    // Another key, or the right key presented as another generation, Crate
    // or Orchard, does not.
    expect(await opens(newSpaceKey(), _crateA, 1), isFalse);
    expect(await opens(made[_crateA]![1]!, _crateB, 1), isFalse);
    expect(await opens(made[_crateA]![1]!, kOrchardScope, 1), isFalse);
    expect(await opens(made[kOrchardScope]![1]!, _crateA, 1), isFalse);
    expect(await opens(made[_crateA]![1]!, _crateA, 2), isFalse, reason: 'no generation 2 yet');
    expect(
        await keyMatchesCommitment(made[_crateA]![1]!, state.keyCommitOf(_crateA, 1),
            orchardId: '66666666-6666-4666-8666-666666666666', crateId: _crateA, generation: 1),
        isFalse,
        reason: 'another Orchard');
    // Every byte of the commitment counts, and all 32 of them.
    final real = state.keyCommitOf(_crateA, 1)!;
    for (final i in [0, 17, 31]) {
      final altered = Uint8List.fromList(real)..[i] ^= 1;
      expect(
          await keyMatchesCommitment(made[_crateA]![1]!, altered, orchardId: _orchard, crateId: _crateA, generation: 1),
          isFalse,
          reason: 'one bit off in byte $i');
    }
    expect(
        await keyMatchesCommitment(made[_crateA]![1]!, real.sublist(0, 31),
            orchardId: _orchard, crateId: _crateA, generation: 1),
        isFalse,
        reason: 'short');

    await add(manager, RecordTypes.keyRotate,
        {'crate': _crateB, 'generation': 2, 'key_commit': await commitFor(_crateB, 2)});
    expect(await opens(made[_crateB]![2]!, _crateB, 2), isTrue);
    expect(await opens(made[_crateB]![1]!, _crateB, 2), isFalse, reason: 'the old key is not the new one');
    expect(await opens(made[_crateB]![2]!, _crateB, 1), isFalse);
  });

  test('someone who has left cannot make a key the next generation', () async {
    // The admin made generation 2 of the Orchard key while still in.
    await add(admin, RecordTypes.keyRotate, {'generation': 2, 'key_commit': await commitFor(kOrchardScope, 2)});
    final theirs = made[kOrchardScope]![2]!;
    await add(owner, RecordTypes.memberRemove, {'uid': admin.uid});
    await add(owner, RecordTypes.keyRotate, {'generation': 3, 'key_commit': await commitFor(kOrchardScope, 3)});

    // They sign no new generation, and a key of their own opens as none.
    final mine = newSpaceKey();
    expect(
        await refused(admin, RecordTypes.keyRotate, {
          'generation': 4,
          'key_commit': base64Encode(await keyCommitment(mine, orchardId: _orchard, generation: 4)),
        }),
        'not an active member');
    for (final g in [1, 2, 3]) {
      expect(await opens(mine, kOrchardScope, g), isFalse, reason: 'generation $g');
    }
    expect(await opens(theirs, kOrchardScope, 3), isFalse, reason: 'the key they knew is not the next one');
    expect(await opens(theirs, kOrchardScope, 2), isTrue, reason: 'what they made while in stays what it was');
    expect(await opens(made[kOrchardScope]![3]!, kOrchardScope, 3), isTrue);
  });

  // Which keys wait to be replaced is the record's to say, not the server's
  // alone (found in a client security review).
  test('a key someone held and lost waits to be replaced, until it is', () async {
    expect(state.keysDue, isEmpty, reason: 'nobody has lost anything');
    // Alice leaves: the Orchard's key and Crate A's (her role opens A) wait;
    // B's does not (she never had it).
    await add(owner, RecordTypes.memberRemove, {'uid': alice.uid});
    expect(state.keysDue, {kOrchardScope, _crateA});
    // The manager suspended: B's too.
    await add(owner, RecordTypes.memberSuspend, {'uid': manager.uid});
    expect(state.keysDue, {kOrchardScope, _crateA, _crateB});
    // Back again, the keys they held still wait: they held them while out.
    await add(owner, RecordTypes.memberResume, {'uid': manager.uid});
    expect(state.keysDue, {kOrchardScope, _crateA, _crateB});

    // Each replaced, each stops waiting; a copy and a replay say the same.
    await add(owner, RecordTypes.keyRotate, {'crate': _crateA, 'generation': 2, 'key_commit': await commitFor(_crateA, 2)});
    expect(state.keysDue, {kOrchardScope, _crateB});
    await add(admin, RecordTypes.keyRotate, {'generation': 2, 'key_commit': await commitFor(kOrchardScope, 2)});
    expect(state.keysDue, {_crateB});
    expect(state.copy().keysDue, {_crateB});
    await add(manager, RecordTypes.keyRotate, {'crate': _crateB, 'generation': 2, 'key_commit': await commitFor(_crateB, 2)});
    expect(state.keysDue, isEmpty);

    // A role changed for everyone who has it: its Members lose Crate A.
    await add(owner, RecordTypes.roleSet, _role(_member, 100, {}));
    expect(state.keysDue, {_crateA});
  });

  test('access that ends by the clock makes the key wait, for whoever came to hold it during this generation',
      () async {
    // Until a set time: the owner gives Alice Crate B until 1000.
    await add(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateB, 'until': 1000, 'switches': ['connect']});
    expect(state.keysDueAt(999), isEmpty, reason: 'still given');
    expect(state.keysDueAt(1000), {_crateB}, reason: 'ended: she holds the key she was given');
    expect(state.copy().keysDueAt(1000), {_crateB}, reason: 'a copy says the same');
    expect(state.keysDue, isEmpty, reason: 'no entry took it away');
    await add(manager, RecordTypes.keyRotate,
        {'crate': _crateB, 'generation': 2, 'key_commit': await commitFor(_crateB, 2)});
    expect(state.keysDueAt(1000), isEmpty, reason: 'replaced since: the new generation never reached her');
    // Given again, later: she holds the new generation, until 1500.
    await add(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateB, 'until': 1500, 'switches': ['connect']});
    expect(state.keysDueAt(1499), isEmpty);
    expect(state.keysDueAt(1500), {_crateB});
    await add(manager, RecordTypes.keyRotate,
        {'crate': _crateB, 'generation': 3, 'key_commit': await commitFor(_crateB, 3)});
    expect(state.keysDueAt(1500), isEmpty);

    // An end date set after the keys she holds were replaced (nothing of
    // the record says she came to hold them): Alice's time in the Orchard
    // ends at 2000. Her ended grant of B is not counted again.
    await add(admin, RecordTypes.keyRotate, {'generation': 2, 'key_commit': await commitFor(kOrchardScope, 2)});
    await add(owner, RecordTypes.keyRotate,
        {'crate': _crateA, 'generation': 2, 'key_commit': await commitFor(_crateA, 2)});
    await add(owner, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 2000});
    expect(state.keysDueAt(1999), isEmpty);
    expect(state.keysDueAt(2000), {kOrchardScope, _crateA});
    await add(admin, RecordTypes.keyRotate, {'generation': 3, 'key_commit': await commitFor(kOrchardScope, 3)});
    await add(owner, RecordTypes.keyRotate,
        {'crate': _crateA, 'generation': 3, 'key_commit': await commitFor(_crateA, 3)});
    expect(state.keysDueAt(2000), isEmpty);

    // Ended early by an entry: given until 5000, taken back at once.
    await add(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateB, 'until': 5000, 'switches': ['connect']});
    await add(owner, RecordTypes.accessGrant, {'uid': alice.uid, 'crate': _crateB, 'until': 0});
    expect(state.keysDue, {_crateB});
    expect(state.keysDueAt(0), {_crateB});
  });

  test('an end date set before the keys were replaced: they wait once it passes, if this device saw the new '
      'generation before then', () async {
    await add(owner, RecordTypes.memberSet, {'uid': alice.uid, 'ends_at': 2000});
    // And Crate B until 1800.
    await add(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateB, 'until': 1800, 'switches': ['connect']});
    expect(state.generationSeq[_crateB], 2, reason: 'made by the crate.add of setUp');
    final orchardKey = await add(admin, RecordTypes.keyRotate,
        {'generation': 2, 'key_commit': await commitFor(kOrchardScope, 2)});
    final crateKey = await add(owner, RecordTypes.keyRotate,
        {'crate': _crateA, 'generation': 2, 'key_commit': await commitFor(_crateA, 2)});
    final bKey = await add(manager, RecordTypes.keyRotate,
        {'crate': _crateB, 'generation': 2, 'key_commit': await commitFor(_crateB, 2)});
    expect(state.generationSeq[kOrchardScope], orchardKey.seq);
    expect(state.generationSeq[_crateA], crateKey.seq);
    expect(state.generationSeq[_crateB], bKey.seq);
    int? Function(int) seenAt(int at) =>
        (int seq) => seq == orchardKey.seq || seq == crateKey.seq || seq == bKey.seq ? at : 1;
    // Without the dates this device saw them, the record cannot tell.
    expect(state.keysDueAt(2500), isEmpty);
    // Seen at 1500, before her ends: they reached her, and each waits once
    // its end passes (B at 1800, the rest at 2000).
    expect(state.keysDueAt(1799, firstSeen: seenAt(1500)), isEmpty, reason: 'still in');
    expect(state.keysDueAt(1800, firstSeen: seenAt(1500)), {_crateB});
    expect(state.keysDueAt(2500, firstSeen: seenAt(1500)), {kOrchardScope, _crateA, _crateB});
    expect(state.copy().keysDueAt(2500, firstSeen: seenAt(1500)), {kOrchardScope, _crateA, _crateB});
    // Seen at 1900: B had ended by then, the rest had not.
    expect(state.keysDueAt(2500, firstSeen: seenAt(1900)), {kOrchardScope, _crateA});
    // Seen at 2100, after both: made when she may have been out already.
    expect(state.keysDueAt(2500, firstSeen: seenAt(2100)), isEmpty);
  });

  test("a member's keys replaced: every key they may hold waits, their old keys may be in other hands", () async {
    final next = await AccountKeys.generate(version: 2);
    final published = await next.publish(alice.uid);
    await add(_Acct(alice.uid, next), RecordTypes.memberKeys,
        {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))});
    expect(state.keysDue, {kOrchardScope, _crateA}, reason: 'the Orchard and the Crate her role opens; not B');
  });

  test('the commitment is HKDF-SHA256 of the key over its label and place (a fixed vector)', () async {
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final orchard = await keyCommitment(key, orchardId: _orchard, generation: 1);
    final crate = await keyCommitment(key, orchardId: _orchard, crateId: _crateA, generation: 7);
    String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    // Checked against Node's crypto.hkdfSync('sha256', key, '', info, 32)
    // with the same info bytes.
    expect(hex(orchard), '3534d1ce370da0dff0fad3e480cdc0f05dbcd2f1259d32385aa9973b4878c137');
    expect(hex(crate), '5d0503a8458551e750c1e380bc6b0ca28b9ba4b8e05813b3d7f857dd847a4a97');
    expect(() => keyCommitment(Uint8List(31), orchardId: _orchard, generation: 1), throwsArgumentError);
  });
}

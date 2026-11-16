import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show canonicalJson;
import 'package:zestssh/features/orchards/members/member_trust.dart' show signMemberVerification;
import 'package:zestssh/features/orchards/members/team_recovery.dart' show signTeamRecovery;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import '../../../helpers/record_commits.dart';

/// The Orchard record's conformance corpus: scenarios built from fixed keys
/// (so every signature is the same each time), each entry with the outcome
/// the app gives it and the state each scenario ends in. The server replays
/// the same file (ZestSSH Cloud's test/fixtures/orchard_record_corpus.json,
/// test/orchard_record_corpus.test.js) and must decide every entry the same
/// way. Regenerate after changing a rule:
///
///   ZEST_WRITE_CORPUS=1 flutter test test/features/orchards/record/record_corpus_test.dart
///
/// then copy the file to the backend's test/fixtures.

const _orchard = '11111111-1111-4111-8111-111111111111';
const _crateA = '22222222-2222-4222-8222-222222222222';
const _crateB = '33333333-3333-4333-8333-333333333333';
const _crateSecret = '44444444-4444-4444-8444-444444444444';
const _crateMine = '99999999-9999-4999-8999-999999999999';
const _member = '55555555-5555-4555-8555-555555555555';
const _guest = '66666666-6666-4666-8666-666666666666';
const _lead = '77777777-7777-4777-8777-777777777777';
const _keeper = '88888888-8888-4888-8888-888888888888';
const _corpusPath = 'test/features/orchards/record/record_corpus.json';

class _Acct {
  _Acct(this.uid, this.keys);

  final String uid;
  final AccountKeys keys;
}

Future<_Acct> _acct(String uid, int seed, {int version = 1}) async => _Acct(
      uid,
      await AccountKeys.fromSeeds(
        encryptionSeed: List<int>.filled(32, seed),
        signingSeed: List<int>.filled(32, seed + 1),
        version: version,
        createdAt: 1790000000 + seed,
      ),
    );

/// A device with a signing key of its own (trusted devices), made from
/// a fixed seed.
class _Device {
  _Device(this._pair, this.keyBytes);

  final SimpleKeyPair _pair;

  /// Its public key: what the record lists.
  final Uint8List keyBytes;

  String get key => base64Encode(keyBytes);

  Future<List<int>> sign(List<int> message) async => (await Ed25519().sign(message, keyPair: _pair)).bytes;
}

Future<_Device> _device(int seed) async {
  final pair = await Ed25519().newKeyPairFromSeed(List<int>.filled(32, seed));
  return _Device(pair, Uint8List.fromList((await pair.extractPublicKey()).bytes));
}

/// [canonical] base64 with a stray bit set after the last byte: the same
/// bytes to a lenient decoder, and not the one spelling of them. Both sides
/// must refuse it, or a member could split the record between the server
/// and the devices.
String _strayBits(String canonical) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final i = canonical.indexOf('=') - 1;
  return canonical.replaceRange(i, i + 1, alphabet[alphabet.indexOf(canonical[i]) | 1]);
}

/// One scenario being recorded.
class _Scenario {
  _Scenario(this.name);

  final String name;
  final state = OrchardRecord(_orchard);
  final steps = <Map<String, Object?>>[];

  /// Signs an entry as [who] and records what the rules say about it.
  Future<String> attempt(_Acct who, String type, Map<String, Object?> body, {int? seq, List<int>? prev, String? by}) async {
    final e = await signRecordEntry(who.keys,
        orchardId: _orchard,
        seq: seq ?? state.seq + 1,
        prev: prev ?? state.head,
        type: type,
        body: body,
        by: by ?? who.uid);
    return record(e);
  }

  Future<String> record(RecordEntry e) async {
    String outcome;
    try {
      await state.append(e);
      outcome = 'ok';
    } on RecordRejected catch (x) {
      outcome = 'rejected: ${x.reason}';
    }
    steps.add({'entry': e.toJson(), 'outcome': outcome});
    return outcome;
  }

  Map<String, Object?> toJson() => {'name': name, 'steps': steps, 'final': summarize(state)};
}

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The state as both implementations describe it.
Map<String, Object?> summarize(OrchardRecord s) {
  List<String> sorted(Iterable<String> x) => x.toList()..sort();
  return {
    'seq': s.seq,
    'format': s.format,
    'head': _hex(s.head),
    'orchard_generation': s.orchardGeneration,
    'orchard_key_commits': {for (final c in s.orchardCommits.entries) '${c.key}': _hex(c.value)},
    'rules': s.rules.toBody(),
    // Only when on: summaries from before team recovery keep their bytes.
    if (s.teamRecovery) 'team_recovery': true,
    // Only once team recording is on, likewise.
    if (!s.tracking.isNone) 'tracking': s.tracking.toBody(),
    // Only while event export is on, likewise.
    if (s.eventExport case final x?) 'export': {'key': x.keyText, 'by': x.by},
    // Only once an owner changed the Admin role (3.3.0), likewise.
    if (s.adminRole case final a?)
      'admin': {
        'can': sorted(a.can),
        'crates': {for (final c in a.crates.entries) c.key: sorted(c.value)},
      },
    // Only while the team is being deleted, likewise.
    if (s.deleting case final d?) 'deleting': {'by': d.by, 'seq': d.seq},
    'members': {
      for (final m in s.members.values)
        m.uid: {
          'role': m.role,
          'status': m.status.name,
          'ends_at': ?m.endsAt,
          'keys': (m.keys.keys.toList()..sort()),
          'grants': {for (final g in m.grants.entries) g.key: sorted(g.value)},
          // Only when given a Crate until a set time: summaries from
          // before keep their bytes.
          if (m.timed.isNotEmpty)
            'timed': {
              for (final t in m.timed.entries) t.key: {'switches': sorted(t.value.switches), 'until': t.value.until},
            },
          // Only with a device approved, likewise.
          if (m.devices.isNotEmpty) 'devices': sorted(m.devices),
          // Only when limited in a Crate (member.limit), likewise.
          if (m.limits.isNotEmpty) 'limits': {for (final l in m.limits.entries) l.key: sorted(l.value)},
        },
    },
    'roles': {
      for (final r in s.roles.values)
        r.id: {
          'rank': r.rank,
          'name_gen': r.nameGeneration,
          'can': sorted(r.can),
          'crates': {for (final c in r.crates.entries) c.key: sorted(c.value)},
        },
    },
    'crates': {
      for (final c in s.crates.values)
        c.id: {
          'owners_only': c.ownersOnly,
          'allow': sorted(c.allow),
          'generation': c.generation,
          'key_commits': {for (final k in c.commits.entries) '${k.key}': _hex(k.value)},
          'confirm_reveal': c.confirmReveal,
          // Only when session logs are on: summaries from before keep their bytes.
          if (c.sessionLogs) 'session_logs': true,
          // Only when watched, likewise.
          if (c.watched) 'watched': true,
          // Only when members too may connect without a watcher while
          // ZestSSH Cloud cannot be reached, likewise.
          if (c.unwatchedAway) 'unwatched_away': true,
          if (c.offlineHours > 0) 'offline_hours': c.offlineHours,
          // Only once set up: summaries from before team CAs keep their bytes.
          if (c.ca != null)
            'ca': {
              'on': c.ca!.on,
              'generation': c.ca!.generation,
              'public_keys': {for (final k in c.ca!.publicKeys.entries) '${k.key}': _hex(k.value)},
              'ttl_minutes': c.ca!.ttlMinutes,
              'principals': c.ca!.principals,
              'key_crate': c.ca!.keyCrate,
            },
        },
    },
    'switches': {
      for (final m in s.members.values)
        m.uid: {
          for (final c in s.crates.keys)
            if (s.switchesOf(m.uid, c).isNotEmpty) c: sorted(s.switchesOf(m.uid, c)),
        },
    },
    'entitlements': {for (final e in s.entitlements().entries) e.key: sorted(e.value)},
    // With access until a set time, what holds depends on the moment:
    // the answers at the start, and a second before and at every end there
    // is (of a grant, of someone's time in the Orchard).
    if (s.members.values.any((m) => m.timed.isNotEmpty))
      'at': {
        for (final now in _moments(s))
          '$now': {
            'switches': {
              for (final m in s.members.values)
                m.uid: {
                  for (final c in s.crates.keys)
                    if (s.switchesAt(m.uid, c, now).isNotEmpty) c: sorted(s.switchesAt(m.uid, c, now)),
                },
            },
            'entitlements': {for (final e in s.entitlementsAt(now).entries) e.key: sorted(e.value)},
            // When what each may do in each Crate next becomes less by itself.
            'ends': {
              for (final m in s.members.values)
                m.uid: {
                  for (final c in s.crates.keys) c: ?s.accessEndsAt(m.uid, c, now),
                },
            },
            // And what a certificate rests on.
            'certificate_ends': {
              for (final m in s.members.values)
                m.uid: {
                  for (final c in s.crates.keys)
                    c: ?s.accessEndsAt(m.uid, c, now, of: CrateSwitches.inCertificate),
                },
            },
          },
      },
  };
}

/// The moments a record with access until a set time is asked about.
List<int> _moments(OrchardRecord s) {
  final ends = <int>{
    for (final m in s.members.values) ...[
      ?m.endsAt,
      for (final t in m.timed.values) t.until,
    ],
  };
  return {0, for (final e in ends) ...[e - 1, e]}.toList()..sort();
}

Map<String, Object?> _role(String id, int rank, Map<String, CrateLevel> crates, {List<String> can = const []}) => {
      'id': id,
      'rank': rank,
      'name_enc': base64Encode(utf8.encode('sealed-$id')),
      'name_gen': 1,
      'can': [...can]..sort(),
      'crates': {for (final e in crates.entries) e.key: switchList(levelSwitches(e.value))},
    };

Future<Map<String, Object?>> _memberBody(_Acct who, String role, {Map<String, CrateLevel>? grants, int? endsAt}) async => {
      ...recordKeysBody(await who.keys.publish(who.uid)),
      'uid': who.uid,
      'role': role,
      if (grants != null) 'grants': {for (final e in grants.entries) e.key: switchList(levelSwitches(e.value))},
      'ends_at': ?endsAt,
    };

Future<Map<String, Object?>> _createBody(_Acct owner) async => {
      'owner': {...recordKeysBody(await owner.keys.publish(owner.uid)), 'uid': owner.uid},
      'key_commit': testCommit('orchard 1'),
      'crate': {'id': _crateA, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit('$_crateA 1')},
      'roles': [
        _role(_member, 200, {_crateA: CrateLevel.edit}),
        _role(_guest, 100, {_crateA: CrateLevel.connect}),
      ],
    };

/// A crate.add body, with the commitment to the Crate's first key.
Map<String, Object?> _crate(String id, {bool ownersOnly = false, List<String> allow = const []}) =>
    {'id': id, 'owners_only': ownersOnly, 'allow': allow, 'key_commit': testCommit('$id 1')};

/// A key.rotate body for the Orchard's key (null [crate]) or a Crate's.
Map<String, Object?> _rotate(int generation, {String? crate}) => {
      'crate': ?crate,
      'generation': generation,
      'key_commit': testCommit('${crate ?? 'orchard'} $generation'),
    };

Future<Map<String, Object?>> buildCorpus() async {
  final owner = await _acct('uid-owner', 0x31);
  final owner2 = await _acct('uid-owner2', 0x33);
  final admin = await _acct('uid-admin', 0x35);
  final lead = await _acct('uid-lead', 0x37);
  final alice = await _acct('uid-alice', 0x39);
  final bob = await _acct('uid-bob', 0x3b);
  final mallory = await _acct('uid-mallory', 0x3d);
  final alice2 = await _acct('uid-alice', 0x41, version: 2);
  final alice3 = await _acct('uid-alice', 0x43, version: 3);

  Future<_Scenario> team(String name) async {
    final s = _Scenario(name);
    await s.attempt(owner, RecordTypes.create, await _createBody(owner));
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateB, allow: ['forward', 'sftp']));
    await s.attempt(owner, RecordTypes.roleSet,
        _role(_lead, 500, {_crateA: CrateLevel.manage, _crateB: CrateLevel.edit}, can: [RoleCan.invite, RoleCan.changeRoles]));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(admin, FixedRoles.admin));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(lead, _lead));
    await s.attempt(admin, RecordTypes.memberAdd, await _memberBody(alice, _member));
    return s;
  }

  final scenarios = <_Scenario>[];

  // The chain itself.
  {
    final s = await team('the chain');
    final body = _crate(_crateMine);
    await s.attempt(owner, RecordTypes.crateAdd, body, seq: s.state.seq + 2);
    await s.attempt(owner, RecordTypes.crateAdd, body, prev: List<int>.filled(32, 7));
    final good = await signRecordEntry(owner.keys,
        orchardId: _orchard, seq: s.state.seq + 1, prev: s.state.head, type: RecordTypes.crateAdd, body: body, by: owner.uid);
    await s.record(RecordEntry(
        seq: good.seq,
        prev: good.prev,
        type: good.type,
        bodyJson: good.bodyJson.replaceFirst('false', 'true'),
        by: good.by,
        byKeyVersion: good.byKeyVersion,
        signature: good.signature));
    await s.attempt(mallory, RecordTypes.crateAdd, body, by: owner.uid);
    await s.record(RecordEntry(
        seq: good.seq,
        prev: good.prev,
        type: good.type,
        bodyJson: '{"owners_only":false, "id":"$_crateMine","allow":[]}',
        by: good.by,
        byKeyVersion: good.byKeyVersion,
        signature: good.signature));
    await s.record(RecordEntry(
        seq: good.seq,
        prev: good.prev,
        type: 'crate.rename',
        bodyJson: good.bodyJson,
        by: good.by,
        byKeyVersion: good.byKeyVersion,
        signature: good.signature));
    await s.record(good);
    scenarios.add(s);
  }

  // Create.
  {
    final s = _Scenario('create');
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateB));
    await s.attempt(mallory, RecordTypes.create, await _createBody(owner));
    await s.attempt(owner, RecordTypes.create, await _createBody(owner), by: alice.uid);
    final twice = await _createBody(owner)
      ..['roles'] = [_role(_member, 200, {}), _role(_member, 100, {})];
    await s.attempt(owner, RecordTypes.create, twice);
    final sameRank = await _createBody(owner)
      ..['roles'] = [_role(_member, 200, {}), _role(_guest, 200, {})];
    await s.attempt(owner, RecordTypes.create, sameRank);
    // The commitments to the first keys: both, 32 bytes each.
    await s.attempt(owner, RecordTypes.create, await _createBody(owner)
      ..remove('key_commit'));
    await s.attempt(owner, RecordTypes.create, await _createBody(owner)
      ..['crate'] = {'id': _crateA, 'owners_only': false, 'allow': ['forward', 'sftp']});
    await s.attempt(owner, RecordTypes.create, await _createBody(owner)
      ..['key_commit'] = base64Encode(List<int>.filled(33, 1)));
    await s.attempt(owner, RecordTypes.create, await _createBody(owner)
      ..['key_commit'] = _strayBits(testCommit('orchard 1')));
    await s.attempt(owner, RecordTypes.create, await _createBody(owner));
    await s.attempt(owner, RecordTypes.create, await _createBody(owner));
    scenarios.add(s);
  }

  // Roles and switches.
  {
    final s = await team('roles and switches');
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': <String>[]});
    await s.attempt(admin, RecordTypes.roleSet, _role(_guest, 101, {_crateA: CrateLevel.use}));
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, 200, {_crateA: CrateLevel.use}));
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, 100, {_crateSecret: CrateLevel.use}));
    await s.attempt(owner, RecordTypes.roleSet, _role(FixedRoles.admin, 150, {}));
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, kAdminRank, {}));
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, 100, {})..['crates'] = {_crateA: ['reveal']});
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, 100, {})..['crates'] = {_crateA: ['sftp', 'connect']});
    await s.attempt(owner, RecordTypes.roleSet, _role(_guest, 100, {})..['can'] = ['fly']);
    await s.attempt(owner, RecordTypes.roleSet, _role(_member, 200, {_crateA: CrateLevel.edit, _crateB: CrateLevel.use}));
    scenarios.add(s);
  }

  // Adding people.
  {
    final s = await team('adding people');
    await s.attempt(alice, RecordTypes.memberAdd, await _memberBody(bob, _guest));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest));
    await s.attempt(admin, RecordTypes.memberAdd, await _memberBody(bob, FixedRoles.admin));
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, FixedRoles.owner));
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _lead));
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest, grants: {_crateB: CrateLevel.manage}));
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest, grants: {_crateB: CrateLevel.edit}, endsAt: 1893456000));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, _guest)..['uid'] = 'uid-carol');
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, _guest, grants: {_crateSecret: CrateLevel.use}));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, FixedRoles.admin, grants: {_crateA: CrateLevel.use}));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, FixedRoles.owner, endsAt: 1893456000));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, 'no-such-role'));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, _guest)..['ed25519_pub'] = 'not base64!');
    // The same keys spelled another way: stray bits after the last byte, or
    // no padding. A lenient decoder reads the same bytes; both sides refuse.
    final spelled = await _memberBody(mallory, _guest);
    await s.attempt(owner, RecordTypes.memberAdd,
        {...spelled, 'ed25519_pub': _strayBits(spelled['ed25519_pub'] as String)});
    await s.attempt(owner, RecordTypes.memberAdd,
        {...spelled, 'x25519_pub': _strayBits(spelled['x25519_pub'] as String)});
    await s.attempt(owner, RecordTypes.memberAdd,
        {...spelled, 'self_sig': _strayBits(spelled['self_sig'] as String)});
    await s.attempt(owner, RecordTypes.memberAdd,
        {...spelled, 'ed25519_pub': (spelled['ed25519_pub'] as String).replaceAll('=', '')});
    await s.attempt(owner, RecordTypes.memberAdd, spelled);
    scenarios.add(s);
  }

  // Changing people.
  {
    final s = await team('changing people');
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(alice, RecordTypes.memberSet, {'uid': lead.uid, 'role': _guest});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': admin.uid, 'role': _guest});
    await s.attempt(admin, RecordTypes.memberSet, {'uid': owner.uid, 'role': _guest});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.admin});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': alice.uid, 'role': _lead});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': alice.uid, 'grants': {_crateB: switchList(levelSwitches(CrateLevel.use))}});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': alice.uid, 'grants': {_crateA: switchList(levelSwitches(CrateLevel.use))}});
    await s.attempt(admin, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin, 'grants': <String, Object?>{}});
    await s.attempt(lead, RecordTypes.memberSet, {'uid': lead.uid, 'role': _member});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    await s.attempt(owner2, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.admin});
    await s.attempt(owner2, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.owner});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': bob.uid, 'role': _guest});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': lead.uid});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': lead.uid, 'ends_at': 1893456000});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': lead.uid, 'role': FixedRoles.owner});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': lead.uid, 'role': FixedRoles.owner, 'ends_at': 0});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner2.uid, 'ends_at': 1893456000});
    scenarios.add(s);
  }

  // Crates.
  {
    final s = await team('crates');
    await s.attempt(alice, RecordTypes.crateAdd, _crate(_crateMine));
    await s.attempt(admin, RecordTypes.crateAdd, _crate(_crateMine, ownersOnly: true));
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateA));
    await s.attempt(owner, RecordTypes.crateAdd, _crate('bad id!'));
    await s.attempt(owner, RecordTypes.roleSet,
        _role(_lead, 500, {_crateA: CrateLevel.manage, _crateB: CrateLevel.edit},
            can: [RoleCan.changeRoles, RoleCan.createCrates, RoleCan.invite]));
    // A Crate's first key needs its commitment.
    await s.attempt(lead, RecordTypes.crateAdd, _crate(_crateMine)..remove('key_commit'));
    await s.attempt(lead, RecordTypes.crateAdd, _crate(_crateMine)..['key_commit'] = base64Encode(List<int>.filled(31, 2)));
    await s.attempt(lead, RecordTypes.crateAdd, _crate(_crateMine)..['key_commit'] = 42);
    await s.attempt(lead, RecordTypes.crateAdd, _crate(_crateMine));
    await s.attempt(alice, RecordTypes.crateSet, {'id': _crateA, 'allow': <String>[]});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateMine, 'allow': ['sftp']});
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateMine, 'owners_only': false});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateMine, 'owners_only': true});
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateSecret, 'owners_only': false});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': ['agent', 'sftp']});
    scenarios.add(s);
  }

  // New keys.
  {
    final s = await team('new keys');
    final published = await alice2.keys.publish(alice.uid);
    final endorsed = {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))};
    await s.attempt(alice, RecordTypes.memberKeys, endorsed);
    await s.attempt(alice2, RecordTypes.memberKeys, {...recordKeysBody(published), 'endorsement': base64Encode(List<int>.filled(64, 0))});
    final far = await alice3.keys.publish(alice.uid);
    await s.attempt(alice3, RecordTypes.memberKeys,
        {...recordKeysBody(far), 'endorsement': base64Encode(await alice.keys.sign(accountKeysEndorsementMessage(1, far)))});
    // The endorsement spelled another way.
    await s.attempt(alice2, RecordTypes.memberKeys,
        {...endorsed, 'endorsement': _strayBits(endorsed['endorsement']! as String)});
    await s.attempt(alice2, RecordTypes.memberKeys, endorsed);
    await s.attempt(alice, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(alice2, RecordTypes.memberRemove, {'uid': alice.uid});
    scenarios.add(s);
  }

  // New keys while suspended: recorded, though nothing else is; once
  // removed, not even that.
  {
    final s = await team('new keys while suspended');
    final published = await alice2.keys.publish(alice.uid);
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(alice2, RecordTypes.memberKeys,
        {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))});
    await s.attempt(alice2, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': alice.uid});
    final third = await alice3.keys.publish(alice.uid);
    await s.attempt(alice3, RecordTypes.memberKeys,
        {...recordKeysBody(third), 'endorsement': base64Encode(await alice2.keys.endorse(third))});
    scenarios.add(s);
  }

  // Suspend, resume, remove.
  {
    final s = await team('suspend and remove');
    await s.attempt(lead, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(alice, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.memberResume, {'uid': alice.uid});
    await s.attempt(alice, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.memberResume, {'uid': alice.uid});
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest));
    await s.attempt(owner, RecordTypes.memberRemove, {'uid': owner.uid});
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': owner.uid});
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': lead.uid});
    scenarios.add(s);
  }

  // New generations of keys: who makes them, one at a time, each with
  // the commitment to the new key.
  {
    final s = await team('new generations');
    await s.attempt(alice, RecordTypes.keyRotate, _rotate(2));
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(2));
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(2, crate: _crateB));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(3));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateSecret));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateA)..remove('generation'));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateA)..['generation'] = 'two');
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: 'bad id!'));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2)..remove('key_commit'));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2)..['key_commit'] = base64Encode(List<int>.filled(16, 3)));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2)..['key_commit'] = _strayBits(testCommit('orchard 2')));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2)..['key_commit'] = testCommit('orchard 2').replaceAll('=', ''));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2));
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(2, crate: _crateA));
    await s.attempt(admin, RecordTypes.keyRotate, _rotate(3));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateA));
    // The admin leaves, and makes no generation after.
    await s.attempt(owner, RecordTypes.memberRemove, {'uid': admin.uid});
    await s.attempt(admin, RecordTypes.keyRotate, _rotate(4));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(4));
    // Suspended, the lead makes none either; resumed, again.
    await s.attempt(owner, RecordTypes.memberSuspend, {'uid': lead.uid});
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(3, crate: _crateA));
    await s.attempt(owner, RecordTypes.memberResume, {'uid': lead.uid});
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(3, crate: _crateA));
    // Owners-only Crates: owners alone, who manage every Crate.
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(2, crate: _crateSecret));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateSecret));
    await s.attempt(owner, RecordTypes.keyRotate, _rotate(2, crate: _crateB));
    scenarios.add(s);
  }

  // The Orchard's rules, and a Crate that asks again before revealing.
  {
    final s = await team('rules');
    Map<String, Object?> rules({
      bool twoFactor = true,
      List<Object?> domains = const ['example.com', 'example.org'],
      bool appLock = true,
      Object lockMinutes = 15,
      bool noExport = true,
      Object offline = 72,
      Object reauth = 30,
    }) =>
        {
          'email_domains': domains,
          'max_lock_minutes': lockMinutes,
          'no_export': noExport,
          'offline_hours': offline,
          'reauth_days': reauth,
          'require_2fa': twoFactor,
          'require_app_lock': appLock,
        };
    await s.attempt(admin, RecordTypes.rulesSet, rules());
    await s.attempt(lead, RecordTypes.rulesSet, rules());
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: ['example.org', 'example.com']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: ['example.com', 'example.com']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: ['Example.com']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: ['localhost']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: ['-bad.example.com']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: [7]));
    await s.attempt(owner, RecordTypes.rulesSet,
        rules(domains: [for (var i = 0; i < 21; i++) 'd${i.toString().padLeft(2, '0')}.example.com']));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lockMinutes: 1441));
    await s.attempt(owner, RecordTypes.rulesSet, rules(offline: 8761));
    await s.attempt(owner, RecordTypes.rulesSet, rules(reauth: 366));
    await s.attempt(owner, RecordTypes.rulesSet, rules(reauth: 'monthly'));
    await s.attempt(owner, RecordTypes.rulesSet, rules(appLock: false));
    await s.attempt(owner, RecordTypes.rulesSet, rules()..remove('no_export'));
    await s.attempt(owner, RecordTypes.rulesSet, rules());
    await s.attempt(owner, RecordTypes.rulesSet, rules(domains: const [], lockMinutes: 0, offline: 0, reauth: 0));
    await s.attempt(owner, RecordTypes.rulesSet,
        rules(twoFactor: false, domains: const [], appLock: false, lockMinutes: 0, noExport: false, offline: 0, reauth: 0));
    await s.attempt(owner, RecordTypes.rulesSet, rules(appLock: true, lockMinutes: 1440, offline: 8760, reauth: 365));
    // Sign in again in hours: newer apps write it, a whole
    // number from 0 to 8760; missing means none (every rules.set above).
    // (No body carries a negative or a fraction: signing refuses them.)
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['reauth_hours'] = 8761);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['reauth_hours'] = 'eight');
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['reauth_hours'] = 8);
    await s.attempt(owner, RecordTypes.rulesSet, rules(reauth: 0)..['reauth_hours'] = 8760);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['reauth_hours'] = 0);
    // Company sign-in: newer apps write it, only a real true or false;
    // missing means off (every rules.set above).
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = 'yes');
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = 1);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = false);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = true);
    // Hours to the end, so the state both readers end in carries them.
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = true..['reauth_hours'] = 8);
    // That sign-in counting as two-step: only a real true
    // or false; missing means off.
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['sso_two_step'] = 'yes');
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['sso_two_step'] = 1);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['sso_two_step'] = false);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['sso_two_step'] = true);
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['require_sso'] = true..['reauth_hours'] = 8);
    // Asking again before revealing: whoever manages the Crate.
    await s.attempt(alice, RecordTypes.crateSet, {'id': _crateA, 'confirm_reveal': true});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateB, 'confirm_reveal': true});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'confirm_reveal': 'yes'});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'confirm_reveal': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'confirm_reveal': true, 'allow': ['sftp']});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'confirm_reveal': false});
    scenarios.add(s);
  }

  // The two rules about remote screens (4.0): only a real true or false; an
  // owner's to set, like the rest; and one that a rules.set does not name
  // stays as it is (an app from before them names neither).
  {
    final s = await team('remote screen rules');
    Map<String, Object?> rules({Object? sshOnly, Object? lock}) => {
          'email_domains': const <Object?>[],
          'max_lock_minutes': 0,
          'no_export': false,
          'offline_hours': 0,
          'reauth_days': 0,
          'require_2fa': false,
          'require_app_lock': false,
          'screens_ssh_only': ?sshOnly,
          'screens_lock_redirections': ?lock,
        };
    await s.attempt(admin, RecordTypes.rulesSet, rules(sshOnly: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(sshOnly: 'yes'));
    await s.attempt(owner, RecordTypes.rulesSet, rules(sshOnly: 1));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lock: 'yes'));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lock: 0));
    await s.attempt(owner, RecordTypes.rulesSet, rules(sshOnly: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(sshOnly: false, lock: false));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lock: true));
    // Rules set by an app from before them say nothing of them: they stay (the second on, the first off).
    await s.attempt(owner, RecordTypes.rulesSet, rules());
    await s.attempt(owner, RecordTypes.rulesSet, rules()..['no_export'] = true);
    // One named, the other not: the one named changes.
    await s.attempt(owner, RecordTypes.rulesSet, rules(sshOnly: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lock: false));
    await s.attempt(owner, RecordTypes.rulesSet, rules(lock: true));
    scenarios.add(s);
  }
  // The same, ending with what an older app's rules.set leaves behind.
  {
    final s = await team('remote screen rules kept by an older rules.set');
    Map<String, Object?> older({bool noExport = false}) => {
          'email_domains': const <Object?>[],
          'max_lock_minutes': 0,
          'no_export': noExport,
          'offline_hours': 0,
          'reauth_days': 0,
          'require_2fa': false,
          'require_app_lock': false,
        };
    await s.attempt(owner, RecordTypes.rulesSet, {...older(), 'screens_ssh_only': true, 'screens_lock_redirections': true});
    await s.attempt(owner, RecordTypes.rulesSet, older(noExport: true));
    await s.attempt(owner, RecordTypes.rulesSet, {...older(), 'screens_ssh_only': false});
    await s.attempt(owner, RecordTypes.rulesSet, older());
    scenarios.add(s);
  }

  // Dropping a role.
  {
    final s = await team('dropping a role');
    await s.attempt(admin, RecordTypes.roleDrop, {'id': _member, 'move_to': _guest});
    await s.attempt(owner, RecordTypes.roleDrop, {'id': _member, 'move_to': _member});
    await s.attempt(owner, RecordTypes.roleDrop, {'id': _member, 'move_to': _guest});
    scenarios.add(s);
  }

  // Format 2 (3.0): making someone an owner or admin carries the
  // author's signed comparison of that person's keys as the record holds
  // them: the member verification statement, canonical base64 of 64 bytes.
  {
    Future<String> compared(_Acct by, _Acct subject) async => base64Encode(await signMemberVerification(by.keys,
        verifierUid: by.uid, orchardId: _orchard, subject: await subject.keys.publish(subject.uid)));
    final s = _Scenario('format 2: owners and admins only after comparing');
    await s.attempt(owner, RecordTypes.create, {...await _createBody(owner), 'format': 2});
    final adminBody = await _memberBody(admin, FixedRoles.admin);
    await s.attempt(owner, RecordTypes.memberAdd, adminBody);
    await s.attempt(owner, RecordTypes.memberAdd, {...adminBody, 'verified': 'not-base64'});
    await s.attempt(owner, RecordTypes.memberAdd, {...adminBody, 'verified': _strayBits(await compared(owner, admin))});
    await s.attempt(owner, RecordTypes.memberAdd, {...adminBody, 'verified': await compared(owner, mallory)});
    await s.attempt(owner, RecordTypes.memberAdd, {...adminBody, 'verified': await compared(alice, admin)});
    await s.attempt(owner, RecordTypes.memberAdd, {...adminBody, 'verified': await compared(owner, admin)});
    // Anyone else joins as before.
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(alice, _member));
    // Promoting: member to admin, admin to owner.
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(owner, bob)});
    await s.attempt(owner, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(owner, alice)});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': admin.uid, 'role': FixedRoles.owner});
    await s.attempt(owner, RecordTypes.memberSet,
        {'uid': admin.uid, 'role': FixedRoles.owner, 'verified': await compared(owner, admin)});
    // Lower roles need none; an owner stepping down needs none.
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': _member});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    // Alice replaces her keys: a comparison of the old ones no longer counts.
    final published = await alice2.keys.publish(alice2.uid);
    await s.attempt(alice2, RecordTypes.memberKeys,
        {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))});
    await s.attempt(admin, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(admin, alice)});
    await s.attempt(admin, RecordTypes.memberSet,
        {'uid': alice.uid, 'role': FixedRoles.admin, 'verified': await compared(admin, alice2)});
    scenarios.add(s);
  }

  // Team recovery: owners turn it on, with two of them; one owner
  // writes a member's recovery, carrying a second owner's approval of the
  // very same keys; a member verification is no approval.
  {
    final s = await team('team recovery');
    final alice2Keys = await alice2.keys.publish(alice.uid);
    final alice3Keys = await alice3.keys.publish(alice.uid);
    Future<Map<String, Object?>> recover(_Acct approver,
        {PublishedAccountKeys? keys, PublishedAccountKeys? approved, String? uid, int? approverVersion}) async {
      final subject = keys ?? alice2Keys;
      return {
        'uid': uid ?? alice.uid,
        'keys': recordKeysBody(subject),
        'approver': approver.uid,
        'approver_key_version': approverVersion ?? approver.keys.version,
        'approval': base64Encode(await signTeamRecovery(approver.keys,
            approverUid: approver.uid, orchardId: _orchard, subject: approved ?? subject)),
      };
    }

    // Off, nothing recovers.
    await s.attempt(owner, RecordTypes.memberRecover, await recover(admin));
    // Only owners turn it on, and only with two of them.
    await s.attempt(admin, RecordTypes.recoverySet, {'on': true});
    await s.attempt(owner, RecordTypes.recoverySet, {'on': true});
    await s.attempt(owner, RecordTypes.recoverySet, {'on': 'yes'});
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.recoverySet, {'on': true});
    // Who writes it, and who approves.
    await s.attempt(admin, RecordTypes.memberRecover, await recover(owner2));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(admin));
    await s.attempt(owner, RecordTypes.memberRecover,
        await recover(owner2, uid: owner.uid, keys: await (await _acct(owner.uid, 0x45, version: 2)).keys.publish(owner.uid)));
    await s.attempt(owner, RecordTypes.memberRecover,
        await recover(owner2, uid: owner2.uid, keys: await (await _acct(owner2.uid, 0x47, version: 2)).keys.publish(owner2.uid)));
    // The approval must be of these keys, with the approver's current keys.
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2, approved: alice3Keys));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2, approverVersion: 2));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2)..['approval'] = base64Encode(List<int>.filled(32, 1)));
    // A member verification, over the very same keys, is no approval.
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2)
      ..['approval'] = base64Encode(await signMemberVerification(owner2.keys,
          verifierUid: owner2.uid, orchardId: _orchard, subject: alice2Keys)));
    // A later version, of someone still in the Orchard.
    await s.attempt(owner, RecordTypes.memberRecover,
        await recover(owner2, keys: await (await _acct(alice.uid, 0x49)).keys.publish(alice.uid)));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2, uid: 'uid-nobody'));
    // Two owners: done, and alice's keys moved on (one version further than
    // the next: she lost the keys she started over with too).
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2, keys: alice3Keys));
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2));
    // Turned off again, by either owner; then nothing recovers.
    await s.attempt(owner2, RecordTypes.recoverySet, {'on': false});
    await s.attempt(owner, RecordTypes.memberRecover, await recover(owner2, keys: alice3Keys));
    scenarios.add(s);
  }

  // Certificate authorities: an owner sets one up for a Crate, its
  // private key kept in another Crate only owners open; its settings change
  // with the same key, its key is replaced one generation at a time and
  // never with one used before; turned off. The key's Crate stays
  // owners-only, and a role that is dropped signs in as nobody.
  {
    final s = await team('certificate authorities');
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    final key1 = base64Encode(List<int>.filled(32, 0x51));
    final key2 = base64Encode(List<int>.filled(32, 0x52));
    Map<String, Object?> ca(String key,
            {String crate = _crateA,
            String keyCrate = _crateSecret,
            int generation = 1,
            int ttl = 1440,
            Map<String, Object?>? principals}) =>
        {
          'crate': crate,
          'on': true,
          'generation': generation,
          'public_key': key,
          'ttl_minutes': ttl,
          'key_crate': keyCrate,
          'principals': principals ?? {FixedRoles.owner: ['root'], _member: ['deploy']},
        };
    // Owners only; the key in another Crate that only owners open.
    await s.attempt(admin, RecordTypes.caSet, ca(key1));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, crate: _crateMine));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, keyCrate: _crateB));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, crate: _crateSecret, keyCrate: _crateSecret));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, keyCrate: _crateMine));
    // Its settings, spelled exactly.
    await s.attempt(owner, RecordTypes.caSet, ca(base64Encode(List<int>.filled(31, 0x51))));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, ttl: 30));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {'no-such-role': ['deploy']}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {FixedRoles.owner: ['Root']}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {FixedRoles.owner: ['root', 'deploy']}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {FixedRoles.owner: <String>[]}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, principals: {FixedRoles.owner: ['a' * 33]}));
    // Set up: generation 1 first, and nothing to turn off before.
    await s.attempt(owner, RecordTypes.caSet, ca(key1, generation: 2));
    await s.attempt(owner, RecordTypes.caSet, {'crate': _crateA, 'on': false});
    await s.attempt(owner, RecordTypes.caSet, ca(key1));
    // Settings change with the same key; a new key is a new generation.
    await s.attempt(owner, RecordTypes.caSet, ca(key2));
    await s.attempt(owner, RecordTypes.caSet,
        ca(key1, ttl: 60, principals: {FixedRoles.admin: ['ops'], _lead: ['deploy', 'ops']}));
    await s.attempt(owner, RecordTypes.caSet, ca(key1, generation: 2));
    await s.attempt(owner, RecordTypes.caSet, ca(key2, generation: 3));
    await s.attempt(owner, RecordTypes.caSet, ca(key2, generation: 2, principals: {_lead: ['deploy']}));
    // The key's Crate stays owners-only.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateSecret, 'owners_only': false});
    // A dropped role signs in as nobody.
    await s.attempt(owner, RecordTypes.roleDrop, {'id': _lead, 'move_to': _member});
    // Off, and off again.
    await s.attempt(owner, RecordTypes.caSet, {'crate': _crateA, 'on': false});
    await s.attempt(owner, RecordTypes.caSet, {'crate': _crateA, 'on': false});
    scenarios.add(s);
  }

  // What the team records: owners only, all four switches spelled
  // exactly and nothing else; on, then some of it off again.
  {
    final s = await team('what the team records');
    Map<String, Object?> tracking({bool history = false, bool activity = false, bool devices = false, bool ips = false}) =>
        {'history': history, 'activity': activity, 'devices': devices, 'ips': ips};
    await s.attempt(admin, RecordTypes.trackingSet, tracking(history: true));
    await s.attempt(lead, RecordTypes.trackingSet, tracking(history: true));
    await s.attempt(owner, RecordTypes.trackingSet, tracking(history: true)..remove('ips'));
    await s.attempt(owner, RecordTypes.trackingSet, tracking(history: true)..['activity'] = 'no');
    await s.attempt(owner, RecordTypes.trackingSet, tracking(history: true)..['screens'] = true);
    await s.attempt(owner, RecordTypes.trackingSet, tracking(history: true, activity: true));
    await s.attempt(owner, RecordTypes.trackingSet, tracking(history: true, devices: true, ips: true));
    // An owner who was not one when it was set may change it; an admin still may not.
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner2, RecordTypes.trackingSet, tracking(ips: true));
    await s.attempt(admin, RecordTypes.trackingSet, tracking());
    // It stays as set while other entries follow.
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    scenarios.add(s);
  }

  // Everything off again: the summary is as if it had never been set.
  {
    final s = await team('nothing recorded again');
    await s.attempt(owner, RecordTypes.trackingSet,
        {'history': true, 'activity': true, 'devices': true, 'ips': true});
    await s.attempt(owner, RecordTypes.trackingSet,
        {'history': false, 'activity': false, 'devices': false, 'ips': false});
    scenarios.add(s);
  }

  // Session logs: a Crate setting only owners change, a flag like any
  // other, and one of several settings at once.
  {
    final s = await team('session logs');
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'session_logs': true});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'session_logs': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'session_logs': 'on'});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateMine, 'session_logs': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'session_logs': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'session_logs': true, 'confirm_reveal': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'session_logs': false});
    // A manager changes what the Crate allows; session logs stay as they are.
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'allow': ['sftp']});
    scenarios.add(s);
  }

  // Watched sessions: a Crate setting only owners change, a flag like
  // any other; while it is on the Crate allows the terminal only, whoever
  // changes what and in which entry.
  {
    final s = await team('watched sessions');
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'watched': true, 'allow': <String>[]});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'watched': true, 'allow': <String>[]});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': 'on', 'allow': <String>[]});
    // (What the flag is comes before who may set it, as for every flag.)
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'watched': 'on'});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateMine, 'watched': true, 'allow': <String>[]});
    // Not while the Crate allows anything but the terminal.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': true, 'allow': ['sftp']});
    // Off, it changes nothing, whatever the Crate allows.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': false});
    // On, with nothing else allowed, in one entry; and with other settings.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': true, 'allow': <String>[]});
    // (Each flag is its own: one on and another off in the same entry.)
    await s.attempt(owner, RecordTypes.crateSet,
        {'id': _crateB, 'watched': true, 'allow': <String>[], 'session_logs': false, 'confirm_reveal': true});
    // A manager cannot allow more again while it is watched, nor can an
    // owner; other settings still change, and saying the same again is fine.
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'allow': ['sftp']});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': ['agent', 'forward', 'sftp']});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'allow': <String>[]});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'confirm_reveal': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': true});
    // Off again and more allowed, in one entry or in two; a manager who is
    // no owner cannot turn it off by allowing more.
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'watched': false, 'allow': ['sftp']});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': false, 'allow': ['forward', 'sftp']});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'watched': false, 'session_logs': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'allow': ['sftp']});
    // A Crate added later is not watched.
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    scenarios.add(s);
  }

  // A Crate's offline limit of its own (3.0): how many
  // hours a device may stay away from ZestSSH Cloud before the Crate closes
  // on it. Only owners set it, from none to a year; it is a setting like any
  // other, kept when something else changes, and a Crate added later has
  // none.
  {
    final s = await team("a Crate's offline limit");
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 24});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 24});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': '24'});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 8761});
    // Someone who is no owner, with a number no owner could set either.
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 99999});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 24});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'offline_hours': 8760, 'confirm_reveal': true});
    // Changed, with something else in the same entry.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'offline_hours': 72, 'allow': ['sftp']});
    // A manager changes what the Crate allows: its limit stays as it is.
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'allow': <String>[]});
    // Taken off again.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'offline_hours': 0});
    // A Crate added later has none.
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    scenarios.add(s);
  }

  // Watched Crates while ZestSSH Cloud cannot be reached (3.0).
  // Nobody can be asked to watch then: a Crate's setting says whether
  // members, and not only owners, may connect without a watcher; and
  // whoever did reports it in an entry of its own, which any active member
  // may write and which changes nothing.
  {
    final s = await team('sessions without a watcher');
    String sealed(int bytes) => base64Encode(List<int>.filled(bytes, 9));
    Map<String, Object?> report(Object? crate, [Map<String, Object?> more = const {}]) =>
        {'crate': crate, 'at': 1791504000, 'gen': 1, 'sealed': sealed(120), ...more};
    const told = RecordTypes.sessionUnwatched;
    // Who else may: the owners say, with a yes or a no.
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': true});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': true});
    await s.attempt(alice, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': false});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': 'true'});
    await s.attempt(admin, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': 1});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'unwatched_away': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'unwatched_away': true, 'confirm_reveal': true});
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'unwatched_away': false});
    // Watched, with it; a manager's change of something else leaves it.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'watched': true, 'allow': <String>[]});
    await s.attempt(lead, RecordTypes.crateSet, {'id': _crateA, 'confirm_reveal': true});
    // Reported by whoever connected: a member, for a Crate they open and for
    // one they do not; an owner; the least and the most there is.
    await s.attempt(alice, told, report(_crateA));
    await s.attempt(alice, told, report(_crateB));
    await s.attempt(owner, told, report(_crateA, {'at': 1, 'sealed': sealed(1)}));
    await s.attempt(lead, told, report(_crateA, {'at': 0xffffffff, 'sealed': sealed(kMaxUnwatchedSealed)}));
    // Sealed with a key that was replaced, and with the one after it.
    await s.attempt(lead, RecordTypes.keyRotate, _rotate(2, crate: _crateA));
    await s.attempt(alice, told, report(_crateA, {'gen': 1}));
    await s.attempt(alice, told, report(_crateA, {'gen': 2}));
    // Each thing that makes it none.
    await s.attempt(alice, told, report(_crateA, {'gen': 3}));
    await s.attempt(alice, told, report(_crateA, {'gen': 0}));
    await s.attempt(alice, told, report(_crateA, {'gen': '1'}));
    await s.attempt(alice, told, {...report(_crateA)}..remove('gen'));
    await s.attempt(alice, told, report(_crateA, {'at': 0}));
    await s.attempt(alice, told, report(_crateA, {'at': 0x100000000}));
    await s.attempt(alice, told, report(_crateA, {'at': '1791504000'}));
    await s.attempt(alice, told, {...report(_crateA)}..remove('at'));
    await s.attempt(alice, told, report(_crateMine));
    await s.attempt(alice, told, report('not an id!'));
    await s.attempt(alice, told, {...report(_crateA)}..remove('crate'));
    await s.attempt(alice, told, report(_crateA, {'host': 'web-01'}));
    await s.attempt(alice, told, report(_crateA, {'sealed': ''}));
    await s.attempt(alice, told, report(_crateA, {'sealed': sealed(kMaxUnwatchedSealed + 1)}));
    await s.attempt(alice, told, report(_crateA, {'sealed': 'AB=='}));
    await s.attempt(alice, told, report(_crateA, {'sealed': 'AA'}));
    await s.attempt(alice, told, report(_crateA, {'sealed': 'AAA*'}));
    // (What the app's decoder would read and base64 does not write.)
    await s.attempt(alice, told, report(_crateA, {'sealed': 'AA-_'}));
    await s.attempt(alice, told, report(_crateA, {'sealed': 'AA%3D%3D'}));
    await s.attempt(alice, told, report(_crateA, {'sealed': 7}));
    await s.attempt(alice, told, {...report(_crateA)}..remove('sealed'));
    // Several things wrong: what is said is the first of them in this order.
    await s.attempt(alice, told, report(_crateMine, {'host': 'web-01'}));
    await s.attempt(alice, told, report(_crateMine, {'at': 0}));
    await s.attempt(alice, told, report(_crateA, {'at': 0, 'gen': 0}));
    await s.attempt(alice, told, report(_crateA, {'gen': 0, 'sealed': ''}));
    // Someone who is not in the Orchard, and someone suspended, and back.
    await s.attempt(mallory, told, report(_crateA));
    await s.attempt(owner, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(alice, told, report(_crateA));
    await s.attempt(owner, RecordTypes.memberResume, {'uid': alice.uid});
    await s.attempt(alice, told, report(_crateA));
    scenarios.add(s);
  }

  // Access until a set time: a Crate, or more in one, given to a member
  // by someone who manages it for good and ranks above them; never manage,
  // never to oneself, to an owner or admin, nor an owners-only Crate; a new
  // one takes the place of the old; ended early by a manager or by the
  // member. The record has no clock: what holds at a moment is in 'at'.
  const soon = 1893456000;
  const later = soon + 3600;
  Map<String, Object?> give(String uid, String crate,
          {CrateLevel level = CrateLevel.use, List<Object?>? switches, Object? until = soon, Object? req}) =>
      {
        'uid': uid,
        'crate': crate,
        'switches': switches ?? switchList(levelSwitches(level)..remove(CrateSwitches.manage)),
        'until': ?until,
        'req': ?req,
      };
  Map<String, Object?> takeBack(String uid, String crate) => {'uid': uid, 'crate': crate, 'until': 0};
  {
    final s = await team('access until a set time');
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, _lead));
    // Who gives: someone who manages the Crate, to someone ranked below.
    await s.attempt(alice, RecordTypes.accessGrant, give(bob.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(lead, RecordTypes.accessGrant, give(bob.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, give(mallory.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, give(lead.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, give(admin.uid, _crateA));
    await s.attempt(admin, RecordTypes.accessGrant, give(owner.uid, _crateB));
    await s.attempt(owner, RecordTypes.accessGrant, give('uid-nobody', _crateB));
    // Which Crate: one there is, that is not owners-only.
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateSecret));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateMine));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, 'bad id!'));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB)..['uid'] = 7);
    // What: switches spelled as everywhere, with connect, never manage.
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, switches: switchList(levelSwitches(CrateLevel.manage))));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, switches: ['reveal']));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, switches: ['sftp', 'connect']));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, switches: ['connect', 'fly']));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, switches: []));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB)..remove('switches'));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB)..['switches'] = 'connect');
    // Until when: seconds since the epoch that fit 32 bits.
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, until: kMaxAccessUntil + 1));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, until: 'tomorrow'));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, until: null));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, level: CrateLevel.connect, until: kMaxAccessUntil));
    // Nothing else in it; the request it answers, when it answers one.
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB)..['note'] = 'please');
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, req: 'bad id!'));
    await s.attempt(owner, RecordTypes.accessGrant, give(alice.uid, _crateB, req: 7));
    await s.attempt(owner, RecordTypes.accessGrant,
        give(alice.uid, _crateB, level: CrateLevel.edit, until: later, req: '88888888-8888-4888-8888-888888888888'));
    // Only what the giver has: agent forwarding is in no level.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': ['agent', 'forward', 'sftp']});
    await s.attempt(lead, RecordTypes.accessGrant, give(bob.uid, _crateA, switches: ['agent', 'connect'], until: later));
    await s.attempt(owner, RecordTypes.accessGrant, give(bob.uid, _crateA, switches: ['agent', 'connect'], until: later));
    // What the Crate does not allow is nobody's to have, and no obstacle.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateA, 'allow': <String>[]});
    await s.attempt(lead, RecordTypes.accessGrant, give(bob.uid, _crateA));
    // Ended early: by a manager of the Crate, or by the member.
    await s.attempt(alice, RecordTypes.accessGrant, takeBack(bob.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, takeBack(alice.uid, _crateB));
    await s.attempt(bob, RecordTypes.accessGrant, takeBack(bob.uid, _crateA)..['switches'] = ['connect']);
    await s.attempt(bob, RecordTypes.accessGrant, takeBack(bob.uid, _crateA));
    await s.attempt(bob, RecordTypes.accessGrant, takeBack(bob.uid, _crateA));
    await s.attempt(lead, RecordTypes.accessGrant, takeBack(mallory.uid, _crateA));
    await s.attempt(admin, RecordTypes.accessGrant, takeBack(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.accessGrant, takeBack(alice.uid, _crateSecret));
    // Given again; bob's time in the Orchard ends before what he was given.
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(lead, RecordTypes.accessGrant, give(bob.uid, _crateA, until: later));
    await s.attempt(owner, RecordTypes.memberSet, {'uid': bob.uid, 'ends_at': soon + 1800});
    // Suspended: given nothing, and ends nothing themselves; resumed, what
    // they were given is as it was.
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': bob.uid});
    await s.attempt(owner, RecordTypes.accessGrant, give(bob.uid, _crateB));
    await s.attempt(bob, RecordTypes.accessGrant, takeBack(bob.uid, _crateA));
    await s.attempt(admin, RecordTypes.memberResume, {'uid': bob.uid});
    // A manager still ends what a suspended member was given, so that it
    // does not come back with them.
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.accessGrant, takeBack(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.memberResume, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    scenarios.add(s);
  }

  // Made an admin or an owner, a member opens every Crate such a grant could
  // name: what they were given until a set time is done with, and does not
  // come back.
  {
    final s = await team('access until a set time: made an admin or an owner');
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest));
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.accessGrant, give(bob.uid, _crateB));
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': _member});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': bob.uid, 'role': FixedRoles.owner});
    scenarios.add(s);
  }

  // An entry its author did not sign gives nothing.
  {
    final s = await team('access until a set time: not signed by its author');
    await s.attempt(mallory, RecordTypes.accessGrant, give(alice.uid, _crateB), by: admin.uid);
    scenarios.add(s);
  }

  // Suspended, a member has nothing of what they were given, at any moment.
  {
    final s = await team('access until a set time: suspended');
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    scenarios.add(s);
  }

  // Removed, a member is given nothing and has nothing to end; added again,
  // they start with nothing given.
  {
    final s = await team('access until a set time: removed and added again');
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.accessGrant, give(alice.uid, _crateB));
    await s.attempt(admin, RecordTypes.accessGrant, takeBack(alice.uid, _crateB));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest));
    scenarios.add(s);
  }

  // A role's own switches and a grant for good count with what was given
  // until a set time: more in a Crate the member opens anyway.
  {
    final s = await team('access until a set time: more in a Crate');
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest, grants: {_crateB: CrateLevel.connect}));
    await s.attempt(lead, RecordTypes.accessGrant, give(bob.uid, _crateA, level: CrateLevel.edit));
    // Agent forwarding, in a Crate that allows it, on top of connecting for good.
    await s.attempt(owner, RecordTypes.crateSet, {'id': _crateB, 'allow': ['agent', 'forward', 'sftp']});
    await s.attempt(owner, RecordTypes.accessGrant,
        give(bob.uid, _crateB, switches: ['agent', 'connect', 'reveal'], until: later));
    // Less than they have anyway takes nothing away.
    await s.attempt(lead, RecordTypes.accessGrant, give(alice.uid, _crateA, level: CrateLevel.connect));
    // His time in the Orchard ends after both.
    await s.attempt(owner, RecordTypes.memberSet, {'uid': bob.uid, 'ends_at': later + 3600});
    // Forwarding, for someone whose role only connects.
    const watch = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await s.attempt(owner, RecordTypes.roleSet, _role(watch, 50, {})..['crates'] = {_crateA: ['connect']});
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(mallory, watch));
    await s.attempt(lead, RecordTypes.accessGrant, give(mallory.uid, _crateA, switches: ['connect', 'forward']));
    // A Crate with nothing but connecting and revealing, for someone who has
    // none of it for good.
    await s.attempt(admin, RecordTypes.accessGrant,
        give(alice.uid, _crateB, switches: ['connect', 'reveal'], until: later));
    scenarios.add(s);
  }

  // Trusted devices: each device has a key of its own, and the record
  // lists the ones approved for each member. An approval, and taking one
  // back, is made on a device of the author's that is approved already, and
  // signed by it over the entry it follows; only an owner's own first device
  // approves itself, and only while the rule is off. Who decides about whose
  // devices: the member, an owner for anyone, an admin for those below.
  final ownerD1 = await _device(0x61);
  final ownerD2 = await _device(0x62);
  final ownerD3 = await _device(0x63);
  final owner2D = await _device(0x64);
  final adminD = await _device(0x65);
  final leadD = await _device(0x66);
  final aliceD1 = await _device(0x67);
  final aliceD2 = await _device(0x68);
  final bobD = await _device(0x69);
  Future<Map<String, Object?>> device(_Scenario s, String type, String uid, _Device which, _Device via,
          {_Device? signer, List<int>? prev, String? signedType, String? signedUid, _Device? signedDevice}) async =>
      {
        'uid': uid,
        'device': which.key,
        'via': via.key,
        'sig': base64Encode(await (signer ?? via).sign(deviceEntryMessage(
          orchardId: _orchard,
          type: signedType ?? type,
          uid: signedUid ?? uid,
          device: (signedDevice ?? which).keyBytes,
          prev: prev ?? s.state.head,
        ))),
      };
  Future<Map<String, Object?>> trust(_Scenario s, String uid, _Device which, _Device via) =>
      device(s, RecordTypes.deviceTrust, uid, which, via);
  Future<Map<String, Object?>> revoke(_Scenario s, String uid, _Device which, _Device via) =>
      device(s, RecordTypes.deviceRevoke, uid, which, via);
  Map<String, Object?> rules({Object? trustedDevices}) => {
        'email_domains': <String>[],
        'max_lock_minutes': 0,
        'no_export': false,
        'offline_hours': 0,
        'reauth_days': 0,
        'require_2fa': false,
        'require_app_lock': false,
        'trusted_devices': ?trustedDevices,
      };
  {
    final s = await team('trusted devices');
    const t = RecordTypes.deviceTrust;
    const x = RecordTypes.deviceRevoke;
    await s.attempt(lead, RecordTypes.memberAdd, await _memberBody(bob, _guest));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    // Before any device is approved: nobody but an owner approves their own
    // first one, an owner approves nobody else's before their own, and the
    // rule cannot be turned on.
    await s.attempt(alice, t, await trust(s, alice.uid, aliceD1, aliceD1));
    await s.attempt(admin, t, await trust(s, admin.uid, adminD, adminD));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    // Only an owner's OWN first device approves itself: not someone else's
    // device for itself, and not another device of the owner's for the first.
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, aliceD1));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD2));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    // The entry, spelled exactly: four fields, the keys 32 bytes, the
    // signature 64, a member who is there.
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..['name'] = 'laptop');
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..['device'] = base64Encode(List<int>.filled(31, 1)));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..['device'] = _strayBits(ownerD1.key));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..remove('via'));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..['sig'] = base64Encode(List<int>.filled(63, 1)));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..remove('sig'));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1)..['uid'] = 7);
    await s.attempt(owner, t, await trust(s, 'uid-nobody', ownerD1, ownerD1));
    // Signed by the device it names, over this very entry: not over another
    // place in the record, another kind of entry, another member or another
    // device, and not by another device.
    await s.attempt(owner, t, await device(s, t, owner.uid, ownerD1, ownerD1, prev: List<int>.filled(32, 9)));
    await s.attempt(owner, t, await device(s, t, owner.uid, ownerD1, ownerD1, signedType: x));
    await s.attempt(owner, t, await device(s, t, owner.uid, ownerD1, ownerD1, signedUid: admin.uid));
    await s.attempt(owner, t, await device(s, t, owner.uid, ownerD1, ownerD1, signedDevice: ownerD2));
    await s.attempt(owner, t, await device(s, t, owner.uid, ownerD1, ownerD1, signer: ownerD2));
    // An owner's first device approves itself; a second one does not, and
    // nothing is approved twice.
    final replayed = await trust(s, owner.uid, ownerD1, ownerD1);
    await s.attempt(owner, t, replayed);
    await s.attempt(owner, t, replayed);
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD2, ownerD2));
    // The rule needs two approved devices among the owners.
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD2, ownerD1));
    // Everyone else's first device is approved by someone above them, on an
    // approved device of that person's own.
    await s.attempt(owner, t, await trust(s, admin.uid, adminD, ownerD2));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(admin, t, await trust(s, lead.uid, leadD, adminD));
    await s.attempt(admin, t, await trust(s, owner.uid, ownerD3, adminD));
    await s.attempt(owner, RecordTypes.memberSet, {'uid': bob.uid, 'role': FixedRoles.admin});
    await s.attempt(admin, t, await trust(s, bob.uid, bobD, adminD));
    await s.attempt(lead, t, await trust(s, alice.uid, aliceD2, leadD));
    await s.attempt(alice, t, await trust(s, bob.uid, bobD, aliceD1));
    // One's own further devices: from one that is approved, not from the new
    // one, and not on someone else's.
    await s.attempt(alice, t, await trust(s, alice.uid, aliceD2, aliceD2));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, aliceD1));
    await s.attempt(alice, t, await trust(s, alice.uid, aliceD2, ownerD1));
    await s.attempt(alice, t, await trust(s, alice.uid, aliceD2, aliceD1));
    // The rule: owners only, spelled as a flag, and from an owner who has a
    // device.
    await s.attempt(admin, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: 'yes'));
    await s.attempt(owner2, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    // On, an owner without a device is approved by another owner like anyone.
    await s.attempt(owner2, t, await trust(s, owner2.uid, owner2D, owner2D));
    await s.attempt(owner, t, await trust(s, owner2.uid, owner2D, ownerD1));
    // Taking an approval back: the device itself, another of one's own that
    // is approved, or someone above; never from a device that is not
    // approved, and only what is approved.
    await s.attempt(alice, x, await revoke(s, alice.uid, aliceD2, aliceD2));
    await s.attempt(alice, x, await revoke(s, alice.uid, aliceD2, aliceD1));
    await s.attempt(alice, x, await revoke(s, alice.uid, aliceD1, aliceD2));
    await s.attempt(lead, x, await revoke(s, alice.uid, aliceD1, leadD));
    await s.attempt(admin, x, await revoke(s, owner.uid, ownerD2, adminD));
    await s.attempt(admin, x, await device(s, x, alice.uid, aliceD1, adminD, prev: List<int>.filled(32, 9)));
    await s.attempt(admin, x, await device(s, x, alice.uid, aliceD1, adminD, signedType: t));
    await s.attempt(admin, x, await revoke(s, alice.uid, aliceD1, adminD)..['why'] = 'lost');
    await s.attempt(admin, x, await revoke(s, 'uid-nobody', aliceD1, adminD));
    await s.attempt(admin, x, await revoke(s, alice.uid, aliceD1, adminD));
    // Suspended, a member decides nothing; those above still do, so that
    // what comes back with them is what the team left.
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(alice, x, await revoke(s, alice.uid, aliceD1, aliceD1));
    await s.attempt(owner, x, await revoke(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, ownerD1));
    await s.attempt(admin, RecordTypes.memberResume, {'uid': alice.uid});
    // While the rule is on the owners keep an approved device: the last one
    // is not removed, and its owner neither steps down nor leaves.
    await s.attempt(owner, x, await revoke(s, owner.uid, ownerD2, ownerD1));
    await s.attempt(owner2, x, await revoke(s, owner2.uid, owner2D, owner2D));
    // One device left among the owners. Another rule changed while this one
    // stays on is not turning it on: by the owner with the device, and by
    // the one without (whom the server holds back, not the record).
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true)..['no_export'] = true);
    await s.attempt(owner2, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(owner, x, await revoke(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberRemove, {'uid': owner.uid});
    await s.attempt(owner2, RecordTypes.memberSuspend, {'uid': owner.uid});
    // Off, it is; and turning it on again takes two devices again.
    await s.attempt(owner, RecordTypes.rulesSet, rules());
    await s.attempt(owner, x, await revoke(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: false));
    scenarios.add(s);
  }

  // Removed, a member's devices are gone with them; added again, they start
  // with none. Twenty devices at most.
  {
    final s = await team('trusted devices: removed, added again, and how many');
    const t = RecordTypes.deviceTrust;
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, ownerD1));
    await s.attempt(owner, RecordTypes.deviceRevoke, await revoke(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(alice, _guest));
    await s.attempt(alice, t, await trust(s, alice.uid, aliceD2, aliceD1));
    for (var i = 0; i < kMaxMemberDevices; i++) {
      await s.attempt(owner, t, await trust(s, alice.uid, await _device(0x80 + i), ownerD1));
    }
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, ownerD1));
    // Someone who stays removed holds no device either.
    await s.attempt(owner, t, await trust(s, lead.uid, leadD, ownerD1));
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': lead.uid});
    scenarios.add(s);
  }

  // Only the owners' devices count for the rule, and only an active member
  // is made an owner: nobody ranks above an owner, so nobody could resume
  // one who was suspended.
  {
    final s = await team('trusted devices: whose devices count for the rule');
    const t = RecordTypes.deviceTrust;
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, t, await trust(s, admin.uid, adminD, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, ownerD1));
    // Four devices, one of them an owner's.
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(admin, RecordTypes.memberSuspend, {'uid': alice.uid});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.owner});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberResume, {'uid': alice.uid});
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    // An owner now, her two devices count; and when she leaves they do not.
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': FixedRoles.owner});
    await s.attempt(alice, RecordTypes.rulesSet, rules(trustedDevices: true));
    await s.attempt(alice, RecordTypes.rulesSet, rules());
    await s.attempt(alice, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    scenarios.add(s);
  }

  // Recovered under new keys, a member starts with no device approved;
  // and with the rule on, a recovery that would leave the owners without one
  // is refused.
  {
    final s = await team('trusted devices: recovered under new keys');
    const t = RecordTypes.deviceTrust;
    final owner3 = await _acct('uid-owner3', 0x4b);
    final ownerNew = await _acct(owner.uid, 0x4d, version: 2);
    Future<Map<String, Object?>> recover(_Acct approver, String uid, PublishedAccountKeys keys) async => {
          'uid': uid,
          'keys': recordKeysBody(keys),
          'approver': approver.uid,
          'approver_key_version': approver.keys.version,
          'approval': base64Encode(
              await signTeamRecovery(approver.keys, approverUid: approver.uid, orchardId: _orchard, subject: keys)),
        };
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner3, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.recoverySet, {'on': true});
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner, t, await trust(s, owner.uid, ownerD2, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD1, ownerD1));
    await s.attempt(owner, t, await trust(s, alice.uid, aliceD2, ownerD1));
    await s.attempt(owner, RecordTypes.rulesSet, rules(trustedDevices: true));
    // Alice, recovered: her devices are approved anew.
    await s.attempt(owner2, RecordTypes.memberRecover, await recover(owner3, alice.uid, await alice2.keys.publish(alice.uid)));
    await s.attempt(alice2, t, await trust(s, alice.uid, aliceD2, aliceD1));
    // The only owner with a device: not while nobody else could manage.
    final ownerKeys = await ownerNew.keys.publish(owner.uid);
    await s.attempt(owner2, RecordTypes.memberRecover, await recover(owner3, owner.uid, ownerKeys));
    await s.attempt(owner, t, await trust(s, owner2.uid, owner2D, ownerD2));
    await s.attempt(owner2, RecordTypes.memberRecover, await recover(owner3, owner.uid, ownerKeys));
    await s.attempt(ownerNew, t, await trust(s, owner.uid, ownerD1, ownerD1));
    await s.attempt(owner2, t, await trust(s, owner.uid, ownerD1, owner2D));
    scenarios.add(s);
  }

  // Event export: owners only; on, with a key of 32 bytes spelled the
  // one way, or off, and nothing else in the entry; on only while the team
  // records activity. It is whoever set it up last whose device sends.
  final exportKey = base64Encode(List<int>.filled(32, 0x61));
  // (One whose base64 has a plus and a slash in it.)
  final exportKey2 = base64Encode(List<int>.filled(32, 0xfb));
  Map<String, Object?> exportOn(String key) => {'on': true, 'key': key};
  const exportOff = <String, Object?>{'on': false};
  const activityOn = <String, Object?>{'history': false, 'activity': true, 'devices': false, 'ips': false};
  const activityOff = <String, Object?>{'history': true, 'activity': false, 'devices': true, 'ips': true};
  {
    final s = await team('event export');
    const t = RecordTypes.exportSet;
    // Not while nothing is recorded, nor while only something else is.
    await s.attempt(owner, t, exportOn(exportKey));
    await s.attempt(owner, RecordTypes.trackingSet, activityOff);
    await s.attempt(owner, t, exportOn(exportKey));
    // Off while it is off changes nothing, and is taken.
    await s.attempt(owner, t, exportOff);
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    // Owners only, on and off.
    await s.attempt(admin, t, exportOn(exportKey));
    await s.attempt(lead, t, exportOn(exportKey));
    await s.attempt(admin, t, exportOff);
    // Spelled exactly.
    await s.attempt(owner, t, {'key': exportKey});
    await s.attempt(owner, t, {'on': 'yes', 'key': exportKey});
    await s.attempt(owner, t, {'on': 1, 'key': exportKey});
    await s.attempt(owner, t, {'on': true});
    await s.attempt(owner, t, {'on': true, 'key': 7});
    await s.attempt(owner, t, {'on': true, 'key': base64Encode(List<int>.filled(31, 0x61))});
    await s.attempt(owner, t, {'on': true, 'key': base64Encode(List<int>.filled(33, 0x61))});
    await s.attempt(owner, t, {'on': true, 'key': _strayBits(exportKey)});
    await s.attempt(owner, t, {'on': true, 'key': exportKey.replaceAll('=', '')});
    await s.attempt(owner, t, {'on': true, 'key': exportKey.replaceAll('Y', '-')});
    await s.attempt(owner, t, {...exportOn(exportKey), 'url': 'https://logs.example.com/in'});
    await s.attempt(owner, t, {'on': false, 'key': exportKey});
    await s.attempt(owner, t, {'on': false, 'by': owner.uid});
    // What is asked first: who writes it, then each field, then that there
    // is nothing else, then what it rests on.
    await s.attempt(admin, t, {'on': 'yes'});
    await s.attempt(owner, t, {'on': true, 'key': 'short', 'url': 'https://logs.example.com/in'});
    await s.attempt(owner, RecordTypes.trackingSet, activityOff);
    await s.attempt(owner, t, {...exportOn(exportKey), 'url': 'https://logs.example.com/in'});
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    // On. Another owner sets it up on a device of theirs: their key, and
    // theirs to send.
    await s.attempt(owner, t, exportOn(exportKey));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner2, t, exportOn(exportKey2));
    // The same again changes nothing, and is taken.
    await s.attempt(owner2, t, exportOn(exportKey2));
    // It stays as set while other entries follow: another Crate, something
    // else recorded as well, someone else stepping down.
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    await s.attempt(owner, RecordTypes.trackingSet, {...activityOn, 'history': true, 'ips': true});
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner.uid, 'role': FixedRoles.admin});
    scenarios.add(s);
  }

  // Turned off by an owner, whoever turned it on.
  {
    final s = await team('event export: turned off');
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner, RecordTypes.exportSet, exportOn(exportKey));
    await s.attempt(owner2, RecordTypes.exportSet, exportOff);
    scenarios.add(s);
  }

  // It ends when activity is no longer recorded, and does not come back
  // when that is recorded again.
  {
    final s = await team('event export: activity no longer recorded');
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner, RecordTypes.exportSet, exportOn(exportKey));
    await s.attempt(owner, RecordTypes.trackingSet, activityOff);
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    scenarios.add(s);
  }

  // It ends when the owner who set it up steps down (their device sent),
  // and stays ended should they be made an owner again.
  {
    final s = await team('event export: the owner who set it up steps down');
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner2, RecordTypes.exportSet, exportOn(exportKey));
    await s.attempt(owner2, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.admin});
    await s.attempt(owner, RecordTypes.memberSet, {'uid': owner2.uid, 'role': FixedRoles.owner});
    scenarios.add(s);
  }

  // And when they leave.
  {
    final s = await team('event export: the owner who set it up leaves');
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner2, RecordTypes.exportSet, exportOn(exportKey));
    await s.attempt(owner2, RecordTypes.memberRemove, {'uid': owner2.uid});
    scenarios.add(s);
  }

  // Recovered under new keys, they are the same owner: it stays on.
  {
    final s = await team('event export: the owner who set it up recovered under new keys');
    final owner3 = await _acct('uid-owner3', 0x4b);
    final ownerNew = await _acct(owner.uid, 0x4d, version: 2);
    final keys = await ownerNew.keys.publish(owner.uid);
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner2, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(owner3, FixedRoles.owner));
    await s.attempt(owner, RecordTypes.recoverySet, {'on': true});
    await s.attempt(owner, RecordTypes.trackingSet, activityOn);
    await s.attempt(owner, RecordTypes.exportSet, exportOn(exportKey));
    await s.attempt(owner2, RecordTypes.memberRecover, {
      'uid': owner.uid,
      'keys': recordKeysBody(keys),
      'approver': owner3.uid,
      'approver_key_version': owner3.keys.version,
      'approval': base64Encode(
          await signTeamRecovery(owner3.keys, approverUid: owner3.uid, orchardId: _orchard, subject: keys)),
    });
    scenarios.add(s);
  }

  // The Admin role changed (3.3.0): owners only, in one of two shapes; an
  // admin may then do what the Admin role may and opens what it opens; a
  // Crate an admin makes, Admin manages; one an owner makes, Admin does not
  // open; and back to all of it.
  {
    final s = await team('the Admin role changed');
    List<String> level(CrateLevel l) => levelSwitches(l).toList()..sort();
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(admin, RecordTypes.adminSet, {'can': <String>[], 'crates': <String, Object?>{}});
    await s.attempt(lead, RecordTypes.adminSet, {'all': true});
    await s.attempt(owner, RecordTypes.adminSet, {'all': false});
    await s.attempt(owner, RecordTypes.adminSet, {'all': true, 'can': <String>[]});
    await s.attempt(owner, RecordTypes.adminSet, {'can': <String>[]});
    await s.attempt(owner, RecordTypes.adminSet, {'can': <String>[], 'crates': <String, Object?>{}, 'rank': 5});
    await s.attempt(owner, RecordTypes.adminSet, {'can': ['own_everything'], 'crates': <String, Object?>{}});
    await s.attempt(owner, RecordTypes.adminSet, {
      'can': <String>[],
      'crates': {_crateSecret: level(CrateLevel.use)},
    });
    await s.attempt(owner, RecordTypes.adminSet, {
      'can': <String>[],
      'crates': {_crateA: ['edit']},
    });
    await s.attempt(owner, RecordTypes.adminSet, {
      'can': [RoleCan.createCrates, RoleCan.invite],
      'crates': {_crateA: level(CrateLevel.manage)},
    });
    // May invite, within what Admin opens; may not remove.
    await s.attempt(admin, RecordTypes.memberAdd, await _memberBody(bob, _member));
    await s.attempt(admin, RecordTypes.memberRemove, {'uid': alice.uid});
    await s.attempt(admin, RecordTypes.crateAdd, _crate(_crateMine));
    await s.attempt(owner, RecordTypes.crateAdd, _crate('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
    scenarios.add(s);
  }

  // And put back to all of it: every Crate that is not owners-only again,
  // and nothing of the changed role left in the state.
  {
    final s = await team('the Admin role put back');
    await s.attempt(owner, RecordTypes.adminSet, {'can': <String>[], 'crates': <String, Object?>{}});
    await s.attempt(admin, RecordTypes.memberAdd, await _memberBody(bob, _member));
    await s.attempt(owner, RecordTypes.adminSet, {'all': true});
    await s.attempt(admin, RecordTypes.memberAdd, await _memberBody(bob, _member));
    scenarios.add(s);
  }

  // A member's access to one Crate held below their role: by
  // one who manages the Crate and ranks above, never about an owner, an
  // admin or oneself, never in an owners-only Crate; a lift is checked as
  // giving; No access takes the Crate away; a limit ends access until a set
  // time, which given after it adds on top; another role keeps it.
  {
    final s = await team('a member limited in a Crate');
    List<String> level(CrateLevel l) => levelSwitches(l).toList()..sort();
    Map<String, Object?> limit(String uid, [List<String>? switches]) =>
        {'uid': uid, 'crate': _crateA, 'switches': ?switches};
    // A role that manages Crate A without editing in it.
    await s.attempt(owner, RecordTypes.roleSet, {
      ..._role(_keeper, 450, {_crateA: CrateLevel.manage}),
      'crates': {_crateA: ['connect', 'manage']},
    });
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(bob, _keeper));
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateSecret, ownersOnly: true));
    await s.attempt(alice, RecordTypes.memberLimit, limit(alice.uid, level(CrateLevel.connect)));
    await s.attempt(lead, RecordTypes.memberLimit, limit(admin.uid, []));
    await s.attempt(admin, RecordTypes.memberLimit, limit(owner.uid, []));
    await s.attempt(alice, RecordTypes.memberLimit, limit(bob.uid, []));
    await s.attempt(owner, RecordTypes.memberLimit, {'uid': alice.uid, 'crate': _crateSecret, 'switches': <String>[]});
    await s.attempt(owner, RecordTypes.memberLimit, limit(alice.uid, ['sftp']));
    await s.attempt(owner, RecordTypes.memberLimit, {...limit(alice.uid, ['connect']), 'why': 'x'});
    await s.attempt(owner, RecordTypes.memberLimit, limit(alice.uid));
    // Held to Connect by one who manages the Crate, again (nothing to change),
    // then No access.
    await s.attempt(bob, RecordTypes.memberLimit, limit(alice.uid, level(CrateLevel.connect)));
    await s.attempt(bob, RecordTypes.memberLimit, limit(alice.uid, level(CrateLevel.connect)));
    await s.attempt(bob, RecordTypes.memberLimit, limit(alice.uid, []));
    // Back to her role: more than the writer has, then by the lead.
    await s.attempt(bob, RecordTypes.memberLimit, limit(alice.uid));
    await s.attempt(lead, RecordTypes.memberLimit, limit(alice.uid));
    // Access until a set time, given after a limit, adds on top; a limit set
    // after it ends it.
    await s.attempt(owner, RecordTypes.memberLimit, limit(alice.uid, []));
    await s.attempt(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateA, 'until': 2000000000, 'switches': level(CrateLevel.use)});
    await s.attempt(owner, RecordTypes.memberLimit, limit(alice.uid, level(CrateLevel.connect)));
    // Another role keeps it.
    await s.attempt(owner, RecordTypes.memberSet, {'uid': alice.uid, 'role': _guest});
    scenarios.add(s);
  }

  // The team deleted by an owner: only owners ask it, owners
  // and admins undo it; meanwhile only what lets the team be seen, undone
  // and left is taken.
  {
    final s = await team('a team deleted, undone, and deleted again');
    List<String> level(CrateLevel l) => levelSwitches(l).toList()..sort();
    await s.attempt(owner, RecordTypes.accessGrant,
        {'uid': alice.uid, 'crate': _crateB, 'until': 2000000000, 'switches': level(CrateLevel.use)});
    await s.attempt(lead, RecordTypes.teamDelete, <String, Object?>{});
    await s.attempt(admin, RecordTypes.teamDelete, <String, Object?>{});
    await s.attempt(owner, RecordTypes.teamDelete, {'why': 'x'});
    await s.attempt(owner, RecordTypes.teamRestore, <String, Object?>{});
    await s.attempt(owner, RecordTypes.teamDelete, <String, Object?>{});
    // Held back: nothing else, an owner's own changes included.
    await s.attempt(owner, RecordTypes.teamDelete, <String, Object?>{});
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    await s.attempt(admin, RecordTypes.memberSet, {'uid': alice.uid, 'role': _lead});
    await s.attempt(owner, RecordTypes.accessGrant, {'uid': alice.uid, 'crate': _crateB, 'until': 0});
    await s.attempt(lead, RecordTypes.memberRemove, {'uid': alice.uid});
    // Taken: Alice ends early what she was given, and replaces her keys.
    await s.attempt(alice, RecordTypes.accessGrant, {'uid': alice.uid, 'crate': _crateB, 'until': 0});
    final published = await alice2.keys.publish(alice.uid);
    await s.attempt(alice2, RecordTypes.memberKeys,
        {...recordKeysBody(published), 'endorsement': base64Encode(await alice.keys.endorse(published))});
    // The undo: an owner's or an admin's, with nothing in it; once undone
    // there is nothing left to undo.
    await s.attempt(lead, RecordTypes.teamRestore, <String, Object?>{});
    await s.attempt(admin, RecordTypes.teamRestore, {'why': 'x'});
    await s.attempt(admin, RecordTypes.teamRestore, <String, Object?>{});
    await s.attempt(owner, RecordTypes.teamRestore, <String, Object?>{});
    await s.attempt(owner, RecordTypes.crateAdd, _crate(_crateMine));
    // Deleted again: the lead leaves meanwhile.
    await s.attempt(owner, RecordTypes.teamDelete, <String, Object?>{});
    await s.attempt(lead, RecordTypes.memberRemove, {'uid': lead.uid});
    scenarios.add(s);
  }

  // A record format this app cannot read.
  {
    final s = _Scenario('record formats');
    await s.attempt(owner, RecordTypes.create, {...await _createBody(owner), 'format': 3});
    await s.attempt(owner, RecordTypes.create, {...await _createBody(owner), 'format': 0});
    await s.attempt(owner, RecordTypes.create, {...await _createBody(owner), 'format': '2'});
    await s.attempt(owner, RecordTypes.create, {...await _createBody(owner), 'format': 1});
    // Format 1 (Orchards made before format 2): no comparison asked.
    await s.attempt(owner, RecordTypes.memberAdd, await _memberBody(admin, FixedRoles.admin));
    scenarios.add(s);
  }

  return {
    'version': 8,
    'orchard': _orchard,
    'scenarios': [for (final s in scenarios) s.toJson()],
  };
}

void main() {
  test('the corpus: every entry decided as recorded, every scenario ending in the recorded state', () async {
    final corpus = await buildCorpus();
    final text = '${const JsonEncoder.withIndent(' ').convert(corpus)}\n';
    final file = File(_corpusPath);
    if (Platform.environment['ZEST_WRITE_CORPUS'] == '1') {
      await file.writeAsString(text);
    }
    // (Git may check the file out with CRLF line ends.)
    expect((await file.readAsString()).replaceAll('\r\n', '\n'), text,
        reason: 'the rules changed: regenerate the corpus and copy it to the backend (see the header)');

    // And replaying the file decides the same way.
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    var steps = 0;
    var refused = 0;
    final reasons = <String>{};
    for (final s in decoded['scenarios'] as List) {
      final state = OrchardRecord(_orchard);
      for (final step in (s as Map<String, dynamic>)['steps'] as List) {
        final entry = RecordEntry.fromJson((step as Map<String, dynamic>)['entry'] as Map<String, dynamic>);
        String outcome;
        try {
          await state.append(entry);
          outcome = 'ok';
        } on RecordRejected catch (x) {
          outcome = 'rejected: ${x.reason}';
          refused++;
          reasons.add(x.reason);
        }
        expect(outcome, step['outcome'], reason: '${s['name']} step ${entry.seq}');
        steps++;
      }
      expect(canonicalJson(summarize(state)), canonicalJson(s['final']), reason: s['name'] as String);
    }
    expect(steps, greaterThan(700));
    expect(refused, greaterThan(280));
    // The spellings and commitments above are each refused for the field.
    expect(reasons, containsAll(<String>[
      'only owners set the rules',
      'malformed email_domains',
      'malformed require_sso',
      'malformed sso_two_step',
      'rule out of range',
      'a lock timeout needs the app lock',
      'malformed key_commit',
      'malformed ed25519_pub',
      'malformed x25519_pub',
      'malformed self_sig',
      'malformed endorsement',
      'only owners and admins replace the Orchard key',
      'replacing a Crate key needs manage',
      'not the next generation',
      'team recovery is off',
      'only owners set team recovery',
      'team recovery needs two owners',
      'malformed on',
      'only owners recover a member',
      'two different owners',
      'the second approval is not from an owner',
      'nobody recovers themselves',
      'the second owner did not approve these keys',
      'the second owner approves with their current keys',
      'malformed approval',
      'keys must be a later version',
      'only owners set a certificate authority',
      'the key is kept in another Crate only owners open',
      'malformed public_key',
      'malformed ttl_minutes',
      'malformed principals',
      'a new key is a new generation',
      'that key was used before',
      "that Crate keeps a certificate authority's key",
      'only owners set what the team records',
      'malformed ips',
      'malformed activity',
      'malformed tracking',
      'only owners set session logs',
      'malformed session_logs',
      // Watched sessions.
      'only owners set watched sessions',
      'malformed watched',
      'a watched Crate allows the terminal only',
      // Watched Crates while ZestSSH Cloud cannot be
      // reached.
      'malformed unwatched_away',
      'malformed session',
      'malformed at',
      'malformed gen',
      'malformed sealed',
      // Access until a set time.
      'giving a Crate needs manage on it',
      'only people below you',
      'nobody gives themselves access',
      'owners and admins need no extra Crate',
      'not a member',
      'not an active member',
      'no such Crate, or owners-only',
      'access until a set time never includes manage',
      'malformed switches',
      'malformed until',
      'malformed access',
      'malformed req',
      'hands out more than they have',
      'ending access to a Crate needs manage on it',
      'nothing to end',
      // Trusted devices.
      'malformed device',
      'malformed via',
      'malformed sig',
      'malformed trusted_devices',
      'only an owner, or an admin for those below',
      'not from an approved device',
      'bad device signature',
      'already approved',
      'too many devices',
      'not an approved device',
      'two approved devices among the owners first',
      'would leave no owner with an approved device',
      // Event export.
      'only owners set event export',
      'malformed key',
      'malformed export',
      'event export needs activity recorded',
    ]));
  });
}

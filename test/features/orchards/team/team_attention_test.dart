import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/members/member_actions.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_attention.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// What about an Orchard's people needs this account, on the Team page's
/// Overview (3.0).
const _now = 1790000000;
const _day = 86400;

OrchardSummary _orchard({String role = FixedRoles.owner, int waiting = 0, Set<String> can = const {RoleCan.invite}}) =>
    OrchardSummary(
      id: 'o1',
      name: 'Acme',
      role: role,
      crates: const [],
      defaultCrateId: null,
      can: can,
      invitesWaiting: waiting,
    );

MemberView _trust(
  String uid, {
  bool fingerprint = true,
  bool byMe = false,
  List<String> byOthers = const [],
  bool changed = false,
  bool deleted = false,
  bool replaced = false,
}) =>
    MemberView(
      uid: uid,
      role: 'r',
      isMe: false,
      fingerprint: fingerprint ? Uint8List(32) : null,
      verifiedByMe: byMe,
      verifiedBy: byOthers,
      pending: changed
          ? PublishedAccountKeys(
              uid: uid,
              version: 2,
              createdAt: 0,
              encryptionKey: Uint8List(32),
              signingKey: Uint8List(32),
              signature: Uint8List(64),
            )
          : null,
      accountDeleted: deleted,
      replacedSinceCompared: replaced,
    );

OrchardPerson _person(
  String uid, {
  bool isMe = false,
  MemberStatus status = MemberStatus.active,
  int? endsAt,
  MemberView? trust,
  bool canEndDate = true,
}) =>
    OrchardPerson(
      uid: uid,
      isMe: isMe,
      role: 'r',
      status: status,
      grants: const {},
      actions: MemberActions(endDate: canEndDate),
      email: '$uid@acme.dev',
      endsAt: endsAt,
      trust: trust,
    );

OrchardPeople _people(List<OrchardPerson> members) => OrchardPeople(
      me: 'me',
      record: OrchardRecord('o1'),
      members: members,
      roles: const [],
      stepDown: false,
      leave: true,
    );

void main() {
  List<(TeamAttentionKind, String?, int)> attention(OrchardSummary o, OrchardPeople? p) => [
        for (final a in teamAttention(orchard: o, people: p, nowSeconds: _now)) (a.kind, a.uid, a.count),
      ];

  test('without the member list only the invitations waiting show', () {
    expect(attention(_orchard(waiting: 2), null), [(TeamAttentionKind.invitesWaiting, null, 2)]);
    // Someone who may not invite is not asked to add anyone.
    expect(attention(_orchard(waiting: 2, can: const {}), null), isEmpty);
  });

  test('changed keys, deleted accounts, ends coming up and members nobody compared', () {
    final people = _people([
      _person('me', isMe: true, trust: _trust('me')),
      _person('jonah', trust: _trust('jonah', changed: true)),
      _person('gone', trust: _trust('gone', deleted: true)),
      _person('priya', endsAt: _now + 6 * _day, trust: _trust('priya', byMe: true)),
      _person('later', endsAt: _now + 30 * _day, trust: _trust('later', byOthers: ['maya'])),
      _person('ended', endsAt: _now - _day, trust: _trust('ended', byMe: true)),
      _person('sam', trust: _trust('sam')),
      _person('nokeys', trust: _trust('nokeys', fingerprint: false)),
      _person('paused', status: MemberStatus.suspended, trust: _trust('paused')),
    ]);
    expect(attention(_orchard(waiting: 1), people), [
      (TeamAttentionKind.keysChanged, 'jonah', 0),
      (TeamAttentionKind.invitesWaiting, null, 1),
      (TeamAttentionKind.accountDeleted, 'gone', 0),
      (TeamAttentionKind.accessEnding, 'priya', 0),
      // Sam only: Jonah is a hard stop, Priya and "later" were compared, no
      // keys yet is not a comparison to make, and suspended waits.
      (TeamAttentionKind.notVerified, null, 1),
    ]);
  });

  test('keys replaced since this account compared: for everyone, apart from those never compared', () {
    final people = _people([
      _person('me', isMe: true),
      _person('maya', trust: _trust('maya', replaced: true)),
      _person('sam', trust: _trust('sam')),
      // Someone else compared Maya's new keys already.
      _person('priya', trust: _trust('priya', replaced: true, byOthers: ['maya'])),
    ]);
    expect(attention(_orchard(), people), [
      (TeamAttentionKind.keysReplaced, null, 1),
      (TeamAttentionKind.notVerified, null, 1),
    ]);
    expect(attention(_orchard(role: 'on-call'), people), [(TeamAttentionKind.keysReplaced, null, 1)]);
  });

  test('a certificate authority needing a new key: owners are told, right after changed keys', () {
    CrateAuthorityView authority(String crate, {required bool due}) => CrateAuthorityView(
          crateId: crate,
          on: true,
          generation: 1,
          ttlMinutes: 1440,
          principals: const {},
          keyCrate: 'vault',
          publicKeys: {1: Uint8List(32)},
          newKeyNeeded: due,
        );
    final authorities = {'prod': authority('prod', due: true), 'stage': authority('stage', due: false)};
    final people = _people([_person('me', isMe: true), _person('jonah', trust: _trust('jonah', changed: true))]);
    List<(TeamAttentionKind, String?)> of(OrchardSummary o) => [
          for (final a in teamAttention(orchard: o, people: people, nowSeconds: _now, authorities: authorities))
            (a.kind, a.crateId ?? a.uid),
        ];
    expect(of(_orchard()), [
      (TeamAttentionKind.keysChanged, 'jonah'),
      (TeamAttentionKind.authorityNewKey, 'prod'),
    ]);
    expect(of(_orchard(role: FixedRoles.admin)), [(TeamAttentionKind.keysChanged, 'jonah')], reason: 'owners hold it');
  });

  test('members, not owners or admins, are not asked to compare everyone', () {
    final people = _people([_person('me', isMe: true), _person('sam', trust: _trust('sam'))]);
    expect(attention(_orchard(role: FixedRoles.admin), people), [(TeamAttentionKind.notVerified, null, 1)]);
    expect(attention(_orchard(role: 'on-call'), people), isEmpty);
  });

  test('an end date shows only to someone who may change it, and not for this account', () {
    final soon = _now + 3 * _day;
    final people = _people([
      _person('me', isMe: true, endsAt: soon),
      _person('priya', endsAt: soon, canEndDate: false, trust: _trust('priya', byMe: true)),
    ]);
    expect(attention(_orchard(), people), isEmpty);
  });
}

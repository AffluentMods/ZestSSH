import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The Team page words each entry of an Orchard's record against the record
/// as it stood just before it (3.0).
const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';

RecordEntry _entry(String type, Map<String, Object?> body, {String by = 'owner', int seq = 7, int version = 1}) =>
    RecordEntry(
      seq: seq,
      prev: Uint8List(0),
      type: type,
      bodyJson: jsonEncode(body),
      by: by,
      byKeyVersion: version,
      signature: Uint8List(0),
    );

RecordKeys _keys() => RecordKeys(
      version: 1,
      signingKey: Uint8List(32),
      encryptionKey: Uint8List(32),
      createdAt: 0,
      selfSignature: Uint8List(64),
    );

void main() {
  late OrchardRecord before;

  setUp(() {
    before = OrchardRecord(_orchard);
    before.roles['on-call'] = RecordRole(
      id: 'on-call',
      rank: 10,
      nameEnc: '',
      nameGeneration: 1,
      can: {},
      crates: {},
    );
    before.members['owner'] = RecordMember(uid: 'owner', role: FixedRoles.owner, keys: {1: _keys()}, since: 1);
    before.members['sam'] = RecordMember(uid: 'sam', role: 'on-call', keys: {1: _keys()}, since: 2);
    before.members['kai'] =
        RecordMember(uid: 'kai', role: 'on-call', keys: {1: _keys()}, since: 3, status: MemberStatus.removed);
  });

  TeamChange describe(String type, Map<String, Object?> body, {String by = 'owner'}) =>
      describeRecordEntry(_entry(type, body, by: by), before);

  test('each kind of entry, with who and what it is about', () {
    expect(describe(RecordTypes.create, {}).kind, TeamChangeKind.created);

    final crate = describe(RecordTypes.crateAdd, {'id': 'prod'});
    expect((crate.kind, crate.crateId), (TeamChangeKind.crateAdded, 'prod'));
    expect(describe(RecordTypes.crateSet, {'id': 'prod'}).kind, TeamChangeKind.crateSettings);

    // A role the record had is changed; one it did not is added.
    expect(describe(RecordTypes.roleSet, {'id': 'on-call'}).kind, TeamChangeKind.roleChanged);
    final added = describe(RecordTypes.roleSet, {'id': 'guest'});
    expect((added.kind, added.roleId), (TeamChangeKind.roleAdded, 'guest'));
    expect(describe(RecordTypes.roleDrop, {'id': 'on-call', 'move_to': 'x'}).kind, TeamChangeKind.roleDeleted);

    final join = describe(RecordTypes.memberAdd, {'uid': 'devon', 'role': 'on-call'});
    expect((join.kind, join.member, join.roleId), (TeamChangeKind.memberAdded, 'devon', 'on-call'));
    // Someone removed before and added again.
    expect(describe(RecordTypes.memberAdd, {'uid': 'kai', 'role': 'on-call'}).kind, TeamChangeKind.memberAddedAgain);

    final promoted = describe(RecordTypes.memberSet, {'uid': 'sam', 'role': FixedRoles.admin});
    expect((promoted.kind, promoted.roleId), (TeamChangeKind.memberRole, FixedRoles.admin));
    // The same role again with other grants is a change of access.
    expect(describe(RecordTypes.memberSet, {'uid': 'sam', 'role': 'on-call', 'grants': {}}).kind,
        TeamChangeKind.memberAccess);
    expect(describe(RecordTypes.memberSet, {'uid': 'sam', 'ends_at': 1800000000}).kind, TeamChangeKind.memberAccess);
    // An owner stepping down names themselves.
    expect(describe(RecordTypes.memberSet, {'uid': 'owner', 'role': FixedRoles.admin}).kind,
        TeamChangeKind.memberSteppedDown);

    final keys = describe(RecordTypes.memberKeys, {}, by: 'sam');
    expect((keys.kind, keys.member), (TeamChangeKind.memberKeys, 'sam'));
    expect(describe(RecordTypes.memberSuspend, {'uid': 'sam'}).kind, TeamChangeKind.memberSuspended);
    expect(describe(RecordTypes.memberResume, {'uid': 'sam'}).kind, TeamChangeKind.memberResumed);
    expect(describe(RecordTypes.memberRemove, {'uid': 'sam'}).kind, TeamChangeKind.memberRemoved);
    // Removing yourself is leaving.
    expect(describe(RecordTypes.memberRemove, {'uid': 'sam'}, by: 'sam').kind, TeamChangeKind.memberLeft);

    final crateKey = describe(RecordTypes.keyRotate, {'crate': 'prod', 'generation': 2});
    expect((crateKey.kind, crateKey.crateId), (TeamChangeKind.crateKey, 'prod'));
    expect(describe(RecordTypes.keyRotate, {'generation': 2}).kind, TeamChangeKind.orchardKey);
    expect(describe(RecordTypes.rulesSet, {}).kind, TeamChangeKind.rules);

    // Team recovery: on or off, and a member given their access back,
    // with the second owner who approved.
    expect(describe(RecordTypes.recoverySet, {'on': true}).kind, TeamChangeKind.teamRecoveryOn);
    expect(describe(RecordTypes.recoverySet, {'on': false}).kind, TeamChangeKind.teamRecoveryOff);
    expect(describe(RecordTypes.recoverySet, {}).kind, TeamChangeKind.teamRecoveryOff);
    final recovered = describe(RecordTypes.memberRecover, {'uid': 'sam', 'approver': 'owner2'});
    expect((recovered.kind, recovered.member, recovered.approver), (TeamChangeKind.memberRecovered, 'sam', 'owner2'));

    // A Crate's certificate authority, and what the team records.
    final ca = describe(RecordTypes.caSet, {'crate': 'prod', 'on': false});
    expect((ca.kind, ca.crateId), (TeamChangeKind.certificateAuthority, 'prod'));
    expect(describe(RecordTypes.trackingSet, {'history': true}).kind, TeamChangeKind.tracking);
    // Session logs, named on their own even beside another setting.
    final logsOn = describe(RecordTypes.crateSet, {'id': 'prod', 'session_logs': true, 'confirm_reveal': true});
    expect((logsOn.kind, logsOn.crateId), (TeamChangeKind.sessionLogsOn, 'prod'));
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'session_logs': false}).kind, TeamChangeKind.sessionLogsOff);
    // Watched sessions, named on their own too, with what the Crate
    // allows going off in the same entry.
    final watchedOn = describe(RecordTypes.crateSet, {'id': 'prod', 'watched': true, 'allow': <String>[]});
    expect((watchedOn.kind, watchedOn.crateId), (TeamChangeKind.watchedOn, 'prod'));
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'watched': false}).kind, TeamChangeKind.watchedOff);
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'watched': 'yes'}).kind, TeamChangeKind.crateSettings,
        reason: 'not a yes or a no: a change to its settings like any other');
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'allow': <String>[]}).kind, TeamChangeKind.crateSettings);
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'confirm_reveal': true}).kind, TeamChangeKind.crateSettings);
    // A Crate's own offline limit: named on its own, with
    // how long it is, also beside another setting; taken off; and what is
    // no number is a change to its settings like any other.
    final limited = describe(RecordTypes.crateSet, {'id': 'prod', 'offline_hours': 24});
    expect((limited.kind, limited.crateId, limited.hours), (TeamChangeKind.crateOfflineSet, 'prod', 24));
    final withMore = describe(RecordTypes.crateSet, {'id': 'prod', 'confirm_reveal': true, 'offline_hours': 8});
    expect((withMore.kind, withMore.hours), (TeamChangeKind.crateOfflineSet, 8));
    final lifted = describe(RecordTypes.crateSet, {'id': 'prod', 'offline_hours': 0});
    expect((lifted.kind, lifted.crateId, lifted.hours), (TeamChangeKind.crateOfflineOff, 'prod', null));
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'offline_hours': '24'}).kind, TeamChangeKind.crateSettings);
    // What the team tracks and oversees is named first where one entry
    // changes both.
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'session_logs': true, 'offline_hours': 24}).kind,
        TeamChangeKind.sessionLogsOn);
    expect(
        describe(RecordTypes.crateSet, {'id': 'prod', 'watched': true, 'allow': <String>[], 'offline_hours': 24}).kind,
        TeamChangeKind.watchedOn);
    // The other kinds carry no length.
    expect(watchedOn.hours, isNull);
    // Who connects with nobody watching while ZestSSH Cloud cannot be
    // reached: everyone, or owners alone again; named on
    // its own, after watching itself where one entry changes both and
    // before a limit; and what is no yes or no is a change like any other.
    final awayOn = describe(RecordTypes.crateSet, {'id': 'prod', 'unwatched_away': true});
    expect((awayOn.kind, awayOn.crateId, awayOn.at), (TeamChangeKind.unwatchedAwayOn, 'prod', null));
    final awayOff = describe(RecordTypes.crateSet, {'id': 'prod', 'unwatched_away': false});
    expect((awayOff.kind, awayOff.crateId), (TeamChangeKind.unwatchedAwayOff, 'prod'));
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'unwatched_away': 'yes'}).kind, TeamChangeKind.crateSettings);
    expect(
        describe(RecordTypes.crateSet, {'id': 'prod', 'watched': true, 'allow': <String>[], 'unwatched_away': true})
            .kind,
        TeamChangeKind.watchedOn);
    expect(describe(RecordTypes.crateSet, {'id': 'prod', 'unwatched_away': true, 'offline_hours': 24}).kind,
        TeamChangeKind.unwatchedAwayOn);
    // A member's report of a session that ran so: which Crate, and when by
    // their device's clock.
    final ran = describe(RecordTypes.sessionUnwatched, {'crate': 'prod', 'at': 1791504000, 'gen': 1, 'sealed': 'AAAA'},
        by: 'sam');
    expect((ran.kind, ran.by, ran.crateId, ran.at, ran.member),
        (TeamChangeKind.sessionUnwatched, 'sam', 'prod', 1791504000, null));
    final untimed = describe(RecordTypes.sessionUnwatched, {'crate': 'prod', 'at': 'noon'});
    expect((untimed.kind, untimed.at), (TeamChangeKind.sessionUnwatched, null));

    // Access until a set time: given, with when it ends; ended early
    // by someone else; given up by the member themselves.
    final given = describe(RecordTypes.accessGrant,
        {'uid': 'sam', 'crate': 'prod', 'switches': ['connect'], 'until': 1800000000, 'req': 'r-1'});
    expect((given.kind, given.member, given.crateId, given.until),
        (TeamChangeKind.accessGiven, 'sam', 'prod', 1800000000));
    final ended = describe(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod', 'until': 0});
    expect((ended.kind, ended.member, ended.crateId, ended.until), (TeamChangeKind.accessEnded, 'sam', 'prod', null));
    final givenUp = describe(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod', 'until': 0}, by: 'sam');
    expect((givenUp.kind, givenUp.member, givenUp.crateId), (TeamChangeKind.accessGivenUp, 'sam', 'prod'));
    // Without a time that is a number it is nothing this version words.
    expect(describe(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod'}).kind, TeamChangeKind.other);
    expect(describe(RecordTypes.accessGrant, {'uid': 'sam', 'crate': 'prod', 'until': '0'}).kind, TeamChangeKind.other);

    // Devices: approved or removed, by the member themselves or by
    // someone above them.
    const device = {'uid': 'sam', 'device': 'key', 'via': 'other', 'sig': 'sig'};
    final approved = describe(RecordTypes.deviceTrust, device);
    expect((approved.kind, approved.member), (TeamChangeKind.deviceApproved, 'sam'));
    final own = describe(RecordTypes.deviceTrust, device, by: 'sam');
    expect((own.kind, own.member), (TeamChangeKind.deviceApprovedOwn, 'sam'));
    final removed = describe(RecordTypes.deviceRevoke, device);
    expect((removed.kind, removed.member), (TeamChangeKind.deviceRemoved, 'sam'));
    final gaveUp = describe(RecordTypes.deviceRevoke, device, by: 'sam');
    expect((gaveUp.kind, gaveUp.member), (TeamChangeKind.deviceRemovedOwn, 'sam'));
  });

  // Vault access per member, and the Admin role, which showed as
  // "Made a change".
  test('a member set apart from their role in a vault, and the Admin role changed or put back, in words', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    String words(String type, Map<String, Object?> body) => teamChangeText(
          describeRecordEntry(_entry(type, body), before),
          l10n,
          nameOf: (uid) => '$uid@example.com',
          crateName: (id) => id == 'prod' ? 'Production' : '?',
          roleName: (id) => id,
        );
    List<String> level(CrateLevel l) => switchList(levelSwitches(l));
    const riley = 'riley@example.com';
    expect(words(RecordTypes.memberLimit, {'uid': 'riley', 'crate': 'prod', 'switches': level(CrateLevel.connect)}),
        l10n.teamChangeVaultSet(riley, 'Production', l10n.crateLevelConnect));
    expect(words(RecordTypes.memberLimit, {'uid': 'riley', 'crate': 'prod', 'switches': <String>[]}),
        l10n.teamChangeVaultTaken(riley, 'Production'));
    expect(words(RecordTypes.memberLimit, {'uid': 'riley', 'crate': 'prod'}), l10n.teamChangeVaultBack(riley, 'Production'));
    // Agent forwarding is in no level; a set of switches no level is, Custom.
    expect(
        words(RecordTypes.memberLimit,
            {'uid': 'riley', 'crate': 'prod', 'switches': [...level(CrateLevel.use), CrateSwitches.agent]}),
        l10n.teamChangeVaultSet(riley, 'Production', l10n.crateLevelUse));
    expect(words(RecordTypes.memberLimit, {'uid': 'riley', 'crate': 'prod', 'switches': ['connect']}),
        l10n.teamChangeVaultSet(riley, 'Production', l10n.crateLevelCustom));
    expect(words(RecordTypes.adminSet, {'can': <String>[], 'crates': <String, Object?>{}}), l10n.teamChangeAdminChanged);
    expect(words(RecordTypes.adminSet, {'all': true}), l10n.teamChangeAdminReset);
    expect(describe(RecordTypes.memberLimit, {'uid': 'riley', 'crate': 'prod', 'switches': 'all'}).kind,
        TeamChangeKind.other, reason: 'a body not of its shape reads as a change');
  });

  test('the author and the version of their keys come along', () {
    final c = describeRecordEntry(_entry(RecordTypes.rulesSet, {}, by: 'sam', seq: 12, version: 3), before);
    expect((c.seq, c.by, c.byKeyVersion), (12, 'sam', 3));
  });

  test('a body that is not what the type expects still reads as its kind', () {
    final c = describeRecordEntry(
      RecordEntry(
        seq: 1,
        prev: Uint8List(0),
        type: RecordTypes.memberRemove,
        bodyJson: 'not json',
        by: 'owner',
        byKeyVersion: 1,
        signature: Uint8List(0),
      ),
      before,
    );
    expect((c.kind, c.member), (TeamChangeKind.memberRemoved, null));
    expect(describe('some.future.type', {}).kind, TeamChangeKind.other);
  });

  test('teamChanges stops at an entry that will not replay, keeping those before', () async {
    // Entry 2 comes before any create: refused, so only entry 1 is worded.
    final changes = await teamChanges(_orchard, [
      _entry(RecordTypes.memberRemove, {'uid': 'nobody'}, seq: 1),
      _entry(RecordTypes.rulesSet, {}, seq: 2),
    ]);
    expect(changes.map((c) => c.kind), [TeamChangeKind.memberRemoved]);
  });
}

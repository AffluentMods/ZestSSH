// A session to a watched Crate's host with nobody watching (3.0;
// unwatched.dart): who may go on then by the record, what a reason
// and a host's name are as a report carries them, the report as it is
// written and read, and its seal, which nobody opens with another key or
// passes off as someone else's, about another Crate, or about another time.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart' show wrapUnderDek;
import 'package:zestssh/services/cloud/cloud_reach.dart';

import '../../sharing/share_fakes.dart';
import '../../sharing/share_world.dart';

void main() {
  setUpAll(makeWorldKeys);

  test('who may go on with nobody watching: an owner always, anyone else in the Orchard where the owners allowed it '
      'for the Crate', () {
    final record = teamRecord(orchardId, crateId, {
      'uid-dana': dana,
      'uid-sam': sam,
      'uid-noa': noa,
    }, levels: {
      'uid-dana': CrateLevel.manage,
      'uid-sam': CrateLevel.manage,
      'uid-noa': CrateLevel.connect,
    });
    record.members['uid-dana']!.role = FixedRoles.owner;
    record.crates[crateId]!
      ..watched = true
      ..allow.clear();
    expect(record.isOwner('uid-dana'), isTrue);
    expect(mayGoUnwatched(record, crateId, 'uid-dana'), isTrue);
    expect(mayGoUnwatched(record, crateId, 'uid-sam'), isFalse, reason: 'managing the Crate is not owning the Orchard');
    expect(mayGoUnwatched(record, crateId, 'uid-noa'), isFalse);
    expect(mayGoUnwatched(record, crateId, 'uid-eve'), isFalse, reason: 'not in the Orchard');
    // An owner, for a Crate the record does not have, too: it is theirs to
    // answer for.
    expect(mayGoUnwatched(record, 'another-crate', 'uid-dana'), isTrue);
    expect(mayGoUnwatched(record, 'another-crate', 'uid-noa'), isFalse);

    // The owners allowed it for the Crate: everyone in the Orchard.
    record.crates[crateId]!.unwatchedAway = true;
    expect(mayGoUnwatched(record, crateId, 'uid-sam'), isTrue);
    expect(mayGoUnwatched(record, crateId, 'uid-noa'), isTrue);
    expect(mayGoUnwatched(record, crateId, 'uid-eve'), isFalse, reason: 'still not in the Orchard');
    expect(mayGoUnwatched(record, 'another-crate', 'uid-noa'), isFalse, reason: 'for that Crate, and no other');
    // Someone suspended is not in it for now, an owner included.
    record.members['uid-noa']!.status = MemberStatus.suspended;
    record.members['uid-dana']!.status = MemberStatus.suspended;
    expect(mayGoUnwatched(record, crateId, 'uid-noa'), isFalse);
    expect(mayGoUnwatched(record, crateId, 'uid-dana'), isFalse);
    record.members['uid-noa']!.status = MemberStatus.removed;
    expect(mayGoUnwatched(record, crateId, 'uid-noa'), isFalse);
  });

  test('a reason and a host as a report carries them: one line, nothing blank around it, and no longer than it takes',
      () {
    expect(unwatchedReason('  the database is down,\n\n restoring   it\t now  '), 'the database is down, restoring it now');
    expect(unwatchedReason('x'), 'x');
    for (final none in ['', '   ', '\n\t \r\n']) {
      expect(unwatchedReason(none), isNull, reason: 'a reason is asked for');
    }
    final long = 'a' * (kUnwatchedReasonMax + 50);
    expect(unwatchedReason(long), 'a' * kUnwatchedReasonMax);
    expect(unwatchedReason('a' * kUnwatchedReasonMax), 'a' * kUnwatchedReasonMax);
    // Cut between characters, never in the middle of one that takes two
    // units to write.
    final faces = String.fromCharCodes(List.filled(kUnwatchedReasonMax + 5, 0x1F600));
    final cut = unwatchedReason(faces)!;
    expect(cut.runes.length, kUnwatchedReasonMax);
    expect(cut.runes.every((r) => r == 0x1F600), isTrue);
    expect(() => utf8.encode(cut), returnsNormally);

    expect(unwatchedHost('  db-primary \n (Production) '), 'db-primary (Production)');
    expect(unwatchedHost('h' * (kUnwatchedHostMax + 1)), 'h' * kUnwatchedHostMax);
    expect(unwatchedHost(''), '', reason: 'a host with no name is reported as that');
    // The lengths themselves: with both at their longest, in a script of
    // four bytes to the character, the host still fits what an entry takes.
    expect((kUnwatchedReasonMax, kUnwatchedHostMax), (300, 120));
  });

  test('a report as it is written and read: what it is not, it is not read as', () {
    const report = UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'down');
    expect(report.toJson(), {'v': 1, 'host': 'db-primary', 'reason': 'restoring the database', 'reach': 'down'});
    expect(UnwatchedReport.fromJson(report.toJson()), report);
    expect(UnwatchedReport.fromJson(jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>), report);
    expect(report, isNot(const UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'fault')));
    expect(report, isNot(const UnwatchedReport(host: 'db-primary', reason: 'another', reach: 'down')));
    expect(report, isNot(const UnwatchedReport(host: 'web-01', reason: 'restoring the database', reach: 'down')));
    expect(report.hashCode,
        const UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'down').hashCode);
    for (final bad in <Map<String, Object?>>[
      {},
      {...report.toJson(), 'v': 2},
      {...report.toJson()}..remove('v'),
      {...report.toJson(), 'host': 7},
      {...report.toJson(), 'reason': null},
      {...report.toJson()}..remove('reach'),
    ]) {
      expect(UnwatchedReport.fromJson(bad), isNull, reason: '$bad');
    }
  });

  test('how the service stood, as a report writes and reads it: what the app found, and the status of a fault',
      () {
    expect(unwatchedReach(const CloudReachState(CloudReach.notResponding)), 'notResponding');
    expect(unwatchedReach(const CloudReachState(CloudReach.deviceOffline)), 'deviceOffline');
    expect(unwatchedReach(const CloudReachState(CloudReach.fault, status: 503)), 'fault 503');
    expect(unwatchedReach(const CloudReachState(CloudReach.down, status: 502)), 'down 502');
    expect(unwatchedReach(const CloudReachState(CloudReach.down)), 'down');
    // Read back as the state it was, every one of them, with a status and
    // without.
    for (final reach in CloudReach.values) {
      for (final status in [null, 500, 599]) {
        final state = CloudReachState(reach, status: status);
        final read = unwatchedReachRead(unwatchedReach(state))!;
        expect((read.reach, read.status), (reach, status), reason: '$state');
      }
    }
    // What this app does not know, or what is no such thing, is none.
    for (final other in ['', 'somethingNew', 'somethingNew 503', 'fault x', 'fault 503 more', 'Fault', ' fault']) {
      expect(unwatchedReachRead(other), isNull, reason: '"$other"');
    }
  });

  test('the seal: opened with the key of the Crate, for the one who reported, the Crate and the time it names, and '
      'in no other way', () async {
    final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
    final other = Uint8List.fromList(List.generate(32, (i) => 99 - i));
    final json = const UnwatchedReport(host: 'db-primary', reason: 'restoring the database', reach: 'down').toJson();
    Future<Uint8List> seal() => sealUnwatchedReport(json, key,
        orchardId: orchardId, crateId: crateId, uid: 'uid-noa', at: 1791504000, generation: 2);
    Future<Map<String, Object?>> open(
      List<int> sealed, {
      List<int>? with_,
      String orchard = orchardId,
      String crate = crateId,
      String uid = 'uid-noa',
      int at = 1791504000,
      int generation = 2,
    }) =>
        openUnwatchedReport(sealed, with_ ?? key, orchardId: orchard, crateId: crate, uid: uid, at: at, generation: generation);

    final sealed = await seal();
    expect(await open(sealed), json);
    expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('db-primary')), reason: 'nothing of it is readable');
    expect(utf8.decode(sealed, allowMalformed: true), isNot(contains('restoring')));
    expect(await seal(), isNot(sealed), reason: 'sealed afresh each time');

    final refused = throwsA(isA<SecretBoxAuthenticationError>());
    await expectLater(open(sealed, with_: other), refused);
    await expectLater(open(sealed, uid: 'uid-sam'), refused, reason: "passed off as someone else's");
    await expectLater(open(sealed, crate: 'another-crate'), refused, reason: 'as one about another Crate');
    await expectLater(open(sealed, at: 1791504001), refused, reason: 'as one about another time');
    await expectLater(open(sealed, generation: 1), refused);
    await expectLater(open(sealed, orchard: 'another-orchard'), refused);
    final changed = Uint8List.fromList(sealed)..[sealed.length ~/ 2] ^= 1;
    await expectLater(open(changed), refused);
    // Something sealed with the key that is no report at all.
    final list = await wrapUnderDek(utf8.encode('[1,2]'), key,
        purpose: 'zestssh.unwatched.v1|$orchardId|$crateId|uid-noa|1791504000|2');
    await expectLater(open(list), throwsFormatException);
    expect(await open(list).then<Object?>((v) => v).catchError((Object _) => null), isNull);
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/members/team_recovery.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Team recovery approvals (3.0): the exact bytes an approval
/// covers (the server checks the same: ZestSSH Cloud's
/// test/team_recovery_lib.test.js holds the same vector), a signature that
/// checks only for those keys, that approver and that Orchard, and a member
/// verification that is never an approval.
void main() {
  const vector =
      '000000187a6573747373682e7465616d2d7265636f766572792e76310000002431313131313131312d313131312d343131312d38'
      '3131312d313131313131313131313131000000097569642d616c6963650000000200000020000102030405060708090a0b0c0d0e0f'
      '101112131415161718191a1b1c1d1e1f0000000a7569642d6f776e65723200000001';

  String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  test('the bytes an approval covers', () {
    final message = teamRecoveryMessage(
      orchardId: '11111111-1111-4111-8111-111111111111',
      subjectUid: 'uid-alice',
      subjectKeyVersion: 2,
      fingerprint: List<int>.generate(32, (i) => i),
      approverUid: 'uid-owner2',
      approverKeyVersion: 1,
    );
    expect(hex(message), vector);
  });

  group('an approval', () {
    late AccountKeys owner2;
    late PublishedAccountKeys alice2;
    late PublishedAccountKeys alice3;
    const orchard = '11111111-1111-4111-8111-111111111111';

    setUpAll(() async {
      owner2 = await AccountKeys.fromSeeds(
          encryptionSeed: List<int>.filled(32, 0x33), signingSeed: List<int>.filled(32, 0x34), version: 1, createdAt: 1790000051);
      alice2 = await (await AccountKeys.fromSeeds(
              encryptionSeed: List<int>.filled(32, 0x41), signingSeed: List<int>.filled(32, 0x42), version: 2, createdAt: 1790000065))
          .publish('uid-alice');
      alice3 = await (await AccountKeys.fromSeeds(
              encryptionSeed: List<int>.filled(32, 0x43), signingSeed: List<int>.filled(32, 0x44), version: 3, createdAt: 1790000067))
          .publish('uid-alice');
    });

    Future<bool> check(Uint8List approval,
            {String orchardId = orchard, PublishedAccountKeys? keys, String approverUid = 'uid-owner2', int approverVersion = 1}) =>
        verifyTeamRecovery(
          owner2.signingPublicKey,
          approval,
          orchardId: orchardId,
          subjectUid: (keys ?? alice2).uid,
          subjectKeyVersion: (keys ?? alice2).version,
          fingerprint: (keys ?? alice2).fingerprint,
          approverUid: approverUid,
          approverKeyVersion: approverVersion,
        );

    test('checks for those keys, that approver, that Orchard', () async {
      final approval = await signTeamRecovery(owner2, approverUid: 'uid-owner2', orchardId: orchard, subject: alice2);
      expect(await check(approval), isTrue);
      expect(await check(approval, keys: alice3), isFalse, reason: 'other keys');
      expect(await check(approval, orchardId: '22222222-2222-4222-8222-222222222222'), isFalse, reason: 'another Orchard');
      expect(await check(approval, approverUid: 'uid-owner'), isFalse, reason: 'claimed by another owner');
      expect(await check(approval, approverVersion: 2), isFalse, reason: 'another key version');
      expect(await check(Uint8List.fromList(approval.sublist(0, 63))), isFalse, reason: 'cut short');
    });

    test('a member verification of the very same keys is no approval', () async {
      final verification =
          await signMemberVerification(owner2, verifierUid: 'uid-owner2', orchardId: orchard, subject: alice2);
      expect(await check(verification), isFalse);
    });
  });
}

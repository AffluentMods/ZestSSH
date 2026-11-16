import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// How far a device trusts each member's keys (3.0): pinned
/// when first seen, a change followed only along the record's chain of
/// vouched versions, anything else a hard stop until someone compares and
/// accepts, and "verified by N" counted only from statements this device can
/// check itself.
void main() {
  const orchard = '11111111-1111-4111-8111-111111111111';

  Future<AccountKeys> seeded(int ed, int x, int version, int createdAt) => AccountKeys.fromSeeds(
        encryptionSeed: List.filled(32, x),
        signingSeed: List.filled(32, ed),
        version: version,
        createdAt: createdAt,
      );

  test('the statement bytes match the server byte for byte', () async {
    // Subject: the version 2 vector keys (0x0b / 0x0d) as uid-subject;
    // checked by the version 1 vector account (uid-vector, 0x07). Pinned in
    // ZestSSH Cloud's test/db/member_verifications_routes.test.js too.
    final subject = await (await seeded(0x0b, 0x0d, 2, 1790000600)).publish('uid-subject');
    expect(subject.fingerprint.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        '526ef8255defa10725721ed23d74be1549f58ce3baa7b5ff711ab3df830e6b54');
    final message = memberVerificationMessage(
      orchardId: orchard,
      subjectUid: 'uid-subject',
      subjectKeyVersion: 2,
      fingerprint: subject.fingerprint,
      verifierUid: 'uid-vector',
      verifierKeyVersion: 1,
    );
    expect(message.length, 147);
    expect(sha256.convert(message).toString(),
        'a37dc1fbea5e433ed7f9ad16617d745040a19b15d71fe738d789c7800ae9250a');
    final verifier = await seeded(0x07, 0x09, 1, 1790000000);
    final signature = await signMemberVerification(verifier,
        verifierUid: 'uid-vector', orchardId: orchard, subject: subject);
    expect(base64Encode(signature),
        'OHZfcxSKbJfp1OKdDJmFJwxAVcxSsOaGD88DCqxbbg/YBsQNidAxsyfcJ5tkFP1BIxpAQntq5r/2bp4pxgvJBg==');
  });

  group('following a member\'s keys along the record', () {
    late AccountKeys v1;
    late AccountKeys v2;
    late AccountKeys v3;
    late PublishedAccountKeys p1;
    late PublishedAccountKeys p2;
    late PublishedAccountKeys p3;

    setUpAll(() async {
      v1 = await AccountKeys.generate(version: 1);
      v2 = await AccountKeys.generate(version: 2);
      v3 = await AccountKeys.generate(version: 3);
      p1 = await v1.publish('alice');
      p2 = await v2.publish('alice');
      p3 = await v3.publish('alice');
    });

    RecordKeys held(PublishedAccountKeys k) => RecordKeys(
          version: k.version,
          signingKey: k.signingKey,
          encryptionKey: k.encryptionKey,
          createdAt: k.createdAt,
          selfSignature: k.signature,
        );

    /// Alice as the record holds her: every version it took, by number.
    RecordMember alice(List<PublishedAccountKeys> versions) => RecordMember(
          uid: 'alice',
          role: 'member',
          keys: {for (final k in versions) k.version: held(k)},
          since: 2,
        );

    test('first sight pins, and the same keys change nothing', () {
      final (pin, change) = applyRecordKeys(null, alice([p1]));
      expect(change, MemberKeyChange.pinned);
      expect(pin!.keyVersion, 1);
      expect(pin.verifiedByMe, isFalse);
      final (again, same) = applyRecordKeys(pin, alice([p1]));
      expect(same, MemberKeyChange.none);
      expect(again!.hardStop, isFalse);
    });

    test('keys the record took one version after another are followed; what was compared shows as replaced',
        () {
      final pin = PinnedMember.fromKeys(p1, verifiedByMe: true);
      final (moved, change) = applyRecordKeys(pin, alice([p1, p2, p3]));
      expect(change, MemberKeyChange.followed);
      expect(moved!.keyVersion, 3);
      expect(moved.signingKey, p3.signingKey);
      expect(moved.verifiedByMe, isFalse, reason: 'the comparison was of version 1');
      expect(moved.replacedSinceCompared, isTrue);
      // Nobody compared before: nothing to say about a replacement.
      final (plain, _) = applyRecordKeys(PinnedMember.fromKeys(p1), alice([p1, p2]));
      expect((plain!.verifiedByMe, plain.replacedSinceCompared), (false, false));
      // Replaced again before anyone compared: still amber.
      final (twice, _) = applyRecordKeys(PinnedMember.fromKeys(p1, verifiedByMe: true).copyWith(), alice([p1, p2]));
      final (later, _) = applyRecordKeys(twice, alice([p1, p2, p3]));
      expect((later!.keyVersion, later.replacedSinceCompared), (3, true));
      // The same keys again change nothing.
      final (same, none) = applyRecordKeys(later, alice([p1, p2, p3]));
      expect((none, same!.replacedSinceCompared), (MemberKeyChange.none, true));
    });

    test('someone added again with other keys is a hard stop, and the pinned key stays', () {
      final pin = PinnedMember.fromKeys(p1, verifiedByMe: true);
      // Removed, then added again: the record holds only the keys they came
      // back with.
      final (kept, change) = applyRecordKeys(pin, alice([p2]));
      expect(change, MemberKeyChange.hardStop);
      expect(kept!.keyVersion, 1);
      expect(kept.signingKey, p1.signingKey);
      expect(kept.pending!.version, 2);
      // Seen again: still the same stop, not a new one.
      final (still, again) = applyRecordKeys(kept, alice([p2]));
      expect(again, MemberKeyChange.none);
      expect(still!.hardStop, isTrue);
    });

    test('other keys under the pinned version, or an older version than the pin, is a hard stop', () async {
      final other = await (await AccountKeys.generate(version: 1)).publish('alice');
      expect(applyRecordKeys(PinnedMember.fromKeys(p1), alice([other, p2])).$2, MemberKeyChange.hardStop);
      expect(applyRecordKeys(PinnedMember.fromKeys(p1), alice([other])).$2, MemberKeyChange.hardStop);
      expect(applyRecordKeys(PinnedMember.fromKeys(p2), alice([p1])).$2, MemberKeyChange.hardStop);
    });

    test('accepting a hard stop after comparing pins the new keys as verified', () {
      final (kept, _) = applyRecordKeys(PinnedMember.fromKeys(p1), alice([p2]));
      final accepted = acceptPending(kept!);
      expect(accepted.keyVersion, 2);
      expect(accepted.hardStop, isFalse);
      expect(accepted.verifiedByMe, isTrue);
      expect(accepted.replacedSinceCompared, isFalse);
    });
  });

  test('verified by: only statements this device can check, for the pinned keys', () async {
    final me = await AccountKeys.generate();
    final bobKeys = await AccountKeys.generate();
    final carolKeys = await AccountKeys.generate();
    final alice = await (await AccountKeys.generate()).publish('alice');
    final bob = await bobKeys.publish('bob');
    final subject = PinnedMember.fromKeys(alice);
    final pins = {
      'alice': subject,
      'bob': PinnedMember.fromKeys(bob),
      // Carol's pinned key is not the one that signs below.
      'carol': PinnedMember.fromKeys(await (await AccountKeys.generate()).publish('carol')),
    };
    Future<MemberCheck> check(String by, AccountKeys keys, {int keyVersion = 1}) async => MemberCheck(
          by: by,
          byKeyVersion: keys.version,
          keyVersion: keyVersion,
          signature: await signMemberVerification(keys, verifierUid: by, orchardId: orchard, subject: alice),
        );
    final checks = [
      await check('me', me),
      await check('bob', bobKeys),
      await check('carol', carolKeys),
      await check('dave', await AccountKeys.generate()), // not a pinned member
      MemberCheck(by: 'bob', byKeyVersion: 1, keyVersion: 7, signature: Uint8List(64)),
    ];
    final by = await verifiedBy(
        orchardId: orchard, subject: subject, checks: checks, pins: pins, myUid: 'me', myKeys: me);
    expect(by, ['me', 'bob']);
  });

  test('a fingerprint reads as 12 groups of 5 digits', () {
    final text = formatFingerprint(List.filled(32, 0xab));
    expect(text, matches(RegExp(r'^(\d{5} ){11}\d{5}$')));
    expect(formatFingerprint(List.filled(32, 0xab)), text, reason: 'the same for everyone');
    expect(formatFingerprint(List.filled(32, 0xac)), isNot(text));
  });
}

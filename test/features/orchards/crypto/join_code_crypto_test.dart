import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/teams/crypto/user_keypair.dart';

// Invite codes: the code, what is derived from
// it, and the two tags. The vector is the one the server's tests use
// (ZestSSH Cloud's test/db/join_codes_routes.test.js), so a device and the
// server's stand-in for one derive and tag alike.

String hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

void main() {
  const code = 'ZESTABCDEFGHJKLMNPQRSTUV';
  final maker = JoinCodeParty(
      uid: 'uid-maker', keyVersion: 2, signingKey: List.filled(32, 0x11), encryptionKey: List.filled(32, 0x22));
  final joiner = JoinCodeParty(
      uid: 'uid-joiner', keyVersion: 1, signingKey: List.filled(32, 0x33), encryptionKey: List.filled(32, 0x44));
  const grants = {
    'c2': {'use', 'connect'},
    'c1': {'sftp'},
  };

  test('a new code: ZEST and 20 characters of the alphabet, written in five groups of four', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final c = newJoinCode();
      expect(c, matches(RegExp('^ZEST[$kJoinCodeAlphabet]{20}\$')));
      seen.add(c);
    }
    expect(seen.length, 200, reason: 'random');
    expect(writtenJoinCode(code), 'ZEST-ABCD-EFGH-JKLM-NPQR-STUV');
    expect(shortJoinCode(code), 'ZEST-ABCD…');
    // No 0, O, 1 or I can ever be in one.
    expect(kJoinCodeAlphabet.contains(RegExp('[01OI]')), isFalse);
    expect(kJoinCodeAlphabet.length, 32);
    // Every character is as likely (the bytes are taken modulo 32).
    final counts = <String, int>{};
    final rng = Random(7);
    for (var i = 0; i < 2000; i++) {
      for (final ch in newJoinCode(random: rng).substring(4).split('')) {
        counts[ch] = (counts[ch] ?? 0) + 1;
      }
    }
    expect(counts.length, 32);
  });

  test('typed, pasted or scanned: any case, spaces and dashes, with or without ZEST, or its link', () {
    expect(normalJoinCode('zest-abcd-efgh-jklm-npqr-stuv'), code);
    expect(normalJoinCode(' ZEST ABCD EFGH JKLM NPQR STUV '), code);
    expect(normalJoinCode('abcdefghjklmnpqrstuv'), code);
    expect(normalJoinCode('ABCD-EFGH-JKLM-NPQR-STU'), isNull, reason: 'one short');
    expect(normalJoinCode('ABCD-EFGH-JKLM-NPQR-STU0'), isNull, reason: 'a 0 is never in a code');
    expect(normalJoinCode('ZEST-ABCD-EFGH-JKLM'), isNull, reason: 'the shape of a redemption code');
    expect(joinCodeFromText('https://zestssh.com/join#ZEST-ABCD-EFGH-JKLM-NPQR-STUV'), code);
    expect(joinCodeFromText('zestssh://join#ZEST-ABCD-EFGH-JKLM-NPQR-STUV'), code);
    expect(joinCodeFromText('zestssh://join?code=zest-abcd-efgh-jklm-npqr-stuv'), code);
    expect(joinCodeFromText('https://evil.example/join#ZEST-ABCD-EFGH-JKLM-NPQR-STUV'), isNull);
    expect(joinCodeFromText('zestssh://share?d=abc'), isNull);
    expect(joinCodeLink(code), 'https://zestssh.com/join#ZEST-ABCD-EFGH-JKLM-NPQR-STUV');
  });

  test('derived keys and tags match the shared vector', () async {
    final keys = await joinCodeKeys(code);
    expect(keys.lookupHex, '8f34209496b8b3b10978ce8528a2c80b');
    expect(hex(keys.macKey), 'ec3fce46c6bf0c0f504ec621c8b52fa48078889dfd00d17069164f47112f7ff8');
    expect(hex(keys.offerKey), '37039391d1b3a70253e8b47f26e6b74332df19f3befb0302977915a7297b137a');
    expect(canonicalGrants(grants), '{"c1":["sftp"],"c2":["connect","use"]}');
    final owner = ownerTranscript(
        orchardId: 'o-1', inviteId: 'i-1', lookupId: keys.lookupId, maker: maker, role: 'member', grants: grants,
        endsAt: 1900000000);
    expect(hex(await joinCodeTag(keys.macKey, owner)),
        '4d0441ca36ee1483830d71d754cb57234f96c9e0272f9b4ce46c4ea6408ef394');
    final join = joinerTranscript(orchardId: 'o-1', inviteId: 'i-1', lookupId: keys.lookupId, maker: maker, joiner: joiner);
    expect(hex(await joinCodeTag(keys.macKey, join)),
        'c93e28cc1cc065804cd891d5dcc9e1f5b9374e7de7ed24281f7395e3d0faebeb');
  });

  test('a tag fails for any other code, team, invitation, keys or offer', () async {
    final keys = await joinCodeKeys(code);
    Uint8List t({String orchard = 'o-1', String invite = 'i-1', JoinCodeParty? by, String role = 'member', int? ends = 1}) =>
        ownerTranscript(
            orchardId: orchard, inviteId: invite, lookupId: keys.lookupId, maker: by ?? maker, role: role,
            grants: grants, endsAt: ends);
    final tag = await joinCodeTag(keys.macKey, t());
    expect(await joinCodeTagMatches(keys.macKey, t(), tag), isTrue);
    expect(await joinCodeTagMatches(keys.macKey, t(orchard: 'o-2'), tag), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(invite: 'i-2'), tag), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(by: joiner), tag), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(role: 'admin'), tag), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(ends: null), tag), isFalse);
    final other = await joinCodeKeys(newJoinCode());
    expect(await joinCodeTagMatches(other.macKey, t(), tag), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(), null), isFalse);
    expect(await joinCodeTagMatches(keys.macKey, t(), Uint8List(31)), isFalse);
  });

  test('the offer opens only with the code, for that team and invitation', () async {
    final keys = await joinCodeKeys(code);
    const offer = JoinOffer(team: 'Platform team', role: 'Member', vaults: [JoinOfferVault('Shared', 'use')]);
    final sealed = await sealJoinOffer(offer, keys.offerKey, orchardId: 'o-1', inviteId: 'i-1');
    final opened = await openJoinOffer(sealed, keys.offerKey, orchardId: 'o-1', inviteId: 'i-1');
    expect(opened.team, 'Platform team');
    expect(opened.vaults.single.level, 'use');
    await expectLater(openJoinOffer(sealed, keys.offerKey, orchardId: 'o-1', inviteId: 'i-2'), throwsA(anything));
    final other = await joinCodeKeys(newJoinCode());
    await expectLater(openJoinOffer(sealed, other.offerKey, orchardId: 'o-1', inviteId: 'i-1'), throwsA(anything));
  });

  // The copy kept for the maker's devices is signed by the maker: anyone can
  // seal to a public key (found in a security
  // review).
  group('the code as its maker made it', () {
    late AccountKeys me;
    late Uint8List sealed;

    Future<Uint8List> seal(AccountKeys by, {String invite = 'i-1', int uses = 1}) => sealMadeJoinCode(code,
        makerEncryptionKey: me.encryption.publicKey,
        sign: by.sign,
        orchardId: 'o-1',
        inviteId: invite,
        usesMax: uses,
        role: 'member',
        grants: grants,
        endsAt: 1900000000);

    Future<MadeJoinCode?> open(List<int> s, {AccountKeys? as, String invite = 'i-1'}) =>
        openMadeJoinCode((as ?? me).encryption, me.signingPublicKey, s, orchardId: 'o-1', inviteId: invite);

    setUp(() async {
      me = await AccountKeys.generate();
      sealed = await seal(me, uses: 10);
    });

    test('opens for its maker with how many it is for and what it offers', () async {
      final made = (await open(sealed))!;
      expect(made.code, code);
      expect(made.usesMax, 10);
      expect(await made.offers(role: 'member', grants: grants, endsAt: 1900000000), isTrue);
      expect(await made.offers(role: 'admin', grants: grants, endsAt: 1900000000), isFalse);
      expect(await made.offers(role: 'member', grants: const {}, endsAt: 1900000000), isFalse);
      expect(await made.offers(role: 'member', grants: grants, endsAt: null), isFalse);
      // The same vaults in another order are the same offer.
      expect(
          await made.offers(role: 'member', grants: const {'c1': {'sftp'}, 'c2': {'connect', 'use'}}, endsAt: 1900000000),
          isTrue);
    });

    test('not for someone else, nor for another invitation', () async {
      expect(await open(sealed, as: await AccountKeys.generate()), isNull);
      expect(await open(sealed, invite: 'i-2'), isNull);
    });

    test('one sealed to the maker by anyone else does not count as the maker\'s', () async {
      // Signed by another account's key.
      expect(await open(await seal(await AccountKeys.generate())), isNull);
      // The form an older version kept: the code alone, unsigned.
      final older = await sealTo(me.encryption.publicKey, utf8.encode(code), context: 'zestssh.join-code.code.v1|o-1|i-1');
      expect(await open(older), isNull);
      // The maker's own, with how many it is for changed and the signature kept.
      final clear = jsonDecode(utf8.decode(
          await openSealed(me.encryption, sealed, context: 'zestssh.join-code.made.v2|o-1|i-1'))) as Map<String, Object?>;
      final changed = await sealTo(me.encryption.publicKey, utf8.encode(jsonEncode({...clear, 'uses_max': 1})),
          context: 'zestssh.join-code.made.v2|o-1|i-1');
      expect(await open(changed), isNull);
    });

    test('fits the 512 bytes ZestSSH Cloud keeps for it, with many vaults', () async {
      final many = {for (var i = 0; i < 40; i++) 'crate-$i-0000-0000-0000-000000000000': {'connect', 'use', 'edit', 'manage'}};
      final big = await sealMadeJoinCode(code,
          makerEncryptionKey: me.encryption.publicKey,
          sign: me.sign,
          orchardId: 'o-1',
          inviteId: 'i-1',
          usesMax: 100,
          role: '00000000-0000-0000-0000-000000000000',
          grants: many,
          endsAt: 9007199254740991);
      expect(big.length, lessThanOrEqualTo(512));
    });
  });
}
